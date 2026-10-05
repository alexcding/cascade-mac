//! The chat engine end to end: commands in, recorded CLI sessions replayed through scripted
//! processes, threads and published events out.

use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use cascade_chat::{
    contracts::{
        base::{ThreadId, TurnId},
        orchestration::{
            ClientThreadCommand, OrchestrationCheckpointStatus, OrchestrationLatestTurnState, OrchestrationMessageRole,
            OrchestrationSessionStatus, OrchestrationThread,
        },
    },
    provider::process::{ScriptedChild, ScriptedSpawner},
    ChatEngine, ChatEngineConfig, ChatEngineEvent, ChatError,
};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines},
    time::timeout,
};

const CLAUDE_FIXTURE: &str = include_str!("fixtures/claude-turn-with-approval.jsonl");
const CODEX_FIXTURE: &str = include_str!("fixtures/codex-turn-with-approval.jsonl");
const CLAUDE_SESSION: &str = "f17ee499-d743-47c0-965c-a383d97a0b55";
const WAIT: Duration = Duration::from_secs(10);
const T0: &str = "2026-10-05T10:00:00.000Z";

type Published = Arc<Mutex<Vec<ChatEngineEvent>>>;

async fn start(data_dir: &Path, spawner: &ScriptedSpawner) -> (ChatEngine, Published) {
    let published: Published = Arc::default();
    let sink = published.clone();
    let engine = ChatEngine::start(ChatEngineConfig {
        data_dir: data_dir.to_path_buf(),
        spawner: Arc::new(spawner.clone()),
        adapters: None,
        publish: Arc::new(move |event| sink.lock().unwrap().push(event)),
        git: None,
    })
    .await
    .unwrap();
    (engine, published)
}

fn command(value: Value) -> ClientThreadCommand {
    serde_json::from_value(value).unwrap()
}

fn create_thread(thread: &str, provider: &str, model: &str, cwd: &Path) -> ClientThreadCommand {
    command(json!({
        "type": "thread.create",
        "commandId": format!("create-{thread}"),
        "threadId": thread,
        "projectId": "project-1",
        "title": "New thread",
        "modelSelection": { "provider": provider, "model": model },
        "runtimeMode": "approval-required",
        "branch": null,
        "worktreePath": cwd.to_string_lossy(),
        "createdAt": T0,
    }))
}

fn turn_start(thread: &str, message: &str, text: &str, dispatch_mode: &str) -> ClientThreadCommand {
    command(json!({
        "type": "thread.turn.start",
        "commandId": format!("turn-{message}"),
        "threadId": thread,
        "message": { "messageId": message, "role": "user", "text": text, "attachments": [] },
        "assistantDeliveryMode": "streaming",
        "dispatchMode": dispatch_mode,
        "runtimeMode": "approval-required",
        "interactionMode": "default",
        "createdAt": T0,
    }))
}

fn approve(thread: &str, request_id: &str) -> ClientThreadCommand {
    command(json!({
        "type": "thread.approval.respond",
        "commandId": format!("approve-{request_id}"),
        "threadId": thread,
        "requestId": request_id,
        "decision": "accept",
        "createdAt": T0,
    }))
}

