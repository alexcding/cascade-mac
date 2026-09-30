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

use crate::{error::ApiError, AppState};
use crate::{Project, Session};

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
    Ok(Json(state.db.config().await?))
}

pub async fn set_config(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let object = body
        .as_object()
        .ok_or_else(|| ApiError::bad_request("JSON object required"))?;
    state.db.set_config(object).await?;
    for key in object.keys() {
        if let Some(id) = key.strip_prefix("board_query_") {
            state.poller.invalidate(id).await;
            state.db.invalidate_snapshots(id).await?;
        }
    }
    state.publish(crate::Event::Config);
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

/// Read only, for one release: the app adopts what an earlier version left here, once.
pub async fn get_settings(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(state.db.settings().await?))
}

pub async fn get_tabs(State(state): State<AppState>) -> ApiResult<Value> {
    Ok(Json(state.db.tabs().await?))
}

pub async fn get_tasks(State(state): State<AppState>) -> ApiResult<Vec<Session>> {
    Ok(Json(state.db.tasks().await?))
}

pub async fn upsert_task(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    const REQUIRED: &str = "id, projectId, workspace, worktree required";
    let session: Session =
        serde_json::from_value(body).map_err(|_| ApiError::bad_request(REQUIRED))?;
    if !state.db.upsert_task(&session).await? {
        return Err(ApiError::bad_request(REQUIRED));
    }
    state.publish(crate::Event::Tasks);
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
        state.db.delete_task(&id).await?;
    }
    state.publish(crate::Event::Tasks);
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
    if !state.db.pin_task(&id, pinned).await? {
        return Err(ApiError::not_found("Session not found"));
    }
    state.publish(crate::Event::Tasks);
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
    if !state.db.patch_task(&id, patch).await? {
        return Err(ApiError::not_found("Session not found"));
    }
    state.publish(crate::Event::Tasks);
    Ok(Json(json!({ "ok": true })))
}

/// The session's conversation as chat turns, with the CLI's hook install beside it (`hooks`):
/// without it the chat cannot tell a working agent from one at its prompt, and without the
/// current permission hook approvals stay in the terminal.
pub async fn agent_transcript(Query(query): Query<crate::agents::TranscriptQuery>) -> Json<Value> {
    let found = tokio::task::spawn_blocking(move || {
        let (agent, mut found) = crate::agents::transcript(&query)?;
        found["hooks"] = json!(crate::integrations::hook_status_for(agent));
        Some(found)
    })
    .await
    .ok()
    .flatten();
    Json(found.unwrap_or_else(|| json!({"revision": "", "turns": []})))
}

pub async fn get_projects(State(state): State<AppState>) -> ApiResult<Vec<Project>> {
    Ok(Json(state.db.projects().await?))
}

pub async fn get_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Project> {
    state
        .db
        .project(&id).await?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("Not found"))
}

