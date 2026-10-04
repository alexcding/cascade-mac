use std::{
    collections::{HashMap, HashSet},
    fs,
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use futures_util::future::BoxFuture;
use tokio::{
    process::Child,
    sync::{mpsc, oneshot},
};
use crate::agents::Agent;
use crate::cli::shell_quote;
use crate::settings_file::{read_json, write_json};
use crate::{cli, error::ApiError, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

/// The webhook forwarders' handle: one `gh webhook forward` child per repo an armed PR pipeline
/// covers. Every method is a message to the one task (`Forwarders`) that owns the children and
/// their backoff. That task never awaits while it handles a message, so the list, the statuses
/// and a retry are answered between reconciles, never behind one.
#[derive(Clone)]
pub struct ForwarderManager {
    tx: mpsc::UnboundedSender<ForwarderMsg>,
}

/// What the reconcile loop asks each tick: the repos whose webhooks to forward.
pub type Wanted = Arc<dyn Fn(AppState) -> BoxFuture<'static, HashSet<String>> + Send + Sync>;

enum ForwarderMsg {
    /// Run the reconcile loop. Once.
    Start(AppState, u16, Wanted),
    /// Bring the children in line with the repos wanted; answers the log lines to write.
    Reconcile {
        desired: HashSet<String>,
        port: u16,
        reply: oneshot::Sender<Vec<LogLine>>,
    },
    List(oneshot::Sender<Vec<String>>),
    Statuses(oneshot::Sender<HashMap<String, ForwarderStatus>>),
    Retry(String),
    Stop(oneshot::Sender<()>),
}

/// A webhook log line, as `Database::add_log("webhook", ..)` takes it. A diagnostic log, not
/// activity: it is never broadcast to the apps (the Node backend kept webhook logs off the
/// activity stream too).
struct LogLine {
    level: &'static str,
    kind: &'static str,
    payload: Value,
}

/// The forwarders' state, owned by their task. Nothing else sees it.
#[derive(Default)]
struct Forwarders {
    started: bool,
    stopped: bool,
    children: HashMap<String, Forwarder>,
    /// Repos whose forwarder keeps dying on start, with when to try again.
    backoff: HashMap<String, Backoff>,
}

struct Forwarder {
    child: Child,
    since: Instant,
    /// The head and tail of the child's stderr. A reader task drains the pipe for as long as the
    /// forwarder runs: an undrained pipe fills and blocks `gh` mid-run, which `try_wait` would never see.
    stderr: Arc<std::sync::Mutex<String>>,
}

/// Keep the first and last of a forwarder's stderr, for the failure it is about to report: `gh`
/// prints why it failed to start at the top, and why a running forwarder died at the bottom.
const STDERR_HEAD: usize = 512;
const STDERR_TAIL: usize = 2048;

/// Drop the middle of a forwarder's stderr once it outgrows what is kept.
fn trim_stderr(text: &mut String) {
    if text.len() <= STDERR_HEAD + STDERR_TAIL {
        return;
    }
    let start = (0..=STDERR_HEAD).rev().find(|i| text.is_char_boundary(*i)).unwrap_or(0);
    let end = (text.len() - STDERR_TAIL..text.len()).find(|i| text.is_char_boundary(*i)).unwrap_or(text.len());
    text.replace_range(start..end, "\n…\n");
}

struct Backoff {
    failures: u32,
    retry_at: Instant,
    /// Why the last start failed, for Settings to show beside the repo.
    reason: String,
    /// The repo already has a `gh webhook forward` hook, which only removing it clears.
    hook_exists: bool,
}

/// GitHub allows one `cli` hook per repo. `gh webhook forward` never deletes the one it creates:
/// it leaves that to GitHub's relay when the connection drops, and a crash, a sleep or an app
/// replaced mid-run can leave one behind that blocks every later forwarder on the repo.
fn is_hook_conflict(stderr: &str) -> bool {
    stderr.contains("Hook already exists")
}

/// The ids of the hooks `gh webhook forward` made, from `GET repos/{repo}/hooks`.
pub(crate) fn forwarder_hook_ids(hooks: &Value) -> Vec<i64> {
    hooks
        .as_array()
        .into_iter()
        .flatten()
        .filter(|hook| {
            hook["name"] == "cli"
                && hook["config"]["url"].as_str().is_some_and(|url| url.contains("webhook-forwarder.github.com"))
        })
        .filter_map(|hook| hook["id"].as_i64())
        .collect()
}

/// A repo's forwarder as Settings shows it.
pub struct ForwarderStatus {
    pub state: &'static str,
    pub error: Option<String>,
}

/// A forwarder that exits sooner than this failed to start (e.g. the `gh webhook` extension is
/// not installed) rather than dropping a working connection.
const QUICK_EXIT: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(15 * 60);

/// How long to wait before starting a repo's forwarder again after `failures` quick exits in a row.
fn backoff_delay(failures: u32) -> Duration {
    Duration::from_secs(10u64.saturating_mul(1u64 << failures.min(10))).min(MAX_BACKOFF)
}

/// Why a forwarder that died on start failed, from its stderr. `gh` prints the error first and its
/// usage after it, so the usage — a wall of flags that pushed the error out of the log — is dropped.
fn failure_reason(stderr: &str) -> String {
    let usage = if stderr.starts_with("Usage:") { Some(0) } else { stderr.find("\nUsage:") };
    let error = usage.map_or(stderr, |at| &stderr[..at]).trim();
    let reason = if error.is_empty() { stderr.trim() } else { error };
    reason.chars().rev().take(500).collect::<Vec<_>>().into_iter().rev().collect()
}

impl Default for ForwarderManager {
    fn default() -> Self {
        Self::new()
    }
}

impl ForwarderManager {
    /// Made inside a Tokio runtime: the forwarders are a task.
    pub fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(Forwarders::default().run(rx));
        Self { tx }
    }

    /// Runs the reconcile loop: every ten seconds, the children are brought in line with what
    /// `wanted` answers. Once.
    pub fn start(&self, app: AppState, port: u16, wanted: Wanted) {
        let _ = self.tx.send(ForwarderMsg::Start(app, port, wanted));
    }

    /// Brings the children in line with `desired`; answers the log lines to write.
    async fn reconcile(&self, desired: HashSet<String>, port: u16) -> Vec<LogLine> {
        let (reply, logs) = oneshot::channel();
        let message = ForwarderMsg::Reconcile { desired, port, reply };
        if self.tx.send(message).is_err() {
            return Vec::new();
        }
        logs.await.unwrap_or_default()
    }

    pub async fn list(&self) -> Vec<String> {
        let (reply, list) = oneshot::channel();
        if self.tx.send(ForwarderMsg::List(reply)).is_err() {
            return Vec::new();
        }
        list.await.unwrap_or_default()
    }

    /// Each repo with a forwarder running or failing, by repo. A repo that is wanted but in
    /// neither is about to start.
    pub async fn statuses(&self) -> HashMap<String, ForwarderStatus> {
        let (reply, statuses) = oneshot::channel();
        if self.tx.send(ForwarderMsg::Statuses(reply)).is_err() {
            return HashMap::new();
        }
        statuses.await.unwrap_or_default()
    }

    /// Start the repo's forwarder on the next reconcile instead of waiting out its backoff.
    pub async fn retry(&self, repo: &str) {
        let _ = self.tx.send(ForwarderMsg::Retry(repo.to_owned()));
    }

    /// Kills every forwarder and starts none again; returns once they are told to go.
    pub async fn stop(&self) {
        let (reply, stopped) = oneshot::channel();
        if self.tx.send(ForwarderMsg::Stop(reply)).is_ok() {
            let _ = stopped.await;
        }
    }
}

impl Forwarders {
    async fn run(mut self, mut rx: mpsc::UnboundedReceiver<ForwarderMsg>) {
        while let Some(message) = rx.recv().await {
            self.handle(message);
        }
        // Reached only when the loop was never started, as its tick task holds a handle: the
        // children are killed on drop. A started actor ends with the runtime, after `Stop`.
    }

    fn handle(&mut self, message: ForwarderMsg) {
        match message {
            ForwarderMsg::Start(app, port, wanted) => self.start(app, port, wanted),
            ForwarderMsg::Reconcile { desired, port, reply } => {
                let _ = reply.send(self.reconcile(desired, port));
            }
            ForwarderMsg::List(reply) => {
                let mut repos: Vec<String> = self.children.keys().cloned().collect();
                repos.sort();
                let _ = reply.send(repos);
            }
            ForwarderMsg::Statuses(reply) => {
                let _ = reply.send(self.statuses());
            }
            ForwarderMsg::Retry(repo) => {
                self.backoff.remove(&repo);
            }
            ForwarderMsg::Stop(reply) => {
                self.stopped = true;
                for forwarder in self.children.values_mut() {
                    let _ = forwarder.child.start_kill();
                }
                self.children.clear();
                self.backoff.clear();
                let _ = reply.send(());
            }
        }
    }

    fn start(&mut self, app: AppState, port: u16, wanted: Wanted) {
        if self.started {
            return;
        }
        self.started = true;
        let manager = app.forwarders.clone();
        tokio::spawn(async move {
            loop {
                let desired = wanted(app.clone()).await;
                for line in manager.reconcile(desired, port).await {
                    let _ = app.db.add_log("webhook", line.level, line.kind, &line.payload).await;
                }
                tokio::time::sleep(Duration::from_secs(10)).await;
            }
        });
    }

    fn statuses(&self) -> HashMap<String, ForwarderStatus> {
        let mut statuses = HashMap::new();
        for (repo, entry) in &self.backoff {
            let state = if entry.hook_exists { "hookExists" } else { "retrying" };
            statuses.insert(repo.clone(), ForwarderStatus { state, error: Some(entry.reason.clone()) });
        }
        for repo in self.children.keys() {
            statuses.insert(repo.clone(), ForwarderStatus { state: "running", error: None });
        }
        statuses
    }

    /// Kills the forwarders no longer wanted or exited, records why one died on start, and
    /// starts the wanted ones whose backoff has passed. Answers what to log.
    fn reconcile(&mut self, desired: HashSet<String>, port: u16) -> Vec<LogLine> {
        let mut logs = Vec::new();
        if self.stopped {
            return logs;
        }
        self.backoff.retain(|repo, _| desired.contains(repo));
        let existing = self.children.keys().cloned().collect::<Vec<_>>();
        for repo in existing {
            let exited = self
                .children
                .get_mut(&repo)
                .and_then(|forwarder| forwarder.child.try_wait().ok())
                .flatten()
                .is_some();
            if exited || !desired.contains(&repo) {
                let Some(mut forwarder) = self.children.remove(&repo) else { continue };
                let _ = forwarder.child.start_kill();
                if !exited || !desired.contains(&repo) {
                    continue;
                }
                let tail = forwarder.stderr.lock().map(|text| text.clone()).unwrap_or_default();
                if forwarder.since.elapsed() >= QUICK_EXIT {
                    self.backoff.remove(&repo); // it ran; a dropped connection restarts right away
                    continue;
                }
                // Died on start: wait longer each time, and log the reason once per streak — never
                // a start/exit pair every sync.
                let failures = self.backoff.get(&repo).map_or(0, |b| b.failures) + 1;
                let reason = failure_reason(&tail);
                let reason = if reason.is_empty() { "gh webhook forward exited immediately".to_owned() } else { reason };
                if failures == 1 {
                    logs.push(LogLine { level: "error", kind: "forwarder_failed", payload: json!({"repo":repo,"error":reason}) });
                }
                // A leftover hook does not go away by waiting, so retry it at the slowest pace:
                // Settings offers to remove it, and a removal retries straight away.
                let hook_exists = is_hook_conflict(&tail);
                let delay = if hook_exists { MAX_BACKOFF } else { backoff_delay(failures) };
                self.backoff.insert(repo, Backoff { failures, retry_at: Instant::now() + delay, reason, hook_exists });
            }
        }
        for repo in desired {
            if self.children.contains_key(&repo) || self.backoff.get(&repo).is_some_and(|b| Instant::now() < b.retry_at) {
                continue;
            }
            let retrying = self.backoff.contains_key(&repo);
            let child = crate::cli::command("gh")
                .args([
                    "webhook",
                    "forward",
                    &format!("--repo={repo}"),
                    "--events=pull_request",
                    &format!("--url=http://127.0.0.1:{port}/webhook/github"),
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .spawn();
            match child {
                Ok(mut child) => {
                    let stderr = Arc::new(std::sync::Mutex::new(String::new()));
                    if let Some(pipe) = child.stderr.take() {
                        let sink = stderr.clone();
                        tokio::spawn(async move {
                            use tokio::io::AsyncReadExt;
                            let mut pipe = pipe;
                            let mut buffer = [0u8; 1024];
                            while let Ok(read) = pipe.read(&mut buffer).await {
                                if read == 0 {
                                    return;
                                }
                                if let Ok(mut text) = sink.lock() {
                                    text.push_str(&String::from_utf8_lossy(&buffer[..read]));
                                    trim_stderr(&mut text);
                                }
                            }
                        });
                    }
                    self.children.insert(repo.clone(), Forwarder { child, since: Instant::now(), stderr });
                    if !retrying {
                        logs.push(LogLine { level: "info", kind: "forwarder_started", payload: json!({"repo":repo}) });
                    }
                }
                Err(error) => {
                    let failures = self.backoff.get(&repo).map_or(0, |b| b.failures) + 1;
                    if failures == 1 {
                        logs.push(LogLine { level: "error", kind: "forwarder_failed", payload: json!({"repo":repo,"error":error.to_string()}) });
                    }
                    let retry_at = Instant::now() + backoff_delay(failures);
                    self.backoff.insert(repo, Backoff { failures, retry_at, reason: error.to_string(), hook_exists: false });
                }
            }
        }
        logs
    }
}

pub async fn jira_site(State(app): State<AppState>) -> ApiResult<Value> {
    let configured = app.db.config_value("jira_base_url").await?.unwrap_or_default();
    let auth = cli::run("acli", ["jira", "auth", "status"], Duration::from_secs(15))
        .await
        .unwrap_or_default();
    let field = |name: &str| {
        auth.lines().find_map(|line| {
            line.split_once(':')
                .filter(|(key, _)| key.trim().eq_ignore_ascii_case(name))
                .map(|(_, value)| value.trim().to_owned())
        })
    };
    let mut base = if configured.is_empty() {
        field("Site").unwrap_or_default()
    } else {
        configured
    };
    if !base.is_empty() && !base.starts_with("http://") && !base.starts_with("https://") {
        base = format!("https://{base}")
    }
    while base.ends_with('/') {
        base.pop();
    }
    Ok(Json(
        json!({"baseUrl":base,"me":{"email":field("Email"),"accountId":null}}),
    ))
}


/// Whether `gh extension list` names the webhook extension the forwarders run (`gh webhook
/// forward`). Rows are `gh webhook<TAB>cli/gh-webhook<TAB>v0.2.0`; a fork keeps the repo name,
/// and a local install (`gh extension install .`) has the command name but an empty repo column.
fn lists_gh_webhook(extensions: &str) -> bool {
    extensions.lines().any(|line| {
        let mut columns = line.split('\t');
        let name = columns.next().unwrap_or("").trim();
        let repo = columns.next().unwrap_or("").trim();
        name == "gh webhook" || repo.ends_with("/gh-webhook")
    })
}

/// Which installer put `path` there, for Settings to name: Homebrew's links point into its
/// Cellar, so the link is followed first.
fn install_source(path: &std::path::Path) -> &'static str {
    let real = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    source_of(&real.to_string_lossy())
}

fn source_of(path: &str) -> &'static str {
    const KNOWN: [(&str, &str); 9] = [
        ("/Cellar/", "Homebrew"),
        ("/opt/homebrew/", "Homebrew"),
        ("/.nvm/", "nvm"),
        ("/fnm/", "fnm"),
        ("/.fnm/", "fnm"),
        ("/.volta/", "Volta"),
        ("/.asdf/", "asdf"),
        ("/mise/", "mise"),
        ("/.nodenv/", "nodenv"),
    ];
    KNOWN
        .iter()
        .find(|(marker, _)| path.contains(marker))
        .map(|(_, name)| *name)
        .unwrap_or(if path.starts_with("/usr/local/") { "installer" } else { "other" })
}

pub async fn cli_tools() -> ApiResult<Value> {
    async fn probe(program: &str, auth: Option<Vec<&str>>) -> Value {
        let present = cli::run(program, ["--version"], Duration::from_secs(4))
            .await
            .is_ok();
        let authed = if present {
            if let Some(args) = auth {
                Some(
                    cli::run(program, args, Duration::from_secs(8))
                        .await
                        .is_ok(),
                )
            } else {
                None
            }
        } else {
            None
        };
        let mut value = json!({"present":present});
        if let Some(authed) = authed {
            value["authed"] = json!(authed)
        }
        value
    }
    // Without gh the listing fails, which reads the same as the extension being absent.
    let gh_webhook = async {
        cli::run("gh", ["extension", "list"], Duration::from_secs(8))
            .await
            .is_ok_and(|list| lists_gh_webhook(&list))
    };
    // The simulator preview runs on Node, which must be recent enough for serve-sim. Found the
    // way the user's terminal finds it, whichever way it was installed.
    let node = async {
        match cli::run("node", ["--version"], Duration::from_secs(4)).await {
            Ok(version) => {
                let supported = crate::sim_preview::node_supported(&version).unwrap_or(false);
                let source = cli::locate("node").map(|path| install_source(&path));
                json!({"present":true,"version":version.trim(),"supported":supported,"source":source})
            }
            Err(_) => json!({"present":false}),
        }
    };
    let agents = futures_util::future::join_all(Agent::ALL.map(|agent| probe(agent.profile().command, None)));
    let (agents, gh, acli, gh_webhook, node) = tokio::join!(
        agents,
        probe("gh", Some(vec!["auth", "status"])),
        probe("acli", Some(vec!["jira", "auth", "status"])),
        gh_webhook,
        node
    );
    // An installed serve-sim is used as is; without one, `npx` fetches it on first use. Either
    // runs on Node, so `needs` names what is actually missing: Node first, then npx.
    let installed = cli::installed("serve-sim");
    let needs = if node["supported"] != json!(true) {
        Some("node")
    } else if !installed && !cli::installed("npx") {
        Some("npx")
    } else {
        None
    };
    let serve_sim = json!({"present":needs.is_none(),"source":if installed { "installed" } else { "npx" },"needs":needs});
    let mut found = json!({"gh":gh,"acli":acli,"ghWebhook":{"present":gh_webhook},
               "node":node,"serveSim":serve_sim,"brew":{"present":cli::installed("brew")}});
    // Each agent's CLI under its own name.
    for (agent, probed) in Agent::ALL.into_iter().zip(agents) {
        found[agent.profile().id] = probed;
    }
    Ok(Json(found))
}

const MARKER: &str = "cascade-workflow-hook";
const EVENTS: [(&str, &str); 2] = [
    ("UserPromptSubmit", "/api/hooks/turn-start"),
    ("Stop", "/api/hooks/turn-done"),
];
/// A CLI that reports sessions (`Hooks::reports_sessions`) says when its conversation changes under
/// a running agent: at launch, and on `/resume` and `/clear`. It is not part of `EVENTS`: an install
/// from before it existed reads as outdated rather than absent, and keeps reporting turns, which is
/// all a workflow needs. Checked against Claude Code 2.1.278: the payload carries top-level
/// `session_id` and `source` (`startup` on a fresh launch, `resume` with the same id on `--resume`).
const SESSION: (&str, &str) = ("SessionStart", "/api/hooks/session-start");
/// Both CLIs ask this hook before showing their approval prompt (checked against Claude Code
/// 2.1.282 and Codex 0.156.1), so the chat view can answer it. Outside `EVENTS` for the same
/// reason as `SESSION`: an install without it still reports turns.
const PERMISSION: (&str, &str) = ("PermissionRequest", "/api/hooks/permission");
/// Where every tool hook (`Hooks::tool_events`) reports. They fire on every call, so
/// they run in the background (`async`): the CLI never waits on one, and an app that is not there
/// costs nothing. Outside `EVENTS` too: an install without them still reports turns.
const TOOL: &str = "/api/hooks/tool";
/// Whatever the agent runs inherits this terminal's `CASCADE_RUN_ID`, so a nested `claude -p`
/// would report as the session's own conversation and take it over. The hook's parent is the
/// CLI that fired it, and only the session's own is the terminal's foreground job: a nested one
/// runs in its tool's process group with no controlling terminal. Checked against Claude Code
/// 2.1.278 (`tpgid == pgid` for the session's, `tpgid 0` for the nested one); a CLI gets it when
/// its adapter says so (`Hooks::foreground_only`).
/// The terminal names its own app's port file (`cascade-ptyd` sets it): a development build and the
/// installed app run side by side with their own data directories, and share the CLI's one hooks
/// file. A hook that reads only the port file it was installed with reaches one of them; one from
/// before this reads as outdated, so it is installed again.
const PORT_FILE_VAR: &str = "CASCADE_PORT_FILE";
const FOREGROUND_GUARD: &str =
    "set -- $(ps -o tpgid=,pgid= -p $PPID 2>/dev/null); [ -n \"$1\" ] && [ \"$1\" = \"$2\" ] || exit 0; ";
fn is_current(entry: &Value, agent: Agent) -> bool {
    entry["hooks"].as_array().is_some_and(|hooks| {
        hooks.iter().any(|hook| {
            hook["command"]
                .as_str()
                .is_some_and(|command| {
                    command.contains(MARKER)
                        && command.contains(PORT_FILE_VAR)
                        && (!agent.hooks().foreground_only || command.contains("tpgid"))
                })
        })
    })
}
/// The permission hook's reply is the CLI's decision; one installed before it failed on errors
/// and stopped at a missing port file must be installed again.
fn is_current_for(entry: &Value, agent: Agent, event: &str) -> bool {
    is_current(entry, agent)
        && (event != PERMISSION.0
            || entry["hooks"].as_array().is_some_and(|hooks| {
                hooks.iter().any(|hook| hook["command"].as_str().is_some_and(|command| command.contains("curl -sf")))
            }))
}
fn events(agent: Agent) -> Vec<(&'static str, &'static str)> {
    let mut events = EVENTS.to_vec();
    if agent.hooks().reports_sessions {
        events.push(SESSION)
    }
    events.push(PERMISSION);
    events.extend(agent.hooks().tool_events.iter().map(|event| (*event, TOOL)));
    events
}
fn hook_file(agent: Agent) -> Result<(PathBuf, Value), ApiError> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| ApiError::bad_request("Home directory is unavailable"))?;
    let hooks = agent.hooks();
    let empty = serde_json::from_str(hooks.empty).map_err(ApiError::internal)?;
    Ok((home.join(hooks.file), empty))
}
fn is_our_entry(entry: &Value) -> bool {
    entry["hooks"].as_array().is_some_and(|hooks| {
        hooks.iter().any(|hook| hook["command"].as_str().is_some_and(|command| command.contains(MARKER)))
    })
}
/// The CLI's hooks file as it is now, or None when it is missing or not JSON.
fn hooks_config(agent: Agent) -> Option<Value> {
    hook_file(agent).ok().and_then(|(file, _)| read_json(&file))
}
pub(crate) fn hook_status_for(agent: Agent) -> String {
    hook_status_in(agent, hooks_config(agent).as_ref())
}
fn hook_status_in(agent: Agent, config: Option<&Value>) -> String {
    let Some(value) = config else {
        return "absent".into();
    };
    let ours = |event: &str| {
        value["hooks"][event]
            .as_array()
            .is_some_and(|items| items.iter().any(is_our_entry))
    };
    let current = |event: &str| {
        value["hooks"][event]
            .as_array()
            .is_some_and(|items| items.iter().any(|entry| is_current_for(entry, agent, event)))
    };
    if !EVENTS.iter().all(|(event, _)| ours(event)) {
        "absent".into()
    } else if events(agent).iter().all(|(event, _)| current(event)) {
        "installed".into()
    } else {
        // Still reporting turns, but from before a hook or its guard was added. Installing again
        // replaces the entries.
        "outdated".into()
    }
}
fn hook_status() -> Value {
    let mut status = json!({crate::agents::statusline::KEY: crate::agents::statusline::status()});
    for agent in Agent::ALL {
        status[agent.profile().id] = json!(hook_status_for(agent));
    }
    status
}
fn hook_entry(agent: Agent, endpoint: &str, port_file: &PathBuf) -> Value {
    let hooks = agent.hooks();
    let cli = agent.profile().id;
    let guard = if hooks.foreground_only { FOREGROUND_GUARD } else { "" };
    // Every other hook only reports, so it is quick and silent. The permission hook waits for an
    // answer and prints it, which is the decision the CLI reads; an empty reply decides nothing.
    let asks = endpoint == PERMISSION.1;
    let (wait, output) = if asks {
        (crate::agents::permission::HOOK_TIMEOUT - 10, "2>/dev/null")
    } else {
        (2, ">/dev/null 2>&1")
    };
    // Its reply is trusted as the decision, so it goes to Cascade or nowhere: no port file means no
    // Cascade to ask, not the old default port, and `-f` turns an error page into no reply.
    let port = shell_quote(&port_file.to_string_lossy());
    // The terminal's own app first; the one that installed the hook when the terminal names none.
    // Assigned, so a path with a space in it is one word.
    let find = format!("F=${{{PORT_FILE_VAR}:-{port}}};");
    let (read_port, flags) = if asks {
        (format!("{find} P=$(cat \"$F\" 2>/dev/null) || exit 0;"), "-sf")
    } else {
        (format!("{find} P=$(cat \"$F\" 2>/dev/null || echo 3000);"), "-s")
    };
    let script=format!("{guard}{read_port} curl {flags} -m {wait} -X POST \"http://127.0.0.1:$P{endpoint}?cli={cli}&runId=${{CASCADE_RUN_ID:-}}\" -H \"Content-Type: application/json\" --data-binary @- {output} || true # {MARKER}");
    let mut hook = json!({"type":"command","command":format!("sh -c {}",shell_quote(&script))});
    if asks {
        hook["timeout"] = json!(crate::agents::permission::HOOK_TIMEOUT)
    }
    if endpoint == TOOL {
        hook["async"] = json!(true)
    }
    let mut entry = json!({"hooks":[hook]});
    if hooks.matches_tools {
        entry["matcher"] = json!(".*")
    }
    entry
}
fn change_hooks(app: &AppState, cli: &str, install: bool) -> Result<Value, ApiError> {
    let agent = Agent::of(cli).ok_or_else(|| ApiError::bad_request(format!("unknown CLI: {cli}")))?;
    let (file, base) = hook_file(agent)?;
    let mut config = match fs::read_to_string(&file) {
        Ok(raw) => serde_json::from_str(&raw).map_err(|_| {
            ApiError::bad_request(format!(
                "Cannot update hooks: {} contains invalid JSON. The file was not changed.",
                file.display()
            ))
        })?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => base,
        Err(error) => return Err(ApiError::internal(error)),
    };
    if !config.is_object() {
        return Err(ApiError::bad_request(format!("Cannot update hooks: {} has an unsupported configuration shape. The file was not changed.",file.display())));
    }
    let original = config.clone();
    if !config["hooks"].is_object() {
        config["hooks"] = json!({})
    }
    let port_file = app.db.data_dir.join(".server-port");
    for (event, endpoint) in events(agent) {
        let mut entries = config["hooks"][event]
            .as_array()
            .cloned()
            .unwrap_or_default();
        entries.retain(|entry| !is_our_entry(entry));
        // Nothing of ours to add or to clear: leave a key the user never had out of their file.
        if !install && entries.is_empty() && config["hooks"].get(event).is_none() {
            continue;
        }
        if install {
            entries.push(hook_entry(agent, endpoint, &port_file))
        }
        config["hooks"][event] = Value::Array(entries)
    }
    // Removing hooks that were never there must not leave a settings file behind, nor add an
    // empty `hooks` map to a file that had none.
    if install || original.get("hooks").is_some_and(|hooks| hooks != &config["hooks"]) {
        write_json(&file, &config)?;
    }
    Ok(hook_status())
}
/// Whether the hooks file holds any entry of this app's, under any of its names: the person
/// installed its hooks once.
fn has_our_hooks(config: &Value) -> bool {
    config["hooks"].as_object().is_some_and(|events| {
        events.values().any(|entries| entries.as_array().is_some_and(|entries| entries.iter().any(is_our_entry)))
    })
}

