//! A session's conversation as chat turns, read from the CLI's own transcript. Prototype for a
//! chat-style view over the terminal: the terminal stays the source of truth, and this only
//! reads what each CLI already writes to disk.
//!
//! A turn is one bubble: a person's prompt, or everything the agent did until the next prompt —
//! its text, its thinking, and each tool call with that call's output attached.

use super::Agent;
use serde_json::{json, Map, Value};
use std::{
    collections::HashMap,
    fs,
    hash::{DefaultHasher, Hash, Hasher},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant, UNIX_EPOCH},
};

/// The newest turns are what a chat view shows; older ones stay in the terminal's scrollback.
const MAX_TURNS: usize = 200;
/// Transcripts run to tens of megabytes, so only the end is read.
const WINDOW: u64 = 4 * 1024 * 1024;
/// Tool output and file contents are shown collapsed; this bounds what one poll carries.
const MAX_OUTPUT: usize = 6_000;
const MAX_FILE_TEXT: usize = 20_000;
/// How long a found transcript stands before it is looked for again. The chat polls every second,
/// and finding a Codex session walks every file it has written; a new conversation (`/clear`)
/// shows up within this.
const LOOKUP: Duration = Duration::from_secs(5);

/// The worktree's transcript, found at most once per `LOOKUP`. A Claude conversation the app knows
/// the agent is in is that one's file alone, looked for on every read: the newest file would be an
/// older conversation until the new one's first message is written.
fn locate(home: &Path, agent: Agent, worktree: &str, conversation: Option<&str>) -> Option<PathBuf> {
    // A conversation its CLI names a file after is found at once; the newest is searched for, and
    // the search kept. A CLI that names none is searched whatever conversation the app knows.
    if let Some(id) = conversation.filter(|_| agent.names_conversation_files()) {
        return agent.transcript_file(home, worktree, Some(id));
    }
    static FOUND: OnceLock<Mutex<HashMap<(PathBuf, Agent, String), (Instant, Option<PathBuf>)>>> = OnceLock::new();
    let key = (home.to_path_buf(), agent, worktree.to_string());
    let found = FOUND.get_or_init(Default::default);
    if let Some((at, path)) = found.lock().unwrap().get(&key) {
        if at.elapsed() < LOOKUP {
            return path.clone();
        }
    }
    let path = agent.transcript_file(home, worktree, None);
    found.lock().unwrap().insert(key, (Instant::now(), path.clone()));
    path
}

/// A turn's id when its line has none: its content's, so it holds as the window slides and the
/// page keeps what is open in it. A line number would change with every poll of a long session.
fn line_id(line: &str) -> String {
    let mut hasher = DefaultHasher::new();
    line.hash(&mut hasher);
    format!("line-{:016x}", hasher.finish())
}

/// `{"revision","turns":[{"id","role","timestamp","model","blocks":[…]}],"atPrompt"}`, oldest
/// first. The revision is the file's size and modification time: when the caller already has it,
/// `turns` and `atPrompt` are left out. `atPrompt` is when the transcript last showed the agent
/// back at its prompt with no turn begun since, or null: both mark every turn's end, an
/// interrupt's included, which no hook reports.
pub fn read(home: &Path, agent: Agent, worktree: &str, since: Option<&str>, conversation: Option<&str>) -> Value {
    let Some(path) = locate(home, agent, worktree, conversation) else {
        return json!({"revision": "", "turns": []});
    };
    let revision = fs::metadata(&path)
        .ok()
        .map(|meta| {
            let modified = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok());
            format!("{}-{}", meta.len(), modified.map_or(0, |d| d.as_millis()))
        })
        .unwrap_or_default();
    if since == Some(revision.as_str()) && !revision.is_empty() {
        return json!({"revision": revision});
    }
    let Some(text) = super::tail_window(&path, WINDOW) else {
        return json!({"revision": revision, "turns": []});
    };
    let mut builder = Builder::new(worktree);
    // A window that starts mid-file starts mid-line; that fragment fails to parse and is skipped.
    for line in text.lines() {
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            match agent {
                Agent::Claude => builder.claude(&value, line_id(line)),
                Agent::Codex => builder.codex(&value, line_id(line)),
            }
        }
    }
    let mut turns = std::mem::take(&mut builder.turns);
    let skip = turns.len().saturating_sub(MAX_TURNS);
    let activity = activity(&turns);
    json!({"revision": revision, "turns": turns.split_off(skip), "atPrompt": builder.at_prompt, "activity": activity})
}

