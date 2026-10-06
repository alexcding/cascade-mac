//! The chat engine (`cascade-chat`) inside the backend: the one `ChatEngine` the app's chats run
//! on, and `POST /api/chat/rpc`, which serves the chat page's calls by the names and shapes of
//! Synara's WebSocket methods (`macos/web/chat/SYNARA.md`). The engine is one task; `Chat` on
//! `AppState` holds its handle, set once the backend has started it.
//!
//! The engine's CLIs are long-lived processes on pipes, so they go through the engine's own
//! `Spawner` seam rather than `cli::run`; the spawner here gives each what `cli::command` gives
//! every other child (the program resolved on the login shell's search path, `PATH`,
//! `SSH_AUTH_SOCK`) and keeps it out of Cascade's agent hooks (`CliSpawner`). Checkpoints run
//! `git` through `cli` itself.

mod flight;
mod knowledge;
mod titles;
mod transcript;
mod workspace;

use std::{
    io,
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
    time::Duration,
};

use axum::{
    extract::{rejection::JsonRejection, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use cascade_chat::{
    checkpointing::{git::GitFuture, GitOutput, GitRunner},
    checkpointing::diff_query::CheckpointDiffError,
    contracts::{
        base::{now_iso, ThreadId},
        orchestration::{
            ClientThreadCommand, OrchestrationGetFullThreadDiffInput, OrchestrationGetTurnDiffInput, OrchestrationThread, ThreadCreateCommand,
            ThreadTurnDiff, PROVIDER_SEND_TURN_MAX_FILE_BYTES, PROVIDER_SEND_TURN_MAX_IMAGE_BYTES,
        },
    },
    provider::attachment_projection::is_attachment_id,
    provider::process::{ChildProcess, ProcessSpawner, SpawnSpec, Spawner},
    ChatEngine, ChatEngineConfig, ChatEngineEvent, ChatError,
};
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};
use tokio::sync::broadcast;

use crate::{agents::Agent, cli, AppState, Event};

pub(crate) use transcript::transcript_thread;

/// The engine, once started, and what the RPCs keep between calls.
pub struct Chat {
    engine: OnceLock<ChatEngine>,
    /// `chat.providerStatuses`: one round of probes at a time, kept for `STATUS_TTL`.
    statuses: flight::Flights<(), Value>,
    /// The files of the folders chats work in, for the `@` menu and file references.
    files: workspace::Index,
    /// Where a chat created with no folder gets one of its own: `<data>/chat/workspaces`.
    scratch: OnceLock<PathBuf>,
}

impl Default for Chat {
    fn default() -> Self {
        Self { engine: OnceLock::new(), statuses: flight::Flights::new(STATUS_TTL, 1), files: workspace::Index::default(), scratch: OnceLock::new() }
    }
}

/// The largest body `POST /api/chat/rpc` takes, which the router sets on that route alone: an
/// `attachments.save` of the largest file the engine takes (`PROVIDER_SEND_TURN_MAX_FILE_BYTES`,
/// 25 MiB) is that file as base64, a third larger, plus the call around it.
pub const RPC_BODY_LIMIT: usize = 36 * 1024 * 1024;

/// The folder, in the engine's, that holds the scratch folders of chats created with none.
const SCRATCH_FOLDER: &str = "workspaces";
/// How long a scratch folder's `git init` may take.
const SCRATCH_INIT_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a provider's installed version stands before it is asked again.
const STATUS_TTL: Duration = Duration::from_secs(120);
/// How long `--version` may take.
const VERSION_TIMEOUT: Duration = Duration::from_secs(5);

impl Chat {
    pub fn engine(&self) -> Option<&ChatEngine> {
        self.engine.get()
    }

    /// Stops every chat's CLI and saves what is unsaved. The engine refuses calls afterwards.
    pub async fn shutdown(&self) {
        if let Some(engine) = self.engine.get() {
            engine.shutdown().await;
        }
    }
}

/// Starts the engine on `<data_dir>/chat` (`chat.db`, `attachments/`). A chat database that
/// cannot be opened leaves chats unavailable rather than the backend down.
pub async fn start(state: &AppState, data_dir: &Path) {
    let config = ChatEngineConfig {
        data_dir: data_dir.join("chat"),
        spawner: Arc::new(CliSpawner),
        adapters: None,
        publish: publisher(state.events.clone()),
        git: Some(Arc::new(CliGit)),
        text_generation: Some(Arc::new(titles::CliTitles::new())),
    };
    if let Err(error) = start_with(state, config).await {
        tracing::error!(error = %format!("{error:#}"), "chat: the engine did not start");
    }
}

/// Starts the engine with `config` as given; tests hand it a scripted spawner.
pub(crate) async fn start_with(state: &AppState, config: ChatEngineConfig) -> anyhow::Result<()> {
    let scratch = config.data_dir.join(SCRATCH_FOLDER);
    let engine = ChatEngine::start(config).await?;
    if let Err(engine) = state.chat.engine.set(engine) {
        engine.shutdown().await;
        anyhow::bail!("the chat engine was already started");
    }
    let _ = state.chat.scratch.set(scratch);
    Ok(())
}

/// The engine's events, as the app's `Event`s.
pub(crate) fn publisher(events: broadcast::Sender<Value>) -> Arc<dyn Fn(ChatEngineEvent) + Send + Sync> {
    Arc::new(move |event| {
        let event = match event {
            ChatEngineEvent::Thread { thread_id, events } => Event::ChatThread {
                thread_id: thread_id.as_str().to_owned(),
                events: serde_json::to_value(events).unwrap_or_default(),
            },
            ChatEngineEvent::Shell { shell } => Event::ChatShell { shell: serde_json::to_value(shell).unwrap_or_default() },
            ChatEngineEvent::Removed { thread_id } => Event::ChatRemoved { thread_id: thread_id.as_str().to_owned() },
        };
        let _ = events.send(event.into());
    })
}

/// Starts a chat's CLI as `cli::command` starts any other: by its path on the login shell's search
/// path (a bare name would make std fork inside the app), with that `PATH` and agent socket, in a
/// process group of its own (`ProcessSpawner`).
///
/// It also keeps the CLI out of Cascade's agent hooks. A hook reports under `CASCADE_RUN_ID` to the
/// app named by `CASCADE_PORT_FILE`, both set by a Cascade terminal; a backend started from one
/// would hand them on, and the chat's CLI would then report as that terminal's agent and offer
/// its tool approvals to that terminal's chat. Without them Claude's hooks stop at their
/// foreground guard (the CLI has no controlling terminal), and Codex's report with no run, which
/// the permission hook answers with no decision at once and the turn hooks only relay.
struct CliSpawner;

/// What a Cascade terminal sets for the agent hooks, kept from a chat's CLI.
const HOOK_VARIABLES: [&str; 2] = ["CASCADE_RUN_ID", "CASCADE_PORT_FILE"];

impl Spawner for CliSpawner {
    fn spawn(&self, spec: &SpawnSpec) -> io::Result<ChildProcess> {
        ProcessSpawner.spawn(&launch_spec(spec))
    }
}

fn launch_spec(spec: &SpawnSpec) -> SpawnSpec {
    let (program, mut env) = cli::launch(&spec.program);
    // The adapter's own variables come after, so one it sets wins.
    env.extend(spec.env.iter().cloned());
    let mut env_remove = spec.env_remove.clone();
    env_remove.extend(HOOK_VARIABLES.iter().map(|name| name.to_string()));
    SpawnSpec { program, args: spec.args.clone(), cwd: spec.cwd.clone(), env, env_remove }
}

/// Checkpoint git through `cli`, so it is resolved, grouped and timed out as every other git is.
struct CliGit;

const GIT_TIMEOUT: Duration = Duration::from_secs(60);

impl GitRunner for CliGit {
    fn run(&self, cwd: &Path, args: &[String], env: &[(String, String)]) -> GitFuture {
        let cwd = cwd.to_path_buf();
        let args = args.to_vec();
        let mut env = env.to_vec();
        env.push(("GIT_TERMINAL_PROMPT".into(), "0".into()));
        Box::pin(async move {
            let env: Vec<(&str, &str)> = env.iter().map(|(key, value)| (key.as_str(), value.as_str())).collect();
            match cli::run_raw("git", &args, GIT_TIMEOUT, Some(&cwd), &env).await {
                Ok(stdout) => Ok(GitOutput { code: Some(0), stdout: String::from_utf8_lossy(&stdout).into_owned(), stderr: String::new() }),
                Err(error) => match cli::Failure::of(&error) {
                    Some(cli::Failure::Exited(code)) => Ok(GitOutput { code, stdout: String::new(), stderr: error.to_string() }),
                    _ => Err(io::Error::other(format!("{error:#}"))),
                },
            }
        })
    }
}

// ---- the RPC ---------------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct RpcRequest {
    method: String,
    #[serde(default)]
    params: Value,
}

