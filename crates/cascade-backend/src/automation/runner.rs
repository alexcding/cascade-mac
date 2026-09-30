//! Running a pipeline against one event, as a dry run or for real.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::Utc;
use serde_json::json;

use super::{
    actions, catalog,
    context::Ctx,
    filters,
    model::{Automation, Event, RunMode, StepKind, StepResult, Trace},
    store,
};
use crate::AppState;

/// Live runs per pipeline per hour before it is held back. A pipeline that loops (it comments,
/// which updates the PR, which triggers it again) stops here instead of flooding a repo.
pub const RATE_LIMIT: i64 = 30;

/// What this process knows of live runs that the ledger does not yet: the runs started in the
/// last hour per pipeline (the recorded count alone races, as one sync can spawn many runs before
/// any of them is recorded) and when each pipeline last told Activity it was held back.
/// `AppState.limits` holds the one instance; its lock is short and never held across an await.
#[derive(Default)]
pub struct Limits {
    state: Mutex<LimitState>,
}

#[derive(Default)]
struct LimitState {
    live: HashMap<String, Vec<Instant>>,
    warned: HashMap<String, Instant>,
}

impl Limits {
    /// Whether to tell Activity the pipeline is held back: once an hour is enough to be seen, and
    /// a released event offered again on every poll would otherwise say it every time.
    pub fn warn_limited(&self, automation: &str) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.warned.get(automation).is_some_and(|at| at.elapsed() < Duration::from_secs(3600)) {
            return false;
        }
        state.warned.insert(automation.to_owned(), Instant::now());
        true
    }

    /// Reserve a live run for `automation`, or refuse because it is over the hourly limit.
    pub fn reserve(&self, automation: &str, recorded: i64) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let runs = state.live.entry(automation.to_owned()).or_default();
        let hour = Duration::from_secs(3600);
        runs.retain(|at| at.elapsed() < hour);
        if recorded.max(runs.len() as i64) >= RATE_LIMIT {
            return false;
        }
        runs.push(Instant::now());
        true
    }
}

fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub async fn run(app: &AppState, automation: &Automation, event: &Event, mode: RunMode) -> Trace {
    let started_at = now();
    let (trigger_matched, trigger_detail) = super::trigger_check(automation, event);
    let mut trace = Trace {
        automation_id: automation.id.clone(),
        automation_name: automation.name.clone(),
        event_kind: event.kind.clone(),
        event_key: event.key.clone(),
        subject: event.subject(),
        mode: mode.as_str().into(),
        trigger_matched,
        trigger_detail,
        status: "completed".into(),
        steps: Vec::new(),
        started_at,
        finished_at: String::new(),
    };
    let mut ctx = Ctx::new(app, event).await;
    let mut stopped = false;
    let mut touched_jira = false;
    // The hourly limit counts runs that act, reserved at the first action that does something: a
    // run its filters stop, or whose actions all skip, has changed nothing and is not held back.
    let mut reserved = false;
    for step in &automation.steps {
        let section = if step.kind == StepKind::Filter { "filters" } else { "actions" };
        let mut result = StepResult {
            step_id: step.id.clone(),
            node: step.node.clone(),
            label: catalog::label(section, &step.node),
            status: String::new(),
            detail: String::new(),
            commands: Vec::new(),
        };
        if stopped {
            result.status = "skipped".into();
            trace.steps.push(result);
            continue;
        }
        match step.kind {
            StepKind::Filter => match filters::eval(step, &mut ctx).await {
                Ok(outcome) => {
                    result.status = if outcome.passed { "passed" } else { "failed" }.into();
                    result.detail = outcome.detail;
                    if !outcome.passed {
                        stopped = true;
                        trace.status = "filtered".into();
                    }
                }
                Err(error) => {
                    result.status = "error".into();
                    result.detail = error.to_string();
                    stopped = true;
                    trace.status = "error".into();
                }
            },
            StepKind::Action => match actions::plan(step, &ctx).await {
                Ok(plans) => {
                    result.commands = plans.iter().map(|p| p.describe()).collect();
                    let all_skip = plans.iter().all(|p| p.is_skip());
                    if all_skip {
                        result.status = "skipped".into();
                        result.detail = result.commands.join("; ");
                        result.commands.clear();
                    } else if mode != RunMode::Live {
                        result.status = "planned".into();
                    } else if !reserved
                        && !app.limits.reserve(&automation.id, store::recent_live_runs(&app.db, &automation.id).await.unwrap_or(0))
                    {
                        result.status = "limited".into();
                        result.detail = format!("Held back: over {RATE_LIMIT} live runs in the last hour");
                        stopped = true;
                        trace.status = "limited".into();
                    } else {
                        reserved = true;
                        // Each plan is one PR or ticket: one that fails does not hold back the rest.
                        let mut outputs = Vec::new();
                        let mut failures = Vec::new();
                        for plan in plans.iter().filter(|p| !p.is_skip()) {
                            match plan.execute(app, &format!("automation \"{}\"", automation.name)).await {
                                Ok(out) => outputs.push(out),
                                Err(error) => failures.push(error.to_string()),
                            }
                        }
                        touched_jira |= step.node.starts_with("jira.") && !outputs.is_empty();
                        if !failures.is_empty() {
                            result.status = "error".into();
                            outputs.retain(|o| !o.is_empty());
                            outputs.extend(failures);
                            result.detail = outputs.join("\n");
                            stopped = !step.continue_on_error;
                            trace.status = "error".into();
                        } else {
                            result.status = "done".into();
                            result.detail = outputs.into_iter().filter(|o| !o.is_empty()).collect::<Vec<_>>().join("\n");
                        }
                    }
                }
                Err(error) => {
                    result.status = "error".into();
                    result.detail = error.to_string();
                    stopped = !step.continue_on_error;
                    trace.status = "error".into();
                }
            },
        }
        trace.steps.push(result);
    }
    trace.finished_at = now();
    if touched_jira {
        // A Jira action moved tickets the project's board shows: refresh it.
        if let Some(project) = event.project.clone() {
            let app = app.clone();
            tokio::spawn(async move { app.poller.sync_board(&app, &project).await });
        }
    }
    trace
}

