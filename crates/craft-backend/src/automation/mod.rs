//! Automation pipelines: a trigger, then filters and actions, across every project.
//!
//! Events come from the sync loops that already run — the poller's PR sync (`observe_prs`),
//! merge detection by poll or webhook (`merged`), and each pipeline's own JQL (`poll_jira`).
//! Nothing here adds a `gh` call to a request handler except dry runs, which plan against a
//! sample on demand.

pub mod actions;
pub mod catalog;
pub mod context;
pub mod filters;
mod migrate;
pub mod model;
pub mod routes;
pub mod runner;
pub mod store;
pub mod triggers;

use std::collections::HashSet;

use chrono::{DateTime, Duration, Utc};
use serde_json::Value;

use model::{Automation, Event, Mode, RunMode};
pub use triggers::{observe_prs, poll_jira};

use crate::AppState;

pub const PAUSED: &str = "automation_paused";
pub const FORWARD_WEBHOOKS: &str = "automation_forward_webhooks";

/// Once at startup, before the first sync: carry the old per-project merge settings over.
pub fn start(app: &AppState) {
    migrate::run(app);
}

pub fn paused(app: &AppState) -> bool {
    app.db.config_value(PAUSED).ok().flatten().as_deref() == Some("true")
}

pub fn forwarding(app: &AppState) -> bool {
    app.db.config_value(FORWARD_WEBHOOKS).ok().flatten().as_deref() != Some("false")
}

/// The pipelines that react to events right now: none while paused.
pub fn armed(app: &AppState) -> Vec<Automation> {
    if paused(app) {
        return Vec::new();
    }
    let mut automations = store::list(&app.db).unwrap_or_default();
    automations.retain(|a| a.mode != Mode::Off);
    automations
}

/// Offer an event to every armed pipeline.
pub fn emit(app: &AppState, event: Event) {
    offer(app, &armed(app), event);
}

/// Offer an event to pipelines already loaded with `armed`.
pub fn offer(app: &AppState, armed: &[Automation], event: Event) {
    for automation in armed {
        fire(app, automation, event.clone());
    }
}

/// A merged PR, from the poll loop or the webhook, whichever reports it first.
pub fn merged(app: &AppState, project: &Value, pr: &Value) {
    emit(app, triggers::merge_event(app, project, pr));
}

/// Run `automation` for `event` if it matches and has not already fired for it.
pub fn fire(app: &AppState, automation: &Automation, event: Event) {
    if automation.mode == Mode::Off || !trigger_check(automation, &event).0 || paused(app) {
        return;
    }
    if !armed_for(automation, &event) {
        return;
    }
    if !store::claim(&app.db, &automation.id, &event.key).unwrap_or(false) {
        return;
    }
    let mode = if automation.mode == Mode::Live { RunMode::Live } else { RunMode::Shadow };
    let (app, automation) = (app.clone(), automation.clone());
    tokio::spawn(async move {
        runner::run_and_record(&app, &automation, &event, mode).await;
    });
}

/// Whether the event is one this pipeline listens for, in a project it covers.
pub fn trigger_check(automation: &Automation, event: &Event) -> (bool, String) {
    let trigger = &automation.trigger;
    if !trigger.types.iter().any(|t| *t == event.kind) {
        return (
            false,
            format!("{} is not one of this pipeline's triggers", catalog::label("triggers", &event.kind)),
        );
    }
    // Jira triggers are scoped by their JQL; the project list scopes PR events.
    if event.pr.is_some() && !trigger.projects.is_empty() {
        let id = event.project["id"].as_str().unwrap_or("");
        if !trigger.projects.iter().any(|p| p == id) {
            return (false, format!("{} is not in this pipeline's projects", event.project["name"].as_str().unwrap_or(id)));
        }
    }
    if event.kind == "pr.stale" {
        let Some(updated) = stale_since(event) else {
            return (false, "the PR has no update time".into());
        };
        let days = stale_days(automation);
        if Utc::now() - updated < Duration::days(days) {
            return (false, format!("last updated {} — not yet {days} days", updated.format("%Y-%m-%d")));
        }
    }
    (true, format!("{} on {}", catalog::label("triggers", &event.kind), event.subject()))
}

fn stale_days(automation: &Automation) -> i64 {
    match automation.trigger.params.get("days") {
        Some(Value::Number(n)) => n.as_i64(),
        Some(Value::String(s)) => s.trim().parse().ok(),
        _ => None,
    }
    .unwrap_or(7)
    .max(1)
}