/// Brings up to date the hooks the person installed, at each start: an app that changed how its
/// hooks report updates its own. It never adds hooks nobody installed, and hooks removed in Settings
/// are gone from the file, so they stay removed. Each update is told as activity, a toast: a CLI
/// may ask its user to review hook changes it did not make.
pub(crate) async fn ensure_hooks(app: &AppState) {
    // The settings files are read and written off the runtime; only the events await.
    let files = app.clone();
    let outcomes: Vec<(&'static str, Value)> = tokio::task::spawn_blocking(move || {
        let mut outcomes = Vec::new();
        for agent in Agent::ALL {
            let profile = agent.profile();
            // Read once: whether they were installed, and whether they are current.
            let config = hooks_config(agent);
            let status = hook_status_in(agent, config.as_ref());
            if !config.as_ref().is_some_and(has_our_hooks) || status == "installed" {
                continue;
            }
            outcomes.push(match change_hooks(&files, profile.id, true) {
                Ok(_) => ("hooks_updated", json!({"cli": profile.id})),
                Err(error) => ("hooks_update_failed", json!({"cli": profile.id, "error": error.to_string()})),
            });
        }
        outcomes
    })
    .await
    .unwrap_or_default();
    for (kind, payload) in outcomes {
        if let Ok(event) = app.db.add_event(kind, &payload).await {
            app.publish(crate::Event::Activity { event });
        }
    }
}
/// Brings the installed hooks up to date, asked by the app once it can show the toasts that say so.
pub async fn update_hooks(State(app): State<AppState>, headers: axum::http::HeaderMap) -> ApiResult<Value> {
    if crate::local::foreign_origin(&headers) {
        return Err(ApiError::forbidden("Hooks are the app's to change"));
    }
    ensure_hooks(&app).await;
    let status = tokio::task::spawn_blocking(hook_status)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(status))
}
pub async fn agent_hooks() -> ApiResult<Value> {
    Ok(Json(hook_status()))
}
pub async fn install_hook(
    State(app): State<AppState>,
    Path(cli): Path<String>,
) -> ApiResult<Value> {
    if cli == crate::agents::statusline::KEY {
        crate::agents::statusline::change(true)?;
        return Ok(Json(json!({"ok":true,"status":hook_status()})));
    }
    let status = change_hooks(&app, &cli, true)?;
    Ok(Json(json!({"ok":true,"status":status})))
}
pub async fn uninstall_hook(
    State(app): State<AppState>,
    Path(cli): Path<String>,
) -> ApiResult<Value> {
    if cli == crate::agents::statusline::KEY {
        crate::agents::statusline::change(false)?;
        return Ok(Json(json!({"ok":true,"status":hook_status()})));
    }
    let status = change_hooks(&app, &cli, false)?;
    Ok(Json(json!({"ok":true,"status":status})))
}

