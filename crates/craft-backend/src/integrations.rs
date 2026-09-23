use std::{
    collections::{HashMap, HashSet},
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, OnceLock,
    },
    time::{Duration, Instant},
};

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use chrono::{Datelike, Local, NaiveDate};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::{
    process::Child,
    sync::Mutex,
};
use uuid::Uuid;

use crate::{cli, error::ApiError, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

pub struct ForwarderManager {
    children: Mutex<HashMap<String, Forwarder>>,
    /// Repos whose forwarder keeps dying on start, with when to try again.
    backoff: Mutex<HashMap<String, Backoff>>,
    started: AtomicBool,
}

struct Forwarder {
    child: Child,
    since: Instant,
    /// The head and tail of the child's stderr. A reader task drains the pipe for as long as the
    /// forwarder runs: an undrained pipe fills and blocks `gh` mid-run, which `try_wait` would never see.
    stderr: Arc<Mutex<String>>,
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

impl ForwarderManager {
    pub fn new() -> Self {
        Self {
            children: Mutex::new(HashMap::new()),
            backoff: Mutex::new(HashMap::new()),
            started: AtomicBool::new(false),
        }
    }
    pub fn start(self: &std::sync::Arc<Self>, app: AppState, port: u16) {
        if self.started.swap(true, Ordering::SeqCst) {
            return;
        }
        let manager = self.clone();
        tokio::spawn(async move {
            loop {
                manager.sync(&app, port).await;
                tokio::time::sleep(Duration::from_secs(10)).await;
            }
        });
    }
    async fn sync(&self, app: &AppState, port: u16) {
        let desired: HashSet<String> = app
            .db
            .projects()
            .unwrap_or_default()
            .into_iter()
            .filter(|project| project["forwardWebhooks"].as_bool() == Some(true))
            .filter_map(|project| {
                project["repo"]
                    .as_str()
                    .filter(|repo| !repo.is_empty())
                    .map(str::to_owned)
            })
            .collect();
        let mut children = self.children.lock().await;
        let mut backoff = self.backoff.lock().await;
        backoff.retain(|repo, _| desired.contains(repo));
        let existing = children.keys().cloned().collect::<Vec<_>>();
        for repo in existing {
            let exited = children
                .get_mut(&repo)
                .and_then(|forwarder| forwarder.child.try_wait().ok())
                .flatten()
                .is_some();
            if exited || !desired.contains(&repo) {
                let Some(mut forwarder) = children.remove(&repo) else { continue };
                let _ = forwarder.child.start_kill();
                if !exited || !desired.contains(&repo) {
                    continue;
                }
                let tail = forwarder.stderr.lock().await.clone();
                if forwarder.since.elapsed() >= QUICK_EXIT {
                    backoff.remove(&repo); // it ran; a dropped connection restarts right away
                    continue;
                }
                // Died on start: wait longer each time, and log the reason once per streak — never
                // a start/exit pair every sync.
                let failures = backoff.get(&repo).map_or(0, |b| b.failures) + 1;
                if failures == 1 {
                    let reason = failure_reason(&tail);
                    let _ = app.db.add_log(
                        "webhook",
                        "error",
                        "forwarder_failed",
                        &json!({"repo":repo,"error":if reason.is_empty() { "gh webhook forward exited immediately".to_owned() } else { reason }}),
                    );
                }
                backoff.insert(repo, Backoff { failures, retry_at: Instant::now() + backoff_delay(failures) });
            }
        }
        for repo in desired {
            if children.contains_key(&repo) || backoff.get(&repo).is_some_and(|b| Instant::now() < b.retry_at) {
                continue;
            }
            let retrying = backoff.contains_key(&repo);
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
                    let stderr = Arc::new(Mutex::new(String::new()));
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
                                let mut text = sink.lock().await;
                                text.push_str(&String::from_utf8_lossy(&buffer[..read]));
                                trim_stderr(&mut text);
                            }
                        });
                    }
                    children.insert(repo.clone(), Forwarder { child, since: Instant::now(), stderr });
                    // A diagnostic log, not activity: it is never broadcast to the apps (the Node
                    // backend kept webhook logs off the activity stream too).
                    if !retrying {
                        let _ = app.db.add_log("webhook", "info", "forwarder_started", &json!({"repo":repo}));
                    }
                }
                Err(error) => {
                    let failures = backoff.get(&repo).map_or(0, |b| b.failures) + 1;
                    if failures == 1 {
                        let _ = app.db.add_log(
                            "webhook",
                            "error",
                            "forwarder_failed",
                            &json!({"repo":repo,"error":error.to_string()}),
                        );
                    }
                    backoff.insert(repo, Backoff { failures, retry_at: Instant::now() + backoff_delay(failures) });
                }
            }
        }
    }
    pub async fn list(&self) -> Vec<String> {
        let mut values = self
            .children
            .lock()
            .await
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        values.sort();
        values
    }
    pub async fn stop(&self) {
        let mut children = self.children.lock().await;
        for (_, forwarder) in children.iter_mut() {
            let _ = forwarder.child.start_kill();
        }
        children.clear();
        self.backoff.lock().await.clear();
    }
}