/// What the agent is doing, as its last turn shows it: a tool it called that has not answered yet,
/// or thinking. The same for every CLI, so the app draws it without knowing which one it has; it
/// shows it only while the agent works.
fn activity(turns: &[Value]) -> Value {
    let pending = turns
        .last()
        .filter(|turn| turn["role"] == "assistant")
        .and_then(|turn| turn["blocks"].as_array()?.last())
        .filter(|block| block["type"] == "tool" && block.get("output").is_none());
    match pending {
        Some(tool) => json!({"kind": tool["kind"], "detail": tool["summary"]}),
        None => json!({"kind": "thinking"}),
    }
}

struct Builder<'a> {
    worktree: &'a str,
    turns: Vec<Value>,
    /// A tool call's id to where it sits, so a result read later lands on its call.
    calls: HashMap<String, (usize, usize)>,
    /// The time of the last line that left the agent at its prompt, cleared by any later work.
    at_prompt: Value,
}

impl<'a> Builder<'a> {
    fn new(worktree: &'a str) -> Self {
        Self { worktree, turns: Vec::new(), calls: HashMap::new(), at_prompt: Value::Null }
    }

    fn user(&mut self, id: String, timestamp: &Value, text: &str) {
        self.at_prompt = Value::Null;
        self.turns.push(json!({
            "id": id, "role": "user", "timestamp": timestamp,
            "blocks": [{"type": "text", "text": text.trim()}],
        }));
    }

    /// The open assistant turn, or a new one when the last turn was a prompt.
    fn assistant(&mut self, id: &str, timestamp: &Value, model: &Value) -> &mut Vec<Value> {
        if self.turns.last().is_none_or(|turn| turn["role"] != "assistant") {
            self.turns.push(json!({
                "id": id, "role": "assistant", "timestamp": timestamp, "model": model, "blocks": [],
            }));
        }
        let turn = self.turns.last_mut().expect("pushed above");
        if turn["model"].is_null() && !model.is_null() {
            turn["model"] = model.clone();
        }
        // The last moment the agent was seen working, for "Worked for 31s".
        if !timestamp.is_null() {
            turn["ended"] = timestamp.clone();
        }
        turn["blocks"].as_array_mut().expect("blocks is an array")
    }

    fn push_text(&mut self, id: &str, timestamp: &Value, model: &Value, kind: &str, text: &str) {
        if text.trim().is_empty() {
            return;
        }
        self.assistant(id, timestamp, model).push(json!({"type": kind, "text": text.trim()}));
    }

    fn push_tool(&mut self, id: &str, timestamp: &Value, tool: Map<String, Value>) {
        let call = tool.get("id").and_then(Value::as_str).map(str::to_string);
        let blocks = self.assistant(id, timestamp, &Value::Null);
        blocks.push(Value::Object(tool));
        let block = blocks.len() - 1;
        let position = (self.turns.len() - 1, block);
        if let Some(call) = call {
            self.calls.insert(call, position);
        }
    }

    fn attach_result(&mut self, call: &str, timestamp: &Value, output: &str, error: bool) {
        let Some(&(turn, block)) = self.calls.get(call) else { return };
        let Some(turn) = self.turns.get_mut(turn) else { return };
        if !timestamp.is_null() {
            turn["ended"] = timestamp.clone();
        }
        if let Some(tool) = turn["blocks"].get_mut(block) {
            tool["output"] = json!(clip(output.trim(), MAX_OUTPUT));
            tool["isError"] = json!(error);
        }
    }

    fn short(&self, path: &str) -> String {
        path.strip_prefix(self.worktree)
            .map(|rest| rest.trim_start_matches('/').to_string())
            .filter(|rest| !rest.is_empty())
            .unwrap_or_else(|| path.to_string())
    }

