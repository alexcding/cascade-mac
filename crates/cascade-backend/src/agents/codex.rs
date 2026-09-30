use super::{percent, tail, AgentProbe, Hooks, Profile};
use crate::cli;
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

pub struct Codex;

impl AgentProbe for Codex {
    /// What Codex does with a message typed mid-turn has not been checked here, so the chat holds
    /// one until its turn ends.
    const PROFILE: Profile = Profile { id: "codex", command: "codex", queues_mid_turn: false };
    /// How Codex spawns its hooks has not been checked, so none is guarded: a wrong guard would
    /// silence them.
    const HOOKS: Hooks = Hooks {
        file: ".codex/hooks.json",
        empty: r#"{"hooks":{}}"#,
        reports_sessions: false,
        foreground_only: false,
        matches_tools: false,
    };

    async fn usage() -> Option<Value> {
        super::usage::daily(Self::PROFILE.id).await
    }

    async fn limits() -> Option<Value> {
        super::usage::codex_limits().await
    }

    /// `apply_patch` has a kind of its own: a patch may touch several files, and asks as one.
    fn tool_kind(name: &str) -> &'static str {
        match name {
            "shell" | "exec" | "exec_command" | "local_shell" => "run",
            "apply_patch" => "patch",
            "web_search" => "web",
            "spawn_agent" => "delegate",
            "update_plan" => "plan",
            _ => "other",
        }
    }

    /// Codex names a session file by its start, not by a conversation the app could ask for.
    fn transcript_file(home: &Path, worktree: &str, _conversation: Option<&str>) -> Option<PathBuf> {
        session_file(home, worktree)
    }

    /// `codex fork` takes the conversation's id. One the hooks have not reported yet is the id the
    /// worktree's newest session file opens with — the agent's own, not a subagent's, which runs
    /// in the same directory under a thread of its own.
    fn fork_source(home: &Path, worktree: &str, conversation: Option<&str>) -> Option<String> {
        if let Some(id) = conversation {
            return Some(id.to_owned());
        }
        let (_, meta) = newest_session(home, worktree, |meta| meta["payload"]["parent_thread_id"].is_null())?;
        meta["payload"]["id"]
            .as_str()
            .filter(|id| !id.is_empty() && super::is_name(id))
            .map(str::to_owned)
    }

    /// `codex debug models` is the CLI's own catalog, reasoning levels included.
    async fn catalog(_home: &Path) -> Value {
        let raw = cli::run("codex", ["debug", "models"], Duration::from_secs(20)).await;
        let parsed = raw.ok().and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
        json!({"models": parsed.as_ref().map(models).unwrap_or_default()})
    }

    /// Codex writes its session file as it goes: each turn's model and effort, and after every
    /// response the tokens it used and the window they count against.
    fn status(home: &Path, worktree: &str, _task: &str) -> Option<Value> {
        let text = tail(&session_file(home, worktree)?)?;
        let mut context = Value::Null;
        let mut usage = Value::Null;
        for line in text.lines().rev() {
            if !context.is_null() && !usage.is_null() {
                break;
            }
            let wanted = (context.is_null() && line.contains("\"turn_context\""))
                || (usage.is_null() && line.contains("\"token_count\""));
            if !wanted {
                continue;
            }
            let Ok(value) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            if context.is_null() && value["type"] == "turn_context" {
                context = value["payload"].clone();
            } else if usage.is_null() && value["payload"]["type"] == "token_count" && value["payload"]["info"].is_object() {
                usage = value["payload"]["info"].clone();
            }
        }
        // The last response's total is what the next turn carries forward.
        let tokens = usage
            .pointer("/last_token_usage/total_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let window = usage["model_context_window"].as_u64();
        Some(json!({
            "model": context["model"],
            "effort": context["effort"],
            "tokens": tokens,
            "window": window,
            "percent": percent(tokens, window),
        }))
    }
}