/// Polls the thread until `done` holds.
async fn wait_for(engine: &ChatEngine, thread: &str, what: &str, done: impl Fn(&OrchestrationThread) -> bool) -> OrchestrationThread {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Some(found) = engine.thread(ThreadId::new(thread)).await.unwrap() {
            if done(&found) {
                return found;
            }
            if tokio::time::Instant::now() > deadline {
                panic!("timed out waiting for {what}: {}", serde_json::to_string_pretty(&found).unwrap());
            }
        } else if tokio::time::Instant::now() > deadline {
            panic!("timed out waiting for {what}: no thread");
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn running(thread: &OrchestrationThread) -> bool {
    thread
        .session
        .as_ref()
        .is_some_and(|s| s.status == OrchestrationSessionStatus::Running && s.active_turn_id.is_some())
}

fn pending_approval(thread: &OrchestrationThread) -> Option<String> {
    thread
        .activities
        .iter()
        .find(|a| a.kind == "approval.requested")
        .and_then(|a| a.payload["requestId"].as_str())
        .map(str::to_owned)
}

fn turn_completed(thread: &OrchestrationThread) -> bool {
    thread.latest_turn.as_ref().is_some_and(|t| t.state == OrchestrationLatestTurnState::Completed)
        && thread.session.as_ref().is_some_and(|s| s.status == OrchestrationSessionStatus::Ready)
}

/// Every event published for `thread`, in order.
fn published_sequences(published: &Published, thread: &str) -> Vec<u64> {
    published
        .lock()
        .unwrap()
        .iter()
        .filter_map(|event| match event {
            ChatEngineEvent::Thread { thread_id, events } if thread_id.as_str() == thread => {
                Some(events.iter().map(|e| e.sequence).collect::<Vec<_>>())
            }
            _ => None,
        })
        .flatten()
        .collect()
}

fn git_init(dir: &Path) {
    let status = std::process::Command::new("git").args(["init", "-q"]).current_dir(dir).status().unwrap();
    assert!(status.success());
}

// --- the Claude CLI's side ---

struct ClaudeCli {
    stdin: Lines<BufReader<DuplexStream>>,
    stdout: DuplexStream,
}

impl ClaudeCli {
    async fn spawned(spawner: &ScriptedSpawner) -> (Self, tokio::sync::oneshot::Sender<Option<i32>>) {
        let child: ScriptedChild = timeout(WAIT, spawner.next()).await.expect("the engine started no CLI");
        assert_eq!(child.spec.program, "claude");
        (Self { stdin: BufReader::new(child.stdin).lines(), stdout: child.stdout }, child.exit)
    }

    /// Reads what the engine wrote until a line matches.
    async fn read_until(&mut self, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = timeout(WAIT, self.stdin.next_line())
                .await
                .unwrap_or_else(|_| panic!("timed out reading {what}"))
                .unwrap()
                .unwrap_or_else(|| panic!("stdin closed before {what}"));
            let value: Value = serde_json::from_str(&line).unwrap();
            if matches(&value) {
                return value;
            }
        }
    }

    async fn read_user_message(&mut self) -> Value {
        self.read_until("a user message", |v| v["type"] == "user").await
    }

    async fn write_line(&mut self, line: &str) {
        self.stdout.write_all(line.as_bytes()).await.unwrap();
        self.stdout.write_all(b"\n").await.unwrap();
    }

    async fn write_lines(&mut self, lines: &[&str]) {
        for line in lines {
            self.write_line(line).await;
        }
    }

    /// Reads stdin to its end: the engine stopped the session.
    async fn expect_closed(&mut self) {
        loop {
            match timeout(WAIT, self.stdin.next_line()).await.expect("stdin stayed open").unwrap() {
                None => return,
                Some(_) => continue,
            }
        }
    }
}

fn claude_lines() -> (Vec<&'static str>, usize) {
    let lines: Vec<&str> = CLAUDE_FIXTURE.lines().filter(|l| !l.trim().is_empty()).collect();
    let approval = lines.iter().position(|l| l.contains("\"can_use_tool\"")).unwrap();
    (lines, approval)
}

fn claude_result(uuid: &str, subtype: &str) -> String {
    json!({
        "type": "result",
        "subtype": subtype,
        "is_error": subtype != "success",
        "duration_ms": 5,
        "num_turns": 1,
        "result": "ok",
        "session_id": CLAUDE_SESSION,
        "uuid": uuid,
    })
    .to_string()
}

/// Runs the recorded Claude turn through the engine up to its end.
async fn play_claude_turn(engine: &ChatEngine, cli: &mut ClaudeCli, thread: &str) -> OrchestrationThread {
    write_claude_turn(engine, cli, thread).await;
    wait_for(engine, thread, "the turn's end", turn_completed).await
}

/// Writes the recorded Claude turn, answering its approval through the engine.
async fn write_claude_turn(engine: &ChatEngine, cli: &mut ClaudeCli, thread: &str) {
    let (lines, approval) = claude_lines();
    cli.write_lines(&lines[..=approval]).await;
    let request_id = pending_approval(&wait_for(engine, thread, "the approval", |t| pending_approval(t).is_some()).await).unwrap();
    engine.dispatch(approve(thread, &request_id)).await.unwrap();
    let response = cli.read_until("the approval response", |v| v["type"] == "control_response").await;
    assert_eq!(response["response"]["response"]["behavior"], "allow");
    cli.write_lines(&lines[approval + 1..]).await;
}

#[tokio::test]
async fn a_claude_turn_with_an_approval_runs_end_to_end() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    git_init(workspace.path());
    std::fs::write(workspace.path().join("README.md"), "hello\n").unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, published) = start(data.path(), &spawner).await;
    let thread = "thread-claude";

    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    let started = engine
        .dispatch(turn_start(thread, "msg-1", "Run the shell command `echo hi > probe.txt` with Bash, then reply with one word.", "queue"))
        .await
        .unwrap();
    assert!(started.sequence >= 3);
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    let user = cli.read_user_message().await;
    assert!(user["message"]["content"][0]["text"].as_str().unwrap().starts_with("Run the shell command"));
    wait_for(&engine, thread, "the turn to run", running).await;

    // The tool's write happens while the turn runs, so the turn's diff shows it.
    std::fs::write(workspace.path().join("probe.txt"), "hi\n").unwrap();
    let done = play_claude_turn(&engine, &mut cli, thread).await;

    assert_eq!(done.title, "Run the shell command echo hi", "the first message names the thread");
    let assistant: Vec<_> = done.messages.iter().filter(|m| m.role == OrchestrationMessageRole::Assistant).collect();
    assert_eq!(assistant.len(), 1);
    assert_eq!(assistant[0].text, "Done.");
    assert!(!assistant[0].streaming);
    let latest = done.latest_turn.clone().unwrap();
    assert_eq!(assistant[0].turn_id.as_ref(), Some(&latest.turn_id));
    let kinds: Vec<&str> = done.activities.iter().map(|a| a.kind.as_str()).collect();
    for kind in ["approval.requested", "approval.resolved", "tool.completed"] {
        assert!(kinds.contains(&kind), "{kind} missing from {kinds:?}");
    }
    let session = done.session.clone().unwrap();
    assert_eq!(session.status, OrchestrationSessionStatus::Ready);
    assert_eq!(session.active_turn_id, None);
    assert_eq!(session.provider_name.as_deref(), Some("claudeAgent"));

    // The turn's checkpoint and its diff.
    let done = wait_for(&engine, thread, "the turn's checkpoint", |t| {
        t.activities.iter().any(|a| a.kind == "checkpoint.captured")
    })
    .await;
    let checkpoint = &done.checkpoints[0];
    assert_eq!(checkpoint.turn_id, latest.turn_id);
    assert_eq!(checkpoint.checkpoint_turn_count, 1);
    assert_eq!(checkpoint.status, OrchestrationCheckpointStatus::Ready);
    let files: Vec<(&str, &str)> = checkpoint.files.iter().map(|f| (f.path.as_str(), f.kind.as_str())).collect();
    assert_eq!(files, [("probe.txt", "added")]);
    assert_eq!(done.latest_turn.as_ref().unwrap().state, OrchestrationLatestTurnState::Completed);

    // Every event was published, numbered without gaps.
    let sequences = published_sequences(&published, thread);
    assert!(sequences.len() > 10);
    assert_eq!(sequences, (1..=sequences.len() as u64).collect::<Vec<_>>());
    let shells = published.lock().unwrap().iter().filter(|e| matches!(e, ChatEngineEvent::Shell { .. })).count();
    assert!(shells > 0);
    let listed = engine.shells(None).await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].title, done.title);

    // A new engine on the same folder reads the same thread back, and numbering carries on.
    engine.shutdown().await;
    let (reopened, republished) = start(data.path(), &ScriptedSpawner::new()).await;
    let read_back = reopened.thread(ThreadId::new(thread)).await.unwrap().unwrap();
    assert_eq!(read_back, done);
    let next = reopened
        .dispatch(command(json!({
            "type": "thread.meta.update", "commandId": "rename", "threadId": thread, "title": "Renamed",
        })))
        .await
        .unwrap();
    assert_eq!(next.sequence, *sequences.last().unwrap() + 1);
    assert_eq!(published_sequences(&republished, thread), [next.sequence]);
    reopened.shutdown().await;
}