fn stale_since(event: &Event) -> Option<DateTime<Utc>> {
    let raw = event.pr.as_ref()?["updatedAt"].as_str()?;
    DateTime::parse_from_rfc3339(raw).ok().map(|v| v.with_timezone(&Utc))
}

/// Events from before the pipeline was switched on never fire it. For a stale PR the moment
/// that counts is when it became stale, not when this sync noticed.
fn armed_for(automation: &Automation, event: &Event) -> bool {
    let Some(armed) = automation
        .armed_at
        .as_deref()
        .and_then(|v| DateTime::parse_from_rfc3339(v).ok())
        .map(|v| v.with_timezone(&Utc))
    else {
        return true;
    };
    let at = if event.kind == "pr.stale" {
        match stale_since(event) {
            Some(updated) => updated + Duration::days(stale_days(automation)),
            None => return false,
        }
    } else {
        event.at
    };
    at >= armed
}

/// Repos whose webhooks are worth forwarding: those an armed PR pipeline covers.
pub fn forward_repos(app: &AppState) -> HashSet<String> {
    if !forwarding(app) {
        return HashSet::new();
    }
    let projects = app.db.projects().unwrap_or_default();
    let mut repos = HashSet::new();
    for automation in store::list(&app.db).unwrap_or_default() {
        if automation.mode == Mode::Off || !automation.trigger.types.iter().any(|t| t.starts_with("pr.")) {
            continue;
        }
        for project in &projects {
            let id = project["id"].as_str().unwrap_or("");
            let covered = automation.trigger.projects.is_empty() || automation.trigger.projects.iter().any(|p| p == id);
            if let Some(repo) = project["repo"].as_str().filter(|r| covered && !r.is_empty()) {
                repos.insert(repo.to_owned());
            }
        }
    }
    repos
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn automation(types: &[&str], projects: &[&str]) -> Automation {
        Automation {
            id: "a".into(),
            mode: Mode::Live,
            trigger: model::Trigger {
                types: types.iter().map(|t| t.to_string()).collect(),
                projects: projects.iter().map(|p| p.to_string()).collect(),
                params: Default::default(),
            },
            ..Default::default()
        }
    }

    fn event(kind: &str, project: &str, at: DateTime<Utc>, pr: Value) -> Event {
        Event { kind: kind.into(), key: "k".into(), at, project: json!({"id":project,"repo":"a/b"}), pr: Some(pr), ticket: None }
    }

    #[test]
    fn triggers_match_on_kind_and_project_scope() {
        let now = Utc::now();
        let pipeline = automation(&["pr.opened"], &["p1"]);
        assert!(trigger_check(&pipeline, &event("pr.opened", "p1", now, json!({"number":1}))).0);
        assert!(!trigger_check(&pipeline, &event("pr.opened", "p2", now, json!({"number":1}))).0);
        assert!(!trigger_check(&pipeline, &event("pr.merged", "p1", now, json!({"number":1}))).0);
        assert!(trigger_check(&automation(&["pr.opened"], &[]), &event("pr.opened", "p2", now, json!({"number":1}))).0);
    }

    #[test]
    fn events_before_arming_never_fire() {
        let now = Utc::now();
        let mut pipeline = automation(&["pr.merged"], &[]);
        pipeline.armed_at = Some(now.to_rfc3339());
        assert!(!armed_for(&pipeline, &event("pr.merged", "p", now - Duration::hours(1), json!({}))));
        assert!(armed_for(&pipeline, &event("pr.merged", "p", now + Duration::seconds(1), json!({}))));
    }

    #[test]
    fn stale_fires_only_after_the_threshold_and_only_if_it_was_crossed_after_arming() {
        let now = Utc::now();
        let mut pipeline = automation(&["pr.stale"], &[]);
        pipeline.trigger.params.insert("days".into(), json!(3));
        pipeline.armed_at = Some((now - Duration::days(1)).to_rfc3339());
        let pr = |days_ago: i64| json!({"number":1,"updatedAt":(now - Duration::days(days_ago)).to_rfc3339()});
        // Quiet for two days: not stale yet.
        assert!(!trigger_check(&pipeline, &event("pr.stale", "p", now, pr(2))).0);
        // Quiet for three and a half days: crossed the threshold after arming.
        let fresh = event("pr.stale", "p", now, json!({"number":1,"updatedAt":(now - Duration::hours(84)).to_rfc3339()}));
        assert!(trigger_check(&pipeline, &fresh).0 && armed_for(&pipeline, &fresh));
        // Quiet for ten days: it was already stale before the pipeline was switched on.
        let old = event("pr.stale", "p", now, pr(10));
        assert!(trigger_check(&pipeline, &old).0 && !armed_for(&pipeline, &old));
    }
}
