//! One probe per agent CLI. The app's footer asks two things of whichever CLI a session runs:
//! what it could switch to, and what it is running right now. Each CLI answers from its own
//! records, so nothing here infers a model's context window: Claude Code reports it to its status
//! line, and Codex writes it into its session file.

mod claude;
mod codex;
mod commands;
pub mod permission;
pub mod statusline;
pub(crate) mod transcript;
pub(crate) mod usage;

use axum::{extract::Query, Json};
use serde_json::{json, Value};
use std::{
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

/// What a CLI has to be able to tell the app: each CLI is one adapter (`claude.rs`, `codex.rs`)
/// implementing it, and `Agent` picks the adapter. `catalog` and `reported_commands` may run the
/// CLI, so they are async; the rest only read files, and run on the blocking pool.
pub trait AgentProbe {
    /// What the app may count on from the CLI, so that it never needs to know which one it has.
    const PROFILE: Profile;
    /// How the CLI takes Cascade's hooks.
    const HOOKS: Hooks;
    /// It keeps each conversation in a file its id names, found without a search. One that does
    /// not has its newest transcript searched for, which is slow, so the search is kept a while.
    const NAMES_CONVERSATION_FILES: bool = false;
    /// `{"models":[{"id","alias","name","efforts":[{"id","name"}],"defaultEffort"}]}`. `alias` is
    /// what the CLI accepts when asked to switch; `id` is what `status` reports back.
    async fn catalog(home: &Path) -> Value;
    /// `{"model","effort","tokens","window","percent"}`, each null when the CLI has not said.
    fn status(home: &Path, worktree: &str, task: &str) -> Option<Value>;
    /// The file the conversation in `worktree` is written to: `conversation`, when the app knows it
    /// and the CLI keeps conversations by id, or the newest.
    fn transcript_file(home: &Path, worktree: &str, conversation: Option<&str>) -> Option<PathBuf>;
    /// Whether the CLI can still resume conversation `id`; None when the app does not read its
    /// storage, and takes it at its word.
    fn has_conversation(_home: &Path, _id: &str) -> Option<bool> {
        None
    }
    /// What a fork of the conversation in `worktree` resumes from, in the form the app's driver
    /// hands the CLI: `conversation`, when the app knows it, or the worktree's newest. None when
    /// there is nothing on disk to fork, and the fork starts a new conversation.
    fn fork_source(home: &Path, worktree: &str, conversation: Option<&str>) -> Option<String>;
    /// Conversation `id`'s own transcript, held for `worktree` exactly: none when it is not on
    /// disk there (filed for another folder, or only the worktree's newest). What a chat that
    /// starts with a session's knowledge reads and forks (`chat::knowledge`).
    fn conversation_in_worktree(home: &Path, worktree: &str, id: &str) -> Option<PathBuf>;
    /// The slash commands the CLI reports itself, ahead of those found on disk.
    async fn reported_commands() -> Value {
        Value::Null
    }
    /// What one of its tools does, in the kinds the app draws every CLI's tools by: `run`, `read`,
    /// `edit`, `patch`, `create`, `search`, `fetch`, `web`, `delegate`, `plan` or `other`.
    fn tool_kind(name: &str) -> &'static str;
    /// The file a tool call would change and both sides of the change, from the call's input: the
    /// path, what is there, and what would be.
    fn tool_change(_name: &str, _input: &Value) -> Option<(String, String, String)> {
        None
    }
    /// Its Stop hook's payload says the turn ended with work it set going in the background still
    /// running: the agent is not done, and takes up what that work reports in a turn of its own.
    fn works_on(_stop: &Value) -> bool {
        false
    }
    /// The last 30 days of its use (`agents::usage::daily`), or None when it cannot be read.
    async fn usage() -> Option<Value> {
        None
    }
    /// Its plan's allowance windows, `{"session","weekly","scoped"}`, or None when unknown.
    async fn limits() -> Option<Value> {
        None
    }
}

/// What the app may count on from a CLI. It travels with the CLI's transcript, and the app acts on
/// it rather than on the CLI's name.
#[derive(serde::Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    /// The name sessions, hooks and requests carry.
    pub id: &'static str,
    /// The executable the CLI runs as.
    pub command: &'static str,
    /// It keeps a message typed while it works and takes it in, mid-turn or after, so the chat may
    /// type one then.
    pub queues_mid_turn: bool,
    /// The provider the chat engine (`cascade-chat`, Synara's `ProviderKind`) drives it as. The
    /// backend's own: the terminal's chat does not need it.
    #[serde(skip)]
    pub chat_provider: &'static str,
    /// What the chat's provider list calls it.
    #[serde(skip)]
    pub display_name: &'static str,
    /// The prompt that compacts its conversation, when a prompt can (`provider.compactThread`).
    #[serde(skip)]
    pub compact_prompt: Option<&'static str>,
}

