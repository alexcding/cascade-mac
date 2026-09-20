use super::{newest_jsonl, percent, tail, AgentProbe};
use serde_json::{json, Value};
use std::{fs, path::Path};

pub struct Claude;

/// Where the app's status line wrapper leaves what Claude Code told it, one file per task.
const STATUS_DIR: &str = "Library/Application Support/Craft/statusline";

impl AgentProbe for Claude {
    async fn catalog(home: &Path) -> Value {
        let home = home.to_path_buf();
        tokio::task::spawn_blocking(move || cached_catalog(&home))
            .await
            .ok()
            .flatten()
            .unwrap_or_else(fallback_catalog)
    }

    fn status(home: &Path, worktree: &str, task: &str) -> Option<Value> {
        let turn = last_turn(home, worktree);
        let line = (!task.is_empty())
            .then(|| fs::read_to_string(home.join(STATUS_DIR).join(format!("{task}.json"))).ok())
            .flatten()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            .or_else(|| session_line(home, worktree));
        if turn.is_none() && line.is_none() {
            return None;
        }
        let turn = turn.unwrap_or(Value::Null);
        // The status line is Claude Code's own account, so it wins. The transcript stands in when
        // a session has no wrapper: tokens, model and effort, but no window to measure against.
        let window = line
            .as_ref()
            .and_then(|v| v.pointer("/context_window/context_window_size")?.as_u64());
        let tokens = line
            .as_ref()
            .and_then(|v| {
                let usage = v.pointer("/context_window/current_usage")?;
                usage.is_object().then(|| input_tokens(usage))
            })
            .unwrap_or_else(|| input_tokens(&turn["message"]["usage"]));
        let model = line
            .as_ref()
            .and_then(|v| v.pointer("/model/id").cloned())
            .unwrap_or_else(|| turn["message"]["model"].clone());
        // Live in the status line, so a `/effort` shows at once; the transcript only learns of
        // it with the next turn. A model with no effort levels reports none.
        let effort = line
            .as_ref()
            .and_then(|v| v.pointer("/effort/level").cloned())
            .unwrap_or_else(|| turn["effort"].clone());
        Some(json!({
            "model": model,
            "effort": effort,
            "tokens": tokens,
            "window": window,
            "percent": percent(tokens, window),
        }))
    }
}

/// Claude files a conversation under the directory it ran in, which a moved worktree changes,
/// so every project is searched rather than the one the session points at today.
///
/// A projects directory that is simply not there is a Claude that has never kept a conversation,
/// so the answer is no. One that cannot be read is unknown, and unknown resumes: reserving an id
/// Claude already owns fails just as hard as a bad resume.
pub(super) fn has_conversation(home: &Path, id: &str) -> bool {
    let projects = match fs::read_dir(home.join(".claude/projects")) {
        Ok(projects) => projects,
        Err(error) => return error.kind() != std::io::ErrorKind::NotFound,
    };
    projects
        .filter_map(Result::ok)
        .any(|project| project.path().join(format!("{id}.jsonl")).is_file())
}

/// A session the app did not launch files its status line under Claude's session id, so it is
/// found by the directory it names: the newest one for this worktree.
fn session_line(home: &Path, worktree: &str) -> Option<Value> {
    fs::read_dir(home.join(STATUS_DIR))
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("session-"))
        .filter_map(|entry| {
            let modified = entry.metadata().and_then(|m| m.modified()).ok()?;
            let value: Value = serde_json::from_str(&fs::read_to_string(entry.path()).ok()?).ok()?;
            (value.pointer("/workspace/project_dir") == Some(&json!(worktree)) || value["cwd"] == worktree)
                .then_some((modified, value))
        })
        .max_by_key(|(modified, _)| *modified)
        .map(|(_, value)| value)
}

/// What the next turn starts from: the last prompt, cached or not. Output only becomes context on
/// the turn after, which is also how Claude Code's own `used_percentage` counts.
fn input_tokens(usage: &Value) -> u64 {
    [
        "input_tokens",
        "cache_creation_input_tokens",
        "cache_read_input_tokens",
    ]
    .iter()
    .filter_map(|key| usage[key].as_u64())
    .sum()
}

/// The last main-thread turn of the worktree's live conversation. Claude files a directory's
/// conversations under its path with everything but letters and digits turned to dashes, which
/// also leaves nothing of the path to climb out with. The newest transcript is the live one: a
/// worktree runs one session, and the id a session was created with goes stale at `/clear`.
fn last_turn(home: &Path, worktree: &str) -> Option<Value> {
    let project: String = worktree
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let path = newest_jsonl(&home.join(".claude/projects").join(project))?;
    let text = tail(&path)?;
    let turn = text.lines().rev().find_map(|line| {
        if !line.contains("\"usage\"") {
            return None;
        }
        let value: Value = serde_json::from_str(line).ok()?;
        (value["type"] == "assistant"
            && value["isSidechain"] != true
            && value.pointer("/message/usage/input_tokens").is_some())
        .then_some(value)
    });
    // A conversation with no turn yet, or one just cleared, holds nothing: a reading of zero.
    Some(turn.unwrap_or(Value::Null))
}

