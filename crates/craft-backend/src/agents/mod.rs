//! One probe per agent CLI. The app's footer asks two things of whichever CLI a session runs:
//! what it could switch to, and what it is running right now. Each CLI answers from its own
//! records, so nothing here infers a model's context window: Claude Code reports it to its status
//! line, and Codex writes it into its session file.

mod claude;
mod codex;
pub mod statusline;

use axum::{extract::Query, Json};
use serde_json::{json, Value};
use std::{
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

/// What a CLI has to be able to tell the app. `catalog` runs the CLI or reads its cache, so it is
/// async; `status` only reads files, and runs on the blocking pool.
pub trait AgentProbe {
    /// `{"models":[{"id","alias","name","efforts":[{"id","name"}],"defaultEffort"}]}`. `alias` is
    /// what the CLI accepts when asked to switch; `id` is what `status` reports back.
    async fn catalog(home: &Path) -> Value;
    /// `{"model","effort","tokens","window","percent"}`, each null when the CLI has not said.
    fn status(home: &Path, worktree: &str, task: &str) -> Option<Value>;
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
    let Some(home) = home() else {
        return Json(json!({"models":[]}));
    };
    Json(match query.cli.as_str() {
        "codex" => codex::Codex::catalog(&home).await,
        _ => claude::Claude::catalog(&home).await,
    })
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
        if query.cli != "claude" {
            return true;
        }
        let Some(home) = home() else { return true };
        !query.id.is_empty() && is_name(&query.id) && claude::has_conversation(&home, &query.id)
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
        match query.cli.as_str() {
            "codex" => codex::Codex::status(&home, &query.worktree, &query.task),
            _ => claude::Claude::status(&home, &query.worktree, &query.task),
        }
    })
    .await
    .ok()
    .flatten();
    Json(found.unwrap_or(Value::Null))
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn is_name(value: &str) -> bool {
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// The end of a session file. They run to tens of megabytes, and the latest turn is at the end.
fn tail(path: &Path) -> Option<String> {
    const TAIL: u64 = 512 * 1024;
    let mut file = fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(TAIL)))
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