/// How a CLI takes Cascade's hooks (`integrations`).
#[derive(Clone, Copy, Debug)]
pub struct Hooks {
    /// Its hooks file, from the home directory.
    pub file: &'static str,
    /// What that file holds with nothing in it.
    pub empty: &'static str,
    /// It says when its conversation changes under a running agent (`SessionStart`).
    pub reports_sessions: bool,
    /// A run of it nested in one of the agent's tools fires hooks too, so each hook answers only
    /// for the terminal's own agent (`FOREGROUND_GUARD`).
    pub foreground_only: bool,
    /// Each entry names the tools it applies to.
    pub matches_tools: bool,
    /// The hooks it fires as a tool call or a subagent starts and ends, by its own event names:
    /// what the Live tab draws as it happens (`integrations::tool_event`). Installed in the background, so only
    /// for a CLI that really runs an `async` hook without waiting on it.
    pub tool_events: &'static [&'static str],
}

/// A CLI Cascade runs agents in: the one place that tells them apart by name. Callers take
/// `Agent::of(cli)` and ask it, and never compare names themselves.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub const ALL: [Agent; 2] = [Agent::Claude, Agent::Codex];

    pub fn of(cli: &str) -> Option<Agent> {
        Self::ALL.into_iter().find(|agent| agent.profile().id == cli)
    }

    /// The CLI the chat engine drives as `provider` (Synara's `ProviderKind`, `claudeAgent`).
    pub fn of_chat_provider(provider: &str) -> Option<Agent> {
        Self::ALL.into_iter().find(|agent| agent.profile().chat_provider == provider)
    }

    /// Whether a session may name `cli`: no agent at all, a plain shell, or one the registry
    /// knows. Creating a session and patching one apply the same rule.
    pub fn allowed_cli(cli: &str) -> bool {
        cli.is_empty() || Self::of(cli).is_some()
    }

    pub fn profile(self) -> Profile {
        match self {
            Agent::Claude => claude::Claude::PROFILE,
            Agent::Codex => codex::Codex::PROFILE,
        }
    }

    pub(crate) async fn catalog(self, home: &Path) -> Value {
        match self {
            Agent::Claude => claude::Claude::catalog(home).await,
            Agent::Codex => codex::Codex::catalog(home).await,
        }
    }

    fn status(self, home: &Path, worktree: &str, task: &str) -> Option<Value> {
        match self {
            Agent::Claude => claude::Claude::status(home, worktree, task),
            Agent::Codex => codex::Codex::status(home, worktree, task),
        }
    }

    pub fn hooks(self) -> Hooks {
        match self {
            Agent::Claude => claude::Claude::HOOKS,
            Agent::Codex => codex::Codex::HOOKS,
        }
    }

    fn names_conversation_files(self) -> bool {
        match self {
            Agent::Claude => claude::Claude::NAMES_CONVERSATION_FILES,
            Agent::Codex => codex::Codex::NAMES_CONVERSATION_FILES,
        }
    }

    fn transcript_file(self, home: &Path, worktree: &str, conversation: Option<&str>) -> Option<PathBuf> {
        match self {
            Agent::Claude => claude::Claude::transcript_file(home, worktree, conversation),
            Agent::Codex => codex::Codex::transcript_file(home, worktree, conversation),
        }
    }

    fn has_conversation(self, home: &Path, id: &str) -> Option<bool> {
        match self {
            Agent::Claude => claude::Claude::has_conversation(home, id),
            Agent::Codex => codex::Codex::has_conversation(home, id),
        }
    }

    fn fork_source(self, home: &Path, worktree: &str, conversation: Option<&str>) -> Option<String> {
        match self {
            Agent::Claude => claude::Claude::fork_source(home, worktree, conversation),
            Agent::Codex => codex::Codex::fork_source(home, worktree, conversation),
        }
    }

    fn conversation_in_worktree(self, home: &Path, worktree: &str, id: &str) -> Option<PathBuf> {
        match self {
            Agent::Claude => claude::Claude::conversation_in_worktree(home, worktree, id),
            Agent::Codex => codex::Codex::conversation_in_worktree(home, worktree, id),
        }
    }

    pub fn tool_kind(self, name: &str) -> &'static str {
        match self {
            Agent::Claude => claude::Claude::tool_kind(name),
            Agent::Codex => codex::Codex::tool_kind(name),
        }
    }

    pub fn tool_change(self, name: &str, input: &Value) -> Option<(String, String, String)> {
        match self {
            Agent::Claude => claude::Claude::tool_change(name, input),
            Agent::Codex => codex::Codex::tool_change(name, input),
        }
    }

    pub fn works_on(self, stop: &Value) -> bool {
        match self {
            Agent::Claude => claude::Claude::works_on(stop),
            Agent::Codex => codex::Codex::works_on(stop),
        }
    }

    pub async fn usage(self) -> Option<Value> {
        match self {
            Agent::Claude => claude::Claude::usage().await,
            Agent::Codex => codex::Codex::usage().await,
        }
    }

    pub async fn limits(self) -> Option<Value> {
        match self {
            Agent::Claude => claude::Claude::limits().await,
            Agent::Codex => codex::Codex::limits().await,
        }
    }

    async fn reported_commands(self) -> Value {
        match self {
            Agent::Claude => claude::Claude::reported_commands().await,
            Agent::Codex => codex::Codex::reported_commands().await,
        }
    }
}

