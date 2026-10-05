//! The chat RPC through the router, with the engine's CLIs scripted, and a terminal transcript
//! read as a thread.

use std::{path::Path, sync::Arc, time::Duration};

use axum::{
    body::Body,
    http::{Request, StatusCode},
    Router,
};
use cascade_chat::{
    contracts::orchestration::PROVIDER_SEND_TURN_MAX_FILE_BYTES, provider::process::ScriptedSpawner, ChatEngineConfig,
    STANDALONE_PROJECT_ID,
};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tokio::{sync::broadcast, time::timeout};
use tower::ServiceExt;

use super::{transcript::{thread_of_transcript, transcript_thread_in}, *};
use crate::build_app;

const WAIT: Duration = Duration::from_secs(10);
const T0: &str = "2026-10-05T10:00:00.000Z";

async fn app_with_engine(dir: &Path, spawner: &ScriptedSpawner) -> AppState {
    let app = AppState::new(crate::Database::open(dir).unwrap(), None);
    let config = ChatEngineConfig {
        data_dir: dir.join("chat"),
        spawner: Arc::new(spawner.clone()),
        adapters: None,
        publish: publisher(app.events.clone()),
        git: None,
    };
    start_with(&app, config).await.unwrap();
    app
}

async fn post(router: &Router, path: &str, body: Value) -> (StatusCode, Value) {
    let request = Request::post(path).header("content-type", "application/json").body(Body::from(body.to_string())).unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

async fn rpc_call(router: &Router, method: &str, params: Value) -> (StatusCode, Value) {
    post(router, "/api/chat/rpc", json!({ "method": method, "params": params })).await
}

fn create(thread: &str, cwd: &Path) -> Value {
    json!({ "command": {
        "type": "thread.create",
        "commandId": format!("create-{thread}"),
        "threadId": thread,
        "projectId": STANDALONE_PROJECT_ID,
        "title": "New chat",
        "modelSelection": { "provider": "claudeAgent", "model": "claude-opus-4-6" },
        "runtimeMode": "approval-required",
        "branch": null,
        "worktreePath": null,
        "workingDirectory": cwd.to_string_lossy(),
        "createdAt": T0,
    }})
}

/// The next chat event on the app's event stream that `wanted` takes.
async fn next_event(events: &mut broadcast::Receiver<Value>, wanted: impl Fn(&Value) -> bool) -> Value {
    timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if wanted(&event) {
                return event;
            }
        }
    })
    .await
    .expect("the event was published")
}

#[tokio::test]
async fn a_chat_is_created_read_and_sent_a_turn_through_the_rpc() {
    let dir = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let app = app_with_engine(dir.path(), &spawner).await;
    let mut events = app.events.subscribe();
    let router = build_app(app.clone());

    let (status, created) = rpc_call(&router, "orchestration.dispatchCommand", create("chat-1", work.path())).await;
    assert_eq!(status, StatusCode::OK, "{created}");
    let created_sequence = created["result"]["sequence"].as_u64().unwrap();
    assert!(created_sequence >= 1);
    let shell = next_event(&mut events, |event| event["type"] == "chat-shell").await;
    assert_eq!(shell["shell"]["id"], "chat-1");

    let (status, snapshot) = rpc_call(&router, "orchestration.getThreadDetailSnapshot", json!({ "threadId": "chat-1" })).await;
    assert_eq!(status, StatusCode::OK);
    let snapshot = &snapshot["result"];
    assert_eq!(snapshot["snapshotSequence"].as_u64(), Some(created_sequence));
    assert_eq!(snapshot["thread"]["id"], "chat-1");
    assert_eq!(snapshot["thread"]["workingDirectory"], work.path().to_string_lossy().as_ref());

    let (_, missing) = rpc_call(&router, "orchestration.getThreadDetailSnapshot", json!({ "threadId": "none" })).await;
    assert_eq!(missing, json!({ "result": null }));

    let (_, listed) = rpc_call(&router, "chat.listThreads", json!({ "projectId": STANDALONE_PROJECT_ID })).await;
    assert_eq!(listed["result"].as_array().map(|shells| shells.len()), Some(1));

    let turn = json!({ "command": {
        "type": "thread.turn.start",
        "commandId": "turn-1",
        "threadId": "chat-1",
        "message": { "messageId": "message-1", "role": "user", "text": "hello", "attachments": [] },
        "assistantDeliveryMode": "streaming",
        "dispatchMode": "queue",
        "runtimeMode": "approval-required",
        "interactionMode": "default",
        "createdAt": T0,
    }});
    let (status, sent) = rpc_call(&router, "orchestration.dispatchCommand", turn).await;
    assert_eq!(status, StatusCode::OK, "{sent}");
    assert!(sent["result"]["sequence"].as_u64().unwrap() > created_sequence);
    let published = next_event(&mut events, |event| {
        event["type"] == "chat-thread"
            && event["events"].as_array().is_some_and(|list| list.iter().any(|e| e["type"] == "thread.message-sent"))
    })
    .await;
    assert_eq!(published["threadId"], "chat-1");
    assert!(published["events"].as_array().unwrap().iter().all(|event| event["sequence"].as_u64().unwrap() > created_sequence));

    // The turn starts the CLI through the engine's spawner, in the chat's folder.
    let child = timeout(WAIT, spawner.next()).await.expect("the engine started the CLI");
    assert_eq!(child.spec.cwd.as_deref(), Some(work.path()));
    drop(child);
    app.chat.shutdown().await;
}

