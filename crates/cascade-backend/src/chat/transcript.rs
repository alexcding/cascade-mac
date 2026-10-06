//! A terminal session's conversation as a read-only chat thread (`GET /api/agent/transcript
//! ?format=thread`), so the chat page shows it as it shows its own chats. The turns are the
//! transcript's (`agents::transcript`); each tool call and thinking block becomes the activity the
//! chat engine would have made of it, by handing the engine's own projection
//! (`project_provider_runtime_activities`) the runtime events a live session would have sent. A
//! tool approval the terminal's agent waits on (`agents::permission`) is an `approval.requested`
//! activity whose `requestId` is the offer's id, which `POST /api/agent/permission` answers.
//!
//! Every id comes from the transcript (a line's id, a tool call's id, an offer's id) and every
//! time from its lines, so reading an unchanged transcript gives the same thread.

use std::{
    hash::{DefaultHasher, Hash, Hasher},
    path::PathBuf,
    sync::Arc,
};

use cascade_chat::{
    contracts::{orchestration::OrchestrationThread, provider_runtime::ProviderRuntimeEvent},
    orchestration::activity_projection::project_provider_runtime_activities,
    STANDALONE_PROJECT_ID,
};
use chrono::{DateTime, SecondsFormat, TimeDelta, Utc};
use serde_json::{json, Map, Value};

use crate::{
    agents::{permission::Waiting, Agent, TranscriptQuery},
    AppState,
};

/// `GET /api/agent/transcript?format=thread`: `{revision, snapshot}`, or `{revision}` alone when
/// `since` is the revision the caller has and neither the transcript nor the terminal's waiting
/// approvals changed since, so a poll of an idle session rebuilds nothing.
pub(crate) async fn transcript_thread(app: &AppState, query: TranscriptQuery) -> Value {
    match crate::agents::home() {
        Some(home) => transcript_thread_in(app, query, home).await,
        None => json!({"revision": "", "snapshot": null}),
    }
}

pub(crate) async fn transcript_thread_in(app: &AppState, query: TranscriptQuery, home: PathBuf) -> Value {
    let changed = match query.run_id.as_deref().filter(|run| !run.is_empty()) {
        Some(run) => app.permissions.waiting(run).await.1,
        None => DateTime::UNIX_EPOCH,
    }
    .timestamp_millis();
    let query = Arc::new(query);
    let reading = query.clone();
    let found = tokio::task::spawn_blocking(move || crate::agents::transcript_in(&home, &reading, Some(changed)))
        .await
        .ok()
        .flatten();
    let Some((agent, found)) = found else {
        return json!({"revision": "", "snapshot": null});
    };
    if found.get("turns").is_none() {
        let revision = found["revision"].as_str().unwrap_or_default();
        return json!({ "revision": format!("{revision}:{changed}") });
    }
    thread_of_transcript(app, agent, &query, found).await
}

/// `{revision, snapshot:{snapshotSequence, thread}}` for `found`, what `agents::transcript` read
/// with `format=thread`. The sequence is the later of the transcript's last write and the last
/// change to the waiting approvals, in milliseconds: it only grows, so the page never takes an
/// older read for a newer one.
pub(crate) async fn thread_of_transcript(app: &AppState, agent: Agent, query: &TranscriptQuery, found: Value) -> Value {
    let run_id = query.run_id.as_deref().filter(|run| !run.is_empty());
    let (waiting, changed) = match run_id {
        Some(run) => app.permissions.waiting(run).await,
        None => (Vec::new(), DateTime::UNIX_EPOCH),
    };
    let revision = found["revision"].as_str().unwrap_or_default();
    let written = revision
        .rsplit_once('-')
        .and_then(|(_, millis)| millis.parse::<i64>().ok())
        .unwrap_or(0);
    let sequence = written.max(changed.timestamp_millis()).max(0);
    let thread_id = query.thread_id.clone().filter(|id| !id.trim().is_empty()).unwrap_or_else(|| {
        let mut hasher = DefaultHasher::new();
        (agent.profile().id, query.worktree(), run_id).hash(&mut hasher);
        format!("transcript-{:016x}", hasher.finish())
    });
    let project_id = query.project_id.clone().filter(|id| !id.trim().is_empty()).unwrap_or_else(|| STANDALONE_PROJECT_ID.to_owned());
    let source = Source {
        agent,
        thread_id: &thread_id,
        project_id: &project_id,
        worktree: query.worktree(),
        turns: found["turns"].as_array().map(Vec::as_slice).unwrap_or_default(),
        at_prompt: &found["atPrompt"],
        waiting: &waiting,
        written: DateTime::from_timestamp_millis(written).unwrap_or(DateTime::UNIX_EPOCH),
    };
    let thread = match build(&source) {
        Ok(thread) => json!(thread),
        Err(error) => {
            tracing::warn!(error = %error, "chat: a transcript did not make a thread");
            Value::Null
        }
    };
    json!({
        "revision": format!("{revision}:{}", changed.timestamp_millis()),
        "snapshot": { "snapshotSequence": sequence, "thread": thread },
    })
}