#[tokio::test]
async fn a_running_session_is_settled_when_the_engine_starts_again() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-settle";
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Take your time", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    let before = wait_for(&engine, thread, "the turn to run", running).await;
    engine.shutdown().await;

    let (reopened, published) = start(data.path(), &ScriptedSpawner::new()).await;
    let after = reopened.thread(ThreadId::new(thread)).await.unwrap().unwrap();
    let session = after.session.clone().unwrap();
    assert_eq!(session.status, OrchestrationSessionStatus::Stopped);
    assert_eq!(session.active_turn_id, None);
    let latest = after.latest_turn.unwrap();
    assert_eq!(latest.turn_id, before.latest_turn.unwrap().turn_id);
    assert_eq!(latest.state, OrchestrationLatestTurnState::Interrupted);
    assert_eq!(after.messages.len(), before.messages.len());
    assert!(!published_sequences(&published, thread).is_empty(), "the settling is published");
    reopened.shutdown().await;
}

#[tokio::test]
async fn an_interrupt_settles_the_running_turn() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-interrupt";
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Count to a million", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    wait_for(&engine, thread, "the turn to run", running).await;

    engine
        .dispatch(command(json!({
            "type": "thread.turn.interrupt", "commandId": "stop-it", "threadId": thread, "createdAt": T0,
        })))
        .await
        .unwrap();
    let interrupt = cli.read_until("the interrupt", |v| v["request"]["subtype"] == "interrupt").await;
    cli.write_line(
        &json!({
            "type": "control_response",
            "response": { "subtype": "success", "request_id": interrupt["request_id"], "response": {} },
        })
        .to_string(),
    )
    .await;
    cli.write_line(&claude_result("result-interrupted", "error_during_execution")).await;

    let done = wait_for(&engine, thread, "the interrupted turn", |t| {
        t.latest_turn.as_ref().is_some_and(|l| l.state == OrchestrationLatestTurnState::Interrupted)
    })
    .await;
    let session = done.session.unwrap();
    assert_eq!(session.active_turn_id, None);
    assert_ne!(session.status, OrchestrationSessionStatus::Running);
    assert!(!done.activities.iter().any(|a| a.kind == "provider.turn.interrupt.failed"));
    engine.shutdown().await;
}

