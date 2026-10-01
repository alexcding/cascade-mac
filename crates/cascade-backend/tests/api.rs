use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use cascade_backend::{build_app, AppState, Database};
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
    assert_eq!(value["service"], "cascade");
    assert_eq!(value["runtime"], "rust");
    assert_eq!(value["instanceId"], "test-instance");
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
async fn tabs_are_served_read_only_for_the_one_time_import() {
    let (app, _directory) = app();
    let (status, tabs) = json_request(&app, "GET", "/api/tabs", Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(tabs, json!({"tabs":[],"active":null}));
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/tabs")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"url":"https://example.test","kind":"web"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn invalid_project_inputs_match_node_errors() {
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
}

#[tokio::test]
async fn automations_round_trip_and_reject_invalid_pipelines() {
    let (app, _directory) = app();
    let (status, catalog) = json_request(&app, "GET", "/api/automations/catalog", Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert!(catalog["triggers"].as_array().is_some_and(|v| v.iter().any(|t| t["type"] == "pr.merged")));
    assert!(catalog["actions"].as_array().is_some_and(|v| v.iter().any(|t| t["type"] == "github.approve")));

    let pipeline = json!({"name":"Approve alice","mode":"live",
        "trigger":{"types":["pr.opened"],"projects":[]},
        "steps":[{"kind":"filter","type":"pr.author","params":{"mode":"in","users":["alice"]}},
                 {"kind":"action","type":"github.approve","params":{}}]});
    let (status, created) = json_request(&app, "POST", "/api/automations", pipeline).await;
    assert_eq!(status, StatusCode::OK, "{created}");
    let id = created["id"].as_str().unwrap().to_owned();
    assert!(created["armedAt"].is_string(), "leaving off arms the pipeline");
    assert!(created["steps"][0]["id"].as_str().is_some_and(|v| !v.is_empty()));

    let mut changed = created.clone();
    changed["mode"] = json!("off");
    let (status, updated) = json_request(&app, "PUT", &format!("/api/automations/{id}"), changed).await;
    assert_eq!(status, StatusCode::OK);
    assert!(updated["armedAt"].is_null());

    let (_, list) = json_request(&app, "GET", "/api/automations", Value::Null).await;
    assert_eq!(list.as_array().map(Vec::len), Some(1));

    for bad in [
        json!({"name":"No trigger","trigger":{"types":[]}}),
        json!({"name":"Bad regex","trigger":{"types":["pr.opened"]},"steps":[{"kind":"filter","type":"pr.title","params":{"regex":"("}}]}),
        json!({"name":"Unknown","trigger":{"types":["pr.opened"]},"steps":[{"kind":"action","type":"github.nuke"}]}),
        json!({"name":"Jira without JQL","trigger":{"types":["jira.entered"]}}),
    ] {
        let (status, _) = json_request(&app, "POST", "/api/automations", bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    let (status, _) = json_request(&app, "DELETE", &format!("/api/automations/{id}"), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    let (_, list) = json_request(&app, "GET", "/api/automations", Value::Null).await;
    assert_eq!(list, json!([]));
}

#[tokio::test]
async fn dry_run_plans_against_a_synced_pr_without_acting() {
    std::env::set_var("CASCADE_AUTOMATION_LOGIN", "me");
    let directory = tempfile::tempdir().unwrap();
    let db = Database::open(directory.path()).unwrap();
    let project = db
        .add_project(json!({"name":"Cascade","repo":"example/cascade"}).as_object().unwrap()).await
        .unwrap();
    let id = project.id.clone();
    let snapshot = serde_json::from_value(json!({"prs":[
        {"number":7,"title":"Bump deps","author":{"login":"alice"},"baseRefName":"main","isDraft":false,"headRefOid":"a1b2c3d4e5",
         "ci":{"status":"completed","conclusion":"success"},"labels":[{"name":"deps"}],"repo":"example/cascade"},
        {"number":8,"title":"Mine","author":{"login":"me"},"baseRefName":"main","isDraft":false,"headRefOid":"f6e5d4","ci":null,"repo":"example/cascade"},
        {"number":9,"title":"Approved","author":{"login":"alice"},"baseRefName":"main","isDraft":false,"headRefOid":"9a8b7c6d5e",
         "myReview":{"state":"APPROVED","commit":"9a8b7c6d5e"},
         "ci":{"status":"completed","conclusion":"success"},"labels":[],"repo":"example/cascade"}
    ],"lastSynced":chrono::Utc::now().to_rfc3339(),"error":null})).unwrap();
    db.set_pr_snapshot(&id, &snapshot).await.unwrap();
    let app = build_app(AppState::new(db, None));
    let pipeline = json!({"name":"Approve alice","mode":"off",
        "trigger":{"types":["pr.ci_passed"],"projects":[id]},
        "steps":[{"kind":"filter","type":"pr.author","params":{"mode":"in","users":"alice, bob"}},
                 {"kind":"filter","type":"pr.ci","params":{"is":"passing"}},
                 {"kind":"action","type":"github.approve","params":{"body":"Auto-approved {{pr.title}}"}},
                 {"kind":"action","type":"github.add_label","params":{"labels":["auto-approved"]}}]});

    let (_, samples) = json_request(&app, "GET", &format!("/api/automations/samples?kind=pr&projects={id}"), Value::Null).await;
    assert_eq!(samples.as_array().map(Vec::len), Some(3));

    let (status, trace) = json_request(&app, "POST", "/api/automations/dry-run",
        json!({"automation":pipeline,"sample":{"kind":"pr","projectId":id,"number":7}})).await;
    assert_eq!(status, StatusCode::OK, "{trace}");
    assert_eq!(trace["mode"], "dry");
    assert_eq!(trace["triggerMatched"], true);
    assert_eq!(trace["status"], "completed");
    let statuses: Vec<&str> = trace["steps"].as_array().unwrap().iter().map(|s| s["status"].as_str().unwrap()).collect();
    assert_eq!(statuses, vec!["passed", "passed", "planned", "planned"]);
    assert_eq!(trace["steps"][2]["commands"][0], "gh pr review 7 -R example/cascade --approve -b 'Auto-approved Bump deps'");
    assert_eq!(trace["steps"][3]["commands"][0], "gh pr edit 7 -R example/cascade --add-label auto-approved");

    // Your own PR stops at the author filter; nothing after it is planned.
    let (_, trace) = json_request(&app, "POST", "/api/automations/dry-run",
        json!({"automation":pipeline,"sample":{"kind":"pr","projectId":id,"number":8}})).await;
    assert_eq!(trace["status"], "filtered");
    let statuses: Vec<&str> = trace["steps"].as_array().unwrap().iter().map(|s| s["status"].as_str().unwrap()).collect();
    assert_eq!(statuses, vec!["failed", "skipped", "skipped", "skipped"]);

    // Already approved at its head commit: the approval is not sent again; the rest still runs.
    let (_, trace) = json_request(&app, "POST", "/api/automations/dry-run",
        json!({"automation":pipeline,"sample":{"kind":"pr","projectId":id,"number":9}})).await;
    let statuses: Vec<&str> = trace["steps"].as_array().unwrap().iter().map(|s| s["status"].as_str().unwrap()).collect();
    assert_eq!(statuses, vec!["passed", "passed", "skipped", "planned"], "{trace}");
    assert_eq!(trace["steps"][2]["detail"], "you already approved 9a8b7c6");

    // Dry runs are never recorded.
    let (_, runs) = json_request(&app, "GET", "/api/automations/runs", Value::Null).await;
    assert_eq!(runs, json!([]));
}

#[tokio::test]
async fn project_webhook_forwarding_can_be_turned_off_and_on() {
    let (app, _dir) = app();
    let (status, created) = json_request(&app, "POST", "/api/projects",
        json!({"name":"Quiet","repo":"o/r","forwardWebhooks":false})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(created["forwardWebhooks"], false);
    let path = format!("/api/projects/{}", created["id"].as_str().unwrap());
    let (_, updated) = json_request(&app, "PUT", &path, json!({"forwardWebhooks":true})).await;
    assert_eq!(updated["forwardWebhooks"], true);
    let (status, _) = json_request(&app, "PUT", &path, json!({"forwardWebhooks":"no"})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (_, unchanged) = json_request(&app, "GET", &path, Value::Null).await;
    assert_eq!(unchanged["forwardWebhooks"], true);
}

async fn post_hook(app: &axum::Router, path: &str, body: Value) -> StatusCode {
    let request = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    app.clone().oneshot(request).await.unwrap().status()
}

/// The hook last kept for `run`, waited for: the relay writes it off the request.
async fn last_hook_type(app: &axum::Router, run: &str, expected: &str) -> Value {
    let mut kept = Value::Null;
    for _ in 0..100 {
        let (_, value) = json_request(app, "GET", &format!("/api/agent/last-hook?runId={run}"), Value::Null).await;
        kept = value["event"]["type"].clone();
        if kept == expected {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    kept
}

#[tokio::test]
async fn a_stop_with_a_background_agent_running_keeps_the_turn_going() {
    let (app, _directory) = app();
    let hook = |kind: &str| format!("/api/hooks/{kind}?cli=claude&runId=pty1-1");
    let agent = json!({"id":"a1","type":"subagent","status":"running","description":"Review","agent_type":"general-purpose"});
    let shell = json!({"id":"b1","type":"shell","status":"running","description":"Dev server","command":"npm run dev"});

    assert_eq!(post_hook(&app, &hook("turn-start"), json!({"session_id":"s1"})).await, StatusCode::NO_CONTENT);
    assert_eq!(last_hook_type(&app, "pty1-1", "agent-turn-start").await, "agent-turn-start");

    let held = json!({"session_id":"s1","hook_event_name":"Stop","background_tasks":[shell, agent]});
    assert_eq!(post_hook(&app, &hook("turn-done"), held).await, StatusCode::NO_CONTENT);
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(last_hook_type(&app, "pty1-1", "agent-turn-start").await, "agent-turn-start");

    // The agent has reported back; the dev server running on does not hold the turn open.
    let done = json!({"session_id":"s1","hook_event_name":"Stop","background_tasks":[shell]});
    assert_eq!(post_hook(&app, &hook("turn-done"), done).await, StatusCode::NO_CONTENT);
    assert_eq!(last_hook_type(&app, "pty1-1", "agent-turn-done").await, "agent-turn-done");
}
