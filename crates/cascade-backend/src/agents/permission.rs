//! Tool approvals answered from the chat view (prototype). Claude Code and Codex both run a
//! `PermissionRequest` hook before they show their own approval prompt, and take `allow` or `deny`
//! from it; a hook that answers nothing leaves the prompt to the terminal, as without Cascade.
//!
//! The hook posts here and waits. The request is offered to the app as an `agent-permission`
//! event; the app answers it from a chat card, or passes at once when that session's chat is not
//! on screen. Nothing listening, a pass, or no answer in time all fall back to the terminal.
//! However the request ends, an `agent-permission-done` event says how, so no card outlives it.

use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::Duration,
};

use axum::{
    extract::{Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::{broadcast, oneshot};
use uuid::Uuid;

use crate::AppState;

/// Under the hook's own timeout (`HOOK_TIMEOUT`), so the answer — or the pass — gets back to it.
const WAIT: Duration = Duration::from_secs(280);
/// The `timeout` written into the hook entry, in seconds; both CLIs read it.
pub(crate) const HOOK_TIMEOUT: u64 = 300;
/// What one card carries. Past it the card says so and offers the terminal instead of Allow: a
/// person must never approve what they were not shown.
const MAX_DETAIL: usize = 20_000;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Answer {
    Allow,
    Deny,
    Pass,
}

fn pending() -> &'static Mutex<HashMap<String, oneshot::Sender<Answer>>> {
    static PENDING: OnceLock<Mutex<HashMap<String, oneshot::Sender<Answer>>>> = OnceLock::new();
    PENDING.get_or_init(Default::default)
}

#[derive(Default, Deserialize)]
pub struct HookQuery {
    cli: Option<String>,
    #[serde(rename = "runId")]
    run_id: Option<String>,
}

/// Cut to `MAX_DETAIL`, and whether anything was cut.
fn bounded(text: &str) -> (String, bool) {
    if text.chars().count() <= MAX_DETAIL {
        (text.to_string(), false)
    } else {
        (text.chars().take(MAX_DETAIL).collect(), true)
    }
}

/// What a person needs to decide: the tool, what it would touch, the agent's own reason, and for
/// a file change both sides of it, as the terminal's own prompt shows them.
fn describe(payload: &Value) -> Value {
    let tool = payload["tool_name"].as_str().unwrap_or("Tool");
    let input = &payload["tool_input"];
    let text = |key: &str| input[key].as_str();
    let change = match tool {
        "Edit" => text("file_path").map(|path| (path, text("old_string").unwrap_or("").to_string(), text("new_string").unwrap_or("").to_string())),
        "MultiEdit" => text("file_path").map(|path| {
            let edits = input["edits"].as_array().map(Vec::as_slice).unwrap_or_default();
            let side = |key: &str| edits.iter().filter_map(|edit| edit[key].as_str()).collect::<Vec<_>>().join("\n⋯\n");
            (path, side("old_string"), side("new_string"))
        }),
        "Write" => text("file_path").map(|path| (path, String::new(), text("content").unwrap_or("").to_string())),
        "NotebookEdit" => text("notebook_path").map(|path| (path, String::new(), text("new_source").unwrap_or("").to_string())),
        _ => None,
    };
    let detail = ["command", "file_path", "notebook_path", "path", "url", "pattern", "query"]
        .iter()
        .find_map(|key| match &input[*key] {
            Value::String(text) => Some(text.clone()),
            Value::Array(parts) => Some(parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")),
            _ => None,
        })
        .or_else(|| (!input.is_null()).then(|| input.to_string()))
        .unwrap_or_default();
    let (detail, mut truncated) = bounded(&detail);
    let reason = text("description").or_else(|| text("justification")).unwrap_or("");
    let mut request = json!({"tool": tool, "detail": detail, "reason": reason});
    if let Some((_, old, new)) = change {
        let (old, cut_old) = bounded(&old);
        let (new, cut_new) = bounded(&new);
        truncated |= cut_old || cut_new;
        request["old"] = json!(old);
        request["new"] = json!(new);
    }
    request["truncated"] = json!(truncated);
    request
}

fn decision(answer: Answer) -> Option<Value> {
    let decision = match answer {
        Answer::Allow => json!({"behavior": "allow"}),
        Answer::Deny => json!({"behavior": "deny", "message": "Denied from Cascade's chat view."}),
        Answer::Pass => return None,
    };
    Some(json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}))
}

/// One offered request. Dropped however the hook's request ends — answered, timed out, or
/// abandoned when the CLI kills the hook mid-wait (an interrupt) — so the entry never leaks and
/// the app always hears how it ended: `answered`, `terminal` (the CLI shows its own prompt), or
/// `cancelled` (nothing is waiting any more).
struct Offer {
    id: String,
    run_id: String,
    events: broadcast::Sender<Value>,
    outcome: &'static str,
}

impl Drop for Offer {
    fn drop(&mut self) {
        pending().lock().unwrap().remove(&self.id);
        let _ = self.events.send(json!({
            "type": "agent-permission-done", "id": self.id, "runId": self.run_id, "outcome": self.outcome,
        }));
    }
}

