use std::{convert::Infallible, path::PathBuf, time::Duration};

use axum::{
    extract::{Path, Query, State},
    response::{
        sse::{Event, KeepAlive},
        IntoResponse, Sse,
    },
    Json,
};
use futures_util::{Stream, StreamExt};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use tokio_stream::wrappers::BroadcastStream;
use url::Url;
use uuid::Uuid;

use crate::{error::ApiError, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

pub async fn health(State(state): State<AppState>) -> impl IntoResponse {
    Json(json!({
        "service": "craft",
        "protocol": 1,
        "pid": std::process::id(),
        "instanceId": state.instance_id,
        "runtime": "rust",
    }))
}

pub async fn get_config(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(state.db.config()?))
}

pub async fn set_config(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let object = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("JSON object required"))?;
    state.db.set_config(object)?;
    for key in object.keys() {
        if let Some(id) = key.strip_prefix("board_query_") {
            state.poller.invalidate(id);
            state.db.invalidate_snapshots(id)?;
        }
    }
    state.broadcast(json!({ "type": "config" }));
    Ok(Json(json!({ "ok": true })))
}

pub async fn sounds() -> ApiResult<Value> {
    let mut result = Vec::new();
    let mut dirs = vec![PathBuf::from("/System/Library/Sounds")];
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join("Library/Sounds"));
    }
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        let mut paths = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
        paths.sort();
        for path in paths {
            let Some(extension) = path
                .extension()
                .and_then(|v| v.to_str())
                .map(str::to_ascii_lowercase)
            else {
                continue;
            };
            if !["aif", "aiff", "wav", "caf", "m4a", "mp3"].contains(&extension.as_str()) {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|v| v.to_str()) else {
                continue;
            };
            result.push(json!({ "name": stem, "path": path.to_string_lossy() }));
        }
    }
    Ok(Json(Value::Array(result)))
}

pub async fn get_settings(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(state.db.settings()?))
}

#[derive(Deserialize)]
pub struct SettingBody {
    value: Value,
}

pub async fn put_setting(
    State(state): State<AppState>,
    Path(key): Path<String>,
    Json(body): Json<SettingBody>,
) -> ApiResult<Value> {
    state.db.setting(&key, &body.value)?;
    state.broadcast(json!({ "type": "settings" }));
    Ok(Json(json!({ "ok": true })))
}

pub async fn get_tabs(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(state.db.tabs()?))
}

pub async fn open_tab(State(state): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let object = body.as_object().ok_or_else(|| {
        ApiError::bad_request("A web URL, tab kind, and string metadata are required")
    })?;
    validate_open_tab(object)?;
    let saved = state.db.open_tab(object)?;
    state.broadcast(json!({ "type": "tabs" }));
    Ok(Json(saved))
}

pub async fn close_tab(State(state): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let id = body
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| ApiError::bad_request("id required"))?;
    let saved = state.db.close_tab(id)?;
    state.broadcast(json!({ "type": "tabs" }));
    Ok(Json(saved))
}

pub async fn rename_tab(State(state): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    if let Some(order) = body.get("order").and_then(Value::as_array) {
        let ids: Vec<&str> = order.iter().filter_map(Value::as_str).collect();
        let saved = state.db.reorder_tabs(&ids)?;
        state.broadcast(json!({ "type": "tabs" }));
        return Ok(Json(saved));
    }
    let id = body
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| ApiError::bad_request("id required"))?;
    if let Some(pinned) = body.get("pinned") {
        let pinned = pinned
            .as_bool()
            .ok_or_else(|| ApiError::bad_request("pinned must be a boolean"))?;
        let saved = state.db.pin_tab(id, pinned)?;
        state.broadcast(json!({ "type": "tabs" }));
        return Ok(Json(saved));
    }
    let title = body
        .get("title")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::bad_request("title required"))?;
    let saved = state.db.rename_tab(id, title)?;
    state.broadcast(json!({ "type": "tabs" }));
    Ok(Json(saved))
}

pub async fn put_tabs(State(state): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let tabs = body
        .get("tabs")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let active = body.get("active").and_then(Value::as_str);
    state.db.set_tabs(tabs, active)?;
    state.broadcast(json!({ "type": "tabs" }));
    Ok(Json(json!({ "ok": true })))
}

pub async fn get_tasks(State(state): State<AppState>) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.tasks()?))
}