#[derive(Default, Deserialize)]
pub struct HookQuery {
    cli: Option<String>,
    #[serde(rename = "runId")]
    run_id: Option<String>,
}
async fn relay(app: AppState, query: HookQuery, body: Value, kind: &str) -> StatusCode {
    let session = body["session_id"].as_str().unwrap_or("");
    let mut event = json!({"type":kind,"cli":query.cli.unwrap_or_default(),"runId":query.run_id.unwrap_or_default(),"sessionId":session,"source":body["source"].as_str().unwrap_or("")});
    // Kept without its payload, which can carry the prompt: the app reads it back only to know
    // where the agent stands. Written and then told off the request: the hook's `curl` gives up
    // after two seconds, and a handler cancelled at an await must not lose the broadcast.
    let run = event["runId"].as_str().filter(|run| is_run_id(run)).map(str::to_owned);
    let stored = event.clone();
    event["payload"] = body;
    tokio::spawn(async move {
        if let Some(run) = run {
            let _ = app.db.set_agent_hook(&run, &stored).await;
        }
        app.broadcast(event);
    });
    StatusCode::NO_CONTENT
}

/// A tool hook (`TOOL`), told to the app as an `AgentTool` event; kept nowhere, unlike
/// the turn hooks, which say where the agent stands. Answered at once: the hook runs in the
/// background, and the app needs it now or not at all.
pub async fn tool_event(
    State(app): State<AppState>,
    Query(query): Query<HookQuery>,
    Json(body): Json<Value>,
) -> StatusCode {
    if let Some(event) = tool_event_of(query, &body) {
        app.publish(event);
    }
    StatusCode::NO_CONTENT
}