/// A call that failed, as the page's bridge reads it: `{error:{message, code?}}`.
#[derive(Debug)]
pub(crate) struct RpcError {
    status: StatusCode,
    message: String,
    code: Option<&'static str>,
}

impl RpcError {
    /// The request breaks a rule: a decider's rejection, or params that do not decode.
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self { status: StatusCode::BAD_REQUEST, message: message.into(), code: Some("invalid") }
    }

    /// Nothing serves it: a method not served, a provider that cannot, an engine not started.
    pub(crate) fn unavailable(message: impl Into<String>) -> Self {
        Self { status: StatusCode::NOT_FOUND, message: message.into(), code: Some("unavailable") }
    }

    pub(crate) fn not_found(message: impl Into<String>) -> Self {
        Self { status: StatusCode::NOT_FOUND, message: message.into(), code: None }
    }

    pub(crate) fn internal(error: impl std::fmt::Display) -> Self {
        tracing::error!(error = %error, "chat: a call failed");
        Self { status: StatusCode::INTERNAL_SERVER_ERROR, message: error.to_string(), code: None }
    }
}

impl IntoResponse for RpcError {
    fn into_response(self) -> Response {
        let mut error = json!({ "message": self.message });
        if let Some(code) = self.code {
            error["code"] = json!(code);
        }
        (self.status, Json(json!({ "error": error }))).into_response()
    }
}

