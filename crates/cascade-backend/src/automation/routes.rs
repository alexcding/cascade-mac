use std::time::Duration;

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
    model::{Automation, Event, Kind, RunMode, StepKind},
    runner, schedule, store, FORWARD_WEBHOOKS, PAUSED,
};
use crate::{db::project_identity, error::ApiError, AppState};
use crate::Project;

type ApiResult<T> = Result<Json<T>, ApiError>;

/// Clean up and check a pipeline before it is stored or dry-run.
fn validate(mut automation: Automation) -> Result<Automation, ApiError> {
    automation.name = automation.name.trim().to_owned();
    if automation.name.is_empty() {
        automation.name = "Untitled automation".into();
    }
    if automation.kind == Kind::Schedule {
        schedule::validate(&mut automation.schedule).map_err(ApiError::bad_request)?;
        // A scheduled automation has no trigger or steps; nothing stale is kept for it.
        automation.trigger = Default::default();
        automation.steps.clear();
        return Ok(automation);
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
    let last = store::last_runs(&app.db).await?;
    let items: Vec<Value> = store::list(&app.db).await?
        .into_iter()
        .map(|automation| {
            let mut value = serde_json::to_value(&automation).unwrap_or(Value::Null);
            if let Some((_, status, mode, at)) = last.iter().find(|(id, ..)| *id == automation.id) {
                value["lastRun"] = json!({"status":status,"mode":mode,"finishedAt":at});
            }
            if let Some(next) = schedule::next_run(&automation) {
                value["nextRun"] = json!(next);
            }
            value
        })
        .collect();
    Ok(Json(json!(items)))
}

pub async fn get(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Automation> {
    store::get(&app.db, &id).await?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("automation not found"))
}

pub async fn create(State(app): State<AppState>, Json(mut automation): Json<Automation>) -> ApiResult<Automation> {
    automation.id = String::new();
    automation.position = 0;
    let saved = store::save(&app.db, validate(automation)?).await?;
    app.publish(crate::Event::Automations { scope: None, id: Some(saved.id.to_string()) });
    Ok(Json(saved))
}

pub async fn update(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Json(mut automation): Json<Automation>,
) -> ApiResult<Automation> {
    let existing = store::get(&app.db, &id).await?.ok_or_else(|| ApiError::not_found("automation not found"))?;
    automation.id = id;
    if automation.position == 0 {
        automation.position = existing.position;
    }
    let saved = store::save(&app.db, validate(automation)?).await?;
    app.publish(crate::Event::Automations { scope: None, id: Some(saved.id.to_string()) });
    Ok(Json(saved))
}

pub async fn remove(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Value> {
    if !store::delete(&app.db, &id).await? {
        return Err(ApiError::not_found("automation not found"));
    }
    app.publish(crate::Event::Automations { scope: None, id: Some(id.to_string()) });
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
    let projects: Vec<Project> = app
        .db
        .projects().await?
        .into_iter()
        .filter(|p| scope.is_empty() || scope.contains(&p.id.as_str()))
        .collect();
    let mut out = Vec::new();
    if query.kind == "jira" {
        let items = if query.jql.trim().is_empty() {
            let mut items = Vec::new();
            for project in &projects {
                if let Ok(Some(snapshot)) = app.db.jira_snapshot(&format!("board:{}", project.id)).await {
                    items.extend(snapshot["items"].as_array().cloned().unwrap_or_default());
                }
            }
            items
        } else {
            crate::jira::search_jira(query.jql.trim(), 25)
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
        let id = project.id.as_str();
        let identity = project_identity(project);
        let merged = app.db.pr_snapshot(id, "merged", Some(&identity)).await?;
        // Nothing else reads the merged window, so a stale one is refreshed here, in the
        // background; the next listing shows it.
        if !project.repo.is_empty() && merged.as_ref().is_none_or(|snapshot| snapshot.is_stale(60)) {
            let (app, project) = (app.clone(), project.clone());
            tokio::spawn(async move {
                let poller = app.poller.clone();
                poller.sync_pr_scope(&app, project, "merged").await
            });
        }
        for (state, snapshot) in [("open", app.db.pr_snapshot(id, "open", None).await?), ("merged", merged)] {
            for pr in snapshot.map(|s| s.prs).unwrap_or_default().into_iter().take(30) {
                let number = pr["number"].as_i64().unwrap_or(0);
                let repo = pr["repo"].as_str().unwrap_or(project.repo.as_str());
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
        let ticket = crate::jira::search_jira(&format!("key = {key}"), 1)
            .await
            .map_err(|e| ApiError::bad_request(e.to_string()))?
            .into_iter()
            .next()
            .ok_or_else(|| ApiError::not_found(format!("{key} not found")))?;
        let prefix = key.split('-').next().unwrap_or("");
        let project = app
            .db
            .projects().await?
            .into_iter()
            .find(|p| p.jira_project_key.eq_ignore_ascii_case(prefix));
        return Ok(Event { kind, key: format!("sample:{key}"), at: now, project, pr: None, ticket: Some(ticket) });
    }
    let project_id = sample["projectId"].as_str().unwrap_or("");
    let number = sample["number"].as_i64().unwrap_or(0);
    let project = app.db.project(project_id).await?.ok_or_else(|| ApiError::not_found("project not found"))?;
    let identity = project_identity(&project);
    let mut pr = None;
    for (state, identity) in [("open", None), ("merged", Some(identity.as_str()))] {
        if let Some(snapshot) = app.db.pr_snapshot(project_id, state, identity).await? {
            pr = snapshot.prs.into_iter().find(|p| p["number"].as_i64() == Some(number));
            if pr.is_some() {
                break;
            }
        }
    }
    let mut pr = pr.ok_or_else(|| ApiError::not_found(format!("PR #{number} is not in the synced snapshot")))?;
    pr["repo"] = json!(pr["repo"].as_str().unwrap_or(project.repo.as_str()));
    Ok(Event { kind, key: format!("sample:{project_id}:{number}"), at: now, project: Some(project), pr: Some(pr), ticket: None })
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
    if automation.kind == Kind::Schedule {
        return Err(ApiError::bad_request("A scheduled automation has no dry run; use Run Now"));
    }
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
    let automation = store::get(&app.db, &id).await?.ok_or_else(|| ApiError::not_found("automation not found"))?;
    if automation.kind == Kind::Schedule {
        let key = format!("manual:{}", Uuid::new_v4());
        let trace = schedule::run_and_record(&app, &automation, &key, "manual").await;
        return Ok(Json(serde_json::to_value(trace).unwrap_or(Value::Null)));
    }
    let event = sample_event(&app, &automation, &body.sample).await?;
    let trace = runner::run_and_record(&app, &automation, &event, RunMode::Live).await;
    Ok(Json(serde_json::to_value(trace).unwrap_or(Value::Null)))
}

#[derive(Deserialize)]
pub struct LaunchBody {
    key: String,
    ok: bool,
    #[serde(default)]
    detail: String,
}

/// The app, on a scheduled run's `automation-launch`: whether it started the agent.
pub async fn launch_report(State(app): State<AppState>, Path(id): Path<String>, Json(body): Json<LaunchBody>) -> ApiResult<Value> {
    let automation = store::get(&app.db, &id).await?.ok_or_else(|| ApiError::not_found("automation not found"))?;
    let settled = schedule::settle(&app, &automation, &body.key, body.ok, &body.detail).await;
    Ok(Json(json!({"ok": settled})))
}

#[derive(Deserialize)]
pub struct RunsQuery {
    automation: Option<String>,
    limit: Option<i64>,
}

pub async fn runs(State(app): State<AppState>, Query(query): Query<RunsQuery>) -> ApiResult<Value> {
    let automation = query.automation.as_deref().filter(|v| !v.is_empty());
    Ok(Json(json!(store::runs(&app.db, automation, query.limit.unwrap_or(50)).await?)))
}

pub async fn get_settings(State(app): State<AppState>) -> ApiResult<Value> {
    let mut forwarding: Vec<String> = app.forwarders.list().await;
    forwarding.sort();
    // Every project with a repo, with what its forwarder is doing: Settings lists them all, and
    // offers a fix for one whose forwarder cannot start.
    let global = super::forwarding(&app).await;
    let all = app.db.projects().await?;
    let mut wanted: Vec<String> =
        if global { super::forwarded(&all).into_iter().collect() } else { Vec::new() };
    wanted.sort();
    let statuses = app.forwarders.statuses().await;
    let projects: Vec<Value> = all
        .iter()
        .filter(|project| !project.repo.is_empty())
        .map(|project| {
            let id = project.id.as_str();
            let repo = project.repo.as_str();
            let (state, error) = if !global {
                ("off", None)
            } else if !super::forwards(project) {
                ("disabled", None)
            } else {
                statuses.get(repo).map_or(("starting", None), |status| (status.state, status.error.clone()))
            };
            json!({"id": id, "name": project.name, "repo": repo, "state": state, "error": error})
        })
        .collect();
    Ok(Json(json!({
        "paused": super::paused(&app).await,
        "forwardWebhooks": global,
        "forwarding": forwarding,
        "forwardable": wanted,
        "projects": projects,
    })))
}

/// The repos whose webhooks are being forwarded right now.
pub async fn forwarders(State(app): State<AppState>) -> ApiResult<Vec<String>> {
    Ok(Json(app.forwarders.list().await))
}

#[derive(Deserialize)]
pub struct FixForwarderBody {
    repo: String,
}

/// Settings' Fix for a repo whose forwarder cannot start: remove the `gh webhook forward` hooks
/// that block it, then start it again. Only for a repo Cascade forwards, and only when asked:
/// the hook may be a teammate's live forwarder, which Settings says before offering this.
pub async fn fix_forwarder(State(app): State<AppState>, Json(body): Json<FixForwarderBody>) -> ApiResult<Value> {
    let repo = body.repo.trim();
    if !super::forward_repos(&app).await.contains(repo) {
        return Err(ApiError::bad_request("Cascade does not forward this repo's webhooks"));
    }
    let path = format!("repos/{repo}/hooks");
    let listed = crate::cli::run("gh", ["api", path.as_str()], Duration::from_secs(20)).await.map_err(ApiError::internal)?;
    let hooks: Value = serde_json::from_str(&listed).map_err(ApiError::internal)?;
    let ids = crate::integrations::forwarder_hook_ids(&hooks);
    let mut failed = None;
    for id in &ids {
        let hook = format!("repos/{repo}/hooks/{id}");
        match crate::cli::run("gh", ["api", "-X", "DELETE", hook.as_str()], Duration::from_secs(20)).await {
            // Gone already, which is what the delete was for.
            Err(error) if !crate::integrations::is_already_gone(&format!("{error:#}")) => failed = Some(error),
            _ => {}
        }
    }
    let _ = app.db.add_log("webhook", "info", "forwarder_hook_removed", &json!({"repo":repo,"hooks":ids})).await;
    // Retry even after a failed delete: an earlier one may have been the hook in the way, and a
    // forwarder left at its slowest backoff would not notice for fifteen minutes.
    app.forwarders.retry(repo).await;
    app.publish(crate::Event::Automations { scope: Some("settings"), id: None });
    if let Some(error) = failed {
        return Err(ApiError::internal(format!("{error:#}")));
    }
    Ok(Json(json!({"removed": ids.len()})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn settings_list_every_project_with_its_forwarding_state() {
        let directory = tempfile::tempdir().unwrap();
        let db = crate::Database::open(directory.path()).unwrap();
        let covered = db.add_project(json!({"name":"Covered","repo":"a/covered"}).as_object().unwrap()).await.unwrap();
        db.add_project(json!({"name":"Plain","repo":"a/plain"}).as_object().unwrap()).await.unwrap();
        db.add_project(json!({"name":"Off","repo":"a/off","forwardWebhooks":false}).as_object().unwrap()).await.unwrap();
        db.add_project(json!({"name":"No repo"}).as_object().unwrap()).await.unwrap();
        let legacy: crate::Project = serde_json::from_value(json!({"id":covered.id,"name":"p","mergeTransition":"Done"})).unwrap();
        let mut pipeline = super::super::migrate::legacy_pipeline(&legacy).unwrap();
        pipeline.mode = super::super::model::Mode::Live;
        super::super::store::save(&db, pipeline).await.unwrap();
        let app = AppState::new(db, None);
        let Json(settings) = get_settings(State(app)).await.unwrap();
        let states: Vec<(String, String)> = settings["projects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| (p["repo"].as_str().unwrap().to_owned(), p["state"].as_str().unwrap().to_owned()))
            .collect();
        // Wanted, pipeline or none, but no forwarder has started in a test: it is about to.
        assert!(states.contains(&("a/covered".into(), "starting".into())));
        assert!(states.contains(&("a/plain".into(), "starting".into())));
        assert!(states.contains(&("a/off".into(), "disabled".into())));
        assert_eq!(states.len(), 3);
    }

    #[test]
    fn every_template_is_a_valid_pipeline() {
        for template in catalog::catalog()["templates"].as_array().unwrap() {
            let mut automation: Automation = serde_json::from_value(template["automation"].clone()).unwrap();
            // A scheduled template leaves its project and agent open; the app fills in the first
            // project and its default agent.
            if automation.kind == Kind::Schedule {
                assert!(automation.schedule.project.is_empty(), "template {} names a project", template["id"]);
                automation.schedule.project = "first-project".into();
                automation.schedule.cli = "claude".into();
            }
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
    app.db.set_config(&values).await?;
    app.publish(crate::Event::Automations { scope: Some("settings"), id: None });
    get_settings(State(app)).await
}