/// The event a tool hook's payload is, by its CLI's adapter: None for a CLI or an event it does
/// not know.
fn tool_event_of(query: HookQuery, body: &Value) -> Option<crate::event::Event> {
    let agent = query.cli.as_deref().and_then(Agent::of)?;
    let event = body["hook_event_name"].as_str()?;
    if !agent.hooks().tool_events.contains(&event) {
        return None;
    }
    let phase = match event {
        "PreToolUse" => "start",
        "PostToolUse" => "done",
        "PostToolUseFailure" => "failed",
        _ => return None,
    };
    let text = |key: &str| body[key].as_str().filter(|value| !value.is_empty()).map(str::to_owned);
    let tool = text("tool_name");
    let label = if body["tool_input"].is_null() { None } else { Some(crate::agents::permission::tool_detail(&body["tool_input"]).0) };
    Some(crate::event::Event::AgentTool {
        run_id: query.run_id.unwrap_or_default(),
        cli: agent.profile().id.to_owned(),
        session_id: text("session_id").unwrap_or_default(),
        phase,
        tool_use_id: text("tool_use_id"),
        kind: tool.as_deref().map(|tool| agent.tool_kind(tool)),
        tool,
        label,
        agent_id: text("agent_id"),
        agent_type: text("agent_type"),
    })
}