fn models(catalog: &Value) -> Vec<Value> {
    catalog["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|model| model["visibility"] == "list")
        .filter_map(|model| {
            let slug = model["slug"].as_str()?;
            let efforts: Vec<Value> = model["supported_reasoning_levels"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|level| level["effort"].as_str().or_else(|| level.as_str()))
                .map(|id| json!({"id": id, "name": effort_name(id)}))
                .collect();
            Some(json!({
                "id": slug,
                "alias": slug,
                "name": model["display_name"].as_str().unwrap_or(slug),
                "efforts": efforts,
                "defaultEffort": model["default_reasoning_level"],
            }))
        })
        .collect()
}

fn effort_name(id: &str) -> String {
    match id {
        "xhigh" => "Extra".into(),
        _ => {
            let mut letters = id.chars();
            letters.next().map_or_else(String::new, |first| first.to_uppercase().chain(letters).collect())
        }
    }
}

/// The session file most recently written for this worktree. A resumed conversation keeps
/// appending to the file from the day it began, so recency is by modification time across every
/// day, not by the dated folder; the first line of each names the directory it ran in.
pub(super) fn session_file(home: &Path, worktree: &str) -> Option<PathBuf> {
    newest_session(home, worktree, |_| true).map(|(path, _)| path)
}

/// The newest session file for this worktree whose opening `session_meta` `accept`s.
fn newest_session(home: &Path, worktree: &str, accept: impl Fn(&Value) -> bool) -> Option<(PathBuf, Value)> {
    let mut files: Vec<(SystemTime, PathBuf)> = Vec::new();
    let mut pending = vec![home.join(".codex/sessions")];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(directory).ok()?.filter_map(Result::ok) {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().is_some_and(|e| e == "jsonl") {
                if let Ok(modified) = entry.metadata().and_then(|m| m.modified()) {
                    files.push((modified, path));
                }
            }
        }
    }
    files.sort_by(|a, b| b.0.cmp(&a.0));
    // Reading one line each is cheap; the cap only bounds a history of thousands.
    files.into_iter().take(500).map(|(_, path)| path).find_map(|path| {
        let mut first = String::new();
        fs::File::open(&path).ok().and_then(|file| BufReader::new(file).read_line(&mut first).ok())?;
        let meta: Value = serde_json::from_str(&first).ok()?;
        (meta["type"] == "session_meta" && meta["payload"]["cwd"] == worktree && accept(&meta)).then_some((path, meta))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fork_starts_from_the_agents_own_conversation_not_a_subagents() {
        let home = std::env::temp_dir().join(format!("cascade-codex-fork-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        let day = home.join(".codex/sessions/2026/09/28");
        fs::create_dir_all(&day).unwrap();
        let meta = |id: &str, parent: Value| json!({"type":"session_meta","payload":{"id":id,"cwd":"/r/a","parent_thread_id":parent}});
        fs::write(day.join("main.jsonl"), format!("{}\n", meta("main-1", Value::Null))).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(day.join("sub.jsonl"), format!("{}\n", meta("sub-1", json!("main-1")))).unwrap();
        assert_eq!(Codex::fork_source(&home, "/r/a", None).as_deref(), Some("main-1"));
        assert_eq!(Codex::fork_source(&home, "/r/a", Some("known")).as_deref(), Some("known"));
        assert_eq!(Codex::fork_source(&home, "/r/b", None), None);
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn status_reads_the_worktrees_newest_session() {
        let home = std::env::temp_dir().join(format!("cascade-codex-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        let day = home.join(".codex/sessions/2026/09/19");
        fs::create_dir_all(&day).unwrap();
        let meta = |cwd: &str| json!({"type":"session_meta","payload":{"cwd":cwd}}).to_string();
        let lines = [
            meta("/tmp/work"),
            json!({"type":"turn_context","payload":{"model":"gpt-5.5","effort":"low"}}).to_string(),
            json!({"type":"event_msg","payload":{"type":"token_count","info":null}}).to_string(),
            json!({"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"high"}}).to_string(),
            json!({"type":"event_msg","payload":{"type":"token_count","info":{
                "last_token_usage":{"total_tokens":20_839},"model_context_window":258_400}}}).to_string(),
        ];
        fs::write(day.join("rollout-a.jsonl"), lines.join("\n")).unwrap();
        fs::write(day.join("rollout-b.jsonl"), meta("/tmp/elsewhere")).unwrap();

        let found = Codex::status(&home, "/tmp/work", "").unwrap();
        assert_eq!(found["model"], "gpt-6-astra");
        assert_eq!(found["effort"], "high");
        assert_eq!(found["tokens"], 20_839);
        assert_eq!(found["window"], 258_400);
        assert!(Codex::status(&home, "/tmp/nowhere", "").is_none());
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn catalog_lists_only_visible_models() {
        let catalog = json!({"models":[
            {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","default_reasoning_level":"medium",
             "supported_reasoning_levels":[{"effort":"low"},{"effort":"xhigh"}]},
            {"slug":"hidden","display_name":"Hidden","visibility":"hide","supported_reasoning_levels":[]}]});
        let found = models(&catalog);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0]["alias"], "gpt-5.5");
        assert_eq!(found[0]["efforts"][1], json!({"id":"xhigh","name":"Extra"}));
        assert_eq!(effort_name("low"), "Low");
        assert_eq!(effort_name(""), "");
        assert_eq!(effort_name("élevé"), "Élevé");
    }
}