    fn claude(&mut self, value: &Value, fallback: String) {
        // A compaction's summary is written as a prompt, but nobody typed it.
        if value["isSidechain"] == true || value["isMeta"] == true || value["isCompactSummary"] == true {
            return;
        }
        let id = value["uuid"].as_str().map(str::to_string).unwrap_or(fallback);
        let timestamp = &value["timestamp"];
        let message = &value["message"];
        let content = &message["content"];
        match value["type"].as_str() {
            Some("user") => match content {
                Value::String(text) => self.prompt(id, timestamp, text),
                Value::Array(blocks) => {
                    for (index, block) in blocks.iter().enumerate() {
                        match block["type"].as_str() {
                            Some("text") => self.prompt(part_id(&id, index), timestamp, block["text"].as_str().unwrap_or("")),
                            Some("tool_result") => {
                                let output = match &block["content"] {
                                    Value::String(text) => text.clone(),
                                    Value::Array(parts) => parts
                                        .iter()
                                        .filter_map(|part| part["text"].as_str())
                                        .collect::<Vec<_>>()
                                        .join("\n"),
                                    _ => String::new(),
                                };
                                let call = block["tool_use_id"].as_str().unwrap_or("");
                                self.attach_result(call, timestamp, &output, block["is_error"] == true);
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            },
            Some("assistant") => {
                let Value::Array(blocks) = content else { return };
                self.at_prompt = Value::Null;
                let model = &message["model"];
                for block in blocks {
                    match block["type"].as_str() {
                        Some("text") => self.push_text(&id, timestamp, model, "text", block["text"].as_str().unwrap_or("")),
                        Some("thinking") => {
                            self.push_text(&id, timestamp, model, "thinking", block["thinking"].as_str().unwrap_or(""))
                        }
                        Some("tool_use") => {
                            let tool = self.claude_tool(block);
                            self.push_tool(&id, timestamp, tool);
                        }
                        _ => {}
                    }
                }
            }
            // Written as every turn ends, an interrupt's included: the agent is back at its prompt.
            Some("system") if value["subtype"] == "turn_duration" => self.at_prompt = timestamp.clone(),
            // A message typed while the agent worked, which it took in mid-turn. It is written only
            // here, never as a prompt. Another session's message or a task's notice is not a person's.
            Some("attachment") => {
                let queued = &value["attachment"];
                if queued["type"] != "queued_command" || queued["commandMode"] != "prompt" || queued["origin"]["kind"] != "human" {
                    return;
                }
                match &queued["prompt"] {
                    Value::String(text) => self.prompt(id, timestamp, text),
                    Value::Array(parts) => {
                        for (index, part) in parts.iter().enumerate() {
                            if let Some(text) = part["text"].as_str() {
                                self.prompt(part_id(&id, index), timestamp, text);
                            }
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    /// A prompt as a person typed it. Injected context and reminders are XML-ish and dropped; a
    /// slash command keeps its `/name args`.
    fn prompt(&mut self, id: String, timestamp: &Value, text: &str) {
        // Claude's record of an interrupt, which versions before `turn_duration` write alone.
        if text.trim_start().starts_with("[Request interrupted by user") {
            self.at_prompt = timestamp.clone();
            return;
        }
        if let Some(command) = slash_command(text) {
            self.user(id, timestamp, &command);
        } else if !is_injected(text) {
            self.user(id, timestamp, text);
        }
    }

    fn claude_tool(&self, block: &Value) -> Map<String, Value> {
        let name = block["name"].as_str().unwrap_or("Tool");
        let input = &block["input"];
        let text = |key: &str| input[key].as_str();
        let summary = match name {
            "Bash" => text("description").or(text("command")).unwrap_or("").to_string(),
            "Read" | "Edit" | "Write" | "NotebookEdit" => text("file_path").map(|p| self.short(p)).unwrap_or_default(),
            "Glob" | "Grep" => text("pattern").unwrap_or("").to_string(),
            "Task" | "Agent" => text("description").or(text("subagent_type")).unwrap_or("").to_string(),
            "WebFetch" => text("url").unwrap_or("").to_string(),
            "WebSearch" => text("query").unwrap_or("").to_string(),
            "TodoWrite" => "todo list".to_string(),
            _ => text("description")
                .or(text("file_path"))
                .or(text("path"))
                .or(text("query"))
                .or(text("prompt"))
                .unwrap_or("")
                .to_string(),
        };
        let mut tool = Map::new();
        tool.insert("type".into(), json!("tool"));
        tool.insert("id".into(), block["id"].clone());
        tool.insert("name".into(), json!(name));
        tool.insert("kind".into(), json!(Agent::Claude.tool_kind(name)));
        tool.insert("summary".into(), json!(first_line(&summary)));
        if name == "Bash" {
            tool.insert("command".into(), json!(text("command").unwrap_or("")));
        }
        let change = match name {
            "Edit" | "NotebookEdit" => text("file_path").map(|path| {
                (path, text("old_string").or(text("old_source")).unwrap_or(""), text("new_string").or(text("new_source")).unwrap_or(""))
            }),
            "Write" => text("file_path").map(|path| (path, "", text("content").unwrap_or(""))),
            _ => None,
        };
        if let Some((path, old, new)) = change {
            tool.insert("path".into(), json!(self.short(path)));
            tool.insert("old".into(), json!(clip(old, MAX_FILE_TEXT)));
            tool.insert("new".into(), json!(clip(new, MAX_FILE_TEXT)));
        }
        tool
    }

    fn codex(&mut self, value: &Value, fallback: String) {
        // A session starts, and each turn ends or is aborted, at the prompt; a turn's start leaves it.
        match (value["type"].as_str(), value["payload"]["type"].as_str()) {
            (Some("session_meta"), _) | (Some("event_msg"), Some("task_complete" | "turn_aborted")) => {
                self.at_prompt = value["timestamp"].clone();
            }
            (Some("event_msg"), Some("task_started")) => self.at_prompt = Value::Null,
            _ => {}
        }
        if value["type"] != "response_item" {
            return;
        }
        let payload = &value["payload"];
        let timestamp = &value["timestamp"];
        let id = payload["id"].as_str().map(str::to_string).unwrap_or(fallback);
        match payload["type"].as_str() {
            Some("message") => {
                let texts = payload["content"].as_array().into_iter().flatten().filter_map(|block| block["text"].as_str());
                match payload["role"].as_str() {
                    Some("user") => {
                        for (index, text) in texts.enumerate() {
                            self.prompt(part_id(&id, index), timestamp, text);
                        }
                    }
                    Some("assistant") => {
                        let text = texts.collect::<Vec<_>>().join("\n\n");
                        self.push_text(&id, timestamp, &Value::Null, "text", &text);
                    }
                    _ => {}
                }
            }
            Some("reasoning") => {
                let summary = payload["summary"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|part| part["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n\n");
                self.push_text(&id, timestamp, &Value::Null, "thinking", &summary);
            }
            Some("function_call") | Some("custom_tool_call") => {
                let name = payload["name"].as_str().unwrap_or("tool");
                let raw = payload["arguments"].as_str().or(payload["input"].as_str()).unwrap_or("");
                let parsed: Value = serde_json::from_str(raw).unwrap_or(Value::Null);
                let command = ["cmd", "command"].iter().find_map(|key| match &parsed[key] {
                    Value::String(text) => Some(text.clone()),
                    Value::Array(parts) => Some(parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")),
                    _ => None,
                });
                let summary = command.clone().or_else(|| parsed["path"].as_str().map(|p| self.short(p))).unwrap_or_else(|| raw.to_string());
                let mut tool = Map::new();
                tool.insert("type".into(), json!("tool"));
                tool.insert("id".into(), payload["call_id"].clone());
                tool.insert("name".into(), json!(name));
                tool.insert("kind".into(), json!(Agent::Codex.tool_kind(name)));
                tool.insert("summary".into(), json!(first_line(&summary)));
                tool.insert("command".into(), json!(command.unwrap_or_else(|| raw.to_string())));
                self.push_tool(&id, timestamp, tool);
            }
            Some("function_call_output") | Some("custom_tool_call_output") => {
                let output = match &payload["output"] {
                    Value::String(text) => text.clone(),
                    Value::Array(parts) => parts.iter().filter_map(|part| part["text"].as_str()).collect::<Vec<_>>().join("\n"),
                    _ => String::new(),
                };
                self.attach_result(payload["call_id"].as_str().unwrap_or(""), timestamp, &output, false);
            }
            _ => {}
        }
    }
}

/// One line can hold several prompts' worth of text blocks; each bubble needs its own id.
fn part_id(id: &str, index: usize) -> String {
    if index == 0 { id.to_string() } else { format!("{id}-{index}") }
}

fn clip(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n…", &text[..end])
}

fn first_line(text: &str) -> String {
    let line = text.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or("");
    if line.chars().count() > 160 {
        line.chars().take(160).collect::<String>() + "…"
    } else {
        line.to_string()
    }
}

/// Injected context, slash-command wrappers and reminders are XML-ish; a person's prompt is not.
/// Claude also records an interrupt as a prompt it wrote itself.
fn is_injected(text: &str) -> bool {
    let text = text.trim_start();
    text.is_empty()
        || text.starts_with('<')
        || text.starts_with("# AGENTS.md")
        || text.starts_with("Caveat:")
        || text.starts_with("[Request interrupted by user")
}

/// `/name args` from Claude's `<command-name>` wrapper, so a slash command still shows as sent.
fn slash_command(text: &str) -> Option<String> {
    let between = |tag: &str| {
        let open = format!("<{tag}>");
        let start = text.find(&open)? + open.len();
        let end = text[start..].find(&format!("</{tag}>"))? + start;
        Some(text[start..end].trim().to_string())
    };
    let name = between("command-name")?;
    let args = between("command-args").unwrap_or_default();
    Some(if args.is_empty() { name } else { format!("{name} {args}") })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_known_conversation_is_read_and_one_not_yet_written_reads_empty() {
        let home = tempfile::tempdir().unwrap();
        let project = home.path().join(".claude/projects/-w-known");
        fs::create_dir_all(&project).unwrap();
        let line = |text: &str| {
            json!({"type":"user","uuid":text,"timestamp":"T1","message":{"role":"user","content":text}}).to_string() + "\n"
        };
        fs::write(project.join("older.jsonl"), line("from an older conversation")).unwrap();
        fs::write(project.join("live.jsonl"), line("from the live one")).unwrap();
        let read = |conversation| read(home.path(), Agent::Claude, "/w/known", None, conversation);
        let live = read(Some("live"));
        assert_eq!(live["turns"].as_array().map(Vec::len), Some(1));
        assert!(live.to_string().contains("from the live one") && !live.to_string().contains("older"));
        let unwritten = read(Some("reserved"));
        assert_eq!(unwritten["turns"], json!([]), "a conversation with no message yet has no turns");
        assert_eq!(unwritten["revision"], "");
    }

    fn summary(turns: &[Value]) -> Vec<String> {
        turns
            .iter()
            .map(|turn| {
                let blocks: Vec<String> = turn["blocks"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|b| format!("{}:{}", b["type"].as_str().unwrap(), b["text"].as_str().or(b["summary"].as_str()).unwrap_or("")))
                    .collect();
                format!("{} [{}]", turn["role"].as_str().unwrap(), blocks.join(", "))
            })
            .collect()
    }

    #[test]
    fn claude_groups_an_agent_run_into_one_turn_with_results_attached() {
        let mut builder = Builder::new("/w");
        for (index, line) in [
            json!({"type":"user","uuid":"a","message":{"role":"user","content":"fix the bug"}}),
            json!({"type":"user","uuid":"b","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}),
            json!({"type":"user","uuid":"c","isMeta":true,"message":{"role":"user","content":"meta"}}),
            json!({"type":"assistant","uuid":"d","timestamp":"T1","message":{"role":"assistant","model":"m1","content":[{"type":"thinking","thinking":"hmm"}]}}),
            json!({"type":"assistant","uuid":"e","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}),
            json!({"type":"assistant","uuid":"f","message":{"role":"assistant","content":[
                {"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w/src/a.rs","old_string":"x","new_string":"y"}}
            ]}}),
            json!({"type":"user","uuid":"g","timestamp":"T2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done","is_error":true}]}}),
            json!({"type":"assistant","uuid":"h","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"sub"}]}}),
            json!({"type":"user","uuid":"i","message":{"role":"user","content":"<command-name>/review</command-name><command-args>12</command-args>"}}),
            json!({"type":"user","uuid":"j","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}),
            json!({"type":"user","uuid":"k","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation"}}),
            json!({"type":"user","uuid":"l","message":{"role":"user","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}}),
        ]
        .iter()
        .enumerate()
        {
            builder.claude(line, index.to_string());
        }
        assert_eq!(
            summary(&builder.turns),
            vec![
                "user [text:fix the bug]",
                "assistant [thinking:hmm, text:Looking., tool:src/a.rs]",
                "user [text:/review 12]",
                "user [text:first]",
                "user [text:second]",
            ]
        );
        let ids: Vec<&str> = builder.turns.iter().filter_map(|turn| turn["id"].as_str()).collect();
        assert_eq!(&ids[2..], ["i", "l", "l-1"]);
        let tool = &builder.turns[1]["blocks"][2];
        assert_eq!(builder.turns[1]["model"], "m1");
        assert_eq!((builder.turns[1]["timestamp"].as_str(), builder.turns[1]["ended"].as_str()), (Some("T1"), Some("T2")));
        assert_eq!((tool["old"].as_str(), tool["new"].as_str()), (Some("x"), Some("y")));
        assert_eq!((tool["output"].as_str(), tool["isError"].as_bool()), (Some("done"), Some(true)));
        assert_eq!(tool["kind"], "edit");
    }

    #[test]
    fn codex_skips_developer_and_agents_md_but_keeps_calls_and_outputs() {
        let mut builder = Builder::new("/w");
        for (index, line) in [
            json!({"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}),
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}),
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}),
            json!({"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\"command\":[\"ls\",\"-la\"]}"}}),
            json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"a\nb"}}),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}),
            json!({"type":"event_msg","payload":{"type":"token_count"}}),
        ]
        .iter()
        .enumerate()
        {
            builder.codex(line, index.to_string());
        }
        assert_eq!(summary(&builder.turns), vec!["user [text:hello]", "assistant [tool:ls -la, text:Done.]"]);
        assert_eq!(builder.turns[1]["blocks"][0]["output"], "a\nb");
        assert_eq!(builder.turns[1]["blocks"][0]["kind"], "run");
    }

    #[test]
    fn the_activity_is_the_call_still_out_or_thinking() {
        let mut builder = Builder::new("/w");
        builder.claude(&json!({"type":"user","uuid":"a","message":{"role":"user","content":"test it"}}), "0".into());
        assert_eq!(activity(&builder.turns), json!({"kind":"thinking"}), "a prompt the agent has not answered");
        builder.claude(&json!({"type":"assistant","uuid":"b","message":{"role":"assistant","content":[
            {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test","description":"Run the tests"}}
        ]}}), "1".into());
        assert_eq!(activity(&builder.turns), json!({"kind":"run","detail":"Run the tests"}));
        builder.claude(&json!({"type":"user","uuid":"c","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}), "2".into());
        assert_eq!(activity(&builder.turns), json!({"kind":"thinking"}), "the call answered");

        let mut codex = Builder::new("/w");
        codex.codex(&json!({"type":"response_item","payload":{"type":"function_call","name":"apply_patch","call_id":"c1","arguments":"{\"path\":\"/w/a.rs\"}"}}), "0".into());
        assert_eq!(activity(&codex.turns), json!({"kind":"patch","detail":"a.rs"}));
    }

    #[test]
    fn the_transcript_says_when_the_agent_is_back_at_its_prompt() {
        let mut claude = Builder::new("/w");
        let lines = [
            json!({"type":"user","uuid":"a","timestamp":"T1","message":{"role":"user","content":"go"}}),
            json!({"type":"assistant","uuid":"b","timestamp":"T2","message":{"role":"assistant","content":[{"type":"text","text":"On it"}]}}),
            json!({"type":"user","uuid":"c","timestamp":"T3","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}),
        ];
        for (index, line) in lines.iter().enumerate() {
            claude.claude(line, index.to_string());
        }
        assert_eq!(claude.at_prompt, "T3");
        claude.claude(&json!({"type":"user","uuid":"d","timestamp":"T4","message":{"role":"user","content":"again"}}), "4".into());
        assert!(claude.at_prompt.is_null(), "a new prompt starts a turn");
        claude.claude(&json!({"type":"assistant","uuid":"e","timestamp":"T5","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}), "5".into());
        claude.claude(&json!({"type":"system","subtype":"stop_hook_summary","uuid":"f","timestamp":"T6"}), "6".into());
        assert!(claude.at_prompt.is_null());
        claude.claude(&json!({"type":"system","subtype":"turn_duration","uuid":"g","timestamp":"T7","isMeta":false}), "7".into());
        assert_eq!(claude.at_prompt, "T7", "a turn's end");

        let mut codex = Builder::new("/w");
        codex.codex(&json!({"type":"session_meta","timestamp":"S0","payload":{"cwd":"/w"}}), "0".into());
        assert_eq!(codex.at_prompt, "S0", "a fresh session is at its prompt");
        codex.codex(&json!({"type":"event_msg","timestamp":"S1","payload":{"type":"task_started"}}), "1".into());
        assert!(codex.at_prompt.is_null());
        codex.codex(&json!({"type":"event_msg","timestamp":"S2","payload":{"type":"turn_aborted"}}), "2".into());
        assert_eq!(codex.at_prompt, "S2");
    }

    #[test]
    fn claude_shows_a_message_it_took_in_mid_turn_where_it_took_it() {
        let queued = |uuid: &str, mode: &str, origin: &str, prompt: Value| {
            json!({"type":"attachment","uuid":uuid,"timestamp":"T2","attachment":{
                "type":"queued_command","prompt":prompt,"commandMode":mode,"origin":{"kind":origin}}})
        };
        let mut builder = Builder::new("/w");
        for (index, line) in [
            json!({"type":"user","uuid":"a","timestamp":"T1","message":{"role":"user","content":"go"}}),
            json!({"type":"assistant","uuid":"b","message":{"role":"assistant","content":[{"type":"text","text":"On it"}]}}),
            queued("c", "prompt", "human", json!("also this")),
            queued("d", "prompt", "human", json!([{"type":"text","text":"and look"},{"type":"image","source":{}}])),
            queued("e", "prompt", "peer", json!("from another session")),
            queued("f", "task-notification", "human", json!("<task-notification>x</task-notification>")),
            json!({"type":"attachment","uuid":"g","attachment":{"type":"hook_success","content":"ok"}}),
            json!({"type":"assistant","uuid":"h","message":{"role":"assistant","content":[{"type":"text","text":"Both done"}]}}),
        ]
        .iter()
        .enumerate()
        {
            builder.claude(line, index.to_string());
        }
        assert_eq!(
            summary(&builder.turns),
            vec!["user [text:go]", "assistant [text:On it]", "user [text:also this]", "user [text:and look]", "assistant [text:Both done]"]
        );
        assert_eq!((builder.turns[2]["id"].as_str(), builder.turns[2]["timestamp"].as_str()), (Some("c"), Some("T2")));
        assert!(builder.at_prompt.is_null(), "still at work");
    }

    #[test]
    fn a_line_without_an_id_keeps_one_as_the_window_moves() {
        let line = r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#;
        assert_eq!(line_id(line), line_id(line));
        assert_ne!(line_id(line), line_id(&line.replace("hi", "ho")));
    }

    #[test]
    fn clip_cuts_on_a_character_boundary() {
        assert_eq!(clip("héllo", 2), "h\n…");
        assert_eq!(clip("hi", 10), "hi");
    }
}