pub async fn upsert_task(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let object = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("id, projectId, workspace, worktree required"))?;
    if !state.db.upsert_task(object)? {
        return Err(ApiError::bad_request(
            "id, projectId, workspace, worktree required",
        ));
    }
    state.broadcast(json!({ "type": "tasks" }));
    Ok(Json(json!({ "ok": true })))
}

#[derive(Default, Deserialize)]
pub struct DeleteTaskQuery {
    id: Option<String>,
}

pub async fn delete_task(
    State(state): State<AppState>,
    Query(query): Query<DeleteTaskQuery>,
) -> ApiResult<Value> {
    if let Some(id) = query.id {
        state.db.delete_task(&id)?;
    }
    state.broadcast(json!({ "type": "tasks" }));
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct PinBody {
    pinned: Value,
}

pub async fn pin_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<PinBody>,
) -> ApiResult<Value> {
    let pinned = body
        .pinned
        .as_bool()
        .ok_or_else(|| ApiError::bad_request("pinned must be a boolean"))?;
    if !state.db.pin_task(&id, pinned)? {
        return Err(ApiError::not_found("Session not found"));
    }
    state.broadcast(json!({ "type": "tasks" }));
    Ok(Json(json!({ "ok": true })))
}

pub async fn patch_task(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let patch = body.as_object().ok_or_else(|| {
        ApiError::bad_request("Only string session metadata fields may be updated")
    })?;
    const ALLOWED: &[&str] = &[
        "title",
        "kind",
        "url",
        "jiraKey",
        "cli",
        "sessionId",
        "runScheme",
        "runSim",
    ];
    if patch.is_empty()
        || patch
            .iter()
            .any(|(key, value)| !ALLOWED.contains(&key.as_str()) || !value.is_string())
    {
        return Err(ApiError::bad_request(
            "Only string session metadata fields may be updated",
        ));
    }
    if let Some(cli) = patch.get("cli").and_then(Value::as_str) {
        if !["", "claude", "codex"].contains(&cli) {
            return Err(ApiError::bad_request("Unsupported agent"));
        }
    }
    if !state.db.patch_task(&id, patch)? {
        return Err(ApiError::not_found("Session not found"));
    }
    state.broadcast(json!({ "type": "tasks" }));
    Ok(Json(json!({ "ok": true })))
}

pub async fn get_projects(State(state): State<AppState>) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.projects()?))
}

pub async fn get_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Value> {
    state
        .db
        .project(&id)?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("Not found"))
}

pub async fn create_project(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let patch = sanitize_project_patch(&body)?;
    if patch
        .get("name")
        .and_then(Value::as_str)
        .is_none_or(str::is_empty)
    {
        return Err(ApiError::bad_request("name required"));
    }
    let project = state.db.add_project(&patch)?;
    state.broadcast(json!({ "type": "sync", "projectId": project["id"] }));
    Ok(Json(project))
}

pub async fn update_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let patch = sanitize_project_patch(&body)?;
    let project = state
        .db
        .update_project(&id, &patch)?
        .ok_or_else(|| ApiError::not_found("Not found"))?;
    if !patch
        .keys()
        .all(|key| key == "runScheme" || key == "runSim")
    {
        state.poller.invalidate(&id);
        state.db.invalidate_snapshots(&id)?;
        state.broadcast(json!({ "type": "sync", "projectId": id }));
    }
    Ok(Json(project))
}

pub async fn delete_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Value> {
    state.poller.invalidate(&id);
    state.db.delete_project(&id)?;
    state.broadcast(json!({ "type": "sync", "projectId": id }));
    Ok(Json(json!({ "ok": true })))
}

#[derive(Default, Deserialize)]
pub struct ProjectPrQuery {
    state: Option<String>,
    snapshot: Option<String>,
    refresh: Option<String>,
}