type RpcResult = Result<Value, RpcError>;

/// A body the route would not take: not JSON, not `{method, params}`, or past `RPC_BODY_LIMIT`.
/// Answered in the shape every other failure is, with the status the rejection carries (413 for
/// one too large).
impl From<JsonRejection> for RpcError {
    fn from(rejection: JsonRejection) -> Self {
        Self { status: rejection.status(), message: rejection.body_text(), code: Some("invalid") }
    }
}

/// `POST /api/chat/rpc` `{method, params}` → `{result}`.
pub async fn rpc(State(app): State<AppState>, headers: HeaderMap, request: Result<Json<RpcRequest>, JsonRejection>) -> Response {
    if crate::local::foreign_origin(&headers) {
        return (StatusCode::FORBIDDEN, Json(json!({"error": {"message": "forbidden"}}))).into_response();
    }
    let request = match request {
        Ok(Json(request)) => request,
        Err(rejection) => return RpcError::from(rejection).into_response(),
    };
    match call(&app, &request.method, request.params).await {
        Ok(result) => Json(json!({ "result": result })).into_response(),
        Err(error) => error.into_response(),
    }
}

async fn call(app: &AppState, method: &str, params: Value) -> RpcResult {
    match method {
        "orchestration.getThreadDetailSnapshot" => thread_detail(app, params).await,
        "orchestration.dispatchCommand" => dispatch(app, params).await,
        "orchestration.getShellSnapshot" => shell_snapshot(app).await,
        "orchestration.getTurnDiff" => turn_diff(app, params).await,
        "orchestration.getFullThreadDiff" => full_thread_diff(app, params).await,
        "provider.listModels" => list_models(app, params).await,
        "provider.getComposerCapabilities" => composer_capabilities(params),
        "provider.listCommands" => list_commands(app, params).await,
        "provider.listSkills" => Ok(json!({ "skills": [] })),
        "provider.listPlugins" => {
            Ok(json!({ "marketplaces": [], "marketplaceLoadErrors": [], "remoteSyncError": null, "featuredPluginIds": [] }))
        }
        "provider.listAgents" => Ok(json!({ "agents": [] })),
        "provider.compactThread" => compact_thread(app, params).await,
        "projects.searchEntries" => {
            let folder = folder_of_call(app, &params).await?;
            workspace::search_entries(&app.chat.files, &folder, params).await
        }
        "projects.readFile" => {
            let folder = folder_of_call(app, &params).await?;
            workspace::read_file(&folder, params).await
        }
        "projects.resolveWorkspaceFileReferences" => {
            let folder = folder_of_call(app, &params).await?;
            workspace::resolve_references(&app.chat.files, &folder, params).await
        }
        "attachments.save" => save_attachment(app, params).await,
        "attachments.read" => read_attachment(app, params).await,
        "chat.listThreads" => list_threads(app, params).await,
        "chat.providerStatuses" => Ok(provider_statuses(app).await),
        "chat.sessionKnowledge" => session_knowledge(app, params).await,
        _ => Err(RpcError::unavailable(format!("{method} is not served"))),
    }
}

pub(crate) fn params<T: DeserializeOwned>(params: Value) -> Result<T, RpcError> {
    serde_json::from_value(if params.is_null() { json!({}) } else { params })
        .map_err(|error| RpcError::invalid(format!("bad params: {error}")))
}