/// Asks Claude Code for its models and commands in the background at start, so the first model
/// menu or `/` list finds the answer waiting rather than waits for it.
pub fn warm() {
    tokio::spawn(claude::initialize());
}

#[derive(serde::Deserialize)]
pub struct CatalogQuery {
    cli: String,
}

#[derive(serde::Deserialize)]
pub struct StatusQuery {
    cli: String,
    worktree: String,
    #[serde(default)]
    task: String,
}

pub async fn catalog(Query(query): Query<CatalogQuery>) -> Json<Value> {
    let (Some(home), Some(agent)) = (home(), Agent::of(&query.cli)) else {
        return Json(json!({"models":[]}));
    };
    Json(agent.catalog(&home).await)
}

#[derive(serde::Deserialize)]
pub struct ConversationQuery {
    cli: String,
    id: String,
}

/// `{"exists":bool}`: whether the CLI can still resume this conversation. An id the app reserved
/// at launch names nothing until the first prompt writes it to disk, and resuming it fails hard.
/// A CLI whose storage the app does not read is taken at its word.
pub async fn conversation(Query(query): Query<ConversationQuery>) -> Json<Value> {
    let exists = tokio::task::spawn_blocking(move || {
        let (Some(agent), Some(home)) = (Agent::of(&query.cli), home()) else { return true };
        agent.has_conversation(&home, &query.id).unwrap_or(true)
    })
    .await
    .unwrap_or(true);
    Json(json!({"exists":exists}))
}

pub async fn status(Query(query): Query<StatusQuery>) -> Json<Value> {
    let found = tokio::task::spawn_blocking(move || {
        let home = home()?;
        // Both become parts of file names, so neither may carry a way out of its directory.
        if !query.worktree.starts_with('/') || !is_name(&query.task) {
            return None;
        }
        Agent::of(&query.cli)?.status(&home, &query.worktree, &query.task)
    })
    .await
    .ok()
    .flatten();
    Json(found.unwrap_or(Value::Null))
}

