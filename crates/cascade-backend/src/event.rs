//! What the backend tells the app, typed. The app decodes each one as `ServerEvent` by its
//! `type`, so the variant names (kebab-case) and field names (camelCase) here are that contract.
//! `AppState::publish` sends one; the one untyped path left is an agent hook relayed as it came.

use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum Event {
    /// A snapshot changed. `scope` says which (`prs`, `usage`); none is a project edit, which
    /// the app answers with a full refresh.
    Sync {
        #[serde(skip_serializing_if = "Option::is_none")]
        scope: Option<&'static str>,
        #[serde(rename = "projectId", skip_serializing_if = "Option::is_none")]
        project_id: Option<String>,
    },
    /// A board's Jira snapshot changed; `id` is `board:<project>`.
    JiraSync { id: String },
    /// The session records changed.
    Tasks,
    /// The backend's config changed.
    Config,
    /// A review was acknowledged.
    Reviews,
    /// Events were missed on the way to this subscriber; it should refetch everything.
    Reload,
    /// A line of activity, as `GET /api/events` lists it.
    Activity { event: Value },
    /// An automation, or the automations' settings or runs, changed.
    Automations {
        #[serde(skip_serializing_if = "Option::is_none")]
        scope: Option<&'static str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    /// A new worktree's setup command started, finished or failed.
    WorktreeSetup {
        worktree: String,
        state: &'static str,
        #[serde(skip_serializing_if = "String::is_empty")]
        error: String,
    },
    /// An IDE warm-up moved; the same fields the warm-up endpoint answers with.
    IdeWarmup {
        worktree: String,
        status: String,
        label: String,
        message: String,
    },
    /// A terminal's `BROWSER` asked for a web address to open.
    TerminalOpenUrl {
        #[serde(rename = "runId")]
        run_id: String,
        url: String,
    },
    /// An agent is waiting on a tool approval.
    AgentPermission {
        id: String,
        #[serde(rename = "runId")]
        run_id: String,
        request: Value,
        cli: String,
    },
    /// The approval was answered, left to the CLI's own prompt, or is no longer waited on.
    AgentPermissionDone {
        id: String,
        #[serde(rename = "runId")]
        run_id: String,
        outcome: &'static str,
    },
}

impl Event {
    /// What a subscriber that fell behind is told in place of the events it missed: refetch
    /// everything. Both transports, the embedded callback and SSE, answer a lag with this, once.
    pub fn lagged() -> String {
        serde_json::to_string(&Event::Reload).expect("an event serializes")
    }
}

impl From<Event> for Value {
    fn from(event: Event) -> Value {
        serde_json::to_value(event).expect("an event serializes")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_serialize_to_the_shapes_the_app_decodes() {
        let sync: Value = Event::Sync {
            scope: Some("prs"),
            project_id: Some("p1".into()),
        }
        .into();
        assert_eq!(sync, json!({"type":"sync","scope":"prs","projectId":"p1"}));
        let edit: Value = Event::Sync {
            scope: None,
            project_id: None,
        }
        .into();
        assert_eq!(edit, json!({"type":"sync"}));
        assert_eq!(Value::from(Event::Tasks), json!({"type":"tasks"}));
        assert_eq!(Value::from(Event::Reload), json!({"type":"reload"}));
        assert_eq!(
            Value::from(Event::JiraSync {
                id: "board:p1".into()
            }),
            json!({"type":"jira-sync","id":"board:p1"})
        );
        assert_eq!(
            Value::from(Event::Automations {
                scope: Some("runs"),
                id: Some("a".into())
            }),
            json!({"type":"automations","scope":"runs","id":"a"})
        );
        assert_eq!(
            Value::from(Event::WorktreeSetup {
                worktree: "/w".into(),
                state: "running",
                error: String::new()
            }),
            json!({"type":"worktree-setup","worktree":"/w","state":"running"})
        );
        assert_eq!(
            Value::from(Event::TerminalOpenUrl {
                run_id: "r".into(),
                url: "https://x".into()
            }),
            json!({"type":"terminal-open-url","runId":"r","url":"https://x"})
        );
        assert_eq!(
            Value::from(Event::AgentPermissionDone {
                id: "i".into(),
                run_id: "r".into(),
                outcome: "answered"
            }),
            json!({"type":"agent-permission-done","id":"i","runId":"r","outcome":"answered"})
        );
        assert_eq!(Value::from(Event::Config), json!({"type":"config"}));
        assert_eq!(Value::from(Event::Reviews), json!({"type":"reviews"}));
        assert_eq!(
            Value::from(Event::Activity {
                event: json!({"type":"pr_merged"})
            }),
            json!({"type":"activity","event":{"type":"pr_merged"}})
        );
        assert_eq!(
            Value::from(Event::IdeWarmup {
                worktree: "/w".into(),
                status: "running".into(),
                label: "Resolving packages".into(),
                message: String::new()
            }),
            json!({"type":"ide-warmup","worktree":"/w","status":"running","label":"Resolving packages","message":""})
        );
        assert_eq!(
            Value::from(Event::AgentPermission {
                id: "i".into(),
                run_id: "r".into(),
                request: json!({"tool":"Bash"}),
                cli: "claude".into()
            }),
            json!({"type":"agent-permission","id":"i","runId":"r","request":{"tool":"Bash"},"cli":"claude"})
        );
    }
}