fn engine(app: &AppState) -> Result<&ChatEngine, RpcError> {
    app.chat.engine().ok_or_else(|| RpcError::unavailable("chats are not available"))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadParams {
    thread_id: String,
}

async fn thread_detail(app: &AppState, raw: Value) -> RpcResult {
    let ThreadParams { thread_id } = params(raw)?;
    let detail = engine(app)?.thread_detail(ThreadId::new(thread_id)).await.map_err(RpcError::internal)?;
    Ok(match detail {
        Some((thread, sequence)) => json!({ "snapshotSequence": sequence, "thread": thread }),
        None => Value::Null,
    })
}

/// Every chat's shell, as Synara's `OrchestrationShellSnapshot`: how the page finds a thread it
/// just made (a fork) before it opens it.
async fn shell_snapshot(app: &AppState) -> RpcResult {
    let snapshot = engine(app)?.shell_snapshot().await.map_err(RpcError::internal)?;
    Ok(json!(snapshot))
}

/// A diff's failure as the page reads it: the request or thread is wrong (`invalid`), the
/// checkpoint is not there (yet), or git failed.
fn diff_result(result: Result<ThreadTurnDiff, CheckpointDiffError>) -> RpcResult {
    match result {
        Ok(diff) => Ok(json!(diff)),
        Err(CheckpointDiffError::Invariant(detail)) => Err(RpcError::invalid(detail)),
        Err(CheckpointDiffError::Unavailable { detail, .. }) => Err(RpcError::not_found(detail)),
        Err(CheckpointDiffError::Failed(detail)) => Err(RpcError::internal(detail)),
    }
}

/// `orchestration.getTurnDiff {threadId, fromTurnCount, toTurnCount, ignoreWhitespace?}`: git
/// between the thread's checkpoint refs, in its own folder.
async fn turn_diff(app: &AppState, raw: Value) -> RpcResult {
    let input: OrchestrationGetTurnDiffInput = params(raw)?;
    diff_result(engine(app)?.turn_diff(input).await)
}

/// `orchestration.getFullThreadDiff {threadId, toTurnCount, ignoreWhitespace?}`
async fn full_thread_diff(app: &AppState, raw: Value) -> RpcResult {
    let input: OrchestrationGetFullThreadDiffInput = params(raw)?;
    diff_result(engine(app)?.full_thread_diff(input).await)
}

#[derive(Deserialize)]
struct DispatchParams {
    command: ClientThreadCommand,
}

async fn dispatch(app: &AppState, raw: Value) -> RpcResult {
    let DispatchParams { command } = params(raw)?;
    run_command(app, command).await
}

async fn run_command(app: &AppState, command: ClientThreadCommand) -> RpcResult {
    run_command_in(app, command, crate::agents::home()).await
}

/// [`run_command`] with the home folder the agents' transcripts are under: a `thread.create`
/// that starts with a session's knowledge has it made whole first (`knowledge::resolve`).
async fn run_command_in(app: &AppState, mut command: ClientThreadCommand, home: Option<PathBuf>) -> RpcResult {
    let mut scratch: Option<PathBuf> = None;
    if let ClientThreadCommand::Create(create) = &mut command {
        if let Some(source) = create.knowledge_source.take() {
            let worktree = create
                .worktree_path
                .clone()
                .or_else(|| create.working_directory.clone().flatten())
                .filter(|path| path.starts_with('/'))
                .ok_or_else(|| RpcError::invalid("A chat starts with a session's knowledge only in that session's worktree."))?;
            if !is_session_worktree(app, &worktree).await? {
                return Err(RpcError::invalid("A chat starts with a session's knowledge only in a session's worktree."));
            }
            let held = engine(app)?.chat_conversations().await.map_err(RpcError::internal)?;
            let home = home.ok_or_else(|| RpcError::internal("no home folder"))?;
            let resolved = tokio::task::spawn_blocking(move || knowledge::resolve(&home, source, &worktree, &held))
                .await
                .map_err(RpcError::internal)?
                .map_err(RpcError::invalid)?;
            create.knowledge_source = Some(resolved);
        }
        scratch = give_scratch_folder(app, create).await?;
    }
    let deleted = match &command {
        ClientThreadCommand::Delete(delete) => engine(app)?.thread(delete.thread_id.clone()).await.ok().flatten(),
        _ => None,
    };
    let created_folder = match &command {
        ClientThreadCommand::Create(create) => create.working_directory.clone().flatten(),
        _ => None,
    };
    match engine(app)?.dispatch(command).await {
        Ok(result) => {
            if let Some(thread) = deleted {
                remove_scratch_folder(app, &thread).await;
            }
            let mut result = json!(result);
            // The folder the chat works in, which the app shows before the chat's shell comes.
            if let Some(folder) = created_folder {
                result["workingDirectory"] = json!(folder);
            }
            Ok(result)
        }
        Err(error) => {
            // A create the engine refused leaves no folder behind.
            if let Some(folder) = scratch {
                let _ = std::fs::remove_dir_all(folder);
            }
            match error {
                ChatError::Invalid(detail) => Err(RpcError::invalid(detail)),
                ChatError::Internal(error) => Err(RpcError::internal(format!("{error:#}"))),
            }
        }
    }
}

/// A chat created with no folder and no worktree (New Task's, which belongs to no project) works
/// in a private folder of its own, `<data>/chat/workspaces/<thread id>`, made here as a git
/// repository of its own: the engine checkpoints a turn's changes there (the diff, revert), and a
/// data folder that happens to sit inside another repository (a development build's, or a home
/// folder kept in git) is not taken for that repository, whose checkpoint of every file it tracks
/// held the first turn back for seconds. A failed `git init` leaves a plain folder, without
/// checkpoints.
/// Answers the folder when it made one (it did not exist before), to be removed if the create
/// is refused.
async fn give_scratch_folder(app: &AppState, create: &mut ThreadCreateCommand) -> Result<Option<PathBuf>, RpcError> {
    let named = |folder: &Option<String>| folder.as_deref().is_some_and(|folder| !folder.trim().is_empty());
    if named(&create.working_directory.clone().flatten()) || named(&create.worktree_path) {
        return Ok(None);
    }
    let root = app.chat.scratch.get().ok_or_else(|| RpcError::unavailable("chats are not available"))?;
    let id = create.thread_id.as_str();
    if id.is_empty() || id.contains('/') || id.contains("..") || id.starts_with('.') {
        return Err(RpcError::invalid("A chat's id names no folder."));
    }
    let folder = root.join(id);
    let existed = folder.exists();
    std::fs::create_dir_all(&folder).map_err(RpcError::internal)?;
    if let Err(error) = cli::run_in("git", ["init", "-q"], SCRATCH_INIT_TIMEOUT, Some(&folder)).await {
        tracing::warn!(folder = %folder.display(), error = %format!("{error:#}"), "chat: the scratch folder is not a repository");
    }
    create.working_directory = Some(Some(folder.to_string_lossy().into_owned()));
    Ok((!existed).then_some(folder))
}

/// A deleted chat's scratch folder goes with it, unless another chat still works there (a fork).
async fn remove_scratch_folder(app: &AppState, thread: &OrchestrationThread) {
    let (Some(root), Some(engine)) = (app.chat.scratch.get(), app.chat.engine()) else { return };
    let Some(folder) = folder_of(thread).map(PathBuf::from) else { return };
    // Only a folder `give_scratch_folder` makes: one plain name right under the root (a fork's is
    // its source's). A path that merely sits under it (`…/workspaces/..`) is never removed.
    let mut components = folder.strip_prefix(root).map(|rest| rest.components().collect::<Vec<_>>()).unwrap_or_default();
    if components.len() != 1 || !matches!(components.pop(), Some(std::path::Component::Normal(_))) {
        return;
    }
    let shells = engine.shells(None).await.unwrap_or_default();
    let shared = shells.iter().any(|shell| {
        shell.id != thread.id && [&shell.working_directory, &shell.worktree_path].into_iter().flatten().any(|f| PathBuf::from(f) == folder)
    });
    if !shared {
        if let Err(error) = std::fs::remove_dir_all(&folder) {
            tracing::warn!(folder = %folder.display(), %error, "chat: a scratch folder was not removed");
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionKnowledgeParams {
    provider: String,
    worktree: String,
    #[serde(default)]
    conversation_id: Option<String>,
}

/// Whether `worktree` is a Cascade session's: the only folder whose agent a chat may start
/// knowing.
async fn is_session_worktree(app: &AppState, worktree: &str) -> Result<bool, RpcError> {
    let trimmed = |path: &str| path.trim_end_matches('/').to_owned();
    let sessions = app.db.tasks().await.map_err(RpcError::internal)?;
    Ok(sessions.iter().any(|session| !session.worktree.is_empty() && trimmed(&session.worktree) == trimmed(worktree)))
}

/// `chat.sessionKnowledge`: whether a chat started in a session's pane can start with what the
/// session's agent knows (`knowledge::describe`), by the rule a `thread.create` is held to.
async fn session_knowledge(app: &AppState, raw: Value) -> RpcResult {
    session_knowledge_in(app, raw, crate::agents::home()).await
}

async fn session_knowledge_in(app: &AppState, raw: Value, home: Option<PathBuf>) -> RpcResult {
    let SessionKnowledgeParams { provider, worktree, conversation_id } = params(raw)?;
    let Some(home) = home else { return Ok(Value::Null) };
    if !is_session_worktree(app, &worktree).await? {
        return Ok(Value::Null);
    }
    let held = engine(app)?.chat_conversations().await.map_err(RpcError::internal)?;
    tokio::task::spawn_blocking(move || knowledge::describe(&home, &provider, &worktree, conversation_id.as_deref(), &held))
        .await
        .map_err(RpcError::internal)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderParams {
    provider: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    thread_id: Option<String>,
}

/// The models the CLI offers, as the terminal's model menu reads them (`Agent::catalog`), with
/// the engine's own list when the CLI could not be asked.
async fn list_models(app: &AppState, raw: Value) -> RpcResult {
    let ProviderParams { provider, .. } = params(raw)?;
    let Some(agent) = Agent::of_chat_provider(&provider) else {
        return Ok(json!({ "models": [] }));
    };
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let catalog = agent.catalog(&home).await;
    let models: Vec<Value> = catalog["models"].as_array().into_iter().flatten().filter_map(model_descriptor).collect();
    if !models.is_empty() {
        return Ok(json!({ "models": models, "source": "cli" }));
    }
    let fallback: Vec<Value> = engine(app)?
        .providers()
        .await
        .into_iter()
        .filter(|info| info.provider.as_str() == provider)
        .flat_map(|info| info.models)
        .map(|model| json!({ "slug": model.slug, "name": model.name }))
        .collect();
    Ok(json!({ "models": fallback, "source": "static", "error": "The CLI did not list its models." }))
}

/// A catalog row (`{"id","alias","name","efforts":[{"id","name"}],"defaultEffort"}`) as Synara's
/// `ProviderModelDescriptor`.
fn model_descriptor(row: &Value) -> Option<Value> {
    let slug = row["id"].as_str().filter(|id| !id.trim().is_empty())?;
    let name = row["name"].as_str().filter(|name| !name.trim().is_empty()).unwrap_or(slug);
    let mut descriptor = json!({ "slug": slug, "name": name });
    let efforts: Vec<Value> = row["efforts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|effort| {
            let value = effort["id"].as_str().filter(|id| !id.trim().is_empty())?;
            let mut descriptor = json!({ "value": value });
            if let Some(label) = effort["name"].as_str().filter(|name| !name.trim().is_empty()) {
                descriptor["label"] = json!(label);
            }
            Some(descriptor)
        })
        .collect();
    if !efforts.is_empty() {
        descriptor["supportedReasoningEfforts"] = json!(efforts);
    }
    if let Some(effort) = row["defaultEffort"].as_str().filter(|effort| !effort.trim().is_empty()) {
        descriptor["defaultReasoningEffort"] = json!(effort);
    }
    Some(descriptor)
}

/// What the composer may offer: `/` commands from the files the CLI reads (`provider.listCommands`),
/// the model list, and compaction where a prompt compacts. No skills, plugins or imports.
fn composer_capabilities(raw: Value) -> RpcResult {
    let ProviderParams { provider, .. } = params(raw)?;
    let agent = Agent::of_chat_provider(&provider);
    Ok(json!({
        "provider": provider,
        "supportsSkillMentions": false,
        "supportsSkillDiscovery": false,
        "supportsNativeSlashCommandDiscovery": agent.is_some(),
        "supportsPluginMentions": false,
        "supportsPluginDiscovery": false,
        "supportsRuntimeModelList": agent.is_some(),
        "supportsThreadCompaction": agent.is_some_and(|agent| agent.profile().compact_prompt.is_some()),
        "supportsThreadImport": false,
    }))
}

/// The folder a call is about. When it names a thread the engine has, that thread's own working
/// folder and nothing else, whatever `cwd` says: the page's `cwd` cannot widen what a chat reads.
/// `cwd` stands only for a call that names no thread, or one not created yet (the composer of a
/// new chat).
async fn working_folder(app: &AppState, thread_id: Option<&str>, cwd: Option<&str>) -> Result<String, RpcError> {
    if let (Some(thread_id), Some(engine)) = (thread_id.filter(|id| !id.is_empty()), app.chat.engine()) {
        if let Some(thread) = engine.thread(ThreadId::new(thread_id)).await.map_err(RpcError::internal)? {
            return folder_of(&thread).ok_or_else(|| RpcError::invalid("This chat has no folder."));
        }
    }
    cwd.filter(|cwd| !cwd.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| RpcError::invalid("cwd required"))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FolderParams {
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    thread_id: Option<String>,
}

/// `working_folder` for a `projects.*` call's `{cwd, threadId?}`.
async fn folder_of_call(app: &AppState, raw: &Value) -> Result<String, RpcError> {
    let FolderParams { cwd, thread_id } = params(raw.clone())?;
    working_folder(app, thread_id.as_deref(), cwd.as_deref()).await
}

fn folder_of(thread: &OrchestrationThread) -> Option<String> {
    [&thread.working_directory, &thread.worktree_path]
        .into_iter()
        .flatten()
        .find(|folder| !folder.trim().is_empty())
        .cloned()
}

async fn list_commands(app: &AppState, raw: Value) -> RpcResult {
    let ProviderParams { provider, cwd, thread_id } = params(raw)?;
    let Some(agent) = Agent::of_chat_provider(&provider) else {
        return Ok(json!({ "commands": [] }));
    };
    let folder = working_folder(app, thread_id.as_deref(), cwd.as_deref()).await?;
    let found = crate::agents::commands_in(agent, PathBuf::from(folder)).await;
    let commands: Vec<Value> = found["commands"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|command| {
            let name = command["name"].as_str().filter(|name| !name.trim().is_empty())?;
            let mut descriptor = json!({ "name": name });
            if let Some(description) = command["description"].as_str().filter(|text| !text.trim().is_empty()) {
                descriptor["description"] = json!(description);
            }
            Some(descriptor)
        })
        .collect();
    Ok(json!({ "commands": commands, "source": "cascade" }))
}

/// Compaction is a turn whose prompt the CLI takes as its compact command (`/compact` for Claude
/// Code, which runs it in a headless session as in a terminal). A CLI with no such prompt, Codex
/// among them, answers `unavailable`, and its composer does not offer it.
async fn compact_thread(app: &AppState, raw: Value) -> RpcResult {
    let ThreadParams { thread_id } = params(raw)?;
    let engine = engine(app)?;
    let thread = engine
        .thread(ThreadId::new(thread_id.clone()))
        .await
        .map_err(RpcError::internal)?
        .ok_or_else(|| RpcError::not_found("no such chat"))?;
    let provider = serde_json::to_value(&thread.model_selection).map_err(RpcError::internal)?["provider"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let prompt = Agent::of_chat_provider(&provider)
        .and_then(|agent| agent.profile().compact_prompt)
        .ok_or_else(|| RpcError::unavailable("This provider cannot compact a conversation."))?;
    let command: ClientThreadCommand = serde_json::from_value(json!({
        "type": "thread.turn.start",
        "commandId": format!("compact:{}", uuid::Uuid::new_v4()),
        "threadId": thread_id,
        "message": { "messageId": uuid::Uuid::new_v4().to_string(), "role": "user", "text": prompt, "attachments": [] },
        "dispatchMode": "queue",
        "runtimeMode": thread.runtime_mode,
        "interactionMode": thread.interaction_mode,
        "createdAt": now_iso(),
    }))
    .map_err(RpcError::internal)?;
    run_command(app, command).await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AttachmentParams {
    thread_id: String,
    name: String,
    mime_type: String,
    data_base64: String,
}

async fn save_attachment(app: &AppState, raw: Value) -> RpcResult {
    let AttachmentParams { thread_id, name, mime_type, data_base64 } = params(raw)?;
    // Refused before it is decoded, by the engine's own limits (`ChatEngine::save_attachment`).
    let limit = match mime_type.to_ascii_lowercase().starts_with("image/") {
        true => PROVIDER_SEND_TURN_MAX_IMAGE_BYTES,
        false => PROVIDER_SEND_TURN_MAX_FILE_BYTES,
    };
    if decoded_length(&data_base64) > limit {
        return Err(RpcError::invalid(format!("'{name}' is larger than the {} MB an attachment may be.", limit / (1024 * 1024))));
    }
    let bytes = decode_base64(&data_base64).ok_or_else(|| RpcError::invalid("dataBase64 is not base64"))?;
    let attachment = engine(app)?
        .save_attachment(ThreadId::new(thread_id), name, mime_type, bytes)
        .await
        .map_err(|error| RpcError::invalid(format!("{error:#}")))?;
    Ok(json!(attachment))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadAttachmentParams {
    attachment_id: String,
}

/// `attachments.read {attachmentId}` → `{mimeType, dataBase64}`: a saved chat attachment, for the
/// image URLs the page shows. Only an attachment id names one (`is_attachment_id`: no path, no
/// extension), and only a file in the attachments folder, no larger than an attachment may be,
/// is read.
async fn read_attachment(app: &AppState, raw: Value) -> RpcResult {
    let ReadAttachmentParams { attachment_id } = params(raw)?;
    if !is_attachment_id(&attachment_id) {
        return Err(RpcError::invalid("not an attachment id"));
    }
    let (path, bytes) = engine(app)?
        .read_attachment(attachment_id)
        .await
        .map_err(RpcError::internal)?
        .ok_or_else(|| RpcError::not_found("no such attachment"))?;
    let mime_type = mime_guess::from_path(&path).first_or_octet_stream();
    Ok(json!({ "mimeType": mime_type.essence_str(), "dataBase64": encode_base64(&bytes) }))
}

/// Standard base64, padded.
fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = u32::from(chunk[0]) << 16 | u32::from(*chunk.get(1).unwrap_or(&0)) << 8 | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * index)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// How many bytes `text` decodes to, as `decode_base64` counts them, without decoding it.
fn decoded_length(text: &str) -> u64 {
    let digits = text.bytes().take_while(|byte| *byte != b'=').filter(|byte| !byte.is_ascii_whitespace()).count() as u64;
    digits * 6 / 8
}

/// Standard or URL-safe base64, padded or not, whitespace ignored.
fn decode_base64(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let (mut buffer, mut bits) = (0u32, 0u32);
    for byte in text.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => break,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListParams {
    #[serde(default)]
    project_id: Option<String>,
}

async fn list_threads(app: &AppState, raw: Value) -> RpcResult {
    let ListParams { project_id } = params(raw)?;
    let shells = engine(app)?.shells(project_id).await.map_err(RpcError::internal)?;
    Ok(json!(shells))
}

/// Synara's `ServerProviderStatus` for each CLI the engine drives: whether it is installed, its
/// version, and the models the engine knows for it. Kept for `STATUS_TTL`: `--version` starts the
/// CLI. The CLIs are asked at once, and calls that come while they are being asked wait for
/// those answers.
async fn provider_statuses(app: &AppState) -> Value {
    app.chat.statuses.get(&(), || probe_providers(app)).await
}

async fn probe_providers(app: &AppState) -> Value {
    let providers = match app.chat.engine() {
        Some(engine) => engine.providers().await,
        None => Vec::new(),
    };
    let probes = Agent::ALL.into_iter().map(|agent| async move {
        let command = agent.profile().command;
        let installed = cli::find(command).is_some();
        let version = match installed {
            true => cli::run(command, ["--version"], VERSION_TIMEOUT).await.ok(),
            false => None,
        };
        (installed, version.as_deref().and_then(version_of))
    });
    let probed = futures_util::future::join_all(probes).await;
    let mut statuses = Vec::new();
    for (agent, (installed, version)) in Agent::ALL.into_iter().zip(probed) {
        let profile = agent.profile();
        let models: Vec<Value> = providers
            .iter()
            .filter(|info| info.provider.as_str() == profile.chat_provider)
            .flat_map(|info| info.models.iter())
            .map(|model| json!({ "slug": model.slug, "name": model.name, "isDefault": model.is_default }))
            .collect();
        let mut status = json!({
            "provider": profile.chat_provider,
            "instanceId": profile.chat_provider,
            "driver": profile.chat_provider,
            "displayName": profile.display_name,
            "enabled": true,
            "status": if !installed { "error" } else if version.is_some() { "ready" } else { "warning" },
            "available": installed,
            "availability": if installed { "available" } else { "unavailable" },
            "authStatus": "unknown",
            "version": version,
            "checkedAt": now_iso(),
            "models": models,
        });
        if !installed {
            let message = format!("{} is not installed: `{}` was not found on the PATH.", profile.display_name, profile.command);
            status["message"] = json!(message);
            status["unavailableReason"] = json!(message);
        } else if version.is_none() {
            status["message"] = json!(format!("`{} --version` did not answer.", profile.command));
        }
        statuses.push(status);
    }
    Value::Array(statuses)
}

/// The version in a `--version` line: `2.1.288 (Claude Code)` and `codex-cli 0.156.1` both
/// answer their number.
fn version_of(output: &str) -> Option<String> {
    output
        .split_whitespace()
        .map(|word| word.trim_start_matches('v'))
        .find(|word| word.chars().next().is_some_and(|c| c.is_ascii_digit()) && word.contains('.'))
        .map(str::to_owned)
}

#[cfg(test)]
mod tests;