#[derive(serde::Deserialize)]
pub struct TranscriptQuery {
    cli: String,
    worktree: String,
    /// The revision the caller has: the turns are left out when it is still current. With
    /// `format=thread` it is the thread's revision, `{transcript revision}:{approvals changed}`.
    #[serde(default)]
    since: Option<String>,
    /// The conversation the agent is in, when the app knows it.
    #[serde(default)]
    session: Option<String>,
    /// `thread`: the conversation as a read-only chat-engine thread (`chat::transcript`).
    #[serde(default)]
    pub format: Option<String>,
    /// The terminal the agent runs in: a tool approval it waits on shows in the thread.
    #[serde(default, rename = "runId")]
    pub run_id: Option<String>,
    /// The thread id the page shows the conversation under; one of its own when absent.
    #[serde(default, rename = "threadId")]
    pub thread_id: Option<String>,
    #[serde(default, rename = "projectId")]
    pub project_id: Option<String>,
}

impl TranscriptQuery {
    pub fn worktree(&self) -> &str {
        &self.worktree
    }

    /// The transcript revision in a thread's `since`, when the approvals have not changed since
    /// (`changed`, the milliseconds the thread revision ends with): only then may the transcript
    /// alone decide that nothing did.
    fn thread_since(&self, changed: i64) -> Option<&str> {
        let (revision, at) = self.since.as_deref()?.rsplit_once(':')?;
        (at == changed.to_string() && !revision.is_empty()).then_some(revision)
    }
}

/// The session's conversation as chat turns, for the chat view over its terminal, and which
/// agent it is. `agent` in the value is the CLI's `Profile`, which the chat goes by instead of
/// the CLI's name. Reads the CLI's files: call it off the runtime.
pub fn transcript(query: &TranscriptQuery) -> Option<(Agent, Value)> {
    transcript_in(&home()?, query, None)
}

/// `transcript` under `home`. With `format=thread`, `changed` is when the terminal's waiting
/// approvals last changed: a `since` naming it and the transcript's current revision answers
/// `{"revision"}` alone, as an unchanged plain read does.
pub(crate) fn transcript_in(home: &Path, query: &TranscriptQuery, changed: Option<i64>) -> Option<(Agent, Value)> {
    if !query.worktree.starts_with('/') {
        return None;
    }
    let agent = Agent::of(&query.cli)?;
    let conversation = query.session.as_deref().filter(|id| !id.is_empty() && is_name(id));
    let detailed = query.format.as_deref() == Some("thread");
    let since = match detailed {
        true => changed.and_then(|changed| query.thread_since(changed)),
        false => query.since.as_deref(),
    };
    let mut found = transcript::read_with(home, agent, &query.worktree, since, conversation, detailed);
    found["agent"] = json!(agent.profile());
    Some((agent, found))
}

#[derive(serde::Deserialize)]
pub struct CommandsQuery {
    cli: String,
    worktree: String,
}

/// The slash commands the CLI offers in this worktree, for the chat's `/` suggestions.
pub async fn commands(Query(query): Query<CommandsQuery>) -> Json<Value> {
    let Some(agent) = Agent::of(&query.cli) else {
        return Json(json!({"commands": []}));
    };
    Json(commands_in(agent, PathBuf::from(query.worktree)).await)
}

/// `{"commands":[…]}` the CLI offers in `worktree`, which must be absolute: what the terminal's
/// chat and the chat engine's composer both suggest after `/`.
pub(crate) async fn commands_in(agent: Agent, worktree: PathBuf) -> Value {
    let reported = agent.reported_commands().await;
    let found = tokio::task::spawn_blocking(move || {
        let home = home()?;
        if !worktree.is_absolute() {
            return None;
        }
        Some(commands::list(&home, agent, &worktree, &reported))
    })
    .await
    .ok()
    .flatten();
    found.unwrap_or_else(|| json!({"commands": []}))
}