pub async fn project_prs(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ProjectPrQuery>,
) -> ApiResult<Value> {
    let project = app
        .db
        .project(&id)?
        .ok_or_else(|| ApiError::not_found("Not found"))?;
    let state = query.state.as_deref().unwrap_or("open");
    if !["open", "merged", "closed", "all"].contains(&state) {
        return Err(ApiError::bad_request("Invalid pull request state"));
    }
    let identity = serde_json::to_string(&json!([
        project["repo"],
        project["jiraProjectKey"],
        project["created_at"]
    ]))
    .unwrap();
    let mut snapshot = app
        .db
        .pr_snapshot(&id, state, Some(&identity))?
        .unwrap_or_else(empty_pr_snapshot);
    let stale = snapshot
        .get("lastSynced")
        .and_then(Value::as_str)
        .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
        .is_none_or(|v| {
            chrono::Utc::now()
                .signed_duration_since(v.with_timezone(&chrono::Utc))
                .num_seconds()
                > 30
        });
    let refresh_requested = query.refresh.as_deref() == Some("1") || stale;
    if refresh_requested {
        let app_copy = app.clone();
        let project_copy = project.clone();
        let state_copy = state.to_owned();
        tokio::spawn(async move {
            let poller = app_copy.poller.clone();
            if state_copy == "open" {
                poller.sync_project(&app_copy, project_copy).await
            } else {
                poller
                    .sync_pr_scope(&app_copy, project_copy, &state_copy)
                    .await
            }
        });
    }
    if query.snapshot.as_deref() == Some("1") {
        snapshot["refreshing"] = json!(refresh_requested || app.poller.pr_syncing(&project, state));
        return Ok(Json(snapshot));
    }
    let mut prs = snapshot
        .get("prs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(error) = snapshot.get("error").and_then(Value::as_str) {
        prs.push(json!({ "repo": project["repo"], "error": error }));
    }
    Ok(Json(Value::Array(prs)))
}

#[derive(Default, Deserialize)]
pub struct PathQuery {
    path: Option<String>,
    url: Option<String>,
    refresh: Option<String>,
}

pub async fn detect_repo(Query(query): Query<PathQuery>) -> ApiResult<Value> {
    let path = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    Ok(Json(
        json!({"repo":crate::github::remote_repo(&path).await.unwrap_or_default()}),
    ))
}
pub async fn lookup_pr(Query(query): Query<PathQuery>) -> ApiResult<Value> {
    Ok(Json(match query.url {
        Some(url) => crate::github::lookup_pr(&url).await.unwrap_or(Value::Null),
        None => Value::Null,
    }))
}
pub async fn whoami() -> ApiResult<Value> {
    Ok(Json(json!({"name":crate::github::user_name().await})))
}

pub async fn poll(State(app): State<AppState>) -> ApiResult<Value> {
    app.poller.sync_all(&app).await;
    app.poller.sync_all_jira(&app).await;
    Ok(Json(json!({"ok":true})))
}

pub async fn project_jira(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<PathQuery>,
) -> ApiResult<Value> {
    let project = app
        .db
        .project(&id)?
        .ok_or_else(|| ApiError::not_found("Not found"))?;
    let effective = crate::poller::project_jql(&app, &project);
    let snapshot = app.db.jira_snapshot(&id)?;
    let stale = snapshot
        .as_ref()
        .and_then(|v| v.get("lastSynced"))
        .and_then(Value::as_str)
        .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
        .is_none_or(|v| {
            chrono::Utc::now()
                .signed_duration_since(v.with_timezone(&chrono::Utc))
                .num_seconds()
                > 90
        });
    if !effective.is_empty() && (stale || query.refresh.is_some()) {
        if query.refresh.is_some() {
            app.poller.sync_project_jira(&app, &project).await
        } else {
            let copy = app.clone();
            tokio::spawn(async move {
                let poller = copy.poller.clone();
                poller.sync_project_jira(&copy, &project).await;
            });
        }
    }
    let mut result = app
        .db
        .jira_snapshot(&id)?
        .unwrap_or_else(|| json!({"items":[],"jql":effective,"lastSynced":null,"error":null}));
    if result["jql"].as_str().unwrap_or("").is_empty() {
        result["jql"] = json!(effective)
    }
    Ok(Json(result))
}
pub async fn project_board(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<PathQuery>,
) -> ApiResult<Value> {
    let project = app
        .db
        .project(&id)?
        .ok_or_else(|| ApiError::not_found("Not found"))?;
    let key = format!("board:{id}");
    if query.refresh.is_some() {
        app.poller.sync_board(&app, &project).await
    } else if app.db.jira_snapshot(&key)?.as_ref().is_none_or(|snapshot| {
        snapshot["lastSynced"]
            .as_str()
            .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
            .is_none_or(|time| {
                (chrono::Utc::now() - time.with_timezone(&chrono::Utc)).num_seconds() > 90
            })
    }) {
        let copy = app.clone();
        tokio::spawn(async move {
            let poller = copy.poller.clone();
            poller.sync_board(&copy, &project).await;
        });
    }
    Ok(Json(app.db.jira_snapshot(&key)?.unwrap_or_else(||json!({"items":[],"jql":"","lastSynced":null,"error":null,"sprint":null,"query":"","columns":null}))))
}