/// Run and record: the path for automatic and manual runs (dry runs are never recorded).
pub async fn run_and_record(app: &AppState, automation: &Automation, event: &Event, mode: RunMode) -> Trace {
    let trace = run(app, automation, event, mode).await;
    let _ = store::record_run(&app.db, &trace).await;
    // Held back, the event has not had its run: its claim is let go so a later offer can fire it.
    if trace.status == "limited" {
        let _ = store::release(&app.db, &automation.id, &trace.event_key).await;
    }
    // A filtered run is the common case (most PRs are not from the trusted author); only runs
    // that did or planned something reach Activity, and a held-back one once an hour.
    if trace.status != "filtered" && (trace.status != "limited" || app.limits.warn_limited(&automation.id)) {
        let kind = match trace.status.as_str() {
            "error" => "automation_failed",
            "limited" => "automation_limited",
            _ => "automation_run",
        };
        if let Ok(event) = app.db.add_event(
            kind,
            &json!({"automation":automation.name,"subject":trace.subject,"mode":trace.mode,"status":trace.status}),
        ).await {
            app.publish(crate::Event::Activity { event });
        }
    }
    app.publish(crate::Event::Automations { scope: Some("runs"), id: Some(automation.id.to_string()) });
    trace
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_catalog_node_has_an_implementation() {
        for item in catalog::catalog()["filters"].as_array().unwrap() {
            assert!(filters::known(item["type"].as_str().unwrap()), "filter {} has no evaluator", item["type"]);
        }
        for item in catalog::catalog()["actions"].as_array().unwrap() {
            assert!(actions::known(item["type"].as_str().unwrap()), "action {} has no planner", item["type"]);
        }
    }

    #[test]
    fn a_held_back_pipeline_tells_activity_once_an_hour() {
        let limits = Limits::default();
        assert!(limits.warn_limited("warn-test"));
        assert!(!limits.warn_limited("warn-test"));
        assert!(limits.warn_limited("warn-other"));
    }

    #[test]
    fn the_live_limit_holds_runs_that_start_together() {
        let limits = Limits::default();
        let id = "rate-limit-test";
        assert_eq!((0..RATE_LIMIT + 5).filter(|_| limits.reserve(id, 0)).count() as i64, RATE_LIMIT);
        assert!(!limits.reserve("recorded-test", RATE_LIMIT), "the recorded count still applies after a restart");
    }

    #[tokio::test]
    async fn the_ledger_lets_one_event_fire_a_pipeline_once() {
        let directory = tempfile::tempdir().unwrap();
        let db = crate::Database::open(directory.path()).unwrap();
        assert!(store::claim(&db, "a", "pr.merged:a/b#1").await.unwrap());
        // The webhook reports the merge the poll already fired.
        assert!(!store::claim(&db, "a", "pr.merged:a/b#1").await.unwrap());
        assert!(store::claim(&db, "b", "pr.merged:a/b#1").await.unwrap());
    }
}