pub(crate) fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// What a fork of `cli`'s conversation in `worktree` resumes from (`AgentProbe::fork_source`).
pub(crate) fn fork_source(cli: &str, worktree: &str, conversation: &str) -> Option<String> {
    let (agent, home) = (Agent::of(cli)?, home()?);
    if !worktree.starts_with('/') {
        return None;
    }
    let conversation = Some(conversation).filter(|id| !id.is_empty() && is_name(id));
    agent.fork_source(&home, worktree, conversation)
}

/// The transcript of conversation `conversation`, which `agent` holds in `worktree` exactly
/// (`AgentProbe::conversation_in_worktree`), that a new chat can start from (`chat::knowledge`).
/// None for an id that is not a name, a worktree that is not absolute, or a conversation not on
/// disk there: no other conversation stands in for it.
pub(crate) fn conversation_in(home: &Path, agent: Agent, worktree: &str, conversation: &str) -> Option<PathBuf> {
    if !worktree.starts_with('/') || conversation.is_empty() || !is_name(conversation) {
        return None;
    }
    agent.conversation_in_worktree(home, worktree, conversation)
}

fn is_name(value: &str) -> bool {
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// The end of a session file. They run to tens of megabytes, and the latest turn is at the end.
fn tail(path: &Path) -> Option<String> {
    tail_window(path, 512 * 1024)
}

fn tail_window(path: &Path, window: u64) -> Option<String> {
    let mut file = fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(window)))
        .ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

fn newest_jsonl(directory: &Path) -> Option<PathBuf> {
    fs::read_dir(directory)
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|e| e == "jsonl"))
        .max_by_key(|entry| entry.metadata().and_then(|m| m.modified()).ok())
        .map(|entry| entry.path())
}

fn percent(tokens: u64, window: Option<u64>) -> Value {
    match window {
        Some(window) if window > 0 => json!((tokens as f64 / window as f64 * 100.0).min(100.0)),
        _ => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_cli_is_found_by_the_name_it_carries_and_no_other() {
        for agent in Agent::ALL {
            assert_eq!(Agent::of(agent.profile().id), Some(agent));
        }
        assert_eq!(Agent::of(""), None);
        assert_eq!(Agent::of("gemini"), None);
    }

    /// The app starts sessions in the CLIs `SessionAgent` lists; each but the plain shell must be
    /// one this registry knows, or every request for it answers empty. Asserted against the Swift
    /// source, as `route_contract` asserts `Routes.swift`.
    #[test]
    fn every_cli_the_native_app_starts_is_known_here() {
        let swift = include_str!("../../../../macos/Services/Workspace/SessionOperations.swift");
        let cases = swift
            .split("enum SessionAgent")
            .nth(1)
            .and_then(|body| body.lines().map(str::trim).find(|line| line.starts_with("case ")))
            .expect("SessionAgent's cases");
        // `case shell = "", claude, codex`: each a name, or a name and its raw value.
        let names: Vec<&str> = cases["case ".len()..]
            .split(',')
            .map(|case| match case.split_once('=') {
                Some((_, raw)) => raw.trim().trim_matches('"'),
                None => case.trim(),
            })
            .filter(|name| !name.is_empty())
            .collect();
        assert!(names.len() >= 2, "parsed too few CLIs: {names:?}");
        let unknown: Vec<_> = names.iter().filter(|name| Agent::of(name).is_none()).collect();
        assert!(unknown.is_empty(), "the native app starts CLIs this backend does not know: {unknown:?}");
    }

    #[test]
    fn every_adapters_empty_hooks_file_is_json() {
        for agent in Agent::ALL {
            let empty: Value = serde_json::from_str(agent.hooks().empty).expect(agent.profile().id);
            assert!(empty.is_object(), "{}", agent.profile().id);
        }
    }

    #[test]
    fn a_profile_is_what_the_app_reads() {
        assert_eq!(json!(Agent::Claude.profile()), json!({"id": "claude", "command": "claude", "queuesMidTurn": true}));
        assert_eq!(json!(Agent::Codex.profile())["queuesMidTurn"], false);
    }
}