pub async fn jira_search(Json(body): Json<Value>) -> ApiResult<Value> {
    let jql = body.get("jql").and_then(Value::as_str).unwrap_or("").trim();
    if jql.is_empty() {
        return Err(ApiError::bad_request("jql is required"));
    }
    let limit = body
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(50)
        .clamp(1, 200) as usize;
    let items = crate::poller::search_jira(jql, limit)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(
        json!({"items":items,"jql":jql,"lastSynced":chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis,true),"error":null}),
    ))
}
pub async fn jira_transition(
    State(app): State<AppState>,
    Path(key): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let transition = body.get("transition").and_then(Value::as_str).unwrap_or("");
    crate::poller::transition(&key, transition)
        .await
        .map_err(ApiError::internal)?;
    let payload = json!({"key":key,"transition":transition,"trigger":"manual"});
    if let Ok(event) = app.db.add_event("jira_transitioned", &payload) {
        app.broadcast(json!({"type":"activity","event":event}))
    }
    Ok(Json(json!({"ok":true})))
}
pub async fn jira_assign(
    State(app): State<AppState>,
    Path(key): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let assignee = body
        .get("assignee")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    crate::poller::assign(&key, assignee)
        .await
        .map_err(ApiError::internal)?;
    let payload = json!({"key":key,"assignee":if assignee.is_empty(){"(unassigned)"}else{assignee},"trigger":"manual"});
    if let Ok(event) = app.db.add_event("jira_assigned", &payload) {
        app.broadcast(json!({"type":"activity","event":event}))
    }
    Ok(Json(json!({"ok":true})))
}

pub async fn prs_tray(State(state): State<AppState>) -> ApiResult<Value> {
    let mut items = Vec::new();
    for project in state.db.projects()? {
        let id = project.get("id").and_then(Value::as_str).unwrap_or("");
        let snapshot = state
            .db
            .pr_snapshot(id, "open", None)?
            .unwrap_or_else(empty_pr_snapshot);
        for mut pr in snapshot
            .get("prs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
        {
            let Some(object) = pr.as_object_mut() else {
                continue;
            };
            object.insert("projectId".into(), project["id"].clone());
            object.insert("projectName".into(), project["name"].clone());
            if object.get("category").and_then(Value::as_str) == Some("review") {
                let repo = object.get("repo").and_then(Value::as_str).unwrap_or("");
                let number = object
                    .get("number")
                    .and_then(Value::as_i64)
                    .unwrap_or_default();
                let stored = state.db.review_state(&format!("{repo}#{number}"))?;
                let requested = object
                    .get("requestedAt")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| stored.as_ref().and_then(|(requested, _)| requested.clone()));
                let viewed = stored.and_then(|(_, viewed)| viewed);
                let pending = requested.is_none() || viewed.is_none() || requested > viewed;
                object.insert(
                    "requestedAt".into(),
                    requested.map(Value::String).unwrap_or(Value::Null),
                );
                object.insert(
                    "viewedAt".into(),
                    viewed.map(Value::String).unwrap_or(Value::Null),
                );
                object.insert("reviewPending".into(), Value::Bool(pending));
            }
            items.push(pr);
        }
    }
    Ok(Json(Value::Array(items)))
}

pub async fn pr_viewed(State(state): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let repo = body
        .get("repo")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("repo and number required"))?;
    let number = body
        .get("number")
        .and_then(Value::as_i64)
        .ok_or_else(|| ApiError::bad_request("repo and number required"))?;
    state.db.mark_review_viewed(&format!("{repo}#{number}"))?;
    state.broadcast(json!({ "type": "reviews" }));
    Ok(Json(json!({ "ok": true })))
}

pub async fn dashboard(State(state): State<AppState>) -> ApiResult<Value> {
    let mut result = Vec::new();
    for mut project in state.db.projects()? {
        let id = project.get("id").and_then(Value::as_str).unwrap_or("");
        let snapshot = state
            .db
            .pr_snapshot(id, "open", None)?
            .unwrap_or_else(empty_pr_snapshot);
        let object = project.as_object_mut().unwrap();
        object.insert("prs".into(), snapshot["prs"].clone());
        object.insert("lastSynced".into(), snapshot["lastSynced"].clone());
        object.insert("syncError".into(), snapshot["error"].clone());
        result.push(project);
    }
    Ok(Json(Value::Array(result)))
}

