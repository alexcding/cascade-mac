use axum::{
    extract::{Path, Query, State},
    Json,
};
use chrono::Utc;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use uuid::Uuid;

use super::{
    actions, catalog, filters,
    model::{Automation, Event, RunMode, StepKind},
    runner, store, FORWARD_WEBHOOKS, PAUSED,
};
use crate::{db::project_identity, error::ApiError, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

/// Clean up and check a pipeline before it is stored or dry-run.
fn validate(mut automation: Automation) -> Result<Automation, ApiError> {
    automation.name = automation.name.trim().to_owned();
    if automation.name.is_empty() {
        automation.name = "Untitled automation".into();
    }
    automation.trigger.types.retain(|t| !t.trim().is_empty());
    automation.trigger.types.dedup();
    if automation.trigger.types.is_empty() {
        return Err(ApiError::bad_request("Choose at least one trigger"));
    }
    for kind in &automation.trigger.types {
        if catalog::find("triggers", kind).is_none() {
            return Err(ApiError::bad_request(format!("Unknown trigger {kind}")));
        }
    }
    if automation.trigger.types.iter().any(|t| t.starts_with("jira."))
        && automation.trigger.params.get("jql").and_then(Value::as_str).is_none_or(|v| v.trim().is_empty())
    {
        return Err(ApiError::bad_request("Jira triggers need a JQL"));
    }
    for step in &mut automation.steps {
        if step.id.is_empty() {
            step.id = Uuid::new_v4().to_string();
        }
        let label = match step.kind {
            StepKind::Filter => {
                if !filters::known(&step.node) {
                    return Err(ApiError::bad_request(format!("Unknown filter {}", step.node)));
                }
                filters::validate(step)
            }
            StepKind::Action => {
                if !actions::known(&step.node) {
                    return Err(ApiError::bad_request(format!("Unknown action {}", step.node)));
                }
                actions::validate(step)
            }
        };
        label.map_err(|e| ApiError::bad_request(e.to_string()))?;
    }
    Ok(automation)
}

pub async fn list(State(app): State<AppState>) -> ApiResult<Value> {
    let last = store::last_runs(&app.db)?;
    let items: Vec<Value> = store::list(&app.db)?
        .into_iter()
        .map(|automation| {
            let mut value = serde_json::to_value(&automation).unwrap_or(Value::Null);
            if let Some((_, status, mode, at)) = last.iter().find(|(id, ..)| *id == automation.id) {
                value["lastRun"] = json!({"status":status,"mode":mode,"finishedAt":at});
            }
            value
        })
        .collect();
    Ok(Json(json!(items)))
}

pub async fn get(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Automation> {
    store::get(&app.db, &id)?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("automation not found"))
}

pub async fn create(State(app): State<AppState>, Json(mut automation): Json<Automation>) -> ApiResult<Automation> {
    automation.id = String::new();
    automation.position = 0;
    let saved = store::save(&app.db, validate(automation)?)?;
    app.broadcast(json!({"type":"automations","id":saved.id}));
    Ok(Json(saved))
}

pub async fn update(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Json(mut automation): Json<Automation>,
) -> ApiResult<Automation> {
    let existing = store::get(&app.db, &id)?.ok_or_else(|| ApiError::not_found("automation not found"))?;
    automation.id = id;
    if automation.position == 0 {
        automation.position = existing.position;
    }
    let saved = store::save(&app.db, validate(automation)?)?;
    app.broadcast(json!({"type":"automations","id":saved.id}));
    Ok(Json(saved))
}

pub async fn remove(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Value> {
    if !store::delete(&app.db, &id)? {
        return Err(ApiError::not_found("automation not found"));
    }
    app.broadcast(json!({"type":"automations","id":id}));
    Ok(Json(json!({"ok":true})))
}

pub async fn get_catalog() -> Json<Value> {
    Json(catalog::catalog().clone())
}

#[derive(Deserialize)]
pub struct SampleQuery {
    #[serde(default)]
    kind: String,
    #[serde(default)]
    projects: String,
    #[serde(default)]
    jql: String,
}

/// Recent PRs (from the snapshots) or tickets to dry-run against.
pub async fn samples(State(app): State<AppState>, Query(query): Query<SampleQuery>) -> ApiResult<Value> {
    let scope: Vec<&str> = query.projects.split(',').map(str::trim).filter(|v| !v.is_empty()).collect();
    let projects: Vec<Value> = app
        .db
        .projects()?
        .into_iter()
        .filter(|p| scope.is_empty() || scope.contains(&p["id"].as_str().unwrap_or("")))
        .collect();
    let mut out = Vec::new();
    if query.kind == "jira" {
        let items = if query.jql.trim().is_empty() {
            projects
                .iter()
                .filter_map(|p| app.db.jira_snapshot(p["id"].as_str().unwrap_or("")).ok().flatten())
                .flat_map(|s| s["items"].as_array().cloned().unwrap_or_default())
                .collect::<Vec<_>>()
        } else {
            crate::poller::search_jira(query.jql.trim(), 25)
                .await
                .map_err(|e| ApiError::bad_request(e.to_string()))?
        };
        for item in items.into_iter().take(50) {
            let key = item["key"].as_str().unwrap_or("").to_owned();
            out.push(json!({"id":format!("jira:{key}"),"kind":"jira","key":key,
                "label":format!("{key} {}",item["summary"].as_str().unwrap_or("")),
                "detail":item["status"]}));
        }
        return Ok(Json(json!(out)));
    }
    for project in &projects {
        let id = project["id"].as_str().unwrap_or("");
        let identity = project_identity(project);
        for (state, snapshot) in [
            ("open", app.db.pr_snapshot(id, "open", None)?),
            ("merged", app.db.pr_snapshot(id, "merged", Some(&identity))?),
        ] {
            for pr in snapshot.and_then(|s| s["prs"].as_array().cloned()).unwrap_or_default().into_iter().take(30) {
                let number = pr["number"].as_i64().unwrap_or(0);
                let repo = pr["repo"].as_str().or_else(|| project["repo"].as_str()).unwrap_or("");
                out.push(json!({"id":format!("pr:{id}:{number}"),"kind":"pr","projectId":id,"number":number,
                    "label":format!("{repo}#{number} {}",pr["title"].as_str().unwrap_or("")),
                    "detail":state}));
            }
        }
    }
    Ok(Json(json!(out)))
}

/// The event a sample stands for, as the trigger would have delivered it.
async fn sample_event(app: &AppState, automation: &Automation, sample: &Value) -> Result<Event, ApiError> {
    let kind = sample["event"]
        .as_str()
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .or_else(|| automation.trigger.types.first().cloned())
        .unwrap_or_else(|| "manual".into());
    let now = Utc::now();
    if sample["kind"] == "jira" {
        let key = sample["key"].as_str().unwrap_or("").trim().to_owned();
        let ticket = crate::poller::search_jira(&format!("key = {key}"), 1)
            .await
            .map_err(|e| ApiError::bad_request(e.to_string()))?
            .into_iter()
            .next()
            .ok_or_else(|| ApiError::not_found(format!("{key} not found")))?;
        let prefix = key.split('-').next().unwrap_or("");
        let project = app
            .db
            .projects()?
            .into_iter()
            .find(|p| p["jiraProjectKey"].as_str().is_some_and(|k| k.eq_ignore_ascii_case(prefix)))
            .unwrap_or(Value::Null);
        return Ok(Event { kind, key: format!("sample:{key}"), at: now, project, pr: None, ticket: Some(ticket) });
    }
    let project_id = sample["projectId"].as_str().unwrap_or("");
    let number = sample["number"].as_i64().unwrap_or(0);
    let project = app.db.project(project_id)?.ok_or_else(|| ApiError::not_found("project not found"))?;
    let identity = project_identity(&project);
    let mut pr = None;
    for (state, identity) in [("open", None), ("merged", Some(identity.as_str()))] {
        if let Some(snapshot) = app.db.pr_snapshot(project_id, state, identity)? {
            pr = snapshot["prs"].as_array().and_then(|prs| prs.iter().find(|p| p["number"].as_i64() == Some(number)).cloned());
            if pr.is_some() {
                break;
            }
        }
    }
    let mut pr = pr.ok_or_else(|| ApiError::not_found(format!("PR #{number} is not in the synced snapshot")))?;
    pr["repo"] = json!(pr["repo"].as_str().or_else(|| project["repo"].as_str()).unwrap_or(""));
    Ok(Event { kind, key: format!("sample:{project_id}:{number}"), at: now, project, pr: Some(pr), ticket: None })
}

#[derive(Deserialize)]
pub struct DryRunBody {
    automation: Automation,
    #[serde(default)]
    sample: Value,
}

/// Plan an unsaved draft against a sample. Reads, never writes, never records.
pub async fn dry_run(State(app): State<AppState>, Json(body): Json<DryRunBody>) -> ApiResult<Value> {
    let automation = validate(body.automation)?;
    let event = sample_event(&app, &automation, &body.sample).await?;
    let trace = runner::run(&app, &automation, &event, RunMode::Dry).await;
    Ok(Json(serde_json::to_value(trace).unwrap_or(Value::Null)))
}

#[derive(Deserialize)]
pub struct RunBody {
    #[serde(default)]
    sample: Value,
}

/// Run a saved pipeline for real against a sample, from the Run button.
pub async fn run_now(State(app): State<AppState>, Path(id): Path<String>, Json(body): Json<RunBody>) -> ApiResult<Value> {
    let automation = store::get(&app.db, &id)?.ok_or_else(|| ApiError::not_found("automation not found"))?;
    let event = sample_event(&app, &automation, &body.sample).await?;
    let trace = runner::run_and_record(&app, &automation, &event, RunMode::Live).await;
    Ok(Json(serde_json::to_value(trace).unwrap_or(Value::Null)))
}

#[derive(Deserialize)]
pub struct RunsQuery {
    automation: Option<String>,
    limit: Option<i64>,
}

pub async fn runs(State(app): State<AppState>, Query(query): Query<RunsQuery>) -> ApiResult<Value> {
    let automation = query.automation.as_deref().filter(|v| !v.is_empty());
    Ok(Json(json!(store::runs(&app.db, automation, query.limit.unwrap_or(50))?)))
}

pub async fn get_settings(State(app): State<AppState>) -> ApiResult<Value> {
    let mut forwarding: Vec<String> = app.forwarders.list().await;
    forwarding.sort();
    // Every project with a repo, with what its forwarder is doing: Settings lists them all, and
    // offers a fix for one whose forwarder cannot start.
    let global = super::forwarding(&app);
    let all = app.db.projects()?;
    let covered = super::pr_covered(&app, &all);
    let mut wanted: Vec<String> =
        if global { super::forwarded(&all, &covered).into_iter().collect() } else { Vec::new() };
    wanted.sort();
    let statuses = app.forwarders.statuses().await;
    let projects: Vec<Value> = all
        .iter()
        .filter(|project| project["repo"].as_str().is_some_and(|repo| !repo.is_empty()))
        .map(|project| {
            let id = project["id"].as_str().unwrap_or("");
            let repo = project["repo"].as_str().unwrap_or("");
            let (state, error) = if !global {
                ("off", None)
            } else if !super::forwards(project) {
                ("disabled", None)
            } else if !covered.contains(id) {
                ("idle", None)
            } else {
                statuses.get(repo).map_or(("starting", None), |status| (status.state, status.error.clone()))
            };
            json!({"id": id, "name": project["name"], "repo": repo, "state": state, "error": error})
        })
        .collect();
    Ok(Json(json!({
        "paused": super::paused(&app),
        "forwardWebhooks": global,
        "forwarding": forwarding,
        "forwardable": wanted,
        "projects": projects,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn settings_list_every_project_with_its_forwarding_state() {
        let directory = tempfile::tempdir().unwrap();
        let db = crate::Database::open(directory.path()).unwrap();
        let covered = db.add_project(json!({"name":"Covered","repo":"a/covered"}).as_object().unwrap()).unwrap();
        db.add_project(json!({"name":"Idle","repo":"a/idle"}).as_object().unwrap()).unwrap();
        db.add_project(json!({"name":"Off","repo":"a/off","forwardWebhooks":false}).as_object().unwrap()).unwrap();
        db.add_project(json!({"name":"No repo"}).as_object().unwrap()).unwrap();
        let mut pipeline = super::super::migrate::legacy_pipeline(&json!({"id":covered["id"],"name":"p","mergeTransition":"Done"})).unwrap();
        pipeline.mode = super::super::model::Mode::Live;
        super::super::store::save(&db, pipeline).unwrap();
        let app = AppState::new(db, None);
        let Json(settings) = get_settings(State(app)).await.unwrap();
        let states: Vec<(String, String)> = settings["projects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| (p["repo"].as_str().unwrap().to_owned(), p["state"].as_str().unwrap().to_owned()))
            .collect();
        // Covered and wanted, but no forwarder has started in a test: it is about to.
        assert!(states.contains(&("a/covered".into(), "starting".into())));
        assert!(states.contains(&("a/idle".into(), "idle".into())));
        assert!(states.contains(&("a/off".into(), "disabled".into())));
        assert_eq!(states.len(), 3);
    }

    #[test]
    fn every_template_is_a_valid_pipeline() {
        for template in catalog::catalog()["templates"].as_array().unwrap() {
            let automation: Automation = serde_json::from_value(template["automation"].clone()).unwrap();
            assert!(validate(automation).is_ok(), "template {} does not validate", template["id"]);
        }
    }
}

pub async fn put_settings(State(app): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let mut values = Map::new();
    if let Some(paused) = body["paused"].as_bool() {
        values.insert(PAUSED.into(), json!(paused.to_string()));
    }
    if let Some(forward) = body["forwardWebhooks"].as_bool() {
        values.insert(FORWARD_WEBHOOKS.into(), json!(forward.to_string()));
    }
    app.db.set_config(&values)?;
    app.broadcast(json!({"type":"automations","scope":"settings"}));
    get_settings(State(app)).await
}