/// Claude Code has no command that lists models; it keeps the picker's contents in a cache file.
/// That file is undocumented, so anything unexpected about it means the fallback.
fn cached_catalog(home: &Path) -> Option<Value> {
    let path = fs::read_dir(home.join(".claude/cache/model-catalog"))
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().ends_with("-cc.json"))
        .max_by_key(|entry| entry.metadata().and_then(|m| m.modified()).ok())?
        .path();
    let value: Value = serde_json::from_str(&fs::read_to_string(path).ok()?).ok()?;
    if value["version"] != 2 {
        return None;
    }
    let models: Vec<Value> = value
        .pointer("/catalog/config/models")?
        .as_array()?
        .iter()
        .filter_map(|model| {
            let options = model.pointer("/thinking/effort_options").and_then(Value::as_array);
            let efforts: Vec<Value> = options
                .into_iter()
                .flatten()
                .filter_map(|o| Some(json!({"id": o["id"].as_str()?, "name": o["name"].as_str()?})))
                .collect();
            let default = options.into_iter().flatten().find_map(|o| {
                (o.pointer("/badge/message") == Some(&json!("Default"))).then(|| o["id"].clone())
            });
            Some(json!({
                "id": model["id"].as_str()?,
                // `/model` is tested with the short names; the picker's short name is that alias.
                "alias": model["short_name"].as_str()?.to_lowercase(),
                "name": model["name"].as_str()?,
                "efforts": efforts,
                "defaultEffort": default,
            }))
        })
        .collect();
    (!models.is_empty()).then(|| json!({"models": models}))
}

fn fallback_catalog() -> Value {
    let efforts: Vec<Value> = [
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Extra"),
        ("max", "Max"),
    ]
    .iter()
    .map(|(id, name)| json!({"id": id, "name": name}))
    .collect();
    let models: Vec<Value> = ["fable", "opus", "sonnet", "haiku"]
        .iter()
        .map(|alias| {
            let name = format!("{}{}", alias[..1].to_uppercase(), &alias[1..]);
            json!({"id": alias, "alias": alias, "name": name,
                "efforts": if *alias == "haiku" { json!([]) } else { json!(efforts) },
                "defaultEffort": if *alias == "haiku" { Value::Null } else { json!("high") }})
        })
        .collect();
    json!({"models": models})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let home = std::env::temp_dir().join(format!("craft-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        home
    }

    fn turn(side: bool, read: u64) -> String {
        json!({"type":"assistant","isSidechain":side,"effort":"high","message":{"model":"claude-opus-5",
            "usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":read,"output_tokens":9}}})
        .to_string()
    }

    #[test]
    fn a_conversation_is_found_in_any_project_and_a_reserved_id_is_not() {
        let home = scratch("claude-conversation");
        assert!(!has_conversation(&home, "abc"), "a Claude that never ran has no conversations");
        let project = home.join(".claude/projects/-tmp-moved-since");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("abc.jsonl"), "{}").unwrap();
        assert!(has_conversation(&home, "abc"));
        assert!(!has_conversation(&home, "reserved-but-never-prompted"));
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn transcript_alone_gives_tokens_but_no_window() {
        let home = scratch("claude-transcript");
        let project = home.join(".claude/projects/-tmp-demo-worktrees-one");
        fs::create_dir_all(&project).unwrap();
        let lines = [turn(false, 1_000), turn(false, 50_000), turn(true, 7), json!({"type":"user"}).to_string()];
        fs::write(project.join("abc.jsonl"), lines.join("\n")).unwrap();

        let found = Claude::status(&home, "/tmp/demo.worktrees/one", "task-1").unwrap();
        assert_eq!(found["tokens"], 50_102);
        assert_eq!(found["model"], "claude-opus-5");
        assert_eq!(found["effort"], "high");
        assert!(found["window"].is_null() && found["percent"].is_null());
        assert!(Claude::status(&home, "/tmp/missing", "task-1").is_none());
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn status_line_supplies_the_window() {
        let home = scratch("claude-statusline");
        let project = home.join(".claude/projects/-tmp-demo");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("abc.jsonl"), turn(false, 1_000)).unwrap();
        let dir = home.join(STATUS_DIR);
        fs::create_dir_all(&dir).unwrap();
        let line = json!({"model":{"id":"claude-fable-5-1"},"effort":{"level":"low"},"context_window":{"context_window_size":1_000_000,
            "current_usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":136_780}}});
        fs::write(dir.join("task-1.json"), line.to_string()).unwrap();

        let found = Claude::status(&home, "/tmp/demo", "task-1").unwrap();
        assert_eq!(found["tokens"], 136_782);
        assert_eq!(found["window"], 1_000_000);
        assert_eq!(found["model"], "claude-fable-5-1");
        assert_eq!(found["effort"], "low");
        assert!((found["percent"].as_f64().unwrap() - 13.6782).abs() < 0.001);
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_hand_started_session_is_found_by_its_directory() {
        let home = scratch("claude-session-line");
        let dir = home.join(STATUS_DIR);
        fs::create_dir_all(&dir).unwrap();
        let line = |cwd: &str, size: u64| json!({"cwd":cwd,"model":{"id":"claude-opus-5"},
            "context_window":{"context_window_size":size,"current_usage":null,"total_input_tokens":0}}).to_string();
        fs::write(dir.join("session-aaa.json"), line("/tmp/elsewhere", 200_000)).unwrap();
        fs::write(dir.join("session-bbb.json"), line("/tmp/mine", 1_000_000)).unwrap();

        let found = Claude::status(&home, "/tmp/mine", "task-without-a-file").unwrap();
        assert_eq!(found["window"], 1_000_000);
        assert_eq!(found["model"], "claude-opus-5");
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_conversation_with_no_turn_reads_zero() {
        let home = scratch("claude-fresh");
        let project = home.join(".claude/projects/-tmp-fresh");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("new.jsonl"), json!({"type":"user"}).to_string()).unwrap();
        assert_eq!(Claude::status(&home, "/tmp/fresh", "").unwrap()["tokens"], 0);
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn fallback_catalog_gives_haiku_no_efforts() {
        let catalog = fallback_catalog();
        let models = catalog["models"].as_array().unwrap();
        assert_eq!(models.len(), 4);
        assert!(models[3]["efforts"].as_array().unwrap().is_empty());
    }
}
