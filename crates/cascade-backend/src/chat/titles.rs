//! A chat's or a session's generated title, by its own CLI run once, headless (Synara
//! `apps/server/src/git/Layers/ClaudeTextGeneration.ts` and `CodexTextGeneration.ts`): the engine
//! decides when and applies it (`cascade_chat::text_generation`); this runs the CLI through `cli`,
//! so it is resolved, grouped and timed out as every other command is, and a test scripts it.
//!
//! Claude is asked on `CLAUDE_TITLE_MODEL` (sonnet) with nothing of the person's setup loaded
//! (`--safe-mode`, no setting sources, no MCP, no tools, no session kept), in an empty folder of
//! its own. A Codex chat or session is titled by Codex, which is the CLI signed in (a Claude that
//! is installed may not be): `codex exec`, read-only and ephemeral, on `CODEX_TITLE_MODEL` at low
//! effort. Only when its own CLI cannot answer is the other one asked.

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
/// The Claude model titles are asked of, a chat's and a session's alike. Sonnet over haiku: in a
/// side-by-side run on real prompts it kept closer to what was asked (it pulled main rather than
/// "synced" it) at the same few seconds, and a title is one short call.
pub(crate) const CLAUDE_TITLE_MODEL: &str = "sonnet";
/// The Codex model titles are asked of: Synara's `DEFAULT_GIT_TEXT_GENERATION_MODEL`, the model it
/// writes branch names, commit messages and titles with. A Codex that refuses it is asked again on
/// its own configured default.
pub(crate) const CODEX_TITLE_MODEL: &str = "gpt-6-luna";

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
    let cli = match &input.model_selection {
        ModelSelection::Codex(_) => TitleCli::Codex,
        ModelSelection::ClaudeAgent(_) => TitleCli::Claude,
    };
    // The engine sanitizes what it is handed (`on_title_generated`).
    title_by(cli, &prompt).await
}

/// Which CLI a title is asked of: the one the chat or session runs, which is the one signed in.
/// Claude being installed says nothing of whether it is signed in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TitleCli {
    Claude,
    Codex,
}

impl TitleCli {
    /// The CLI of a session's agent (`claude`, `codex`); Claude for anything else.
    pub(crate) fn of_session(cli: &str) -> Self {
        if cli == "codex" {
            TitleCli::Codex
        } else {
            TitleCli::Claude
        }
    }
}

/// A title for `prompt` (a whole title prompt, `{title}` schema) from `cli`: Claude on
/// `CLAUDE_TITLE_MODEL`, Codex on `CODEX_TITLE_MODEL` and then on its own default model, should
/// that one be refused. Only when `cli` cannot answer at all is the other asked. Raw: the caller
/// sanitizes.
pub(crate) async fn title_by(cli: TitleCli, prompt: &str) -> Result<String, String> {
    let folder = Scratch::new().map_err(|error| format!("no folder for the title's CLI: {error}"))?;
    let codex = |folder: std::path::PathBuf| async move {
        match codex_title(prompt, Some(CODEX_TITLE_MODEL), &folder).await {
            Ok(title) => Ok(title),
            Err(pinned) => codex_title(prompt, None, &folder).await.map_err(|default| format!("{pinned}; {default}")),
        }
    };
    match cli {
        TitleCli::Claude => match claude_title(prompt, &folder.0).await {
            Ok(title) => Ok(title),
            Err(claude) => codex(folder.0.clone()).await.map_err(|codex| format!("{claude}; {codex}")),
        },
        TitleCli::Codex => match codex(folder.0.clone()).await {
            Ok(title) => Ok(title),
            Err(codex) => claude_title(prompt, &folder.0).await.map_err(|claude| format!("{codex}; {claude}")),
        },
    }
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

/// Synara `CodexTextGeneration`'s `codex exec`, at low effort, on `model` or else the person's
/// configured default.
async fn codex_title(prompt: &str, model: Option<&str>, folder: &std::path::Path) -> Result<String, String> {
    let schema = folder.join("schema.json");
    let output = folder.join("title.txt");
    std::fs::write(&schema, THREAD_TITLE_OUTPUT_SCHEMA).map_err(|error| error.to_string())?;
    let mut args = vec!["exec".to_owned(), "--ephemeral".into(), "--skip-git-repo-check".into(), "-s".into(), "read-only".into()];
    if let Some(model) = model {
        args.extend(["--model".to_owned(), model.to_owned()]);
    }
    args.extend([
        "--config".to_owned(),
        "model_reasoning_effort=\"low\"".into(),
        "--output-schema".into(),
        schema.to_string_lossy().into_owned(),
        "--output-last-message".into(),
        output.to_string_lossy().into_owned(),
        "-".into(),
    ]);
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