#[derive(Default, Deserialize)]
pub struct LinksQuery {
    project: Option<String>,
}

pub async fn get_links(
    State(state): State<AppState>,
    Query(query): Query<LinksQuery>,
) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.links(query.project.as_deref())?))
}

pub async fn add_link(State(state): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let number = body
        .get("prNumber")
        .and_then(Value::as_i64)
        .filter(|v| *v != 0)
        .ok_or_else(|| ApiError::bad_request("prNumber, prRepo, jiraKey required"))?;
    let repo = required_string(&body, "prRepo", "prNumber, prRepo, jiraKey required")?;
    let jira = required_string(&body, "jiraKey", "prNumber, prRepo, jiraKey required")?;
    state.db.add_link(
        number,
        repo,
        jira,
        body.get("projectId").and_then(Value::as_str),
    )?;
    Ok(Json(json!({ "ok": true })))
}

pub async fn delete_link(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Value> {
    state.db.delete_link(&id)?;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Default, Deserialize)]
pub struct LogsQuery {
    category: Option<String>,
    level: Option<String>,
    limit: Option<i64>,
}

pub async fn get_events(State(state): State<AppState>) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.query_logs(Some("event"), None, 100)?))
}
pub async fn get_logs(
    State(state): State<AppState>,
    Query(query): Query<LogsQuery>,
) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.query_logs(
        query.category.as_deref(),
        query.level.as_deref(),
        query.limit.unwrap_or(200),
    )?))
}
pub async fn log_categories(State(state): State<AppState>) -> ApiResult<Vec<String>> {
    Ok(Json(state.db.log_categories()?))
}
pub async fn clear_logs(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    state
        .db
        .clear_logs(body.get("category").and_then(Value::as_str))?;
    Ok(Json(json!({ "ok": true })))
}

pub async fn inspect_db(State(state): State<AppState>) -> ApiResult<Value> {
    let config = state.db.config()?;
    let projects = state.db.projects()?;
    let links = state.db.links(None)?;
    let snapshots = summarize_snapshots(state.db.all_pr_snapshots()?, "open");
    let jira = summarize_snapshots(state.db.all_jira_snapshots()?, "tickets");
    Ok(Json(json!({
        "config": config, "projects": projects,
        "counts": { "projects": projects.len(), "links": links.len(), "events": state.db.event_count()? },
        "ghStats": { "calls":0,"errors":0,"totalMs":0,"maxMs":0,"slowest":null,"inflight":0,"coalesced":0,"avgMs":0 },
        "snapshots": snapshots, "jiraSnapshots": jira,
    })))
}