#[tokio::test]
async fn a_queued_turn_runs_when_the_first_one_ends() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, published) = start(data.path(), &spawner).await;
    let thread = "thread-queue";
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine
        .dispatch(turn_start(thread, "msg-1", "Run the shell command `echo hi > probe.txt` with Bash, then reply with one word.", "queue"))
        .await
        .unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    let first = wait_for(&engine, thread, "the first turn to run", running).await;
    let first_turn = first.session.unwrap().active_turn_id.unwrap();

    engine.dispatch(turn_start(thread, "msg-2", "And now the second thing", "queue")).await.unwrap();
    let queued = published.lock().unwrap().iter().any(|e| match e {
        ChatEngineEvent::Thread { events, .. } => {
            events.iter().any(|ev| serde_json::to_value(ev).unwrap()["type"] == "thread.turn-queued")
        }
        _ => false,
    });
    assert!(queued, "the second turn waits in the queue");

    write_claude_turn(&engine, &mut cli, thread).await;
    // The first turn's end hands the second to the CLI.
    let second = cli.read_user_message().await;
    assert_eq!(second["message"]["content"][0]["text"], "And now the second thing");
    cli.write_line(&claude_result("result-second", "success")).await;
    let done = wait_for(&engine, thread, "the second turn's end", |t| {
        turn_completed(t) && t.latest_turn.as_ref().is_some_and(|l| l.turn_id != first_turn)
    })
    .await;
    // Synara leaves a queued user message unbound (only a steer binds one to its turn).
    let users: Vec<&str> =
        done.messages.iter().filter(|m| m.role == OrchestrationMessageRole::User).map(|m| m.id.as_str()).collect();
    assert_eq!(users, ["msg-1", "msg-2"]);
    let second_turn: TurnId = done.latest_turn.clone().unwrap().turn_id;
    assert_ne!(second_turn, first_turn);
    assert!(!done.activities.iter().any(|a| a.kind == "provider.turn.start.failed"));
    engine.shutdown().await;
}