/// A terminal id as cascade-ptyd makes them. Anything else posting here keeps nothing.
fn is_run_id(run: &str) -> bool {
    !run.is_empty() && run.len() <= 64 && run.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

#[derive(Deserialize)]
pub struct LastHookQuery {
    #[serde(rename = "runId")]
    run_id: String,
}

/// The last turn hook a terminal's agent sent, as it was relayed: `{"event": …}`, null when none
/// was heard. For an app that has just attached again to a shell it did not see the hook of.
pub async fn last_hook(State(app): State<AppState>, Query(query): Query<LastHookQuery>) -> Json<Value> {
    let event = if is_run_id(&query.run_id) { app.db.agent_hook(&query.run_id).await.ok().flatten() } else { None };
    Json(json!({ "event": event }))
}
#[derive(Deserialize)]
pub struct OpenUrlQuery {
    url: String,
    #[serde(rename = "runId")]
    run_id: String,
}
/// A terminal's BROWSER (the helper cascade-ptyd installs) asking for a URL to open in the panel
/// beside it. Only the app subscribes to events, so a send nobody receives means no app is there
/// to take the link: that answers 503, and the helper opens it with `open` instead.
///
/// Its query-only POST is one a web page may send without a preflight, so a page's origin is
/// refused, and only a web address is relayed: the helper sends nothing else.
pub async fn open_url(
    State(app): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(query): Query<OpenUrlQuery>,
) -> StatusCode {
    if crate::local::foreign_origin(&headers) {
        return StatusCode::FORBIDDEN;
    }
    let web = url::Url::parse(&query.url).is_ok_and(|url| matches!(url.scheme(), "http" | "https"));
    if !web || query.run_id.is_empty() {
        return StatusCode::BAD_REQUEST;
    }
    match app.events.send(crate::Event::TerminalOpenUrl { run_id: query.run_id, url: query.url }.into()) {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}
#[derive(Deserialize)]
pub struct RelaunchQuery {
    pid: u32,
}
/// A Run that has rebuilt the copy of the app its terminal belongs to, asking that copy to leave
/// so the new build can take its place. It is asked because it cannot always be ended: a debugger
/// holds the copy it is attached to against every signal. The copy is named by its process ID and
/// leaves by itself; nothing else is relayed, and a page's origin is refused as for `open_url`.
pub async fn relaunch(
    State(app): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(query): Query<RelaunchQuery>,
) -> StatusCode {
    if crate::local::foreign_origin(&headers) {
        return StatusCode::FORBIDDEN;
    }
    match app.events.send(json!({"type":"terminal-relaunch","pid":query.pid})) {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}
pub async fn turn_start(
    State(app): State<AppState>,
    Query(query): Query<HookQuery>,
    Json(body): Json<Value>,
) -> StatusCode {
    relay(app, query, body, "agent-turn-start").await
}
pub async fn session_start(
    State(app): State<AppState>,
    Query(query): Query<HookQuery>,
    Json(body): Json<Value>,
) -> StatusCode {
    relay(app, query, body, "agent-session").await
}
pub async fn turn_done(
    State(app): State<AppState>,
    Query(query): Query<HookQuery>,
    Json(body): Json<Value>,
) -> StatusCode {
    // A turn that ended with an agent of its own still working in the background is not the agent
    // done: it stays at work until the Stop after that agent reports, and nothing is told or kept.
    if query.cli.as_deref().and_then(Agent::of).is_some_and(|agent| agent.works_on(&body)) {
        return StatusCode::NO_CONTENT;
    }
    relay(app, query, body, "agent-turn-done").await
}


/// A hook delete that failed because the hook no longer exists.
pub(crate) fn is_already_gone(error: &str) -> bool {
    error.contains("HTTP 404")
}

pub async fn github_webhook(
    State(app): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(body): Json<Value>,
) -> StatusCode {
    if headers.get("x-github-event").and_then(|v| v.to_str().ok()) != Some("pull_request")
        || body["action"] != "closed"
        || body["pull_request"]["merged"] != true
    {
        return StatusCode::OK;
    }
    let repo = body["repository"]["full_name"].as_str().unwrap_or("");
    if let Ok(projects) = app.db.projects().await {
        if let Some(project) = projects
            .into_iter()
            .find(|p| p.repo.eq_ignore_ascii_case(repo))
        {
            let mut pr = body["pull_request"].clone();
            pr["url"] = pr["html_url"].clone();
            pr["state"] = json!("MERGED");
            app.poller.handle_merge(&app, &project, &pr).await;
        }
    }
    StatusCode::OK
}

#[cfg(test)]
mod forwarder_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn claude_hooks_drop_nested_runs_and_older_entries_read_as_outdated() {
        let port = PathBuf::from("/tmp/.server-port");
        let claude = hook_entry(Agent::Claude, "/api/hooks/turn-start", &port);
        let command = claude["hooks"][0]["command"].as_str().unwrap();
        assert!(command.contains("ps -o tpgid=,pgid= -p $PPID") && command.contains("|| exit 0;"));
        assert!(is_current(&claude, Agent::Claude));
        let older = json!({"hooks":[{"type":"command","command":format!("sh -c 'curl x # {MARKER}'")}]});
        assert!(is_our_entry(&older) && !is_current(&older, Agent::Claude));
        let codex = hook_entry(Agent::Codex, "/api/hooks/turn-start", &port);
        assert!(!codex["hooks"][0]["command"].as_str().unwrap().contains("tpgid"));
        assert!(is_current(&codex, Agent::Codex) && !is_current(&older, Agent::Codex), "from before terminals named their app");
    }

    /// Runs the hook as the CLI would, with a `curl` that writes down where it was sent.
    fn run_hook(entry: &Value, env: &[(&str, &str)], scratch: &std::path::Path) -> String {
        let bin = scratch.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let curl = bin.join("curl");
        fs::write(&curl, "#!/bin/sh\necho \"$@\" > \"$CURL_SENT\"\n").unwrap();
        fs::set_permissions(&curl, fs::Permissions::from_mode(0o755)).unwrap();
        let mut command = std::process::Command::new("/bin/sh");
        command.arg("-c").arg(entry["hooks"][0]["command"].as_str().unwrap());
        let _ = fs::remove_file(scratch.join("sent"));
        command.env_clear().env("PATH", format!("{}:/usr/bin:/bin", bin.display())).env("CURL_SENT", scratch.join("sent"));
        for (key, value) in env {
            command.env(key, value);
        }
        command.stdin(std::process::Stdio::null()).status().unwrap();
        fs::read_to_string(scratch.join("sent")).unwrap_or_default()
    }

    #[test]
    fn a_hook_reaches_the_app_that_started_its_terminal() {
        let scratch = std::env::temp_dir().join(format!("hook port '{}", std::process::id()));
        let installed = scratch.join("installed app/.server-port");
        let running = scratch.join("dev build/.server-port");
        fs::create_dir_all(installed.parent().unwrap()).unwrap();
        fs::create_dir_all(running.parent().unwrap()).unwrap();
        fs::write(&installed, "1111").unwrap();
        fs::write(&running, "2222").unwrap();
        // Codex's: Claude's also asks that the hook's parent be the terminal's foreground job.
        let entry = hook_entry(Agent::Codex, "/api/hooks/turn-start", &installed);
        let named = run_hook(&entry, &[("CASCADE_PORT_FILE", running.to_str().unwrap()), ("CASCADE_RUN_ID", "pty9")], &scratch);
        assert!(named.contains("http://127.0.0.1:2222/api/hooks/turn-start?cli=codex&runId=pty9"), "{named}");
        let unnamed = run_hook(&entry, &[("CASCADE_RUN_ID", "pty9")], &scratch);
        assert!(unnamed.contains("http://127.0.0.1:1111/"), "a terminal that names no app: {unnamed}");
        let _ = fs::remove_dir_all(&scratch);
    }

    #[test]
    fn only_hooks_the_person_installed_are_updated_unasked() {
        let port = PathBuf::from("/tmp/.server-port");
        let theirs = json!({"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}});
        assert!(!has_our_hooks(&theirs), "their own hooks only: never installed");
        assert!(!has_our_hooks(&json!({})) && !has_our_hooks(&json!({"hooks":{}})));
        let ours = json!({"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}, hook_entry(Agent::Claude, "/api/hooks/turn-done", &port)]}});
        assert!(has_our_hooks(&ours));
    }

    #[test]
    fn only_a_cli_that_reports_sessions_is_asked_for_them() {
        assert!(events(Agent::Claude).contains(&SESSION));
        assert!(!events(Agent::Codex).contains(&SESSION));
    }

    #[test]
    fn both_clis_ask_for_permission_and_wait_for_the_answer() {
        let port = PathBuf::from("/tmp/.server-port");
        for cli in Agent::ALL {
            assert!(events(cli).contains(&PERMISSION));
            let entry = hook_entry(cli, PERMISSION.1, &port);
            let hook = &entry["hooks"][0];
            assert_eq!(hook["timeout"], crate::agents::permission::HOOK_TIMEOUT);
            let command = hook["command"].as_str().unwrap();
            // The answer is the hook's output, so it must not be thrown away.
            assert!(command.contains("-m 290") && !command.contains(">/dev/null 2>&1"));
            // Its reply is the decision: only Cascade may give it.
            assert!(command.contains("curl -sf") && !command.contains("echo 3000"));
            assert!(is_current_for(&entry, cli, PERMISSION.0));
            let before = json!({"hooks":[{"type":"command","command":command.replace("curl -sf", "curl -s")}]});
            assert!(is_current(&before, cli) && !is_current_for(&before, cli, PERMISSION.0));
        }
        let quiet = hook_entry(Agent::Codex, "/api/hooks/turn-start", &port);
        assert!(quiet["hooks"][0].get("timeout").is_none());
    }

    #[test]
    fn tool_hooks_run_in_the_background_for_both_clis() {
        let port = PathBuf::from("/tmp/.server-port");
        assert!(events(Agent::Claude).contains(&("PreToolUse", TOOL)) && events(Agent::Claude).contains(&("PostToolUseFailure", TOOL)));
        let entry = hook_entry(Agent::Claude, TOOL, &port);
        assert_eq!(entry["hooks"][0]["async"], true, "the CLI never waits on one");
        assert!(entry["hooks"][0].get("timeout").is_none() && is_current_for(&entry, Agent::Claude, "PreToolUse"));
        assert!(!events(Agent::Codex).iter().any(|(_, endpoint)| *endpoint == TOOL), "Codex would wait on them");
        assert!(hook_entry(Agent::Claude, "/api/hooks/turn-start", &port)["hooks"][0].get("async").is_none());
    }

    #[test]
    fn a_tool_hook_becomes_one_event_in_the_kinds_every_cli_shares() {
        let query = |cli: &str| HookQuery { cli: Some(cli.into()), run_id: Some("pty9".into()) };
        let start = json!({"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_use_id":"toolu_1",
                           "tool_input":{"command":"cargo test"}});
        let event = Value::from(tool_event_of(query("claude"), &start).unwrap());
        assert_eq!(event, json!({"type":"agent-tool","runId":"pty9","cli":"claude","sessionId":"s1","phase":"start",
            "toolUseId":"toolu_1","tool":"Bash","kind":"run","label":"cargo test","agentId":null,"agentType":null}));
        let nested = json!({"hook_event_name":"PostToolUseFailure","tool_name":"Read","tool_use_id":"toolu_2",
                            "tool_input":{"file_path":"/w/a.swift"},"agent_id":"a1","agent_type":"Explore"});
        let event = Value::from(tool_event_of(query("claude"), &nested).unwrap());
        assert_eq!((event["phase"].as_str(), event["kind"].as_str(), event["agentId"].as_str()), (Some("failed"), Some("read"), Some("a1")));
        assert!(tool_event_of(query("claude"), &json!({"hook_event_name":"SubagentStart","agent_id":"a1"})).is_none(), "not installed");
        assert!(tool_event_of(query("codex"), &start).is_none(), "Codex installs none");
        assert!(tool_event_of(query("other"), &start).is_none() && tool_event_of(query("claude"), &json!({"hook_event_name":"Stop"})).is_none());
    }

    #[test]
    fn gh_webhook_is_found_by_repo_name_in_the_extension_list() {
        assert!(lists_gh_webhook("gh webhook\tcli/gh-webhook\tv0.2.0\n"));
        assert!(lists_gh_webhook("gh dash\tdlvhdr/gh-dash\tv4\ngh webhook\tfork/gh-webhook\t\n"));
        assert!(lists_gh_webhook("gh webhook\t\t\n")); // installed from a local checkout
        assert!(!lists_gh_webhook("gh dash\tdlvhdr/gh-dash\tv4\n"));
        assert!(!lists_gh_webhook(""));
    }

    #[test]
    fn node_is_named_by_whichever_installer_put_it_there() {
        assert_eq!(source_of("/opt/homebrew/Cellar/node/22.1.0/bin/node"), "Homebrew");
        assert_eq!(source_of("/usr/local/Cellar/node@20/20.18.0/bin/node"), "Homebrew");
        assert_eq!(source_of("/usr/local/bin/node"), "installer");
        assert_eq!(source_of("/Users/me/.nvm/versions/node/v22.1.0/bin/node"), "nvm");
        assert_eq!(source_of("/Users/me/Library/Application Support/fnm/node-versions/v22/installation/bin/node"), "fnm");
        assert_eq!(source_of("/Users/me/.volta/tools/image/node/22.1.0/bin/node"), "Volta");
        assert_eq!(source_of("/Users/me/.asdf/installs/nodejs/22.1.0/bin/node"), "asdf");
        assert_eq!(source_of("/Users/me/.local/share/mise/installs/node/22/bin/node"), "mise");
        assert_eq!(source_of("/somewhere/else/node"), "other");
    }

    #[test]
    fn backoff_grows_from_ten_seconds_and_caps_at_fifteen_minutes() {
        assert_eq!(backoff_delay(1), Duration::from_secs(20));
        assert_eq!(backoff_delay(2), Duration::from_secs(40));
        assert_eq!(backoff_delay(6), Duration::from_secs(640));
        assert_eq!(backoff_delay(7), MAX_BACKOFF);
        assert_eq!(backoff_delay(u32::MAX), MAX_BACKOFF);
    }

    #[test]
    fn a_failed_start_reports_the_error_and_not_the_usage_after_it() {
        let usage = "Usage:\n  gh webhook forward [flags]\n\nFlags:\n  -U, --url string   Address of the local server\n";
        assert_eq!(failure_reason(&format!("Error: HTTP 403: Must have admin rights\n{usage}")), "Error: HTTP 403: Must have admin rights");
        assert_eq!(failure_reason("unknown command \"webhook\" for \"gh\"\n"), "unknown command \"webhook\" for \"gh\"");
        assert_eq!(failure_reason(usage), usage.trim());
        assert_eq!(failure_reason(&"x".repeat(900)).len(), 500);
        let inline = "Error: bad flags, see Usage: gh webhook forward --help";
        assert_eq!(failure_reason(&format!("{inline}\n{usage}")), inline);
    }

    #[test]
    fn long_stderr_keeps_the_error_at_the_top_and_the_last_words_at_the_bottom() {
        let mut text = format!("Error: HTTP 403\n{}", "é".repeat(STDERR_TAIL));
        text.push_str("last line");
        trim_stderr(&mut text);
        assert!(text.starts_with("Error: HTTP 403\n") && text.ends_with("last line") && text.contains("\n…\n"));
        assert!(text.len() <= STDERR_HEAD + STDERR_TAIL + "\n…\n".len());
        let mut again = text.clone();
        again.push_str(&"x".repeat(STDERR_TAIL));
        trim_stderr(&mut again);
        assert!(again.starts_with("Error: HTTP 403\n") && again.matches('…').count() == 1);
        let mut short = "Error: HTTP 403".to_owned();
        trim_stderr(&mut short);
        assert_eq!(short, "Error: HTTP 403");
    }

    #[test]
    fn a_leftover_hook_is_told_apart_from_other_failures() {
        let stderr = "Error: error creating webhook: HTTP 422: Validation Failed (https://api.github.com/repos/o/r/hooks)\nHook already exists on this repository";
        assert!(is_hook_conflict(stderr));
        assert!(!is_hook_conflict("Error: HTTP 403: you do not have access to this feature"));
    }

    #[test]
    fn only_forwarder_hooks_are_picked_for_removal() {
        let hooks = json!([
            {"id": 1, "name": "cli", "config": {"url": "https://webhook-forwarder.github.com/hook"}},
            {"id": 2, "name": "web", "config": {"url": "https://ci.example.com/github"}},
            {"id": 3, "name": "cli", "config": {"url": "https://ci.example.com/cli"}},
        ]);
        assert_eq!(forwarder_hook_ids(&hooks), vec![1]);
        assert!(forwarder_hook_ids(&json!({"message": "Not Found"})).is_empty());
    }

    #[test]
    fn a_hook_that_is_already_gone_counts_as_removed() {
        assert!(is_already_gone("gh api -X DELETE repos/o/r/hooks/1: gh: Not Found (HTTP 404)"));
        assert!(!is_already_gone("gh: Must have admin rights to Repository. (HTTP 403)"));
    }
}
