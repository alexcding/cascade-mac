//! Tool approvals answered from the chat view (prototype). Claude Code and Codex both run a
//! `PermissionRequest` hook before they show their own approval prompt, and take `allow` or `deny`
//! from it; a hook that answers nothing leaves the prompt to the terminal, as without Cascade.
//!
//! The hook posts here and waits. The request is offered to the app as an `agent-permission`
//! event; the app answers it from a chat card, or passes at once when that session's chat is not
//! on screen. Nothing listening, a pass, or no answer in time all fall back to the terminal.
//! However the request ends, an `agent-permission-done` event says how, so no card outlives it.

use std::{collections::HashMap, time::Duration};

use axum::{
    extract::{Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, oneshot};
use uuid::Uuid;

use super::Agent;
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

/// The offers waiting for an answer, owned by one task; `AppState.permissions` is its handle. An
/// offer is entered when the hook asks, taken when the app answers, and forgotten however the
/// hook's request ends. Made inside a Tokio runtime.
#[derive(Clone)]
pub struct Permissions {
    tx: mpsc::UnboundedSender<PermissionMsg>,
}

enum PermissionMsg {
    Offer(String, oneshot::Sender<Answer>),
    /// Hands an answer to an offer; replies whether one was waiting and took it.
    Answer(String, Answer, oneshot::Sender<bool>),
    Forget(String),
}

impl Default for Permissions {
    fn default() -> Self {
        Self::new()
    }
}

impl Permissions {
    pub fn new() -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut pending: HashMap<String, oneshot::Sender<Answer>> = HashMap::new();
            while let Some(message) = rx.recv().await {
                match message {
                    PermissionMsg::Offer(id, sender) => {
                        pending.insert(id, sender);
                    }
                    PermissionMsg::Answer(id, answer, reply) => {
                        let taken = pending
                            .remove(&id)
                            .is_some_and(|sender| sender.send(answer).is_ok());
                        let _ = reply.send(taken);
                    }
                    PermissionMsg::Forget(id) => {
                        pending.remove(&id);
                    }
                }
            }
        });
        Self { tx }
    }

    fn offer(&self, id: &str, sender: oneshot::Sender<Answer>) {
        let _ = self.tx.send(PermissionMsg::Offer(id.to_owned(), sender));
    }

    /// `true` when an offer was waiting for the answer and took it; `false` when none was, or
    /// the hook had stopped waiting.
    async fn answer(&self, id: &str, answer: Answer) -> bool {
        let (reply, taken) = oneshot::channel();
        let message = PermissionMsg::Answer(id.to_owned(), answer, reply);
        if self.tx.send(message).is_err() {
            return false;
        }
        taken.await.unwrap_or(false)
    }

    fn forget(&self, id: &str) {
        let _ = self.tx.send(PermissionMsg::Forget(id.to_owned()));
    }
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

/// What a person needs to decide: the tool and what it does, what it would touch, the agent's own
/// reason, and for a file change both sides of it, as the terminal's own prompt shows them. The
/// CLI's adapter reads its own tools; one the app does not know has its tool shown by name.
fn describe(payload: &Value, agent: Option<Agent>) -> Value {
    let tool = payload["tool_name"].as_str().unwrap_or("Tool");
    let input = &payload["tool_input"];
    let text = |key: &str| input[key].as_str();
    let kind = agent.map_or("other", |agent| agent.tool_kind(tool));
    let change = agent.and_then(|agent| agent.tool_change(tool, input));
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
    let mut request = json!({"tool": tool, "kind": kind, "detail": detail, "reason": reason});
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
    permissions: Permissions,
    events: broadcast::Sender<Value>,
    outcome: &'static str,
}