pub async fn stream(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let initial = futures_util::stream::once(async {
        Ok(Event::default()
            .comment("connected")
            .retry(Duration::from_secs(1)))
    });
    let events = BroadcastStream::new(state.events.subscribe()).filter_map(|message| async move {
        match message {
            Ok(value) => Some(Ok(Event::default().data(value.to_string()))),
            Err(_) => None,
        }
    });
    Sse::new(initial.chain(events)).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

fn validate_open_tab(tab: &Map<String, Value>) -> Result<(), ApiError> {
    const FIELDS: &[&str] = &[
        "id", "url", "kind", "title", "repo", "branch", "category", "login",
    ];
    let valid_fields = tab
        .iter()
        .all(|(key, value)| FIELDS.contains(&key.as_str()) && value.is_string());
    let url = tab
        .get("url")
        .and_then(Value::as_str)
        .and_then(|value| Url::parse(value).ok());
    let kind = tab.get("kind").and_then(Value::as_str);
    let valid_url = url.as_ref().is_some_and(|url| {
        ["http", "https"].contains(&url.scheme())
            && url.username().is_empty()
            && url.password().is_none()
    });
    if !valid_fields
        || !valid_url
        || !kind.is_some_and(|kind| ["github", "jira", "web"].contains(&kind))
    {
        return Err(ApiError::bad_request(
            "A web URL, tab kind, and string metadata are required",
        ));
    }
    Ok(())
}

fn sanitize_project_patch(body: &Value) -> Result<Map<String, Value>, ApiError> {
    let body = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("JSON object required"))?;
    let mut patch = Map::new();
    for key in [
        "name",
        "jql",
        "workspace",
        "mergeTransition",
        "ide",
        "ideCmd",
        "runScheme",
        "runSim",
    ] {
        if let Some(value) = body.get(key) {
            let trimmed = value.as_str().map(str::trim).unwrap_or_default();
            if key == "name" && trimmed.is_empty() {
                return Err(ApiError::bad_request("name required"));
            }
            patch.insert(key.into(), Value::String(trimmed.into()));
        }
    }
    if let Some(value) = body.get("jiraProjectKey") {
        patch.insert(
            "jiraProjectKey".into(),
            Value::String(value.as_str().unwrap_or_default().trim().to_uppercase()),
        );
    }
    if let Some(value) = body.get("fixVersionScript") {
        patch.insert(
            "fixVersionScript".into(),
            Value::String(value.as_str().unwrap_or_default().into()),
        );
    }
    for key in ["forwardWebhooks", "fixVersionEnabled"] {
        if let Some(value) = body.get(key) {
            patch.insert(
                key.into(),
                Value::Bool(value.as_bool().unwrap_or(!value.is_null())),
            );
        }
    }
    if let Some(value) = body.get("ideTarget") {
        let rel = value
            .as_str()
            .unwrap_or_default()
            .trim()
            .trim_start_matches('/');
        if rel.split('/').any(|piece| piece == "..") {
            return Err(ApiError::bad_request(
                "IDE target must stay inside the checkout",
            ));
        }
        patch.insert("ideTarget".into(), Value::String(rel.into()));
    }
    if let Some(value) = body.get("repo") {
        let raw = value.as_str().unwrap_or_default().trim();
        let repo = if raw.is_empty() {
            String::new()
        } else {
            parse_repo(raw).ok_or_else(|| {
                ApiError::bad_request("Invalid repo — use owner/repo or a GitHub URL")
            })?
        };
        patch.insert("repo".into(), Value::String(repo));
    }
    if let Some(workflows) = body.get("workflows") {
        patch.insert("workflows".into(), sanitize_workflows(workflows));
    }
    Ok(patch)
}

fn sanitize_workflows(value: &Value) -> Value {
    let Some(items) = value.as_array() else {
        return json!([]);
    };
    Value::Array(items.iter().take(20).map(|workflow| {
        let steps=workflow.get("steps").and_then(Value::as_array).or_else(||workflow.get("commands").and_then(Value::as_array));
        let steps=steps.into_iter().flatten().filter_map(|step| {
            let (title,command)=if let Some(command)=step.as_str() { ("",command) } else { (step.get("title").and_then(Value::as_str).unwrap_or(""),step.get("command").and_then(Value::as_str).unwrap_or("")) };
            if command.trim().is_empty() { None } else { Some(json!({"title":truncate(title,120),"command":truncate(command,500)})) }
        }).take(20).collect::<Vec<_>>();
        json!({
            "id": workflow.get("id").and_then(Value::as_str).filter(|v|!v.is_empty()).map(|v|truncate(v,64)).unwrap_or_else(||Uuid::new_v4().to_string()),
            "name": truncate(workflow.get("name").and_then(Value::as_str).unwrap_or(""),80),
            "cli": if workflow.get("cli").and_then(Value::as_str)==Some("codex") {"codex"} else {"claude"},
            "steps": steps,
        })
    }).collect())
}

fn parse_repo(input: &str) -> Option<String> {
    let mut repo = input
        .trim()
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .to_owned();
    if let Some(index) = repo.find("github.com") {
        repo = repo[index + "github.com".len()..]
            .trim_start_matches([':', '/'])
            .to_owned();
    }
    let pieces = repo.split('/').collect::<Vec<_>>();
    if pieces.len() != 2
        || pieces.iter().any(|piece| {
            piece.is_empty()
                || !piece
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c))
        })
    {
        return None;
    }
    Some(repo)
}

fn summarize_snapshots(value: Value, count_key: &str) -> Value {
    let mut out = Map::new();
    for (id, snapshot) in value.as_object().into_iter().flatten() {
        let count = if count_key == "open" {
            snapshot.get("prs")
        } else {
            snapshot.get("items")
        }
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
        out.insert(
            id.clone(),
            json!({count_key:count,"lastSynced":snapshot["lastSynced"],"error":snapshot["error"]}),
        );
    }
    Value::Object(out)
}

fn required_string<'a>(body: &'a Value, key: &str, error: &str) -> Result<&'a str, ApiError> {
    body.get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ApiError::bad_request(error))
}
fn truncate(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}
fn empty_pr_snapshot() -> Value {
    json!({"prs":[],"lastSynced":null,"error":null})
}
