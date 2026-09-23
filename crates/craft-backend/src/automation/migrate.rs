//! Before pipelines, each project carried its own merge automation: a Fix Version template and a
//! Jira transition. They become one live pipeline per project, once, so nothing a user had set up
//! stops working. The old columns stay in `projects` (no migration framework) but are not read.

use serde_json::{json, Map, Value};

use super::{
    model::{Automation, Mode, Step, StepKind, Trigger},
    store,
};
use crate::AppState;

const DONE: &str = "automations_migrated";

fn step(id: &str, kind: StepKind, node: &str, params: Value) -> Step {
    Step {
        id: id.into(),
        kind,
        node: node.into(),
        params: params.as_object().cloned().unwrap_or_else(Map::new),
        continue_on_error: false,
    }
}

/// The pipeline equivalent of one project's legacy settings, if it had any.
pub fn legacy_pipeline(project: &Value) -> Option<Automation> {
    let transition = project["mergeTransition"].as_str().unwrap_or("").trim();
    let key = project["jiraProjectKey"].as_str().unwrap_or("").trim();
    let fix_version = project["fixVersionEnabled"] == true && !key.is_empty();
    if transition.is_empty() && !fix_version {
        return None;
    }
    // No Jira-project filter: keys from the title and body are already scoped to the project's
    // key, and the old flow also moved tickets linked by hand from any Jira project.
    let mut steps = vec![step("s1", StepKind::Filter, "jira.has_key", json!({}))];
    if fix_version {
        // The old flow logged a failed Fix Version and still transitioned.
        let mut version = step(
            "s3",
            StepKind::Action,
            "jira.fix_version",
            json!({"source":"template","template":project["fixVersionScript"].as_str().unwrap_or("")}),
        );
        version.continue_on_error = true;
        steps.push(version);
    }
    if !transition.is_empty() {
        steps.push(step("s4", StepKind::Action, "jira.transition", json!({"status":transition})));
    }
    Some(Automation {
        // Stable, so a migration interrupted part-way and run again updates rather than duplicates.
        id: format!("legacy-{}", project["id"].as_str().unwrap_or("")),
        name: format!("On merge → Jira ({})", project["name"].as_str().unwrap_or("project")),
        mode: Mode::Live,
        trigger: Trigger {
            types: vec!["pr.merged".into()],
            projects: vec![project["id"].as_str().unwrap_or("").to_owned()],
            params: Map::new(),
        },
        steps,
        ..Default::default()
    })
}

pub fn run(app: &AppState) {
    if app.db.config_value(DONE).ok().flatten().is_some() {
        return;
    }
    let projects = app.db.projects().unwrap_or_default();
    let mut complete = true;
    for project in &projects {
        let Some(automation) = legacy_pipeline(project) else { continue };
        // Migrated by an earlier, interrupted run: it may have been edited since, so leave it be.
        if store::get(&app.db, &automation.id).ok().flatten().is_some() {
            continue;
        }
        if let Err(error) = store::save(&app.db, automation) {
            tracing::warn!(%error, "could not migrate a project's merge automation");
            complete = false;
        }
    }
    // Retried on the next start for the projects that failed.
    if !complete {
        return;
    }
    // Webhook forwarding is left unset, so it takes its default (on) rather than each project's old
    // opt-in: it only runs for repos a pipeline covers, and polling covers any it cannot forward.
    let mut values = Map::new();
    values.insert(DONE.into(), json!("1"));
    let _ = app.db.set_config(&values);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_settings_become_a_merge_pipeline() {
        let project = json!({"id":"p1","name":"Craft","jiraProjectKey":"CRAFT","mergeTransition":"Done","fixVersionEnabled":true,"fixVersionScript":"{year}.{isoWeek}"});
        let pipeline = legacy_pipeline(&project).unwrap();
        assert_eq!(pipeline.mode, Mode::Live);
        assert_eq!(pipeline.trigger.types, vec!["pr.merged"]);
        assert_eq!(pipeline.trigger.projects, vec!["p1"]);
        let nodes: Vec<&str> = pipeline.steps.iter().map(|s| s.node.as_str()).collect();
        // Like the old flow: linked keys from any Jira project, and a failed Fix Version is
        // logged without holding back the transition.
        assert_eq!(nodes, vec!["jira.has_key", "jira.fix_version", "jira.transition"]);
        assert_eq!(pipeline.steps[1].params["template"], "{year}.{isoWeek}");
        assert!(pipeline.steps[1].continue_on_error);
        assert_eq!(pipeline.steps[2].params["status"], "Done");
        assert_eq!(pipeline.id, "legacy-p1");
    }

    #[test]
    fn an_interrupted_migration_run_again_does_not_duplicate() {
        let directory = tempfile::tempdir().unwrap();
        let db = crate::Database::open(directory.path()).unwrap();
        let project = json!({"id":"p1","name":"Craft","jiraProjectKey":"CRAFT","mergeTransition":"Done"});
        store::save(&db, legacy_pipeline(&project).unwrap()).unwrap();
        store::save(&db, legacy_pipeline(&project).unwrap()).unwrap();
        assert_eq!(store::list(&db).unwrap().len(), 1);
    }

    #[test]
    fn a_retried_migration_leaves_a_pipeline_it_already_made() {
        let directory = tempfile::tempdir().unwrap();
        let db = crate::Database::open(directory.path()).unwrap();
        let project = db
            .add_project(json!({"name":"Craft","repo":"a/b","jiraProjectKey":"CRAFT","mergeTransition":"Done"}).as_object().unwrap())
            .unwrap();
        // An earlier run migrated it and stopped short; since then it was switched off.
        let mut edited = legacy_pipeline(&project).unwrap();
        edited.mode = Mode::Off;
        store::save(&db, edited).unwrap();
        let app = AppState::new(db, None);
        run(&app);
        let pipelines = store::list(&app.db).unwrap();
        assert_eq!(pipelines.len(), 1);
        assert_eq!(pipelines[0].mode, Mode::Off);
        assert!(app.db.config_value(DONE).unwrap().is_some());
    }

    #[test]
    fn projects_without_merge_settings_migrate_nothing() {
        assert!(legacy_pipeline(&json!({"id":"p","mergeTransition":"","fixVersionEnabled":false})).is_none());
        // Fix Version without a Jira project key never ran, so it does not migrate either.
        assert!(legacy_pipeline(&json!({"id":"p","fixVersionEnabled":true})).is_none());
    }

    #[test]
    fn migration_runs_once_and_leaves_forwarding_on() {
        let directory = tempfile::tempdir().unwrap();
        let db = crate::Database::open(directory.path()).unwrap();
        db.add_project(json!({"name":"Craft","repo":"a/b","jiraProjectKey":"CRAFT","mergeTransition":"Done","forwardWebhooks":false}).as_object().unwrap()).unwrap();
        let app = AppState::new(db, None);
        run(&app);
        run(&app);
        let pipelines = store::list(&app.db).unwrap();
        assert_eq!(pipelines.len(), 1);
        assert!(pipelines[0].armed_at.is_some());
        // A project that had forwarding off does not turn it off for every pipeline.
        assert_eq!(app.db.config_value(super::super::FORWARD_WEBHOOKS).unwrap(), None);
        assert!(super::super::forwarding(&app));
    }
}
