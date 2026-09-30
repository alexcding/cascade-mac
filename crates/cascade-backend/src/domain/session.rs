use serde::{Deserialize, Serialize};

/// A session: one task record per worktree, the agent running on that worktree and the page it
/// was started from. Serializes to the JSON `GET /api/tasks` has always answered with. Every
/// field has a default, so the app's own partial records and older rows still read.
///
/// `name`, `run_scheme`, `run_sim`, `fork_from` and `forked_from` are set through a patch, never
/// an upsert: the app re-saves the whole record on other changes, and that must not drop a name
/// it never knew.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Session {
    pub id: String,
    pub project_id: String,
    pub workspace: String,
    pub worktree: String,
    pub branch: String,
    pub title: String,
    pub kind: String,
    pub url: String,
    pub jira_key: String,
    pub cli: String,
    /// The agent's own conversation ID, once it has one.
    pub session_id: String,
    pub created_at: String,
    pub pinned: bool,
    pub run_scheme: String,
    pub run_sim: String,
    pub name: String,
    pub fork_from: String,
    pub forked_from: String,
}

impl Session {
    /// Whether the record names what every session must: itself, its project and where it runs.
    pub fn is_complete(&self) -> bool {
        !self.id.is_empty()
            && !self.project_id.is_empty()
            && !self.workspace.is_empty()
            && !self.worktree.is_empty()
    }

    /// What the sidebar shows a session as, as the app's `WorkspaceSession.label` works it out:
    /// the name it was given, else its worktree folder, else its title, else its ID.
    pub fn label(&self) -> String {
        let name = self.name.trim();
        if !name.is_empty() {
            return name.to_owned();
        }
        let folder = folder(self.worktree.trim());
        if !folder.is_empty() {
            return folder.to_owned();
        }
        let title = self.title.trim();
        if title.is_empty() {
            self.id.trim().to_owned()
        } else {
            title.to_owned()
        }
    }

}

/// The last component of a path.
pub fn folder(path: &str) -> &str {
    path.trim_end_matches('/').rsplit('/').next().unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_session_serializes_to_the_json_the_app_reads() {
        let session = Session {
            id: "t".into(),
            project_id: "p".into(),
            workspace: "/w".into(),
            worktree: "/w/.worktrees/t".into(),
            branch: "fix".into(),
            title: "Page".into(),
            kind: "pr".into(),
            url: "https://github.com/o/r/pull/1".into(),
            jira_key: "ABC-1".into(),
            cli: "claude".into(),
            session_id: "conv".into(),
            created_at: "2026-01-01T00:00:00Z".into(),
            pinned: true,
            run_scheme: "App".into(),
            run_sim: "iPhone".into(),
            name: "Mine".into(),
            fork_from: "".into(),
            forked_from: "s".into(),
        };
        let value = serde_json::to_value(&session).unwrap();
        assert_eq!(
            value,
            json!({
                "id": "t", "projectId": "p", "workspace": "/w", "worktree": "/w/.worktrees/t",
                "branch": "fix", "title": "Page", "kind": "pr", "url": "https://github.com/o/r/pull/1",
                "jiraKey": "ABC-1", "cli": "claude", "sessionId": "conv",
                "createdAt": "2026-01-01T00:00:00Z", "pinned": true,
                "runScheme": "App", "runSim": "iPhone", "name": "Mine", "forkFrom": "",
                "forkedFrom": "s",
            })
        );
        assert_eq!(value.as_object().unwrap().len(), 18);
    }

    #[test]
    fn a_partial_record_reads_with_defaults() {
        let session: Session =
            serde_json::from_value(json!({"id": "t", "projectId": "p", "workspace": "/w", "worktree": "/w/t"}))
                .unwrap();
        assert!(session.is_complete());
        assert_eq!(session.created_at, "");
        assert!(!session.pinned);
        assert_eq!(session.name, "");
        let short: Session = serde_json::from_value(json!({"id": "t", "projectId": "p"})).unwrap();
        assert!(!short.is_complete());
    }

    #[test]
    fn a_session_is_labelled_as_the_sidebar_shows_it() {
        let session = |name: &str, worktree: &str, title: &str| Session {
            id: "x".into(),
            name: name.into(),
            worktree: worktree.into(),
            title: title.into(),
            ..Session::default()
        };
        assert_eq!(session(" Mine ", "/r/fix", "").label(), "Mine");
        assert_eq!(session("", "/r/.worktrees/fix-login", "").label(), "fix-login");
        assert_eq!(session("", "/r/.worktrees/fix-login/", "").label(), "fix-login");
        assert_eq!(session("", "", "T").label(), "T");
        assert_eq!(session("", "", "").label(), "x");
    }
}