impl Drop for Offer {
    fn drop(&mut self) {
        self.permissions.forget(&self.id);
        let _ = self.events.send(
            crate::Event::AgentPermissionDone {
                id: self.id.clone(),
                run_id: self.run_id.clone(),
                outcome: self.outcome,
            }
            .into(),
        );
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
    let mut offer = Offer {
        id: Uuid::new_v4().to_string(),
        run_id,
        permissions: app.permissions.clone(),
        events: app.events.clone(),
        outcome: "cancelled",
    };
    app.permissions.offer(&offer.id, sender);
    let offered = app.events.send(
        crate::Event::AgentPermission {
            id: offer.id.clone(),
            run_id: offer.run_id.clone(),
            request: describe(&payload, query.cli.as_deref().and_then(Agent::of)),
            cli: query.cli.unwrap_or_default(),
        }
        .into(),
    );
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
pub async fn answer(
    State(app): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<AnswerBody>,
) -> StatusCode {
    if crate::local::foreign_origin(&headers) {
        return StatusCode::FORBIDDEN;
    }
    let answer = match body.decision.as_str() {
        "allow" => Answer::Allow,
        "deny" => Answer::Deny,
        "pass" => Answer::Pass,
        _ => return StatusCode::BAD_REQUEST,
    };
    if app.permissions.answer(&body.id, answer).await {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::GONE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describes_a_command_and_a_file_edit() {
        let claude = Some(Agent::Claude);
        let bash = describe(&json!({"tool_name":"Bash","tool_input":{"command":"gh repo view","description":"Check the branch"}}), claude);
        assert_eq!(bash, json!({"tool":"Bash","kind":"run","detail":"gh repo view","reason":"Check the branch","truncated":false}));
        let edit = describe(&json!({"tool_name":"Edit","tool_input":{"file_path":"/a/b.rs","old_string":"x","new_string":"y"}}), claude);
        assert_eq!((edit["detail"].as_str(), edit["old"].as_str(), edit["new"].as_str()), (Some("/a/b.rs"), Some("x"), Some("y")));
        let multi = describe(&json!({"tool_name":"MultiEdit","tool_input":{"file_path":"/a","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}}), claude);
        assert_eq!((multi["old"].as_str(), multi["new"].as_str()), (Some("a\n⋯\nc"), Some("b\n⋯\nd")));
        let write = describe(&json!({"tool_name":"Write","tool_input":{"file_path":"/n.txt","content":"hi"}}), claude);
        assert_eq!((write["old"].as_str(), write["new"].as_str()), (Some(""), Some("hi")));
        let argv = describe(&json!({"tool_name":"shell","tool_input":{"command":["git","push"]}}), Some(Agent::Codex));
        assert_eq!(argv["detail"], "git push");
        assert!(argv.get("old").is_none());
        assert_eq!(argv["kind"], "run", "another CLI's name for the same kind of tool");
        let unknown = describe(&json!({"tool_name":"Edit","tool_input":{"file_path":"/a"}}), None);
        assert_eq!((unknown["kind"].as_str(), unknown.get("old")), (Some("other"), None), "a CLI the app does not know");
    }

    #[test]
    fn a_request_too_long_to_show_says_so() {
        let long = "x".repeat(MAX_DETAIL + 1);
        let bash = describe(&json!({"tool_name":"Bash","tool_input":{"command":long}}), Some(Agent::Claude));
        assert_eq!((bash["truncated"].as_bool(), bash["detail"].as_str().map(str::len)), (Some(true), Some(MAX_DETAIL)));
        let write = describe(&json!({"tool_name":"Write","tool_input":{"file_path":"/a","content":long}}), Some(Agent::Claude));
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

    #[tokio::test]
    async fn an_abandoned_offer_is_removed_and_reported() {
        let permissions = Permissions::new();
        let (events, mut heard) = broadcast::channel(4);
        let (sender, receiver) = oneshot::channel();
        permissions.offer("abandoned", sender);
        drop(Offer {
            id: "abandoned".into(),
            run_id: "run".into(),
            permissions: permissions.clone(),
            events,
            outcome: "cancelled",
        });
        assert!(!permissions.answer("abandoned", Answer::Allow).await, "nothing is waiting");
        assert!(receiver.await.is_err(), "the hook's side was dropped with the offer");
        let done = heard.try_recv().unwrap();
        assert_eq!((done["type"].as_str(), done["outcome"].as_str()), (Some("agent-permission-done"), Some("cancelled")));
    }

    #[tokio::test]
    async fn an_answer_reaches_the_hook_that_is_waiting_once() {
        let permissions = Permissions::new();
        let (sender, receiver) = oneshot::channel();
        permissions.offer("asked", sender);
        assert!(permissions.answer("asked", Answer::Deny).await);
        assert_eq!(receiver.await.unwrap(), Answer::Deny);
        assert!(!permissions.answer("asked", Answer::Allow).await, "taken already");
        let (sender, receiver) = oneshot::channel();
        permissions.offer("gone", sender);
        drop(receiver);
        assert!(!permissions.answer("gone", Answer::Allow).await, "the hook stopped waiting");
    }
}