#[tokio::test]
async fn deleting_a_thread_stops_its_session_and_removes_it() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, published) = start(data.path(), &spawner).await;
    let thread = "thread-delete";
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Hello", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    wait_for(&engine, thread, "the turn to run", running).await;

    engine
        .dispatch(command(json!({ "type": "thread.delete", "commandId": "delete-it", "threadId": thread })))
        .await
        .unwrap();
    cli.expect_closed().await;
    assert_eq!(engine.thread(ThreadId::new(thread)).await.unwrap(), None);
    assert!(engine.shells(None).await.unwrap().is_empty());
    assert!(published
        .lock()
        .unwrap()
        .iter()
        .any(|e| matches!(e, ChatEngineEvent::Removed { thread_id } if thread_id.as_str() == thread)));
    // The thread is gone for good: a command for it is refused.
    let refused = engine.dispatch(turn_start(thread, "msg-2", "Still there?", "queue")).await.unwrap_err();
    assert!(matches!(refused, ChatError::Invalid(_)));
    engine.shutdown().await;
}

#[tokio::test]
async fn an_invalid_command_returns_the_deciders_error() {
    let data = tempfile::tempdir().unwrap();
    let (engine, published) = start(data.path(), &ScriptedSpawner::new()).await;
    let error = engine.dispatch(turn_start("thread-nowhere", "msg-1", "Hello", "queue")).await.unwrap_err();
    match error {
        ChatError::Invalid(detail) => {
            assert_eq!(detail, "Thread 'thread-nowhere' does not exist for command 'thread.turn.start'.")
        }
        ChatError::Internal(error) => panic!("expected an invalid command, got {error:#}"),
    }
    assert!(published.lock().unwrap().is_empty());
    engine.shutdown().await;
}

#[tokio::test]
async fn a_thread_without_a_workspace_fails_its_turn() {
    let data = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-no-cwd";
    engine
        .dispatch(command(json!({
            "type": "thread.create", "commandId": "create", "threadId": thread, "projectId": "",
            "title": "New thread", "modelSelection": { "provider": "claudeAgent", "model": "haiku" },
            "runtimeMode": "full-access", "envMode": "worktree", "branch": null, "worktreePath": null, "createdAt": T0,
        })))
        .await
        .unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Hello", "queue")).await.unwrap();
    let failed = wait_for(&engine, thread, "the failed start", |t| {
        t.session.as_ref().is_some_and(|s| s.status == OrchestrationSessionStatus::Error)
    })
    .await;
    let activity = failed.activities.iter().find(|a| a.kind == "provider.turn.start.failed").unwrap();
    assert_eq!(activity.payload["detail"], "Thread 'thread-no-cwd' targets a worktree that has not been created yet.");
    assert_eq!(
        failed.session.unwrap().last_error.as_deref(),
        Some("Thread 'thread-no-cwd' targets a worktree that has not been created yet.")
    );
    engine.shutdown().await;
}

// --- the Codex app-server's side (as in tests/codex_adapter.rs) ---

struct CodexCli {
    from_engine: Lines<BufReader<DuplexStream>>,
    to_engine: DuplexStream,
}

impl CodexCli {
    async fn read(&mut self) -> Option<Value> {
        let line = timeout(WAIT, self.from_engine.next_line()).await.expect("the engine went quiet").unwrap()?;
        Some(serde_json::from_str(&line).unwrap())
    }