#[tokio::test]
async fn an_unknown_method_is_unavailable_and_a_rejected_command_invalid() {
    let dir = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let app = app_with_engine(dir.path(), &spawner).await;
    let router = build_app(app.clone());

    let (status, unknown) = rpc_call(&router, "server.reboot", json!({})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(unknown["error"]["code"], "unavailable");

    let (status, _) = rpc_call(&router, "orchestration.dispatchCommand", create("chat-2", work.path())).await;
    assert_eq!(status, StatusCode::OK);
    let (status, again) = rpc_call(&router, "orchestration.dispatchCommand", create("chat-2", work.path())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{again}");
    assert_eq!(again["error"]["code"], "invalid");
    assert!(again["error"]["message"].as_str().is_some_and(|message| !message.is_empty()));

    let (status, malformed) = rpc_call(&router, "orchestration.dispatchCommand", json!({ "command": { "type": "thread.nonsense" } })).await;
    assert_eq!((status, malformed["error"]["code"].as_str()), (StatusCode::BAD_REQUEST, Some("invalid")));

    let (_, plugins) = rpc_call(&router, "provider.listPlugins", json!({ "provider": "codex" })).await;
    assert_eq!(plugins["result"]["marketplaces"], json!([]));
    let (_, capabilities) = rpc_call(&router, "provider.getComposerCapabilities", json!({ "provider": "claudeAgent" })).await;
    assert_eq!(capabilities["result"]["supportsThreadCompaction"], true);
    let (_, codex) = rpc_call(&router, "provider.getComposerCapabilities", json!({ "provider": "codex" })).await;
    assert_eq!(codex["result"]["supportsThreadCompaction"], false);
    app.chat.shutdown().await;
}

#[tokio::test]
async fn without_an_engine_the_chat_calls_are_unavailable() {
    let dir = tempfile::tempdir().unwrap();
    let router = build_app(AppState::new(crate::Database::open(dir.path()).unwrap(), None));
    let (status, reply) = rpc_call(&router, "chat.listThreads", json!({})).await;
    assert_eq!((status, reply["error"]["code"].as_str()), (StatusCode::NOT_FOUND, Some("unavailable")));
}

#[tokio::test]
async fn an_attachment_is_saved_from_base64() {
    let dir = tempfile::tempdir().unwrap();
    let app = app_with_engine(dir.path(), &ScriptedSpawner::new()).await;
    let router = build_app(app.clone());
    let (status, saved) = rpc_call(
        &router,
        "attachments.save",
        json!({ "threadId": "chat-3", "type": "file", "name": "note.txt", "mimeType": "text/plain", "dataBase64": "aGVsbG8gd29ybGQ=" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!((saved["result"]["type"].as_str(), saved["result"]["sizeBytes"].as_u64()), (Some("file"), Some(11)));
    let id = saved["result"]["id"].as_str().unwrap();
    let stored: Vec<_> = std::fs::read_dir(dir.path().join("chat/attachments")).unwrap().flatten().collect();
    assert!(stored.iter().any(|entry| entry.file_name().to_string_lossy().starts_with(id)));
    app.chat.shutdown().await;
}

/// `attachments.save` of `size` bytes of zeros, as base64.
fn attachment(size: usize) -> Value {
    json!({ "threadId": "chat-big", "type": "file", "name": "big.bin", "mimeType": "application/octet-stream", "dataBase64": "AAAA".repeat(size / 3) })
}

#[tokio::test]
async fn an_attachment_up_to_the_engine_limit_saves_and_a_larger_one_is_invalid() {
    assert!(
        RPC_BODY_LIMIT as u64 >= PROVIDER_SEND_TURN_MAX_FILE_BYTES.div_ceil(3) * 4 + 64 * 1024,
        "the route takes the largest file the engine takes, as base64"
    );
    let dir = tempfile::tempdir().unwrap();
    let app = app_with_engine(dir.path(), &ScriptedSpawner::new()).await;
    let router = build_app(app.clone());

    // 20 MB: past the router's own 15 MiB as base64, inside the route's.
    let (status, saved) = rpc_call(&router, "attachments.save", attachment(20_000_000)).await;
    assert_eq!(status, StatusCode::OK, "{}", saved.to_string().chars().take(300).collect::<String>());
    assert_eq!(saved["result"]["sizeBytes"].as_u64(), Some(19_999_998));

    // 26 MB: the body is taken, but the file is refused before it is decoded.
    let (status, refused) = rpc_call(&router, "attachments.save", attachment(26 * 1024 * 1024)).await;
    assert_eq!((status, refused["error"]["code"].as_str()), (StatusCode::BAD_REQUEST, Some("invalid")), "{refused}");
    // An image by the engine's image limit.
    let mut image = attachment(11 * 1024 * 1024);
    image["mimeType"] = json!("image/png");
    let (status, refused) = rpc_call(&router, "attachments.save", image).await;
    assert_eq!((status, refused["error"]["code"].as_str()), (StatusCode::BAD_REQUEST, Some("invalid")), "{refused}");

    // 40 MB: past the route's limit, still answered as an error the page reads.
    let (status, refused) = rpc_call(&router, "attachments.save", attachment(40_000_000)).await;
    assert_eq!((status, refused["error"]["code"].as_str()), (StatusCode::PAYLOAD_TOO_LARGE, Some("invalid")), "{refused}");
    assert!(refused["error"]["message"].as_str().is_some_and(|message| !message.is_empty()));
    app.chat.shutdown().await;
}

#[test]
fn a_decoded_length_is_counted_without_decoding() {
    for text in ["aGVsbG8gd29ybGQ=", "aGk", "-_8=", "aGVs\nbG8=", ""] {
        assert_eq!(decoded_length(text), decode_base64(text).unwrap().len() as u64, "{text}");
    }
}

#[tokio::test]
async fn a_body_the_route_cannot_read_is_an_invalid_error() {
    let dir = tempfile::tempdir().unwrap();
    let router = build_app(AppState::new(crate::Database::open(dir.path()).unwrap(), None));
    let send = |content_type: Option<&str>, body: &str| {
        let mut request = Request::post("/api/chat/rpc");
        if let Some(content_type) = content_type {
            request = request.header("content-type", content_type);
        }
        let request = request.body(Body::from(body.to_owned())).unwrap();
        let router = router.clone();
        async move {
            let response = router.oneshot(request).await.unwrap();
            let status = response.status();
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            (status, serde_json::from_slice::<Value>(&bytes).expect("a JSON error"))
        }
    };
    for (content_type, body, expected) in [
        (Some("application/json"), "{not json", StatusCode::BAD_REQUEST),
        (Some("application/json"), r#"{"params":{}}"#, StatusCode::UNPROCESSABLE_ENTITY),
        (None, r#"{"method":"chat.listThreads"}"#, StatusCode::UNSUPPORTED_MEDIA_TYPE),
    ] {
        let (status, reply) = send(content_type, body).await;
        assert_eq!((status, reply["error"]["code"].as_str()), (expected, Some("invalid")), "{body}: {reply}");
        assert!(reply["error"]["message"].as_str().is_some_and(|message| !message.is_empty()));
    }
}

#[tokio::test]
async fn a_chats_files_are_read_in_its_own_folder_whatever_cwd_the_page_sends() {
    let work = tempfile::tempdir().unwrap();
    std::fs::write(work.path().join("mine.txt"), "mine").unwrap();
    let foreign = tempfile::tempdir().unwrap();
    std::fs::write(foreign.path().join("secret.txt"), "secret").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let app = app_with_engine(dir.path(), &ScriptedSpawner::new()).await;
    let router = build_app(app.clone());
    let (status, _) = rpc_call(&router, "orchestration.dispatchCommand", create("chat-folder", work.path())).await;
    assert_eq!(status, StatusCode::OK);
    let cwd = foreign.path().to_string_lossy().into_owned();
    let read = |thread: &str, relative: &str| {
        let params = json!({ "cwd": cwd, "threadId": thread, "relativePath": relative });
        let router = router.clone();
        async move { rpc_call(&router, "projects.readFile", params).await }
    };

    let (status, refused) = read("chat-folder", "secret.txt").await;
    assert!(status.is_client_error(), "the page's cwd is not the chat's folder: {refused}");
    let (status, mine) = read("chat-folder", "mine.txt").await;
    assert_eq!((status, mine["result"]["contents"].as_str()), (StatusCode::OK, Some("mine")));
    let (_, found) = rpc_call(&router, "projects.searchEntries", json!({ "cwd": cwd, "threadId": "chat-folder", "query": "" })).await;
    assert_eq!(found["result"]["entries"], json!([{ "path": "mine.txt", "kind": "file" }]));
    let (_, refs) = rpc_call(
        &router,
        "projects.resolveWorkspaceFileReferences",
        json!({ "cwd": cwd, "threadId": "chat-folder", "relativePaths": ["secret.txt", "mine.txt"] }),
    )
    .await;
    assert_eq!(refs["result"]["relativePaths"], json!([null, "mine.txt"]));

    // A chat not created yet reads where the page says.
    let (status, new) = read("chat-not-yet", "secret.txt").await;
    assert_eq!((status, new["result"]["contents"].as_str()), (StatusCode::OK, Some("secret")));
    app.chat.shutdown().await;
}

/// Answers `git ls-files` slowly, counting how often it is asked.
#[derive(Default)]
struct SlowGit {
    listings: std::sync::atomic::AtomicUsize,
}

impl cli::CommandRunner for SlowGit {
    fn output<'a>(&'a self, invocation: cli::Invocation) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<Vec<u8>>> + Send + 'a>> {
        Box::pin(async move {
            assert_eq!(invocation.program, "git");
            self.listings.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(150)).await;
            Ok(b"src/a.rs\0src/b.rs\0".to_vec())
        })
    }
}

#[tokio::test]
async fn concurrent_cold_searches_of_a_folder_share_one_listing() {
    let work = tempfile::tempdir().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let router = build_app(AppState::new(crate::Database::open(dir.path()).unwrap(), None));
    let git = Arc::new(SlowGit::default());
    let search = |query: &str| rpc_call(&router, "projects.searchEntries", json!({ "cwd": work.path().to_string_lossy(), "query": query }));
    let (a, b, c) = cli::scoped(git.clone(), async { tokio::join!(search("a"), search("b"), search("src")) }).await;
    assert_eq!(git.listings.load(std::sync::atomic::Ordering::SeqCst), 1, "one listing for three cold searches");
    assert_eq!(a.1["result"]["entries"][0]["path"], "src/a.rs");
    assert_eq!(b.1["result"]["entries"][0]["path"], "src/b.rs");
    assert_eq!(c.1["result"]["entries"][0], json!({ "path": "src", "kind": "directory" }));
}

/// Answers `--version` slowly, counting how often it is asked.
#[derive(Default)]
struct SlowVersion {
    asked: std::sync::atomic::AtomicUsize,
}

impl cli::CommandRunner for SlowVersion {
    fn output<'a>(&'a self, _: cli::Invocation) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<Vec<u8>>> + Send + 'a>> {
        Box::pin(async move {
            self.asked.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(300)).await;
            Ok(b"1.2.3 (CLI)".to_vec())
        })
    }
}

#[tokio::test]
async fn provider_statuses_probe_the_clis_at_once_and_concurrent_calls_share_the_probes() {
    let dir = tempfile::tempdir().unwrap();
    let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let installed = Agent::ALL.into_iter().filter(|agent| cli::find(agent.profile().command).is_some()).count();
    let runner = Arc::new(SlowVersion::default());
    let started = std::time::Instant::now();
    let (first, second) = cli::scoped(runner.clone(), async { tokio::join!(provider_statuses(&app), provider_statuses(&app)) }).await;
    let elapsed = started.elapsed();
    assert_eq!(first, second);
    assert_eq!(runner.asked.load(std::sync::atomic::Ordering::SeqCst), installed, "each installed CLI asked once, for both calls");
    if installed > 1 {
        assert!(elapsed < Duration::from_millis(550), "asked at once, not one after another: {elapsed:?}");
    }
    assert_eq!(first.as_array().map(Vec::len), Some(Agent::ALL.len()));
}

#[test]
fn base64_decodes_standard_and_url_safe_text() {
    assert_eq!(decode_base64("aGVsbG8gd29ybGQ=").unwrap(), b"hello world");
    assert_eq!(decode_base64("aGk").unwrap(), b"hi");
    assert_eq!(decode_base64("-_8=").unwrap(), [0xfb, 0xff]);
    assert!(decode_base64("not base64!").is_none());
}

#[test]
fn a_chat_cli_starts_by_its_path_and_out_of_the_agent_hooks() {
    let spec = SpawnSpec {
        program: "claude".into(),
        args: vec!["--verbose".into()],
        cwd: None,
        env: vec![("PATH".into(), "/adapter".into())],
        env_remove: vec!["CLAUDECODE".into()],
    };
    let launched = launch_spec(&spec);
    assert!(launched.program.starts_with('/'), "never a bare name: {}", launched.program);
    assert!(launched.program.ends_with("/claude"));
    let paths: Vec<&str> = launched.env.iter().filter(|(key, _)| key == "PATH").map(|(_, value)| value.as_str()).collect();
    assert_eq!(paths.last(), Some(&"/adapter"), "the adapter's own variable wins");
    assert!(paths.len() == 2, "the search path is set first");
    for name in ["CLAUDECODE", "CASCADE_RUN_ID", "CASCADE_PORT_FILE"] {
        assert!(launched.env_remove.iter().any(|removed| removed == name), "{name}");
    }
}

#[tokio::test]
async fn read_file_stays_inside_the_folder() {
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
    let folder = outside.path().join("work");
    std::fs::create_dir_all(folder.join("src")).unwrap();
    std::fs::write(folder.join("src/a.rs"), "fn main() {}\r\n").unwrap();
    std::os::unix::fs::symlink(outside.path().join("secret.txt"), folder.join("leak.txt")).unwrap();
    std::os::unix::fs::symlink(folder.join("src/a.rs"), folder.join("inside.rs")).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let router = build_app(AppState::new(crate::Database::open(dir.path()).unwrap(), None));
    let cwd = folder.to_string_lossy().into_owned();
    let read = |relative: &str| {
        let router = router.clone();
        let params = json!({ "cwd": cwd, "relativePath": relative });
        async move { rpc_call(&router, "projects.readFile", params).await }
    };

    let (status, found) = read("./src/a.rs").await;
    assert_eq!(status, StatusCode::OK, "{found}");
    let found = &found["result"];
    assert_eq!((found["relativePath"].as_str(), found["contents"].as_str()), (Some("src/a.rs"), Some("fn main() {}\r\n")));
    assert_eq!((found["lineEnding"].as_str(), found["encoding"].as_str()), (Some("crlf"), Some("utf8")));
    for escape in ["../secret.txt", "src/../../secret.txt", "/etc/hosts", "leak.txt"] {
        let (status, refused) = read(escape).await;
        assert!(status.is_client_error(), "{escape} was read: {refused}");
        assert!(refused["result"].is_null());
    }
    let (status, linked) = read("inside.rs").await;
    assert_eq!((status, linked["result"]["symlink"].as_bool()), (StatusCode::OK, Some(true)), "a link that stays inside is read");

    let (_, refs) = rpc_call(
        &router,
        "projects.resolveWorkspaceFileReferences",
        json!({ "cwd": cwd, "relativePaths": ["a.rs", "src/a.rs", "../secret.txt", "missing.rs"] }),
    )
    .await;
    assert_eq!(refs["result"]["relativePaths"], json!(["src/a.rs", "src/a.rs", null, null]));
    let (_, found) = rpc_call(&router, "projects.searchEntries", json!({ "cwd": cwd, "query": "a.r", "limit": 10 })).await;
    assert_eq!(found["result"]["entries"][0], json!({ "path": "src/a.rs", "kind": "file", "parentPath": "src" }));
}

/// The fixture is a Claude Code session file as Claude writes it: a turn that ran a command, and
/// one waiting on an approval to run another.
const CLAUDE_TRANSCRIPT: &str = include_str!("fixtures/claude-transcript.jsonl");
const SESSION: &str = "5b0c2f1e-4f7a-4d8e-9a51-0d3c6e2b7a10";

fn read_fixture(home: &Path, run: Option<&str>) -> (Agent, crate::agents::TranscriptQuery, Value) {
    let project = home.join(".claude/projects/-w-chat");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join(format!("{SESSION}.jsonl")), CLAUDE_TRANSCRIPT).unwrap();
    let query: crate::agents::TranscriptQuery = serde_json::from_value(json!({
        "cli": "claude", "worktree": "/w/chat", "session": SESSION, "format": "thread", "runId": run, "threadId": "session-1",
    }))
    .unwrap();
    let found = crate::agents::transcript::read_with(home, Agent::Claude, "/w/chat", None, Some(SESSION), true);
    (Agent::Claude, query, found)
}