pub(super) struct Source<'a> {
    pub agent: Agent,
    pub thread_id: &'a str,
    pub project_id: &'a str,
    pub worktree: &'a str,
    pub turns: &'a [Value],
    pub at_prompt: &'a Value,
    pub waiting: &'a [Waiting],
    /// When the transcript was last written: the time of anything it gives none for.
    pub written: DateTime<Utc>,
}

/// Times in the order things happened: a line's own time, or a millisecond after the last one
/// when it has none or would go back (a block's time is its line's, shared by every block in it).
struct Clock {
    last: Option<DateTime<Utc>>,
    fallback: DateTime<Utc>,
}

impl Clock {
    fn next(&mut self, at: &Value) -> String {
        let parsed = at.as_str().and_then(|text| DateTime::parse_from_rfc3339(text).ok()).map(|time| time.with_timezone(&Utc));
        let time = match (parsed, self.last) {
            (Some(time), Some(last)) if time > last => time,
            (Some(time), None) => time,
            (_, Some(last)) => last + TimeDelta::milliseconds(1),
            (None, None) => self.fallback,
        };
        self.last = Some(time);
        time.to_rfc3339_opts(SecondsFormat::Millis, true)
    }

    fn now(&self) -> String {
        self.last.unwrap_or(self.fallback).to_rfc3339_opts(SecondsFormat::Millis, true)
    }
}

/// What a tool's kind (`Agent::tool_kind`) is as the chat engine's item type, and the title the
/// Claude adapter gives that type (Synara `titleForTool`).
fn item_type(kind: &str) -> (&'static str, &'static str) {
    match kind {
        "run" => ("command_execution", "Command run"),
        "edit" | "patch" | "create" => ("file_change", "File change"),
        "delegate" => ("collab_agent_tool_call", "Subagent task"),
        "web" => ("web_search", "Web search"),
        "plan" => ("plan", "Plan"),
        _ => ("dynamic_tool_call", "Tool call"),
    }
}

/// What a tool approval asks for, by the tool's kind.
fn request_type(kind: &str) -> &'static str {
    match kind {
        "run" => "command_execution_approval",
        "edit" | "patch" | "create" => "file_change_approval",
        "read" => "file_read_approval",
        _ => "tool_approval",
    }
}

