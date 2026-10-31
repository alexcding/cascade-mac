//! The Simulator pane's routes, its frame socket, and the device tools through `POST /mcp`, on the
//! real router with the fake backend behind the manager. Synara's counterpart is
//! `wsDeviceHandlers.test.ts`.

use std::{sync::Arc, time::Duration};

use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
    Router,
};
use base64::Engine;
use cascade_chat::{contracts::base::ThreadId, AgentGateway};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tower::ServiceExt;

use super::fake::{FakeCall, FakeDeviceBackend, DEVICE_A, DEVICE_B};
use crate::{
    device::{
        backend::DeviceBackend,
        frame::decode_device_frame,
        manager::{DeviceManager, DeviceManagerOptions},
    },
    gateway::{CWD_HEADER, MCP_PATH, RUN_HEADER},
    AppState,
};

const OWNER: &str = "/work/session";

struct App {
    state: AppState,
    router: Router,
    backend: Arc<FakeDeviceBackend>,
    dir: tempfile::TempDir,
}

fn app_with(backend: Option<Arc<FakeDeviceBackend>>) -> App {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let backend = backend.unwrap_or_else(FakeDeviceBackend::new);
    let mut options = DeviceManagerOptions::new(backend.clone());
    options.attach_deadline = Duration::ZERO;
    state.device.install(&state, DeviceManager::new(options));
    state.device.set_proofs_dir(dir.path().join("proof"));
    let router = crate::build_app(state.clone());
    App { state, router, backend, dir }
}