pub async fn jira_site(State(app): State<AppState>) -> ApiResult<Value> {
    let configured = app.db.config_value("jira_base_url")?.unwrap_or_default();
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

/// Renders a Fix Version name from a placeholder template against the local clock. Literal
/// text such as a platform prefix (`ios-`) is kept as written.
///
/// Placeholders are `{name}` or `{name+N}` / `{name-N}`: `year`, `month`, `day`, `isoWeek`
/// (zero-padded), `y`, `m`, `d`, `w` (unpadded) and `prNumber`. An offset shifts the value and
/// drops the padding, so `ios-{year-2026}.{m}.{d}` renders `ios-0.9.21` on 2026-09-21. Dates use the machine's time zone,
/// which is the one the user reads the version in.
pub(crate) fn render_version_template(template: &str, pr_number: i64) -> Result<String, ApiError> {
    render_version_template_at(template, pr_number, Local::now().date_naive())
}

fn render_version_template_at(
    template: &str,
    pr_number: i64,
    today: NaiveDate,
) -> Result<String, ApiError> {
    let raw = template.trim();
    if raw.is_empty() {
        return Err(ApiError::bad_request("version template is empty"));
    }
    if raw.contains("${") || raw.contains("return ") || raw.contains("=>") || raw.contains("function") {
        return Err(ApiError::bad_request(
            "JavaScript version scripts are no longer executed. Replace this value with a template such as ios-{year-2026}.{m}.{d}.",
        ));
    }
    static PLACEHOLDER: OnceLock<Regex> = OnceLock::new();
    let placeholder = PLACEHOLDER.get_or_init(|| {
        Regex::new(r"\{([A-Za-z]+)(?:([+-])(\d{1,6}))?\}").expect("valid placeholder regex")
    });
    let mut error = None;
    let value = placeholder.replace_all(raw, |caps: &regex::Captures| {
        let (base, width) = match &caps[1] {
            "year" => (i64::from(today.year()), 4),
            "month" => (i64::from(today.month()), 2),
            "day" => (i64::from(today.day()), 2),
            "isoWeek" => (i64::from(today.iso_week().week()), 2),
            "y" => (i64::from(today.year()), 0),
            "m" => (i64::from(today.month()), 0),
            "d" => (i64::from(today.day()), 0),
            "w" => (i64::from(today.iso_week().week()), 0),
            "prNumber" => (pr_number, 0),
            other => {
                error.get_or_insert(format!("Unknown version-template placeholder {{{other}}}"));
                return String::new();
            }
        };
        let offset = caps.get(3).and_then(|digits| digits.as_str().parse::<i64>().ok()).unwrap_or(0);
        let shifted = if caps.get(2).map(|sign| sign.as_str()) == Some("-") { base - offset } else { base + offset };
        if shifted < 0 {
            error.get_or_insert(format!("Version-template placeholder {} renders a negative number", &caps[0]));
            return String::new();
        }
        let width = if caps.get(2).is_some() { 0 } else { width };
        format!("{shifted:0width$}")
    });
    if let Some(message) = error {
        return Err(ApiError::bad_request(message));
    }
    if value.contains('{') || value.contains('}') || value.chars().any(char::is_control) {
        return Err(ApiError::bad_request("Unknown or invalid version-template placeholder"));
    }
    let value = value.trim();
    if value.is_empty() || value.len() > 128 {
        return Err(ApiError::bad_request("version template must produce 1–128 characters"));
    }
    Ok(value.into())
}

#[cfg(test)]
mod version_template_tests {
    use super::render_version_template_at;
    use chrono::NaiveDate;

    fn render(template: &str) -> Result<String, String> {
        render_at(template, 2026, 9, 21)
    }

    fn render_at(template: &str, year: i32, month: u32, day: u32) -> Result<String, String> {
        let today = NaiveDate::from_ymd_opt(year, month, day).unwrap();
        render_version_template_at(template, 482, today).map_err(|e| format!("{e:?}"))
    }

    #[test]
    fn padded_placeholders_keep_their_shape() {
        assert_eq!(render("{year}.{month}.{day}").unwrap(), "2026.09.21");
        assert_eq!(render("0.{isoWeek}").unwrap(), "0.39");
        assert_eq!(render("{prNumber}").unwrap(), "482");
    }

    #[test]
    fn unpadded_and_offset_placeholders_match_the_old_script() {
        assert_eq!(render("ios-{year-2026}.{m}.{d}").unwrap(), "ios-0.9.21");
        assert_eq!(render("{year+1}.{w}").unwrap(), "2027.39");
        assert_eq!(render("{y-2000}").unwrap(), "26");
        assert_eq!(render("{month+3}").unwrap(), "12");
        assert_eq!(render_at("{day}.{d}.{isoWeek}.{w}", 2026, 1, 5).unwrap(), "05.5.02.2");
    }

    #[test]
    fn negative_results_are_rejected() {
        assert!(render("{year-2030}").is_err());
        assert!(render("{m-9}").is_ok());
        assert!(render("{m-10}").is_err());
    }

    #[test]
    fn javascript_and_unknown_placeholders_are_rejected() {
        assert!(render("((d)=>`${d.getFullYear()}`)(new Date())").is_err());
        assert!(render("{yeer}").is_err());
        assert!(render("{year}.{").is_err());
        assert!(render("   ").is_err());
    }
}

pub async fn fix_version_preview(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let project = app
        .db
        .project(&id)?
        .ok_or_else(|| ApiError::not_found("project not found"))?;
    let version = render_version_template(body["script"].as_str().unwrap_or(""), 0)?;
    let key = project["jiraProjectKey"].as_str().unwrap_or("");
    let existing = if key.is_empty() {
        vec![]
    } else {
        cli::run(
            "acli",
            ["jira", "project", "view", "--key", key, "--json"],
            Duration::from_secs(30),
        )
        .await
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|value| value["versions"].as_array().cloned())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|item| item["name"].as_str().map(String::from))
        .collect::<Vec<_>>()
    };
    Ok(Json(
        json!({"version":version,"exists":existing.contains(&version)}),
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
    let (claude, codex, gh, acli, gh_webhook, node) = tokio::join!(
        probe("claude", None),
        probe("codex", None),
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
    Ok(Json(
        json!({"claude":claude,"codex":codex,"gh":gh,"acli":acli,"ghWebhook":{"present":gh_webhook},
               "node":node,"serveSim":serve_sim,"brew":{"present":cli::installed("brew")}}),
    ))
}

const MARKER: &str = "craft-workflow-hook";
/// The marker from when the app was called TaskHub. Those entries are ours to replace and remove,
/// but they report nothing here: they read the old run-id variable, so every event they send
/// names no terminal. They count as absent, and installing replaces them.
const LEGACY_MARKER: &str = "taskhub-workflow-hook";
const EVENTS: [(&str, &str); 2] = [
    ("UserPromptSubmit", "/api/hooks/turn-start"),
    ("Stop", "/api/hooks/turn-done"),
];
/// Claude also says when its conversation changes under a running agent: at launch, and on
/// `/resume` and `/clear`. It is not part of `EVENTS`: an install from before it existed reads as
/// outdated rather than absent, and keeps reporting turns, which is all a workflow needs.
/// Checked against Claude Code 2.1.278: the payload carries top-level `session_id` and `source`
/// (`startup` on a fresh launch, `resume` with the same id on `--resume`).
const CLAUDE_SESSION: (&str, &str) = ("SessionStart", "/api/hooks/session-start");
/// Whatever the agent runs inherits this terminal's `CRAFT_RUN_ID`, so a nested `claude -p`
/// would report as the session's own conversation and take it over. The hook's parent is the
/// `claude` that fired it, and only the session's own is the terminal's foreground job: a nested
/// one runs in its tool's process group with no controlling terminal. Checked against Claude Code
/// 2.1.278 (`tpgid == pgid` for the session's, `tpgid 0` for the nested one). Codex is left
/// alone: how it spawns its hooks has not been checked, and a wrong guard would silence them.
const FOREGROUND_GUARD: &str =
    "set -- $(ps -o tpgid=,pgid= -p $PPID 2>/dev/null); [ -n \"$1\" ] && [ \"$1\" = \"$2\" ] || exit 0; ";
fn is_current(entry: &Value, cli: &str) -> bool {
    entry["hooks"].as_array().is_some_and(|hooks| {
        hooks.iter().any(|hook| {
            hook["command"]
                .as_str()
                .is_some_and(|command| command.contains(MARKER) && (cli != "claude" || command.contains("tpgid")))
        })
    })
}
fn events(cli: &str) -> Vec<(&'static str, &'static str)> {
    let mut events = EVENTS.to_vec();
    if cli == "claude" {
        events.push(CLAUDE_SESSION)
    }
    events
}
fn hook_file(cli: &str) -> Result<(PathBuf, Value), ApiError> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| ApiError::bad_request("Home directory is unavailable"))?;
    match cli {
        "claude" => Ok((home.join(".claude/settings.json"), json!({}))),
        "codex" => Ok((home.join(".codex/hooks.json"), json!({"hooks":{}}))),
        _ => Err(ApiError::bad_request(format!("unknown CLI: {cli}"))),
    }
}
pub(crate) fn read_json(path: &PathBuf) -> Option<Value> {
    fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
}
/// An entry whose events reach this app with a run id: ours, and not from under the old name.
fn reports_here(entry: &Value) -> bool {
    entry["hooks"].as_array().is_some_and(|hooks| {
        hooks
            .iter()
            .any(|hook| hook["command"].as_str().is_some_and(|command| command.contains(MARKER)))
    })
}
fn is_our_entry(entry: &Value) -> bool {
    entry["hooks"].as_array().is_some_and(|hooks| {
        hooks.iter().any(|hook| {
            hook["command"]
                .as_str()
                .is_some_and(|command| command.contains(MARKER) || command.contains(LEGACY_MARKER))
        })
    })
}
fn hook_status_for(cli: &str) -> String {
    let Ok((file, _)) = hook_file(cli) else {
        return "absent".into();
    };
    let Some(value) = read_json(&file) else {
        return "absent".into();
    };
    let ours = |event: &str| {
        value["hooks"][event]
            .as_array()
            .is_some_and(|items| items.iter().any(reports_here))
    };
    let current = |event: &str| {
        value["hooks"][event]
            .as_array()
            .is_some_and(|items| items.iter().any(|entry| is_current(entry, cli)))
    };
    if !EVENTS.iter().all(|(event, _)| ours(event)) {
        "absent".into()
    } else if events(cli).iter().all(|(event, _)| current(event)) {
        "installed".into()
    } else {
        // Still reporting turns, but from before a hook or its guard was added. Installing again
        // replaces the entries.
        "outdated".into()
    }
}
fn hook_status() -> Value {
    json!({"claude":hook_status_for("claude"),"codex":hook_status_for("codex"),
        crate::agents::statusline::KEY:crate::agents::statusline::status()})
}
pub(crate) fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace(char::from(39), "'\"'\"'"))
}
fn hook_entry(cli: &str, endpoint: &str, port_file: &PathBuf) -> Value {
    let guard = if cli == "claude" { FOREGROUND_GUARD } else { "" };
    let script=format!("{guard}P=$(cat {} 2>/dev/null || echo 3000); curl -s -m 2 -X POST \"http://127.0.0.1:$P{endpoint}?cli={cli}&runId=${{CRAFT_RUN_ID:-}}\" -H \"Content-Type: application/json\" --data-binary @- >/dev/null 2>&1 || true # {MARKER}",shell_quote(&port_file.to_string_lossy()));
    let mut entry =
        json!({"hooks":[{"type":"command","command":format!("sh -c {}",shell_quote(&script))}]});
    if cli == "claude" {
        entry["matcher"] = json!(".*")
    }
    entry
}
pub(crate) fn write_json(path: &PathBuf, value: &Value) -> Result<(), ApiError> {
    let destination = fs::canonicalize(path).unwrap_or_else(|_| path.clone());
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(ApiError::internal)?
    }
    let temporary = destination.with_file_name(format!(".craft-hooks-{}.json", Uuid::new_v4()));
    let mut bytes = serde_json::to_vec_pretty(value).map_err(ApiError::internal)?;
    bytes.push(b'\n');
    fs::write(&temporary, bytes).map_err(ApiError::internal)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))
        .map_err(ApiError::internal)?;
    fs::rename(temporary, destination).map_err(ApiError::internal)
}
fn change_hooks(app: &AppState, cli_name: &str, install: bool) -> Result<Value, ApiError> {
    let (file, base) = hook_file(cli_name)?;
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
    for (event, endpoint) in events(cli_name) {
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
            entries.push(hook_entry(cli_name, endpoint, &port_file))
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
    app.broadcast(json!({"type":kind,"cli":query.cli.unwrap_or_default(),"runId":query.run_id.unwrap_or_default(),"sessionId":session,"source":body["source"].as_str().unwrap_or(""),"payload":body}));
    StatusCode::NO_CONTENT
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
    relay(app, query, body, "agent-turn-done").await
}

fn analysis_prompt(text: &str, context: &str) -> String {
    let workflow = !context.trim().is_empty();
    let mut prompt=format!("You are monitoring a coding agent in a terminal. Reply with ONLY a compact JSON object. Required fields: summary (max 18 words), state (done, needs_input, working, or blocked){}.",if workflow{", decision (proceed, retry, or stop), and reason (max 12 words)"}else{""});
    if workflow {
        prompt.push_str("\nWorkflow context: ");
        prompt.push_str(context)
    }
    prompt.push_str("\n---\n");
    prompt.push_str(text);
    prompt
}
fn parse_analysis(raw: &str, workflow: bool) -> Value {
    let trimmed = raw
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    let mut value = serde_json::from_str::<Value>(trimmed).unwrap_or_else(
        |_| json!({"summary":trimmed.lines().last().unwrap_or("").trim(),"state":""}),
    );
    if workflow
        && !matches!(
            value["decision"].as_str(),
            Some("proceed" | "retry" | "stop")
        )
    {
        value["decision"] = json!("proceed")
    }
    value
}
pub async fn agent_analyze(
    State(app): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let text = body["text"]
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("no text to analyze"))?;
    let context = body["context"].as_str().unwrap_or("");
    let agent = if body["cli"] == "codex" {
        "codex"
    } else {
        "claude"
    };
    let prompt = analysis_prompt(text, context);
    let result = if agent == "codex" {
        cli::run(
            "codex",
            [
                "exec",
                "--sandbox",
                "read-only",
                "--skip-git-repo-check",
                &prompt,
            ],
            Duration::from_secs(120),
        )
        .await
    } else {
        cli::run(
            "claude",
            ["-p", "--max-turns", "1", "--output-format", "text", &prompt],
            Duration::from_secs(120),
        )
        .await
    };
    match result {
        Ok(raw) => Ok(Json(parse_analysis(&raw, !context.trim().is_empty()))),
        Err(error) => {
            let _ = app.db.add_log(
                "agent",
                "error",
                "analyze_failed",
                &json!({"cli":agent,"error":error.to_string()}),
            );
            Err(ApiError::status(StatusCode::BAD_GATEWAY, error.to_string()))
        }
    }
}