pub async fn create_project(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Project> {
    let patch = sanitize_project_patch(&body)?;
    if patch
        .get("name")
        .and_then(Value::as_str)
        .is_none_or(str::is_empty)
    {
        return Err(ApiError::bad_request("name required"));
    }
    let project = state.db.add_project(&patch).await?;
    state.publish(crate::Event::Sync { scope: None, project_id: Some(project.id.clone()) });
    Ok(Json(project))
}

pub async fn update_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> ApiResult<Project> {
    let patch = sanitize_project_patch(&body)?;
    let project = state
        .db
        .update_project(&id, &patch).await?
        .ok_or_else(|| ApiError::not_found("Not found"))?;
    if !patch
        .keys()
        .all(|key| key == "runScheme" || key == "runSim")
    {
        state.poller.invalidate(&id).await;
        state.db.invalidate_snapshots(&id).await?;
        state.publish(crate::Event::Sync { scope: None, project_id: Some(id.to_string()) });
    }
    Ok(Json(project))
}

pub async fn delete_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Value> {
    state.poller.invalidate(&id).await;
    state.db.delete_project(&id).await?;
    state.publish(crate::Event::Sync { scope: None, project_id: Some(id.to_string()) });
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
        crate::github::forget_login();
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
        .project(&id).await?
        .ok_or_else(|| ApiError::not_found("Not found"))?;
    let key = format!("board:{id}");
    if query.refresh.is_some() {
        app.poller.sync_board(&app, &project).await
    } else if app.db.jira_snapshot(&key).await?.as_ref().is_none_or(|snapshot| {
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
    Ok(Json(app.db.jira_snapshot(&key).await?.unwrap_or_else(||json!({"items":[],"jql":"","lastSynced":null,"error":null,"sprint":null,"query":"","columns":null}))))
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
            .projects().await?
            .iter()
            .filter(|project| crate::issues::lists_issues(project))
            .map(|project| project.repo.to_ascii_lowercase())
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
    let items = crate::jira::search_jira(jql, limit)
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
    crate::jira::transition(&key, transition)
        .await
        .map_err(ApiError::internal)?;
    let payload = json!({"key":key,"transition":transition,"trigger":"manual"});
    if let Ok(event) = app.db.add_event("jira_transitioned", &payload).await {
        app.publish(crate::Event::Activity { event })
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
    crate::jira::assign(&key, assignee)
        .await
        .map_err(ApiError::internal)?;
    let payload = json!({"key":key,"assignee":if assignee.is_empty(){"(unassigned)"}else{assignee},"trigger":"manual"});
    if let Ok(event) = app.db.add_event("jira_assigned", &payload).await {
        app.publish(crate::Event::Activity { event })
    }
    Ok(Json(json!({"ok":true})))
}

pub async fn prs_tray(State(state): State<AppState>) -> ApiResult<Value> {
    let mut items = Vec::new();
    for project in state.db.projects().await? {
        let snapshot = state
            .db
            .pr_snapshot(&project.id, "open", None).await?
            .unwrap_or_default();
        for mut pr in snapshot.prs {
            let Some(object) = pr.as_object_mut() else {
                continue;
            };
            object.insert("projectId".into(), json!(project.id));
            object.insert("projectName".into(), json!(project.name));
            if object.get("category").and_then(Value::as_str) == Some("review") {
                let repo = object.get("repo").and_then(Value::as_str).unwrap_or("");
                let number = object
                    .get("number")
                    .and_then(Value::as_i64)
                    .unwrap_or_default();
                let stored = state.db.review_state(&format!("{repo}#{number}")).await?;
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
    state.db.mark_review_viewed(&format!("{repo}#{number}")).await?;
    state.publish(crate::Event::Reviews);
    Ok(Json(json!({ "ok": true })))
}

pub async fn dashboard(State(state): State<AppState>) -> ApiResult<Value> {
    let mut result = Vec::new();
    for project in state.db.projects().await? {
        let snapshot = state
            .db
            .pr_snapshot(&project.id, "open", None).await?
            .unwrap_or_default();
        // The project's own fields, with its snapshot beside them: one row of the dashboard.
        let mut row = project.to_value();
        let object = row.as_object_mut().expect("a project serializes to an object");
        object.insert("prs".into(), Value::Array(snapshot.prs));
        object.insert("lastSynced".into(), json!(snapshot.last_synced));
        object.insert("syncError".into(), json!(snapshot.error));
        result.push(row);
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
    Ok(Json(state.db.links(query.project.as_deref()).await?))
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
    ).await?;
    Ok(Json(json!({ "ok": true })))
}

pub async fn delete_link(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Value> {
    state.db.delete_link(&id).await?;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Default, Deserialize)]
pub struct LogsQuery {
    category: Option<String>,
    level: Option<String>,
    limit: Option<i64>,
}

pub async fn get_events(State(state): State<AppState>) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.query_logs(Some("event"), None, 100).await?))
}
pub async fn get_logs(
    State(state): State<AppState>,
    Query(query): Query<LogsQuery>,
) -> ApiResult<Vec<Value>> {
    Ok(Json(state.db.query_logs(
        query.category.as_deref(),
        query.level.as_deref(),
        query.limit.unwrap_or(200),
    ).await?))
}
pub async fn log_categories(State(state): State<AppState>) -> ApiResult<Vec<String>> {
    Ok(Json(state.db.log_categories().await?))
}
pub async fn clear_logs(
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    state
        .db
        .clear_logs(body.get("category").and_then(Value::as_str)).await?;
    Ok(Json(json!({ "ok": true })))
}

pub async fn inspect_db(State(state): State<AppState>) -> ApiResult<Value> {
    let config = state.db.config().await?;
    let projects = state.db.projects().await?;
    let links = state.db.links(None).await?;
    let snapshots: Map<String, Value> = state
        .db
        .all_pr_snapshots().await?
        .into_iter()
        .map(|(id, snapshot)| {
            let summary = json!({"open": snapshot.prs.len(), "lastSynced": snapshot.last_synced, "error": snapshot.error});
            (id, summary)
        })
        .collect();
    let jira = summarize_snapshots(state.db.all_jira_snapshots().await?, "tickets");
    Ok(Json(json!({
        "config": config, "projects": projects,
        "counts": { "projects": projects.len(), "links": links.len(), "events": state.db.event_count().await? },
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
            // The subscriber lagged and missed events; a reload has it refetch rather than stay stale.
            Err(_) => Some(Ok(Event::default().data(
                crate::Event::lagged(),
            ))),
        }
    });
    Sse::new(initial.chain(events)).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
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

/// Each Jira snapshot as its item count under `count_key`, its stamp and its error.
fn summarize_snapshots(value: Value, count_key: &str) -> Value {
    let mut out = Map::new();
    for (id, snapshot) in value.as_object().into_iter().flatten() {
        let count = snapshot
            .get("items")
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