async fn send(router: &Router, request: Request<Body>) -> (StatusCode, Value) {
    let response = router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

async fn post(router: &Router, path: &str, body: Value) -> (StatusCode, Value) {
    let request = Request::post(path).header("content-type", "application/json").body(Body::from(body.to_string())).unwrap();
    send(router, request).await
}

async fn until(what: &str, mut check: impl FnMut() -> bool) {
    for _ in 0..2_000 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    panic!("never observed: {what}");
}

fn events_of(receiver: &mut tokio::sync::broadcast::Receiver<Value>, kind: &str) -> Vec<Value> {
    let mut found = Vec::new();
    while let Ok(event) = receiver.try_recv() {
        if event["type"] == kind {
            found.push(event);
        }
    }
    found
}

#[tokio::test(start_paused = true)]
async fn the_pane_reads_its_state_and_drives_the_device_through_its_routes() {
    let app = app_with(None);
    let mut events = app.state.events.subscribe();

    let (status, state) = post(&app.router, "/api/device/state", json!({ "owner": "/work/session/" })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(state["owner"], OWNER, "a trailing slash names the same owner");
    assert_eq!(state["attachedDeviceUdid"], Value::Null);
    assert_eq!(state["availability"], json!({ "kind": "available" }));
    assert_eq!(state["devices"].as_array().unwrap().len(), 4);

    let (_, listed) = post(&app.router, "/api/device/list", json!({})).await;
    assert_eq!(listed["devices"], json!([]), "only booted devices without includeShutdown");
    let (_, listed) = post(&app.router, "/api/device/list", json!({ "includeShutdown": true })).await;
    assert_eq!(listed["devices"].as_array().unwrap().len(), 4);

    let (status, booted) = post(&app.router, "/api/device/boot", json!({ "udid": DEVICE_A })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(booted["kind"], "booted");
    assert_eq!(booted["device"]["bootSource"], "cascade");

    let (_, attached) = post(&app.router, "/api/device/attach", json!({ "owner": OWNER, "udid": DEVICE_A })).await;
    assert_eq!(attached["attachedDeviceUdid"], DEVICE_A);
    assert_eq!(attached["attachPhase"], "connecting");
    until("the stream", || app.backend.has_stream(DEVICE_A)).await;

    // The user's own input: sent as is, with no settle observation.
    let (status, _) = post(&app.router, "/api/device/tap", json!({ "udid": DEVICE_A, "x": 10, "y": 20 })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(app.backend.last_call(), Some(FakeCall::Tap { udid: DEVICE_A.into(), x: 10.0, y: 20.0, hold_ms: None }));
    assert_eq!(app.backend.count("describeUi"), 0);
    post(&app.router, "/api/device/tap", json!({ "udid": DEVICE_A, "label": "Continue" })).await;
    assert_eq!(app.backend.last_call(), Some(FakeCall::Tap { udid: DEVICE_A.into(), x: 196.0, y: 725.0, hold_ms: None }));
    let (status, _) = post(
        &app.router,
        "/api/device/swipe",
        json!({ "udid": DEVICE_A, "fromX": 200, "fromY": 600, "toX": 200, "toY": 200, "durationMs": 250 }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(matches!(app.backend.last_call(), Some(FakeCall::Swipe { gesture, .. }) if gesture.duration_ms == 250 && gesture.edge.is_none()));
    post(&app.router, "/api/device/type", json!({ "udid": DEVICE_A, "text": "hi" })).await;
    assert_eq!(app.backend.last_call(), Some(FakeCall::TypeText { udid: DEVICE_A.into(), text: "hi".into() }));
    let (status, _) =
        post(&app.router, "/api/device/key", json!({ "udid": DEVICE_A, "keyCode": 40, "modifiers": ["shift"], "direction": "down" })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(app.backend.count("keyEvent"), 1);
    post(&app.router, "/api/device/button", json!({ "udid": DEVICE_A, "button": "home" })).await;
    assert_eq!(app.backend.count("pressButton"), 1);

    // Refused before anything is sent.
    let (status, error) = post(&app.router, "/api/device/tap", json!({ "udid": "not a udid", "x": 1, "y": 1 })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(error["error"].is_string());
    let (status, _) = post(&app.router, "/api/device/tap", json!({ "udid": DEVICE_A, "x": -1, "y": 1 })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, error) = post(&app.router, "/api/device/tap", json!({ "udid": DEVICE_B, "x": 1, "y": 1 })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "a device that is not booted");
    assert!(error["error"].as_str().unwrap().contains("not booted"));

    let (_, detached) = post(&app.router, "/api/device/detach", json!({ "owner": OWNER })).await;
    assert_eq!(detached["attachedDeviceUdid"], Value::Null);
    let (status, _) = post(&app.router, "/api/device/shutdown", json!({ "udid": DEVICE_A })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(app.backend.udids_of("shutdown"), [DEVICE_A]);

    // The pane hears every change as a `device` event for its owner.
    tokio::time::sleep(Duration::from_millis(5)).await;
    let device_events = events_of(&mut events, "device");
    assert!(!device_events.is_empty());
    assert!(device_events.iter().all(|event| event["owner"] == OWNER && event["state"]["owner"] == OWNER));
    let versions: Vec<u64> = device_events.iter().map(|event| event["state"]["version"].as_u64().unwrap()).collect();
    assert!(versions.windows(2).all(|pair| pair[0] <= pair[1]), "{versions:?}");
}

#[tokio::test]
async fn the_frame_socket_streams_records_to_every_viewer_and_answers_a_resync() {
    let app = app_with(None);
    app.backend.boot(DEVICE_A).await.unwrap();

    let (status, body) = post(&app.router, "/api/device/frames", json!({ "owner": OWNER, "udid": DEVICE_A })).await;
    assert_eq!(status, StatusCode::OK);
    let path = body["socketPath"].as_str().unwrap().to_owned();
    let (_, again) = post(&app.router, "/api/device/frames", json!({ "owner": OWNER, "udid": DEVICE_A })).await;
    assert_eq!(again["socketPath"], path.as_str(), "one socket per device");

    // A viewer is a subscriber: connecting starts the stream.
    let mut viewer = tokio::net::UnixStream::connect(&path).await.unwrap();
    until("the stream", || app.backend.has_stream(DEVICE_A)).await;
    app.backend.emit_frame(DEVICE_A, false, true).unwrap();
    app.backend.emit_frame(DEVICE_A, true, false).unwrap();

    let config = tokio::time::timeout(Duration::from_secs(5), read_record(&mut viewer)).await.unwrap();
    let (header, _) = decode_device_frame(&config).unwrap();
    assert_eq!(header.device_id, DEVICE_A);
    assert!(header.codec_config);
    let keyframe = tokio::time::timeout(Duration::from_secs(5), read_record(&mut viewer)).await.unwrap();
    assert!(decode_device_frame(&keyframe).unwrap().0.keyframe);

    // A late viewer is primed with the cached codec config and keyframe.
    let mut late = tokio::net::UnixStream::connect(&path).await.unwrap();
    let primed = tokio::time::timeout(Duration::from_secs(5), read_record(&mut late)).await.unwrap();
    assert!(decode_device_frame(&primed).unwrap().0.codec_config);
    let primed = tokio::time::timeout(Duration::from_secs(5), read_record(&mut late)).await.unwrap();
    assert!(decode_device_frame(&primed).unwrap().0.keyframe);

    // A resync rebuilds the stream for a fresh keyframe.
    let attaches = app.backend.count("attachStream");
    viewer.write_all(b"{\"type\":\"device.frame.resync\"}\n").await.unwrap();
    until("the rebuilt stream", || app.backend.count("attachStream") > attaches && app.backend.has_stream(DEVICE_A)).await;

    // The last viewer leaving stops the encode.
    drop(viewer);
    drop(late);
    until("the stream to stop", || !app.backend.has_stream(DEVICE_A)).await;

    crate::stop_devices(&app.state).await;
    assert!(!std::path::Path::new(&path).exists());
}

#[tokio::test]
async fn off_a_mac_the_pane_is_told_the_platform_rather_than_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let router = crate::build_app(state);

    let (status, body) = post(&router, "/api/device/state", json!({ "owner": OWNER })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["availability"]["kind"], "unsupported-platform");
    assert_eq!(body["devices"], json!([]));
    let (status, body) = post(&router, "/api/device/list", json!({})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("requires macOS"));
}

/// One record off a frame socket, its length prefix stripped.
async fn read_record(viewer: &mut tokio::net::UnixStream) -> Vec<u8> {
    let mut length = [0u8; 4];
    viewer.read_exact(&mut length).await.unwrap();
    let mut record = vec![0u8; u32::from_le_bytes(length) as usize];
    viewer.read_exact(&mut record).await.unwrap();
    record
}

// ── Through the gateway ────────────────────────────────────────────────

async fn mcp(app: &App, token: &str, run: Option<&str>, cwd: Option<&str>, body: Value) -> Value {
    let mut request =
        Request::post(MCP_PATH).header("content-type", "application/json").header("authorization", format!("Bearer {token}"));
    if let Some(run) = run {
        request = request.header(RUN_HEADER, run);
    }
    if let Some(cwd) = cwd {
        request = request.header(CWD_HEADER, base64::engine::general_purpose::STANDARD.encode(cwd));
    }
    let (status, body) = send(&app.router, request.body(Body::from(body.to_string())).unwrap()).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

async fn call_tool(app: &App, token: &str, run: Option<&str>, cwd: Option<&str>, name: &str, arguments: Value) -> Value {
    let body = mcp(
        app,
        token,
        run,
        cwd,
        json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": name, "arguments": arguments } }),
    )
    .await;
    body["result"].clone()
}

fn first_json(result: &Value) -> Value {
    serde_json::from_str(result["content"][0]["text"].as_str().unwrap()).unwrap()
}

#[tokio::test(start_paused = true)]
async fn a_terminal_agent_lists_boots_launches_and_taps_through_the_gateway() {
    let app = app_with(None);
    app.state.gateway.configure(4321, app.dir.path()).unwrap();
    app.state.gateway.register_all();
    let token = std::fs::read_to_string(app.dir.path().join(".gateway-token")).unwrap();
    let (run, cwd) = (Some("run-7"), Some("/work/session"));
    let mut events = app.state.events.subscribe();

    let initialized = mcp(&app, &token, run, cwd, json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {} })).await;
    assert!(initialized["result"]["instructions"].as_str().unwrap().contains("call device_* directly"));
    let listed = mcp(&app, &token, run, cwd, json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" })).await;
    let names: Vec<&str> = listed["result"]["tools"].as_array().unwrap().iter().map(|tool| tool["name"].as_str().unwrap()).collect();
    assert_eq!(names.len(), 15, "{names:?}");
    assert!(names.iter().all(|name| name.starts_with("device_")));

    let devices = first_json(&call_tool(&app, &token, run, cwd, "device_list", json!({ "includeShutdown": true })).await);
    assert_eq!(devices["devices"].as_array().unwrap().len(), 4);

    let booted = first_json(&call_tool(&app, &token, run, cwd, "device_boot", json!({ "udid": DEVICE_A })).await);
    assert_eq!(booted["kind"], "booted");

    let launched = call_tool(&app, &token, run, cwd, "device_launch", json!({ "udid": DEVICE_A, "bundleId": "com.example.Demo" })).await;
    assert_eq!(launched["isError"], Value::Null, "{launched}");
    assert_eq!(first_json(&launched)["bundleId"], "com.example.Demo");

    let tapped = call_tool(&app, &token, run, cwd, "device_tap", json!({ "udid": DEVICE_A, "label": "Continue" })).await;
    assert_eq!(first_json(&tapped)["element"]["label"], "Continue");
    assert!(matches!(app.backend.last_call(), Some(FakeCall::DescribeUi(_))), "the screen is read after the tap");
    assert!(app.backend.calls().contains(&FakeCall::Tap { udid: DEVICE_A.into(), x: 196.0, y: 725.0, hold_ms: None }));

    // The terminal's folder owns the device: that session's pane is attached and asked to open.
    let state = app.state.device.manager().unwrap().owner_state(OWNER).await;
    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_A));
    tokio::time::sleep(Duration::from_millis(5)).await;
    let opened = events_of(&mut events, "device-open-pane");
    assert_eq!(opened, [json!({ "type": "device-open-pane", "owner": OWNER, "udid": DEVICE_A, "reason": "agent-launch" })]);

    let failed = call_tool(&app, &token, run, cwd, "device_tap", json!({ "udid": DEVICE_A })).await;
    assert_eq!(failed["isError"], true);
}

#[tokio::test(start_paused = true)]
async fn a_chat_is_offered_the_device_tools_and_drives_its_own_owner() {
    let app = app_with(None);
    app.state.gateway.configure(4321, app.dir.path()).unwrap();
    app.state.gateway.register_all();
    let token = app.state.gateway.connection(&ThreadId::new("thread-1")).unwrap().bearer_token;

    let listed = mcp(&app, &token, None, None, json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" })).await;
    let names: Vec<&str> = listed["result"]["tools"].as_array().unwrap().iter().map(|tool| tool["name"].as_str().unwrap()).collect();
    assert!(names.contains(&"device_list") && names.contains(&"device_tap"), "{names:?}");

    first_json(&call_tool(&app, &token, None, None, "device_boot", json!({ "udid": DEVICE_A })).await);
    // No chat engine here, so the thread's folder is unknown and it keys by its own id.
    let state = app.state.device.manager().unwrap().owner_state("chat:thread-1").await;
    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_A));
}

// ── Review fixes ───────────────────────────────────────────────────────

#[tokio::test]
async fn drops_a_viewer_that_sends_more_than_a_resync_line_without_a_newline() {
    let app = app_with(None);
    app.backend.boot(DEVICE_A).await.unwrap();
    let (_, body) = post(&app.router, "/api/device/frames", json!({ "owner": OWNER, "udid": DEVICE_A })).await;
    let mut viewer = tokio::net::UnixStream::connect(body["socketPath"].as_str().unwrap()).await.unwrap();

    viewer.write_all(&[b'x'; 4096]).await.unwrap();

    // The backend closes the connection instead of buffering the line without end.
    let mut rest = Vec::new();
    let read = tokio::time::timeout(Duration::from_secs(3), viewer.read_to_end(&mut rest)).await;
    assert!(read.is_ok(), "the connection was kept open");
}

#[tokio::test]
async fn makes_the_socket_folder_again_when_the_temporary_folder_was_cleaned() {
    let app = app_with(None);
    app.backend.boot(DEVICE_A).await.unwrap();
    let (_, body) = post(&app.router, "/api/device/frames", json!({ "owner": OWNER, "udid": DEVICE_A })).await;
    let first = std::path::PathBuf::from(body["socketPath"].as_str().unwrap());
    std::fs::remove_dir_all(first.parent().unwrap()).unwrap();

    let (status, body) = post(&app.router, "/api/device/frames", json!({ "owner": OWNER, "udid": DEVICE_B })).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    let second = body["socketPath"].as_str().unwrap().to_owned();
    tokio::net::UnixStream::connect(&second).await.unwrap();
    let (_, again) = post(&app.router, "/api/device/frames", json!({ "owner": OWNER, "udid": DEVICE_A })).await;
    tokio::net::UnixStream::connect(again["socketPath"].as_str().unwrap()).await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_deleted_chat_releases_the_device_its_own_owner_held() {
    let app = app_with(None);
    app.state.gateway.configure(4321, app.dir.path()).unwrap();
    app.state.gateway.register_all();
    let token = app.state.gateway.connection(&ThreadId::new("thread-1")).unwrap().bearer_token;
    first_json(&call_tool(&app, &token, None, None, "device_boot", json!({ "udid": DEVICE_A })).await);
    let manager = app.state.device.manager().unwrap().clone();
    assert_eq!(manager.owner_state("chat:thread-1").await.attached_device_udid.as_deref(), Some(DEVICE_A));

    crate::device::service::chat_removed(&app.state.device, &Arc::downgrade(&app.state.chat), &app.state.db, "thread-1").await;

    assert_eq!(manager.owner_state("chat:thread-1").await.attached_device_udid, None);
    // Cascade booted it and nobody watches it now: it shuts down after the idle wait.
    tokio::time::sleep(crate::device::manager::DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the idle shutdown", || app.backend.udids_of("shutdown") == [DEVICE_A]).await;
}

#[tokio::test(start_paused = true)]
async fn a_deleted_chat_leaves_a_folder_a_session_still_works_in() {
    let app = app_with(None);
    let manager = app.state.device.manager().unwrap().clone();
    app.backend.boot(DEVICE_A).await.unwrap();
    let removed = |thread: &'static str| {
        let state = app.state.clone();
        async move { crate::device::service::chat_removed(&state.device, &Arc::downgrade(&state.chat), &state.db, thread).await }
    };

    // A session works in /w/s: the chat's deletion leaves its pane alone.
    app.state.device.remember_chat_owner("thread-2", "/w/s");
    manager.attach("/w/s", DEVICE_A).await;
    let session = crate::Session {
        id: "t".into(),
        project_id: "p".into(),
        workspace: "/w".into(),
        worktree: "/w/s".into(),
        title: "Page".into(),
        ..Default::default()
    };
    assert!(app.state.db.upsert_task(&session).await.unwrap());
    removed("thread-2").await;
    assert_eq!(manager.owner_state("/w/s").await.attached_device_udid.as_deref(), Some(DEVICE_A));

    // Another chat still works in /w/c: kept; once the last one goes, released.
    app.state.device.remember_chat_owner("thread-3", "/w/c");
    app.state.device.remember_chat_owner("thread-4", "/w/c");
    manager.attach("/w/c", DEVICE_A).await;
    removed("thread-3").await;
    assert_eq!(manager.owner_state("/w/c").await.attached_device_udid.as_deref(), Some(DEVICE_A));
    removed("thread-4").await;
    assert_eq!(manager.owner_state("/w/c").await.attached_device_udid, None);
}

/// A terminal agent's `SessionStart` (a `/clear` or `/resume` after an interrupt that sent no
/// `Stop`) ends the turn its run still held (review fix 1).
#[tokio::test(start_paused = true)]
async fn a_terminal_session_change_ends_the_turn_its_run_held() {
    let app = app_with(None);
    let manager = app.state.device.manager().unwrap().clone();
    manager.boot(DEVICE_A).await.unwrap();
    crate::device::service::terminal_turn_started(&app.state, "pty1-1");
    let turn = app.state.device.terminal_turn("pty1-1");
    let used = Some(crate::device::manager::DeviceUse { udid: DEVICE_A.into(), turn, lapses: false });
    manager.with_agent_activity(OWNER, used, manager.ensure_attached(OWNER, DEVICE_A)).await.unwrap();

    // A compaction mid-turn is the same conversation going on: the turn keeps its device.
    let (status, _) = post(&app.router, "/api/hooks/session-start?cli=claude&runId=pty1-1", json!({ "session_id": "s", "source": "compact" })).await;
    assert!(status.is_success(), "{status}");
    assert!(app.state.device.terminal_turn("pty1-1").is_some(), "a compaction keeps the run's turn");
    tokio::time::sleep(crate::device::manager::DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    tokio::task::yield_now().await;
    assert_eq!(app.backend.count("shutdown"), 0, "the turn still holds its device");

    let (status, _) = post(&app.router, "/api/hooks/session-start?cli=claude&runId=pty1-1", json!({ "session_id": "s", "source": "clear" })).await;
    assert!(status.is_success(), "{status}");
    tokio::time::sleep(crate::device::manager::DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the idle shutdown", || app.backend.count("shutdown") == 1).await;
}
