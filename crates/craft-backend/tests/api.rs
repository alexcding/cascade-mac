use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use craft_backend::{build_app, AppState, Database};
use tempfile::TempDir;
use tower::ServiceExt;

fn app() -> (axum::Router, TempDir) {
    let directory = tempfile::tempdir().unwrap();
    let db = Database::open(directory.path()).unwrap();
    let state = AppState::new(db, Some("test-instance".into()));
    (build_app(state), directory)
}

async fn json_request(
    app: &axum::Router,
    method: &str,
    path: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn health_identifies_the_rust_backend() {
    let (app, _directory) = app();
    let (status, value) = json_request(&app, "GET", "/api/backend/health", Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["service"], "craft");
    assert_eq!(value["runtime"], "rust");
    assert_eq!(value["instanceId"], "test-instance");
}

#[tokio::test]
async fn project_pr_snapshots_include_refresh_metadata_for_every_scope() {
    let directory = tempfile::tempdir().unwrap();
    let db = Database::open(directory.path()).unwrap();
    let project = db
        .add_project(
            json!({"name":"PR contract","repo":"example/repo"})
                .as_object()
                .unwrap(),
        )
        .unwrap();
    let id = project["id"].as_str().unwrap();
    let snapshot = json!({"prs":[{"number":1,"title":"Cached PR"}],
        "lastSynced":chrono::Utc::now().to_rfc3339(),"error":"Previous sync failed"});
    db.set_pr_snapshot(id, &snapshot).unwrap();
    for scope in ["merged", "closed", "all"] {
        db.set_pr_scope_snapshot(&project, scope, &snapshot)
            .unwrap();
    }
    let app = build_app(AppState::new(db, None));
    for scope in ["open", "merged", "closed", "all"] {
        let path = format!("/api/projects/{id}/prs?state={scope}&snapshot=1");
        let (status, value) = json_request(&app, "GET", &path, Value::Null).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            value["refreshing"], false,
            "{scope}: missing refresh metadata"
        );
        assert_eq!(value["prs"], snapshot["prs"]);
        assert_eq!(value["error"], snapshot["error"]);
    }
    let (_, legacy) =
        json_request(&app, "GET", &format!("/api/projects/{id}/prs"), Value::Null).await;
    assert!(legacy.is_array());
    assert_eq!(legacy[0]["number"], 1);
    assert_eq!(legacy[1]["error"], snapshot["error"]);
}

#[tokio::test]
async fn project_pr_snapshot_refresh_flag_clears_before_completion_event() {
    let directory = tempfile::tempdir().unwrap();
    let db = Database::open(directory.path()).unwrap();
    // Empty repositories complete without invoking GitHub or credentials.
    let project = db
        .add_project(
            json!({"name":"Empty repository","repo":""})
                .as_object()
                .unwrap(),
        )
        .unwrap();
    let id = project["id"].as_str().unwrap();
    let state = AppState::new(db, None);
    let mut events = state.events.subscribe();
    let app = build_app(state);
    let path = format!("/api/projects/{id}/prs?snapshot=1");
    let (_, initial) = json_request(&app, "GET", &path, Value::Null).await;
    assert_eq!(initial["prs"], json!([]));
    assert_eq!(initial["refreshing"], true);
    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(event, json!({"type":"sync","scope":"prs","projectId":id}));
    let (_, completed) = json_request(&app, "GET", &path, Value::Null).await;
    assert_eq!(completed["refreshing"], false);
    assert!(completed["lastSynced"].is_string());
    let (_, forced) = json_request(&app, "GET", &(path + "&refresh=1"), Value::Null).await;
    assert_eq!(forced["refreshing"], true);
}