    async fn write(&mut self, message: &Value) {
        let mut line = serde_json::to_vec(message).unwrap();
        line.push(b'\n');
        self.to_engine.write_all(&line).await.unwrap();
    }

    async fn expect_request(&mut self, method: &str) -> Value {
        loop {
            let message = self.read().await.unwrap_or_else(|| panic!("stdin closed before {method}"));
            match message.get("method").and_then(Value::as_str) {
                Some(found) if found == method && message.get("id").is_some() => return message,
                Some(_) if message.get("id").is_some() => {
                    let id = message["id"].clone();
                    self.write(&json!({ "id": id, "error": { "code": -32601, "message": "not recorded" } })).await;
                }
                _ => {}
            }
        }
    }

    /// Plays the recording, waiting at each response for its request and at the approval for the
    /// engine's answer; ends when the engine closes stdin.
    async fn play(mut self, exit: tokio::sync::oneshot::Sender<Option<i32>>) {
        let recorded_methods = [(1, "initialize"), (2, "thread/start"), (3, "turn/start")];
        for line in CODEX_FIXTURE.lines().filter(|line| !line.trim().is_empty()) {
            let mut message: Value = serde_json::from_str(line).unwrap();
            let is_response = message.get("method").is_none();
            let is_server_request = message.get("method").is_some() && message.get("id").is_some();
            if is_response {
                let recorded_id = message["id"].as_i64().unwrap();
                let method = recorded_methods.iter().find(|(id, _)| *id == recorded_id).unwrap().1;
                let request = self.expect_request(method).await;
                message["id"] = request["id"].clone();
                self.write(&message).await;
            } else if is_server_request {
                self.write(&message).await;
                let answer = loop {
                    let answer = self.read().await.expect("stdin closed before the approval was answered");
                    if answer.get("id") == message.get("id") && answer.get("method").is_none() {
                        break answer;
                    }
                };
                assert_eq!(answer, json!({ "id": message["id"], "result": { "decision": "accept" } }));
            } else {
                self.write(&message).await;
            }
        }
        while self.read().await.is_some() {}
        let _ = exit.send(Some(0));
    }
}

#[tokio::test]
async fn a_codex_turn_with_an_approval_runs_end_to_end() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, published) = start(data.path(), &spawner).await;
    let thread = "thread-codex";

    engine.dispatch(create_thread(thread, "codex", "gpt-6-astra", workspace.path())).await.unwrap();
    engine
        .dispatch(turn_start(thread, "msg-1", "Run the shell command `echo hi > codex.txt`, then reply with one word.", "queue"))
        .await
        .unwrap();
    let child = timeout(WAIT, spawner.next()).await.expect("the engine started no CLI");
    assert_eq!(child.spec.program, "codex");
    let cli = CodexCli { from_engine: BufReader::new(child.stdin).lines(), to_engine: child.stdout };
    let script = tokio::spawn(cli.play(child.exit));

    let request_id = pending_approval(&wait_for(&engine, thread, "the approval", |t| pending_approval(t).is_some()).await).unwrap();
    engine.dispatch(approve(thread, &request_id)).await.unwrap();
    let done = wait_for(&engine, thread, "the turn's end", turn_completed).await;

    let assistant: Vec<_> = done.messages.iter().filter(|m| m.role == OrchestrationMessageRole::Assistant).collect();
    assert!(!assistant.is_empty());
    let text: String = assistant.iter().map(|m| m.text.as_str()).collect::<Vec<_>>().join("\n");
    assert!(text.contains("Done"), "{text}");
    assert!(assistant.iter().all(|m| !m.streaming));
    let kinds: Vec<&str> = done.activities.iter().map(|a| a.kind.as_str()).collect();
    for kind in ["approval.requested", "approval.resolved", "tool.completed"] {
        assert!(kinds.contains(&kind), "{kind} missing from {kinds:?}");
    }
    let session = done.session.clone().unwrap();
    assert_eq!(session.status, OrchestrationSessionStatus::Ready);
    assert_eq!(session.provider_name.as_deref(), Some("codex"));
    assert_eq!(done.latest_turn.as_ref().unwrap().state, OrchestrationLatestTurnState::Completed);
    let sequences = published_sequences(&published, thread);
    assert_eq!(sequences, (1..=sequences.len() as u64).collect::<Vec<_>>());

    engine.shutdown().await;
    timeout(WAIT, script).await.expect("the recording did not finish").unwrap();
    let (reopened, _) = start(data.path(), &ScriptedSpawner::new()).await;
    assert_eq!(reopened.thread(ThreadId::new(thread)).await.unwrap().unwrap(), done);
    reopened.shutdown().await;
}