#[tokio::test]
async fn a_terminal_transcript_reads_as_a_thread_of_messages_and_tool_activities() {
    let home = tempfile::tempdir().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let (agent, query, found) = read_fixture(home.path(), None);
    let read = thread_of_transcript(&app, agent, &query, found.clone()).await;
    let snapshot = &read["snapshot"];
    assert!(snapshot["snapshotSequence"].as_i64().unwrap() > 0);
    let thread: OrchestrationThread = serde_json::from_value(snapshot["thread"].clone()).expect("an OrchestrationThread");
    assert_eq!(thread.id.as_str(), "session-1");
    assert_eq!(thread.project_id.as_str(), STANDALONE_PROJECT_ID);

    let messages: Vec<(String, &str)> = thread.messages.iter().map(|m| (json!(m.role).as_str().unwrap().to_owned(), m.text.as_str())).collect();
    assert_eq!(
        messages,
        vec![
            ("user".to_owned(), "List the files here, then tell me how many there are."),
            ("assistant".to_owned(), "There are 2 entries: `README.md` and `src`."),
            ("user".to_owned(), "Now delete the build folder."),
        ]
    );
    let kinds: Vec<&str> = thread.activities.iter().map(|a| a.kind.as_str()).collect();
    assert_eq!(kinds, ["task.progress", "tool.started", "tool.completed", "tool.started"]);
    let started = &thread.activities[1];
    assert_eq!(started.payload["itemType"], "command_execution");
    assert_eq!(started.payload["detail"], "Bash: ls -1");
    assert_eq!(started.payload["data"]["toolCallId"], "toolu_01ABC");
    assert_eq!(started.payload["data"]["input"]["command"], "ls -1");
    let completed = &thread.activities[2];
    assert_eq!(completed.payload["status"], "completed");
    assert_eq!(completed.payload["data"]["result"]["content"], "README.md\nsrc");
    assert_eq!(thread.activities[0].payload["detail"], "I should run ls to see the files.");
    // In the order they happened, each with its turn.
    let times: Vec<&str> = thread.activities.iter().map(|a| a.created_at.as_str()).collect();
    assert!(times.windows(2).all(|pair| pair[0] < pair[1]), "{times:?}");
    assert_eq!(thread.activities[3].turn_id.as_ref().map(|t| t.as_str()), Some("turn:0b6d1a2e-0000-4000-8000-000000000008"));
    // The second turn waits on its command: the agent is at work.
    let latest = thread.latest_turn.as_ref().unwrap();
    assert_eq!(json!(latest.state), "running");
    assert_eq!(json!(thread.session.as_ref().unwrap().status), "running");

    let again = thread_of_transcript(&app, agent, &query, found).await;
    assert_eq!(again, read, "an unchanged transcript reads the same");
}

