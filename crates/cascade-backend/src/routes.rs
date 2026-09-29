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

use crate::{error::ApiError, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

pub async fn health(State(state): State<AppState>) -> impl IntoResponse {
    Json(json!({
        "service": "cascade",
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
    // Every field present is applied; a body naming none of them is a mistake, not a no-op.
    let pinned = match body.get("pinned") {
        Some(value) => Some(
            value
                .as_bool()
                .ok_or_else(|| ApiError::bad_request("pinned must be a boolean"))?,
        ),
        None => None,
    };
    let adopt = match body.get("standalone") {
        Some(value) if value.as_bool() == Some(false) => true,
        Some(_) => return Err(ApiError::bad_request("standalone can only be cleared")),
        None => false,
    };
    let title = match body.get("title") {
        Some(value) => Some(
            value
                .as_str()
                .ok_or_else(|| ApiError::bad_request("title must be a string"))?,
        ),
        None => None,
    };
    if pinned.is_none() && !adopt && title.is_none() {
        return Err(ApiError::bad_request("title required"));
    }
    let mut saved = Value::Null;
    if let Some(pinned) = pinned {
        saved = state.db.pin_tab(id, pinned)?;
    }
    if adopt {
        saved = state.db.adopt_tab(id)?;
    }
    if let Some(title) = title {
        saved = state.db.rename_tab(id, title)?;
    }
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
        "name",
        "forkFrom",
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
        // No agent at all, a plain shell, or one the registry knows.
        if !cli.is_empty() && crate::agents::Agent::of(cli).is_none() {
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
pub struct PathQuery {
    path: Option<String>,
    url: Option<String>,
    refresh: Option<String>,
}

pub async fn detect_repo(Query(query): Query<PathQuery>) -> ApiResult<Value> {
    let path = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = std::path::PathBuf::from(&path);
    let ide = tokio::task::spawn_blocking(move || crate::local::detect_ide(&root))
        .await
        .unwrap_or_default();
    Ok(Json(json!({
        "repo": crate::github::remote_repo(&path).await.unwrap_or_default(),
        "ide": ide,
    })))
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

#[derive(Default, Deserialize)]
pub struct PollQuery {
    scope: Option<String>,
}

pub async fn poll(
    State(app): State<AppState>,
    Query(query): Query<PollQuery>,
) -> ApiResult<Value> {
    let (prs, jira) = poll_targets(query.scope.as_deref());
    if prs {
        app.poller.sync_all(&app).await;
    }
    if jira {
        app.poller.sync_all_jira(&app).await;
    }
    Ok(Json(json!({"ok":true})))
}

/// Which syncs a poll runs, as (pull requests, Jira): `prs` or `jira` narrows it to one, and no
/// scope (or any other value) runs both, as a poll always did.
fn poll_targets(scope: Option<&str>) -> (bool, bool) {
    let scope = scope.unwrap_or_default();
    (scope != "jira", scope != "prs")
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

/// A live issue search (never snapshotted) over `repos`, or with `allProjects` over every project
/// repo that lists its issues: `#123` or `123` looks one issue up in each repo, anything else is a
/// GitHub search. With `allProjects` and no such repo, the result is empty rather than an error.
pub async fn issues_search(
    State(app): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let query = body.get("query").and_then(Value::as_str).unwrap_or("").trim();
    if query.is_empty() {
        return Err(ApiError::bad_request("query is required"));
    }
    let all_projects = body.get("allProjects").and_then(Value::as_bool).unwrap_or(false);
    let mut repos: Vec<String> = if all_projects {
        app.db
            .projects()?
            .iter()
            .filter(|project| crate::issues::lists_issues(project))
            .filter_map(|project| project["repo"].as_str().map(str::to_ascii_lowercase))
            .collect()
    } else {
        body.get("repos")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter_map(crate::github::parse_repo)
            .map(|repo| repo.to_ascii_lowercase())
            .collect()
    };
    // GitHub repo names ignore case, so `Owner/Repo` and `owner/repo` are searched once.
    repos.sort();
    repos.dedup();
    if repos.is_empty() {
        if all_projects {
            return Ok(Json(json!({"items":[],"jql":query,"lastSynced":null,"error":null})));
        }
        return Err(ApiError::bad_request("repos is required"));
    }
    let limit = body
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(50)
        .clamp(1, 200) as usize;
    let mut items = crate::issues::search_repos(&repos, query, limit)
        .await
        .map_err(ApiError::internal)?;
    let login = crate::github::cached_login().await;
    crate::issues::mark_mine(&mut items, login.as_deref());
    // Without a login nothing can be marked the user's: say so rather than show all as others'.
    let warning = login
        .is_none()
        .then_some("GitHub didn’t say who is signed in, so no issue could be marked yours. Run gh auth login.");
    Ok(Json(
        json!({"items":items,"jql":query,"lastSynced":chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis,true),"error":null,"warning":warning}),
    ))
}

pub async fn issue_lookup(Query(query): Query<PathQuery>) -> ApiResult<Value> {
    Ok(Json(match query.url {
        Some(url) => crate::issues::lookup(&url).await.unwrap_or(Value::Null),
        None => Value::Null,
    }))
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
    // `standalone`: a tab opened on purpose beside a session with the same page; never the session's own.
    let valid_fields = tab.iter().all(|(key, value)| {
        (FIELDS.contains(&key.as_str()) && value.is_string()) || (key == "standalone" && value.is_boolean())
    });
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
        || !kind.is_some_and(|kind| ["github", "issue", "jira", "web"].contains(&kind))
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
        "workspace",
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
    // Scripts and patterns are kept as typed: their whitespace and line breaks are content.
    for key in ["worktreeSetup", "worktreeInclude"] {
        if let Some(value) = body.get(key) {
            patch.insert(key.into(), Value::String(value.as_str().unwrap_or_default().into()));
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
    if let Some(value) = body.get("forwardWebhooks") {
        let forward = value
            .as_bool()
            .ok_or_else(|| ApiError::bad_request("forwardWebhooks must be true or false"))?;
        patch.insert("forwardWebhooks".into(), Value::Bool(forward));
    }
    if let Some(value) = body.get("issuesEnabled") {
        let enabled = value
            .as_bool()
            .ok_or_else(|| ApiError::bad_request("issuesEnabled must be true or false"))?;
        patch.insert("issuesEnabled".into(), Value::Bool(enabled));
    }
    if let Some(value) = body.get("boardEnabled") {
        let enabled = value
            .as_bool()
            .ok_or_else(|| ApiError::bad_request("boardEnabled must be true or false"))?;
        patch.insert("boardEnabled".into(), Value::Bool(enabled));
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
    Ok(patch)
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
fn empty_pr_snapshot() -> Value {
    json!({"prs":[],"lastSynced":null,"error":null})
}

#[cfg(test)]
mod tests {
    use super::poll_targets;

    #[test]
    fn poll_scope_narrows_to_one_sync_and_defaults_to_both() {
        assert_eq!(poll_targets(Some("prs")), (true, false));
        assert_eq!(poll_targets(Some("jira")), (false, true));
        assert_eq!(poll_targets(None), (true, true));
        assert_eq!(poll_targets(Some("")), (true, true));
    }
}
