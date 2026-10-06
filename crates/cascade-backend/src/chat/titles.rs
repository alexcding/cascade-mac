//! A chat's generated title, by its own CLI run once, headless (Synara
//! `apps/server/src/git/Layers/ClaudeTextGeneration.ts` and `CodexTextGeneration.ts`): the engine
//! decides when and applies it (`cascade_chat::text_generation`); this runs the CLI through `cli`,
//! so it is resolved, grouped and timed out as every other command is, and a test scripts it.
//!
//! Claude is asked on its cheapest model (`haiku`) with nothing of the person's setup loaded
//! (`--safe-mode`, no setting sources, no MCP, no tools, no session kept), in an empty folder of
//! its own. A Codex chat is titled by Claude when Claude is installed, since Codex's model names
//! change too often to pick its cheapest; without Claude, `codex exec` runs read-only on the
//! chat's own model at low effort.

use std::{path::PathBuf, sync::Arc, time::Duration};

use cascade_chat::{
    contracts::orchestration::ModelSelection,
    text_generation::{
        build_thread_title_prompt, TextGeneration, TextGenerationFuture,
        ThreadTitleGenerationInput, MAX_CHAT_THREAD_TITLE_WORDS, THREAD_TITLE_OUTPUT_SCHEMA,
    },
};
use serde_json::Value;

use crate::cli;

/// How long a title may take (Synara allows 180 s; a title that late is no longer wanted).
pub(crate) const TITLE_TIMEOUT: Duration = Duration::from_secs(90);
/// The Claude model titles are asked of.
pub(crate) const CLAUDE_TITLE_MODEL: &str = "haiku";

/// Titles through the chat's CLI. `runner` is a test's scripted one, carried into the engine's
/// task (`cli::inherited`), which a task-local would not follow.
pub(crate) struct CliTitles {
    runner: Option<Arc<dyn cli::CommandRunner>>,
}

impl CliTitles {
    pub(crate) fn new() -> Self {
        Self { runner: cli::inherited() }
    }
}

impl TextGeneration for CliTitles {
    fn generate_thread_title(&self, input: ThreadTitleGenerationInput) -> TextGenerationFuture {
        let runner = self.runner.clone();
        Box::pin(async move {
            match runner {
                Some(runner) => cli::scoped(runner, generate(input)).await,
                None => generate(input).await,
            }
        })
    }
}

async fn generate(input: ThreadTitleGenerationInput) -> Result<String, String> {
    let prompt = build_thread_title_prompt(&input.message, &input.attachments);
    let folder = Scratch::new().map_err(|error| format!("no folder for the title's CLI: {error}"))?;
    let raw = match &input.model_selection {
        ModelSelection::Codex(selection) if cli::find("claude").is_none() => {
            codex_title(&prompt, &selection.model, &folder.0).await?
        }
        _ => claude_title(&prompt, &folder.0).await?,
    };
    // The engine sanitizes what it is handed (`on_title_generated`).
    Ok(raw)
}

/// Synara `runClaudeJson`'s arguments, on `CLAUDE_TITLE_MODEL`.
pub(crate) fn claude_args() -> Vec<String> {
    [
        "-p",
        "--safe-mode",
        "--setting-sources",
        "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--output-format",
        "json",
        "--json-schema",
        THREAD_TITLE_OUTPUT_SCHEMA,
        "--model",
        CLAUDE_TITLE_MODEL,
        "--tools",
        "",
    ]
    .map(str::to_owned)
    .to_vec()
}

async fn claude_title(prompt: &str, folder: &std::path::Path) -> Result<String, String> {
    let stdout = cli::run_with_input("claude", claude_args(), prompt.as_bytes(), TITLE_TIMEOUT, Some(folder))
        .await
        .map_err(|error| format!("Claude CLI command failed: {error:#}"))?;
    title_of_claude_output(&stdout).ok_or_else(|| "Claude CLI returned unexpected output format.".to_owned())
}

/// The title in `claude -p --output-format json`'s envelope: its `structured_output`, else its
/// `result` read as the JSON object or as the title itself (Synara's raw-text fallback).
pub(crate) fn title_of_claude_output(stdout: &str) -> Option<String> {
    let envelope: Value = serde_json::from_str(stdout.trim()).ok()?;
    if envelope["is_error"] == true {
        return None;
    }
    if let Some(title) = envelope["structured_output"]["title"].as_str() {
        return Some(title.to_owned());
    }
    envelope["result"].as_str().and_then(title_of_text)
}

/// A reply's title: `{"title": …}`, or text short enough to be one (Synara `rawTextFallback`).
fn title_of_text(text: &str) -> Option<String> {
    if let Ok(value) = serde_json::from_str::<Value>(text.trim()) {
        return value["title"].as_str().map(str::to_owned);
    }
    let words = text.split_whitespace().count();
    (words > 0 && words <= MAX_CHAT_THREAD_TITLE_WORDS + 4).then(|| text.to_owned())
}

/// Synara `CodexTextGeneration`'s `codex exec`, at low effort.
async fn codex_title(prompt: &str, model: &str, folder: &std::path::Path) -> Result<String, String> {
    let schema = folder.join("schema.json");
    let output = folder.join("title.txt");
    std::fs::write(&schema, THREAD_TITLE_OUTPUT_SCHEMA).map_err(|error| error.to_string())?;
    let args = [
        "exec".to_owned(),
        "--ephemeral".into(),
        "--skip-git-repo-check".into(),
        "-s".into(),
        "read-only".into(),
        "--model".into(),
        model.to_owned(),
        "--config".into(),
        "model_reasoning_effort=\"low\"".into(),
        "--output-schema".into(),
        schema.to_string_lossy().into_owned(),
        "--output-last-message".into(),
        output.to_string_lossy().into_owned(),
        "-".into(),
    ];
    let stdout = cli::run_with_input("codex", args, prompt.as_bytes(), TITLE_TIMEOUT, Some(folder))
        .await
        .map_err(|error| format!("Codex CLI command failed: {error:#}"))?;
    let reply = std::fs::read_to_string(&output).unwrap_or(stdout);
    title_of_text(&reply).ok_or_else(|| "Codex CLI returned unexpected output format.".to_owned())
}

/// An empty folder of the title's own, removed when it is done with.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> std::io::Result<Self> {
        let path = std::env::temp_dir().join(format!("cascade-chat-title-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path)?;
        Ok(Self(path))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