pub async fn forwarders(State(app): State<AppState>) -> ApiResult<Vec<String>> {
    Ok(Json(app.forwarders.list().await))
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
    if let Ok(projects) = app.db.projects() {
        if let Some(project) = projects.into_iter().find(|p| {
            p["repo"]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(repo))
        }) {
            let mut pr = body["pull_request"].clone();
            pr["url"] = pr["html_url"].clone();
            pr["state"] = json!("MERGED");
            app.poller.handle_merge(&app, &project, &pr);
        }
    }
    StatusCode::OK
}

#[cfg(test)]
mod forwarder_tests {
    use super::*;

    #[test]
    fn claude_hooks_drop_nested_runs_and_older_entries_read_as_outdated() {
        let port = PathBuf::from("/tmp/.server-port");
        let claude = hook_entry("claude", "/api/hooks/turn-start", &port);
        let command = claude["hooks"][0]["command"].as_str().unwrap();
        assert!(command.contains("ps -o tpgid=,pgid= -p $PPID") && command.contains("|| exit 0;"));
        assert!(is_current(&claude, "claude"));
        let older = json!({"hooks":[{"type":"command","command":format!("sh -c 'curl x # {MARKER}'")}]});
        assert!(is_our_entry(&older) && !is_current(&older, "claude"));
        let codex = hook_entry("codex", "/api/hooks/turn-start", &port);
        assert!(!codex["hooks"][0]["command"].as_str().unwrap().contains("tpgid"));
        assert!(is_current(&codex, "codex") && is_current(&older, "codex"));
    }

    #[test]
    fn a_hook_installed_under_the_old_name_is_ours_to_replace_but_reports_nothing() {
        let legacy = json!({"hooks":[{"type":"command",
            "command":format!("sh -c 'ps -o tpgid= ; curl x?runId=${{TASKHUB_RUN_ID:-}} # {LEGACY_MARKER}'")}]});
        assert!(is_our_entry(&legacy) && !reports_here(&legacy));
        assert!(!is_current(&legacy, "claude") && !is_current(&legacy, "codex"));
    }

    #[test]
    fn only_claude_is_asked_for_session_starts() {
        assert!(events("claude").contains(&CLAUDE_SESSION));
        assert_eq!(events("codex"), EVENTS.to_vec());
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
}
