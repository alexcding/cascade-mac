use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A tracked project: one GitHub repository, an optional Jira project, a workspace on disk and
/// the settings the app edits. Serializes to the JSON `GET /api/projects` has always answered
/// with; `created_at` keeps its old spelling. Every field has a default, so a partial record
/// (a test fixture, an older row) still reads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub repo: String,
    pub workspace: String,
    pub jira_project_key: String,
    pub merge_transition: String,
    pub forward_webhooks: bool,
    #[serde(rename = "created_at")]
    pub created_at: String,
    pub fix_version_enabled: bool,
    pub fix_version_script: String,
    pub ide: String,
    pub ide_cmd: String,
    pub ide_target: String,
    pub run_scheme: String,
    pub run_sim: String,
    pub worktree_setup: String,
    pub worktree_include: String,
    pub issues_enabled: bool,
    pub board_enabled: bool,
}

impl Default for Project {
    /// What a row has before anything is set: webhooks forwarded and issues listed, as the
    /// schema's column defaults say.
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            repo: String::new(),
            workspace: String::new(),
            jira_project_key: String::new(),
            merge_transition: String::new(),
            forward_webhooks: true,
            created_at: String::new(),
            fix_version_enabled: false,
            fix_version_script: String::new(),
            ide: String::new(),
            ide_cmd: String::new(),
            ide_target: String::new(),
            run_scheme: String::new(),
            run_sim: String::new(),
            worktree_setup: String::new(),
            worktree_include: String::new(),
            issues_enabled: true,
            board_enabled: false,
        }
    }
}

impl Project {
    /// The JSON the app reads, for the places that still hand a project on as a `Value`.
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).expect("a project serializes")
    }
}

impl From<Project> for Value {
    fn from(project: Project) -> Value {
        project.to_value()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_project_serializes_to_the_json_the_app_reads() {
        let project = Project {
            id: "p1".into(),
            name: "App".into(),
            repo: "o/r".into(),
            workspace: "/w".into(),
            jira_project_key: "APP".into(),
            forward_webhooks: true,
            created_at: "2026-01-01T00:00:00Z".into(),
            issues_enabled: true,
            ..Project::default()
        };
        let value = project.to_value();
        assert_eq!(value["jiraProjectKey"], "APP");
        assert_eq!(value["created_at"], "2026-01-01T00:00:00Z");
        assert_eq!(value["forwardWebhooks"], true);
        assert_eq!(value["boardEnabled"], false);
        assert_eq!(value["fixVersionScript"], "");
        assert_eq!(value.as_object().unwrap().len(), 19, "every column the row has");
        let back: Project = serde_json::from_value(value).unwrap();
        assert_eq!(back, project);
    }

    #[test]
    fn a_partial_record_reads_with_defaults() {
        let project: Project = serde_json::from_value(json!({"id":"p","repo":"a/b"})).unwrap();
        assert_eq!(project.repo, "a/b");
        assert!(project.name.is_empty() && !project.board_enabled);
        assert!(project.issues_enabled && project.forward_webhooks, "the schema's defaults");
    }
}