#[tokio::test]
async fn project_task_and_dashboard_contracts_round_trip() {
    let (app, _directory) = app();
    let (_, project) = json_request(&app, "POST", "/api/projects", json!({"name":"Native","repo":"openai/codex","workspace":"/tmp/native","jiraProjectKey":"task"})).await;
    assert_eq!(project["name"], "Native");
    assert_eq!(project["repo"], "openai/codex");
    assert_eq!(project["jiraProjectKey"], "TASK");
    let id = project["id"].as_str().unwrap();

    let (status, _) = json_request(&app, "POST", "/api/tasks", json!({"id":"session-1","projectId":id,"workspace":"/tmp/native","worktree":"/tmp/native.worktrees/task"})).await;
    assert_eq!(status, StatusCode::OK);
    let (_, tasks) = json_request(&app, "GET", "/api/tasks", Value::Null).await;
    assert_eq!(tasks[0]["id"], "session-1");
    assert_eq!(tasks[0]["pinned"], false);

    let (_, dashboard) = json_request(&app, "GET", "/api/dashboard", Value::Null).await;
    assert_eq!(dashboard[0]["id"], id);
    assert_eq!(dashboard[0]["prs"], json!([]));
}

#[tokio::test]
async fn settings_and_tabs_preserve_existing_json_shapes() {
    let (app, _directory) = app();
    let (status, _) =
        json_request(&app, "PUT", "/api/settings/theme", json!({"value":"dark"})).await;
    assert_eq!(status, StatusCode::OK);
    let (_, settings) = json_request(&app, "GET", "/api/settings", Value::Null).await;
    assert_eq!(settings["theme"], "dark");

    let (_, tabs) = json_request(&app, "POST", "/api/tabs", json!({"url":"https://github.com/openai/codex/pull/1","kind":"github","title":"PR 1","repo":"openai/codex","branch":"feature","category":"review","login":"octocat"})).await;
    assert_eq!(tabs["active"], tabs["tabs"][0]["id"]);
    assert_eq!(tabs["tabs"][0]["url"], "https://github.com/openai/codex/pull/1");
    assert_eq!(tabs["tabs"][0]["paneView"], "term");
    // The same page opens again as a second tab: tabs are keyed by id, not URL.
    let (_, again) = json_request(&app, "POST", "/api/tabs", json!({"url":"https://github.com/openai/codex/pull/1","kind":"github"})).await;
    assert_eq!(again["tabs"].as_array().map(Vec::len), Some(2));
    assert_ne!(again["tabs"][0]["id"], again["tabs"][1]["id"]);
    assert_eq!(again["active"], again["tabs"][1]["id"]);
    // A title change touches one row and leaves the other tab alone.
    let id = again["tabs"][1]["id"].as_str().unwrap().to_owned();
    let (status, renamed) = json_request(&app, "PATCH", "/api/tabs", json!({"id": id, "title": "Loaded"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(renamed["tabs"][1]["title"], "Loaded");
    assert_eq!(renamed["tabs"][0]["title"], "PR 1");
    let first = renamed["tabs"][0]["id"].as_str().unwrap().to_owned();
    let (status, reordered) = json_request(&app, "PATCH", "/api/tabs", json!({"order": [id, "missing", &first, id]})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(reordered["tabs"][0]["id"], id);
    assert_eq!(reordered["tabs"][1]["id"], first);
    // Pinning is its own one-row update; every tab reports the flag.
    assert_eq!(reordered["tabs"][0]["pinned"], false);
    let (status, pinned) = json_request(&app, "PATCH", "/api/tabs", json!({"id": id, "pinned": true})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(pinned["tabs"][0]["pinned"], true);
    assert_eq!(pinned["tabs"][1]["pinned"], false);
    let (status, _) = json_request(&app, "PATCH", "/api/tabs", json!({"id": id, "pinned": "yes"})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn invalid_project_and_tab_inputs_match_node_errors() {
    let (app, _directory) = app();
    let (status, value) = json_request(
        &app,
        "POST",
        "/api/projects",
        json!({"name":"","repo":"bad"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(value["error"], "name required");
    let (status, _) = json_request(
        &app,
        "POST",
        "/api/tabs",
        json!({"url":"file:///etc/passwd","kind":"web"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