/// The hook's request. It answers with the hook's output: a decision, or an empty body, which
/// both CLIs take as "no decision" and show their own prompt.
pub async fn request(
    State(app): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HookQuery>,
    Json(payload): Json<Value>,
) -> Response {
    let pass = || StatusCode::NO_CONTENT.into_response();
    if crate::local::foreign_origin(&headers) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let run_id = query.run_id.unwrap_or_default();
    if run_id.is_empty() {
        return pass();
    }
    let (sender, receiver) = oneshot::channel();
    let mut offer = Offer { id: Uuid::new_v4().to_string(), run_id, events: app.events.clone(), outcome: "cancelled" };
    pending().lock().unwrap().insert(offer.id.clone(), sender);
    let offered = app.events.send(json!({
        "type": "agent-permission", "id": offer.id, "runId": offer.run_id,
        "cli": query.cli.unwrap_or_default(), "request": describe(&payload),
    }));
    let answer = if offered.is_ok() {
        tokio::time::timeout(WAIT, receiver).await.ok().and_then(Result::ok)
    } else {
        None
    };
    let output = answer.and_then(decision);
    offer.outcome = if output.is_some() { "answered" } else { "terminal" };
    drop(offer);
    match output {
        Some(output) => ([(header::CONTENT_TYPE, "application/json")], output.to_string()).into_response(),
        None => pass(),
    }
}

#[derive(Deserialize)]
pub struct AnswerBody {
    id: String,
    /// `allow`, `deny`, or `pass` to hand the prompt back to the terminal.
    decision: String,
}

/// An answer runs a tool on the person's behalf, so a page in a browser must not reach it.
pub async fn answer(headers: HeaderMap, Json(body): Json<AnswerBody>) -> StatusCode {
    if crate::local::foreign_origin(&headers) {
        return StatusCode::FORBIDDEN;
    }
    let answer = match body.decision.as_str() {
        "allow" => Answer::Allow,
        "deny" => Answer::Deny,
        "pass" => Answer::Pass,
        _ => return StatusCode::BAD_REQUEST,
    };
    let Some(sender) = pending().lock().unwrap().remove(&body.id) else {
        return StatusCode::GONE;
    };
    match sender.send(answer) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(_) => StatusCode::GONE,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describes_a_command_and_a_file_edit() {
        let bash = describe(&json!({"tool_name":"Bash","tool_input":{"command":"gh repo view","description":"Check the branch"}}));
        assert_eq!(bash, json!({"tool":"Bash","detail":"gh repo view","reason":"Check the branch","truncated":false}));
        let edit = describe(&json!({"tool_name":"Edit","tool_input":{"file_path":"/a/b.rs","old_string":"x","new_string":"y"}}));
        assert_eq!((edit["detail"].as_str(), edit["old"].as_str(), edit["new"].as_str()), (Some("/a/b.rs"), Some("x"), Some("y")));
        let multi = describe(&json!({"tool_name":"MultiEdit","tool_input":{"file_path":"/a","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}}));
        assert_eq!((multi["old"].as_str(), multi["new"].as_str()), (Some("a\n⋯\nc"), Some("b\n⋯\nd")));
        let write = describe(&json!({"tool_name":"Write","tool_input":{"file_path":"/n.txt","content":"hi"}}));
        assert_eq!((write["old"].as_str(), write["new"].as_str()), (Some(""), Some("hi")));
        let argv = describe(&json!({"tool_name":"shell","tool_input":{"command":["git","push"]}}));
        assert_eq!(argv["detail"], "git push");
        assert!(argv.get("old").is_none());
    }

    #[test]
    fn a_request_too_long_to_show_says_so() {
        let long = "x".repeat(MAX_DETAIL + 1);
        let bash = describe(&json!({"tool_name":"Bash","tool_input":{"command":long}}));
        assert_eq!((bash["truncated"].as_bool(), bash["detail"].as_str().map(str::len)), (Some(true), Some(MAX_DETAIL)));
        let write = describe(&json!({"tool_name":"Write","tool_input":{"file_path":"/a","content":long}}));
        assert_eq!(write["truncated"], true);
    }

    #[test]
    fn decisions_match_the_hook_schema() {
        assert_eq!(
            decision(Answer::Allow).unwrap(),
            json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})
        );
        assert_eq!(decision(Answer::Deny).unwrap()["hookSpecificOutput"]["decision"]["behavior"], "deny");
        assert!(decision(Answer::Pass).is_none());
    }

    #[test]
    fn an_abandoned_offer_is_removed_and_reported() {
        let (events, mut heard) = broadcast::channel(4);
        let (sender, _receiver) = oneshot::channel();
        pending().lock().unwrap().insert("abandoned".into(), sender);
        drop(Offer { id: "abandoned".into(), run_id: "run".into(), events, outcome: "cancelled" });
        assert!(!pending().lock().unwrap().contains_key("abandoned"));
        let done = heard.try_recv().unwrap();
        assert_eq!((done["type"].as_str(), done["outcome"].as_str()), (Some("agent-permission-done"), Some("cancelled")));
    }
}
