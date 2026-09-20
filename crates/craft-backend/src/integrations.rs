use std::{
    collections::{HashMap, HashSet},
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use chrono::{Datelike, Utc};
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
    /// The tail of the child's stderr. A reader task drains the pipe for as long as the forwarder
    /// runs: an undrained pipe fills and blocks `gh` mid-run, which `try_wait` would never see.
    stderr: Arc<Mutex<String>>,
}

/// Keep the last of a forwarder's stderr, for the failure it is about to report.
const STDERR_TAIL: usize = 2048;

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
                    let reason: String = tail.trim().chars().rev().take(500).collect::<Vec<_>>().into_iter().rev().collect();
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
                                if text.len() > STDERR_TAIL {
                                    let cut = text.len() - STDERR_TAIL;
                                    let cut = (cut..text.len()).find(|i| text.is_char_boundary(*i)).unwrap_or(text.len());
                                    *text = text[cut..].to_owned();
                                }
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

pub(crate) fn render_version_template(template: &str, pr_number: i64) -> Result<String, ApiError> {
    let raw = template.trim();
    if raw.is_empty() {
        return Err(ApiError::bad_request("version template is empty"));
    }
    if raw.contains("${")
        || raw.contains("return ")
        || raw.contains("=>")
        || raw.contains("function")
    {
        return Err(ApiError::bad_request("JavaScript version scripts are no longer executed. Replace this value with a template such as 0.{isoWeek}."));
    }
    let now = Utc::now();
    let replacements = [
        ("{year}", format!("{:04}", now.year())),
        ("{month}", format!("{:02}", now.month())),
        ("{day}", format!("{:02}", now.day())),
        ("{isoWeek}", format!("{:02}", now.iso_week().week())),
        ("{prNumber}", pr_number.to_string()),
    ];
    let mut value = raw.to_owned();
    for (key, replacement) in replacements {
        value = value.replace(key, &replacement)
    }
    if value.contains('{') || value.contains('}') || value.chars().any(char::is_control) {
        return Err(ApiError::bad_request(
            "Unknown or invalid version-template placeholder",
        ));
    }
    let value = value.trim();
    if value.is_empty() || value.len() > 128 {
        return Err(ApiError::bad_request(
            "version template must produce 1–128 characters",
        ));
    }
    Ok(value.into())
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
    let number = render_version_template(body["script"].as_str().unwrap_or(""), 0)?;
    let version = format!("{}{}", body["prefix"].as_str().unwrap_or(""), number);
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
        json!({"version":version,"number":number,"exists":existing.contains(&version)}),
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
    let (claude, codex, gh, acli, gh_webhook) = tokio::join!(
        probe("claude", None),
        probe("codex", None),
        probe("gh", Some(vec!["auth", "status"])),
        probe("acli", Some(vec!["jira", "auth", "status"])),
        gh_webhook
    );
    Ok(Json(
        json!({"claude":claude,"codex":codex,"gh":gh,"acli":acli,"ghWebhook":{"present":gh_webhook}}),
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
    fn backoff_grows_from_ten_seconds_and_caps_at_fifteen_minutes() {
        assert_eq!(backoff_delay(1), Duration::from_secs(20));
        assert_eq!(backoff_delay(2), Duration::from_secs(40));
        assert_eq!(backoff_delay(6), Duration::from_secs(640));
        assert_eq!(backoff_delay(7), MAX_BACKOFF);
        assert_eq!(backoff_delay(u32::MAX), MAX_BACKOFF);
    }
}