#[tokio::test]
async fn an_approval_the_terminal_waits_on_is_a_pending_request_its_offer_answers() {
    let home = tempfile::tempdir().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let router = build_app(app.clone());
    // An offer nobody hears is left to the terminal at once: the app listens.
    let _app_listening = app.events.subscribe();
    // The terminal's hook asks, and waits for an answer.
    let hook = tokio::spawn({
        let router = router.clone();
        async move {
            post(
                &router,
                "/api/hooks/permission?cli=claude&runId=pty7",
                json!({ "tool_name": "Bash", "tool_input": { "command": "rm -rf build", "description": "Delete the build folder" } }),
            )
            .await
        }
    });
    timeout(WAIT, async {
        while app.permissions.waiting("pty7").await.0.is_empty() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the hook's request was offered");

    let (agent, query, found) = read_fixture(home.path(), Some("pty7"));
    let read = thread_of_transcript(&app, agent, &query, found.clone()).await;
    let thread: OrchestrationThread = serde_json::from_value(read["snapshot"]["thread"].clone()).unwrap();
    let approval = thread.activities.iter().find(|a| a.kind == "approval.requested").expect("a pending approval");
    let offer = approval.payload["requestId"].as_str().unwrap().to_owned();
    assert_eq!(offer, app.permissions.waiting("pty7").await.0[0].id);
    assert_eq!(approval.payload["requestKind"], "command");
    assert_eq!(approval.payload["detail"], "Bash: rm -rf build");
    assert_eq!(thread.has_pending_approvals, Some(true));

    // Another terminal's read shows none of it.
    let (_, other, _) = read_fixture(home.path(), Some("pty8"));
    let elsewhere = thread_of_transcript(&app, agent, &other, found.clone()).await;
    assert!(!elsewhere.to_string().contains("approval.requested"));

    // The offer's id is what the app answers it by.
    let (status, _) = post(&router, "/api/agent/permission", json!({ "id": offer, "decision": "deny" })).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, decision) = timeout(WAIT, hook).await.unwrap().unwrap();
    assert_eq!(status, StatusCode::OK);
    assert_eq!(decision["hookSpecificOutput"]["decision"]["behavior"], "deny");
    let after = thread_of_transcript(&app, agent, &query, found).await;
    assert!(!after.to_string().contains("approval.requested"), "answered, it is gone");
    assert!(
        after["snapshot"]["snapshotSequence"].as_i64() >= read["snapshot"]["snapshotSequence"].as_i64(),
        "the sequence never goes back"
    );
}

#[tokio::test]
async fn a_thread_read_since_its_revision_answers_the_revision_alone() {
    let home = tempfile::tempdir().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    read_fixture(home.path(), None);
    let query = |since: Option<&str>| -> crate::agents::TranscriptQuery {
        serde_json::from_value(json!({
            "cli": "claude", "worktree": "/w/chat", "session": SESSION, "format": "thread", "threadId": "session-1", "since": since,
        }))
        .unwrap()
    };
    let full = transcript_thread_in(&app, query(None), home.path().to_path_buf()).await;
    let revision = full["revision"].as_str().unwrap().to_owned();
    assert!(full["snapshot"]["thread"].is_object());
    assert!(revision.ends_with(":0"), "no terminal, no approvals: {revision}");

    let unchanged = transcript_thread_in(&app, query(Some(&revision)), home.path().to_path_buf()).await;
    assert_eq!(unchanged, json!({ "revision": revision }), "nothing rebuilt");

    // The approvals changed since (another time after the colon): rebuilt.
    let (file, _) = revision.rsplit_once(':').unwrap();
    let approvals = transcript_thread_in(&app, query(Some(&format!("{file}:1"))), home.path().to_path_buf()).await;
    assert_eq!(approvals, full);
    // The transcript changed since: rebuilt.
    let written = transcript_thread_in(&app, query(Some("1-1:0")), home.path().to_path_buf()).await;
    assert_eq!(written, full);
}