#[tokio::test]
async fn an_unreadable_thread_row_fails_only_that_thread() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    engine.dispatch(create_thread("thread-good", "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(create_thread("thread-bad", "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start("thread-bad", "msg-1", "Take your time", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    wait_for(&engine, "thread-bad", "the turn to run", running).await;
    engine.shutdown().await;

    // A running thread whose message no longer decodes (so settling it cannot load it), and a
    // thread row that is not a thread at all.
    let db = rusqlite::Connection::open(data.path().join("chat.db")).unwrap();
    assert!(db.execute("UPDATE messages SET json = '{' WHERE thread_id = 'thread-bad'", []).unwrap() > 0);
    db.execute(
        "INSERT INTO threads (id, project_id, deleted, updated_at, json) VALUES ('thread-garbage', 'project-1', 0, ?1, '{\"nope\":1}')",
        [T0],
    )
    .unwrap();
    drop(db);

    let (reopened, _) = start(data.path(), &ScriptedSpawner::new()).await;
    let mut listed: Vec<String> = reopened.shells(None).await.unwrap().into_iter().map(|s| s.id.as_str().to_owned()).collect();
    listed.sort();
    assert_eq!(listed, ["thread-bad", "thread-good"]);
    assert!(reopened.thread(ThreadId::new("thread-good")).await.unwrap().is_some());
    assert!(reopened.thread(ThreadId::new("thread-bad")).await.is_err());
    reopened.shutdown().await;
}

fn edit_and_resend(thread: &str, message: &str, text: &str) -> ClientThreadCommand {
    command(json!({
        "type": "thread.message.edit-and-resend",
        "commandId": format!("edit-{message}"),
        "threadId": thread,
        "messageId": message,
        "text": text,
        "assistantDeliveryMode": "streaming",
        "runtimeMode": "approval-required",
        "interactionMode": "default",
        "createdAt": T0,
    }))
}

fn git_refs(dir: &Path) -> Vec<String> {
    let output = std::process::Command::new("git").args(["for-each-ref", "--format=%(refname)"]).current_dir(dir).output().unwrap();
    String::from_utf8(output.stdout).unwrap().lines().map(str::to_owned).collect()
}

/// A git workspace whose thread has run the recorded turn (which writes `probe.txt`) and has its
/// checkpoint; the CLI is still running.
async fn thread_after_one_turn(
    engine: &ChatEngine,
    spawner: &ScriptedSpawner,
    workspace: &Path,
    thread: &str,
) -> (ClaudeCli, tokio::sync::oneshot::Sender<Option<i32>>) {
    git_init(workspace);
    std::fs::write(workspace.join("README.md"), "hello\n").unwrap();
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace)).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Write the probe", "queue")).await.unwrap();
    let (mut cli, exit) = ClaudeCli::spawned(spawner).await;
    cli.read_user_message().await;
    wait_for(engine, thread, "the turn to run", running).await;
    std::fs::write(workspace.join("probe.txt"), "hi\n").unwrap();
    play_claude_turn(engine, &mut cli, thread).await;
    wait_for(engine, thread, "the turn's checkpoint", |t| t.checkpoints.iter().any(|c| c.checkpoint_turn_count == 1)).await;
    (cli, exit)
}