/// Synara `summarizeToolRequest`: `Name: command`, else `Name: {input}`, at most 400 characters.
fn summarize(name: &str, input: &Value) -> String {
    let command = match input.get("command").or_else(|| input.get("cmd")) {
        Some(Value::String(text)) => Some(text.clone()),
        Some(Value::Array(parts)) => Some(parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")),
        _ => None,
    };
    if let Some(command) = command.filter(|command| !command.trim().is_empty()) {
        return format!("{name}: {}", command.trim().chars().take(400).collect::<String>().trim_end());
    }
    let serialized = input.to_string();
    if serialized.chars().count() <= 400 {
        format!("{name}: {serialized}")
    } else {
        format!("{name}: {}...", serialized.chars().take(397).collect::<String>())
    }
}

pub(super) fn build(source: &Source) -> Result<OrchestrationThread, serde_json::Error> {
    let provider = source.agent.profile().chat_provider;
    let first_time = source
        .turns
        .iter()
        .find_map(|turn| turn["timestamp"].as_str().and_then(|text| DateTime::parse_from_rfc3339(text).ok()))
        .map(|time| time.with_timezone(&Utc));
    let mut clock = Clock { last: None, fallback: first_time.unwrap_or(source.written) };
    let mut messages: Vec<Value> = Vec::new();
    let mut activities: Vec<Value> = Vec::new();
    let mut sequence = 0u64;
    let mut project = |event: Value, activities: &mut Vec<Value>| -> Result<(), serde_json::Error> {
        let event: ProviderRuntimeEvent = serde_json::from_value(event)?;
        sequence += 1;
        for activity in project_provider_runtime_activities(&event, Some(sequence)) {
            activities.push(serde_json::to_value(activity)?);
        }
        Ok(())
    };
    let runtime_event = |id: String, kind: &str, turn: &str, at: &str, item: Option<&str>, payload: Value| {
        let mut event = json!({
            "eventId": id, "provider": provider, "threadId": source.thread_id, "createdAt": at,
            "turnId": turn, "type": kind, "payload": payload,
        });
        if let Some(item) = item {
            event["itemId"] = json!(item);
        }
        event
    };

    let mut turn_id: Option<String> = None;
    let mut latest: Option<Map<String, Value>> = None;
    let mut latest_user_at = Value::Null;
    let mut model = String::new();
    let mut title = String::new();
    for turn in source.turns {
        let Some(id) = turn["id"].as_str() else { continue };
        let blocks = turn["blocks"].as_array().map(Vec::as_slice).unwrap_or_default();
        if turn["role"] == "user" {
            let text = blocks.iter().filter_map(|block| block["text"].as_str()).collect::<Vec<_>>().join("\n\n");
            let at = clock.next(&turn["timestamp"]);
            let current = format!("turn:{id}");
            if title.is_empty() {
                title = text.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default().chars().take(80).collect();
            }
            messages.push(json!({
                "id": format!("user:{id}"), "role": "user", "text": text, "turnId": current,
                "streaming": false, "createdAt": at, "updatedAt": at,
            }));
            latest_user_at = json!(at);
            latest = Some(new_turn(&current, &at));
            turn_id = Some(current);
            continue;
        }
        let current = match &turn_id {
            Some(current) => current.clone(),
            None => {
                let current = format!("turn:{id}");
                let at = clock.next(&turn["timestamp"]);
                latest = Some(new_turn(&current, &at));
                turn_id = Some(current.clone());
                current
            }
        };
        if let Some(name) = turn["model"].as_str().filter(|name| !name.is_empty()) {
            model = name.to_owned();
        }
        for (index, block) in blocks.iter().enumerate() {
            let line_time = if block["at"].is_null() { &turn["timestamp"] } else { &block["at"] };
            match block["type"].as_str() {
                Some("text") => {
                    let at = clock.next(line_time);
                    let message_id = format!("assistant:{id}:{index}");
                    messages.push(json!({
                        "id": message_id, "role": "assistant", "text": block["text"], "turnId": current,
                        "streaming": false, "createdAt": at, "updatedAt": at,
                    }));
                    if let Some(latest) = latest.as_mut() {
                        latest.insert("assistantMessageId".into(), json!(message_id));
                    }
                }
                Some("thinking") => {
                    let at = clock.next(line_time);
                    let item = format!("reasoning:{id}:{index}");
                    let payload = json!({ "itemType": "reasoning", "status": "completed", "title": "Thinking", "detail": block["text"] });
                    project(runtime_event(format!("{item}:completed"), "item.completed", &current, &at, Some(&item), payload), &mut activities)?;
                }
                Some("tool") => {
                    let call = block["id"].as_str().map(str::to_owned).unwrap_or_else(|| format!("{id}:{index}"));
                    let name = block["name"].as_str().unwrap_or("Tool");
                    let (item_type, item_title) = item_type(block["kind"].as_str().unwrap_or("other"));
                    let input = if block["input"].is_object() { block["input"].clone() } else { json!({}) };
                    let mut data = json!({ "toolCallId": call, "callId": call, "toolName": name, "input": input });
                    let detail = summarize(name, &input);
                    let at = clock.next(line_time);
                    let started = json!({ "itemType": item_type, "status": "inProgress", "title": item_title, "detail": detail, "data": data });
                    project(runtime_event(format!("tool:{call}:started"), "item.started", &current, &at, Some(&call), started), &mut activities)?;
                    if let Some(output) = block.get("output") {
                        let failed = block["isError"] == true;
                        data["result"] = json!({ "type": "tool_result", "tool_use_id": call, "content": output, "is_error": failed });
                        let at = clock.next(&block["endedAt"]);
                        let completed = json!({
                            "itemType": item_type, "status": if failed { "failed" } else { "completed" },
                            "title": item_title, "detail": detail, "data": data,
                        });
                        project(runtime_event(format!("tool:{call}:completed"), "item.completed", &current, &at, Some(&call), completed), &mut activities)?;
                    }
                }
                _ => {}
            }
        }
    }

    let at_prompt = !source.at_prompt.is_null();
    let current = turn_id.clone().unwrap_or_default();
    let mut pending = false;
    for waiting in source.waiting {
        let kind = source.agent.tool_kind(&waiting.tool);
        let at = clock.next(&json!(waiting.at.to_rfc3339_opts(SecondsFormat::Millis, true)));
        let mut event = runtime_event(
            format!("approval:{}", waiting.id),
            "request.opened",
            &current,
            &at,
            None,
            json!({
                "requestType": request_type(kind),
                "detail": summarize(&waiting.tool, &waiting.input),
                "args": { "toolName": waiting.tool, "input": waiting.input },
            }),
        );
        event["requestId"] = json!(waiting.id);
        if current.is_empty() {
            event.as_object_mut().expect("an object").remove("turnId");
        }
        project(event, &mut activities)?;
        pending = true;
    }

    let latest_turn = latest.map(|mut latest| {
        if at_prompt {
            latest.insert("state".into(), json!("completed"));
            latest.insert("completedAt".into(), json!(clock.next(source.at_prompt)));
        }
        Value::Object(latest)
    });
    let running = !at_prompt && latest_turn.is_some();
    let created = messages.first().map(|message| message["createdAt"].clone()).unwrap_or_else(|| json!(clock.now()));
    let updated = json!(clock.now());
    let mut thread = json!({
        "id": source.thread_id,
        "projectId": source.project_id,
        "title": if title.is_empty() { "Terminal session".to_owned() } else { title },
        "modelSelection": { "provider": provider, "model": model },
        "runtimeMode": "approval-required",
        "interactionMode": "default",
        "branch": null,
        "worktreePath": source.worktree,
        "workingDirectory": source.worktree,
        "latestTurn": latest_turn,
        "createdAt": created,
        "updatedAt": updated,
        "deletedAt": null,
        "messages": messages,
        "activities": activities,
        "checkpoints": [],
        "session": {
            "threadId": source.thread_id,
            "status": if running { "running" } else { "ready" },
            "providerName": provider,
            "runtimeMode": "approval-required",
            "activeTurnId": if running { json!(current) } else { Value::Null },
            "lastError": null,
            "updatedAt": updated,
        },
    });
    if !latest_user_at.is_null() {
        thread["latestUserMessageAt"] = latest_user_at.clone();
        thread["latestHumanMessageAt"] = latest_user_at;
    }
    if pending {
        thread["hasPendingApprovals"] = json!(true);
    }
    serde_json::from_value(thread)
}

fn new_turn(turn_id: &str, at: &str) -> Map<String, Value> {
    let Value::Object(turn) = json!({
        "turnId": turn_id, "state": "running", "requestedAt": at, "startedAt": at,
        "completedAt": null, "assistantMessageId": null,
    }) else {
        unreachable!("an object")
    };
    turn
}