#[tokio::test]
async fn an_edit_whose_restore_checkpoint_is_gone_changes_nothing() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-edit-missing";
    let (mut cli, _exit) = thread_after_one_turn(&engine, &spawner, workspace.path(), thread).await;

    // The turn-0 baseline is gone: there is nothing to restore the edit to.
    let baseline = git_refs(workspace.path()).into_iter().find(|r| r.ends_with("/turn/0")).expect("a turn-0 baseline");
    let status = std::process::Command::new("git").args(["update-ref", "-d", &baseline]).current_dir(workspace.path()).status().unwrap();
    assert!(status.success());
    std::fs::write(workspace.path().join("later.txt"), "kept\n").unwrap();

    engine.dispatch(edit_and_resend(thread, "msg-1", "Write the probe again")).await.unwrap();
    let failed = wait_for(&engine, thread, "the refused edit", |t| {
        t.session.as_ref().is_some_and(|s| s.status == OrchestrationSessionStatus::Error)
    })
    .await;
    assert_eq!(
        failed.session.unwrap().last_error.as_deref(),
        Some("Filesystem checkpoint for edit replay turn 0 is unavailable.")
    );
    // Not HEAD, not a clean: the workspace is as it was.
    assert!(workspace.path().join("probe.txt").exists());
    assert!(workspace.path().join("later.txt").exists());
    // The conversation was not reset: the CLI was not stopped.
    let read = timeout(Duration::from_millis(300), cli.stdin.next_line()).await;
    assert!(!matches!(read, Ok(Ok(None))), "the edit stopped the CLI before it found its checkpoint");
    assert!(!git_refs(workspace.path()).iter().any(|r| r.contains("/revert-rescue/")));
    engine.shutdown().await;
}

#[tokio::test]
async fn an_edit_stops_the_cli_then_restores_the_workspace_and_resends() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-edit";
    let (mut cli, exit) = thread_after_one_turn(&engine, &spawner, workspace.path(), thread).await;

    engine.dispatch(edit_and_resend(thread, "msg-1", "Write the probe again")).await.unwrap();
    // The old CLI is stopped first, and the workspace is untouched until it has gone.
    cli.expect_closed().await;
    assert!(workspace.path().join("probe.txt").exists(), "the workspace was restored before the CLI had stopped");
    let _ = exit.send(Some(0));

    let (mut resent, _exit) = ClaudeCli::spawned(&spawner).await;
    let user = resent.read_user_message().await;
    assert_eq!(user["message"]["content"][0]["text"], "Write the probe again");
    assert!(!workspace.path().join("probe.txt").exists(), "the workspace is back at turn 0");
    assert!(workspace.path().join("README.md").exists());
    assert!(!git_refs(workspace.path()).iter().any(|r| r.contains("/revert-rescue/")), "the rescue snapshot is cleaned up");
    engine.shutdown().await;
}

#[tokio::test]
async fn threads_let_go_from_memory_read_back_and_number_on() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let (engine, _) = start(data.path(), &ScriptedSpawner::new()).await;
    let created = engine.dispatch(create_thread("thread-0", "claudeAgent", "haiku", workspace.path())).await.unwrap();
    for n in 1..=cascade_chat::orchestration::engine::MAX_IDLE_THREADS_IN_MEMORY + 8 {
        engine.dispatch(create_thread(&format!("thread-{n}"), "claudeAgent", "haiku", workspace.path())).await.unwrap();
    }
    // An unknown id is refused and leaves nothing behind.
    assert!(engine.dispatch(turn_start("thread-unknown", "msg-1", "Hello", "queue")).await.is_err());
    assert!(engine.thread(ThreadId::new("thread-unknown")).await.unwrap().is_none());
    // The first thread was let go; it is read back and its numbering carries on.
    let renamed = engine
        .dispatch(command(json!({ "type": "thread.meta.update", "commandId": "rename", "threadId": "thread-0", "title": "Renamed" })))
        .await
        .unwrap();
    assert_eq!(renamed.sequence, created.sequence + 1);
    assert_eq!(engine.thread(ThreadId::new("thread-0")).await.unwrap().unwrap().title, "Renamed");
    engine.shutdown().await;
}
