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
            OrchestrationMessageSource, OrchestrationSessionStatus, OrchestrationThread,
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
    write_claude_turn_as(engine, cli, thread, CLAUDE_SESSION).await;
}

/// [`write_claude_turn`] as a CLI whose session is `session`.
async fn write_claude_turn_as(engine: &ChatEngine, cli: &mut ClaudeCli, thread: &str, session: &str) {
    let (lines, approval) = claude_lines();
    let lines: Vec<String> = lines.iter().map(|line| line.replace(CLAUDE_SESSION, session)).collect();
    let lines: Vec<&str> = lines.iter().map(String::as_str).collect();
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
    // Codex resolves an approval twice: the decision Cascade sent (`item/requestApproval/decision`)
    // and the app-server's `serverRequest/resolved`. Synara records both too; its work log shows
    // only the activities of the turns on screen and hides accepted resolutions, so the decision
    // row is the one that can show, and the other, like the session's startup notices
    // (`provider.event.unmapped`), carries no turn and never does.
    let resolved: Vec<_> = done.activities.iter().filter(|a| a.kind == "approval.resolved").collect();
    let in_turn: Vec<_> = resolved.iter().filter(|a| a.turn_id.is_some()).collect();
    assert_eq!(in_turn.len(), 1, "{resolved:?}");
    assert_eq!(in_turn[0].payload["requestId"], json!(request_id));
    assert_eq!(in_turn[0].payload["decision"], "accept");
    assert!(resolved.iter().filter(|a| a.turn_id.is_none()).all(|a| a.payload.get("requestId").is_none()));
    let unmapped: Vec<_> = done.activities.iter().filter(|a| a.kind == "provider.event.unmapped").collect();
    assert!(!unmapped.is_empty());
    assert!(unmapped.iter().all(|a| a.turn_id.is_none()), "{unmapped:?}");
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

fn undo_files(thread: &str, turn_count: u64, id: &str) -> ClientThreadCommand {
    command(json!({
        "type": "thread.checkpoint.revert",
        "commandId": id,
        "threadId": thread,
        "turnCount": turn_count,
        "scope": "files",
        "createdAt": T0,
    }))
}

#[tokio::test]
async fn a_files_undo_takes_back_one_turns_changes_and_keeps_the_conversation() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-undo-files";
    let (mut cli, _exit) = thread_after_one_turn(&engine, &spawner, workspace.path(), thread).await;
    let before = engine.thread(ThreadId::new(thread)).await.unwrap().unwrap();
    assert!(before.checkpoints.iter().any(|c| c.checkpoint_turn_count == 1 && c.files.iter().any(|f| f.path == "probe.txt")));
    // An edit made after the turn, to a file the turn did not touch, is left alone.
    std::fs::write(workspace.path().join("README.md"), "hello\nlater\n").unwrap();

    engine.dispatch(undo_files(thread, 1, "undo-1")).await.unwrap();
    let undone = wait_for(&engine, thread, "the files undo", |t| {
        t.activities.iter().any(|a| a.kind == "checkpoint.revert.succeeded" || a.kind == "checkpoint.revert.failed")
    })
    .await;
    assert!(
        undone.activities.iter().any(|a| a.kind == "checkpoint.revert.succeeded" && a.payload["turnCount"] == 1),
        "{:#?}",
        undone.activities.iter().map(|a| (&a.kind, &a.payload)).collect::<Vec<_>>()
    );
    assert!(!workspace.path().join("probe.txt").exists(), "the turn's file was taken back");
    assert_eq!(std::fs::read_to_string(workspace.path().join("README.md")).unwrap(), "hello\nlater\n");
    let checkpoint = undone.checkpoints.iter().find(|c| c.checkpoint_turn_count == 1).unwrap();
    assert!(checkpoint.files.is_empty(), "the turn's diff is now empty");
    // The conversation stays: same messages, same latest turn, the CLI still running.
    assert_eq!(undone.messages.len(), before.messages.len());
    assert_eq!(undone.latest_turn.as_ref().map(|t| &t.turn_id), before.latest_turn.as_ref().map(|t| &t.turn_id));
    let read = timeout(Duration::from_millis(300), cli.stdin.next_line()).await;
    assert!(!matches!(read, Ok(Ok(None))), "a files undo stopped the CLI");

    // Undoing it again is refused: there is nothing left to take back.
    engine.dispatch(undo_files(thread, 1, "undo-2")).await.unwrap();
    let refused = wait_for(&engine, thread, "the refused second undo", |t| {
        t.activities.iter().any(|a| a.kind == "checkpoint.revert.failed")
    })
    .await;
    let failure = refused.activities.iter().find(|a| a.kind == "checkpoint.revert.failed").unwrap();
    assert_eq!(failure.payload["detail"], "File changes for turn 1 are unavailable or already undone.");
    engine.shutdown().await;
}

#[tokio::test]
async fn a_files_undo_that_conflicts_leaves_the_workspace_as_it_was() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-undo-conflict";
    let (_cli, _exit) = thread_after_one_turn(&engine, &spawner, workspace.path(), thread).await;
    // The file the turn wrote has since been rewritten: its reverse no longer applies.
    std::fs::write(workspace.path().join("probe.txt"), "rewritten\n").unwrap();

    engine.dispatch(undo_files(thread, 1, "undo-conflict")).await.unwrap();
    let failed = wait_for(&engine, thread, "the failed undo", |t| {
        t.activities.iter().any(|a| a.kind == "checkpoint.revert.failed" || a.kind == "checkpoint.revert.succeeded")
    })
    .await;
    let failure = failed.activities.iter().find(|a| a.kind == "checkpoint.revert.failed").expect("the undo failed");
    assert!(
        failure.payload["detail"].as_str().unwrap().starts_with("Undo could not be applied because the workspace changed"),
        "{}",
        failure.payload["detail"]
    );
    assert_eq!(std::fs::read_to_string(workspace.path().join("probe.txt")).unwrap(), "rewritten\n");
    assert!(!failed.checkpoints.iter().find(|c| c.checkpoint_turn_count == 1).unwrap().files.is_empty());
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

// --- forks ---

fn fork_thread(thread: &str, source: &str, project: &str, provider: &str, model: &str, cwd: &Path, imported: Vec<Value>) -> ClientThreadCommand {
    command(json!({
        "type": "thread.fork.create",
        "commandId": format!("fork-{thread}"),
        "threadId": thread,
        "sourceThreadId": source,
        "projectId": project,
        "title": "Ignored: a fork is titled from its lineage",
        "modelSelection": { "provider": provider, "model": model },
        "runtimeMode": "approval-required",
        "branch": null,
        "worktreePath": cwd.to_string_lossy(),
        "importedMessages": imported,
        "createdAt": T0,
    }))
}

/// The transcript a page imports into a fork: the settled messages, under ids of their own.
fn imported_messages(thread: &OrchestrationThread) -> Vec<Value> {
    thread
        .messages
        .iter()
        .filter(|m| !m.streaming && m.role != OrchestrationMessageRole::System)
        .map(|m| {
            json!({
                "messageId": format!("fork-{}", m.id),
                "role": if m.role == OrchestrationMessageRole::User { "user" } else { "assistant" },
                "text": m.text,
                "createdAt": m.created_at,
                "updatedAt": m.updated_at,
            })
        })
        .collect()
}

fn arg_value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter().find_map(|arg| arg.strip_prefix(flag)?.strip_prefix('='))
}

#[tokio::test]
async fn a_claude_fork_resumes_the_source_conversation_under_a_session_of_its_own() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let source = "thread-fork-source";
    engine.dispatch(create_thread(source, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(source, "msg-1", "Write the probe", "queue")).await.unwrap();
    let source_child = timeout(WAIT, spawner.next()).await.expect("the engine started no CLI");
    // The CLI keeps the session id it is started with; the recording's is replaced by it.
    let source_session = arg_value(&source_child.spec.args, "--session-id").unwrap().to_owned();
    let mut cli = ClaudeCli { stdin: BufReader::new(source_child.stdin).lines(), stdout: source_child.stdout };
    cli.read_user_message().await;
    write_claude_turn_as(&engine, &mut cli, source, &source_session).await;
    let done = wait_for(&engine, source, "the turn's end", turn_completed).await;

    // The fork is a new thread of the same project and folder that names its source, titled in
    // the source's lineage, with the source's transcript imported.
    let imported = imported_messages(&done);
    let fork = "thread-fork";
    engine
        .dispatch(fork_thread(fork, source, "project-1", "claudeAgent", "haiku", workspace.path(), imported.clone()))
        .await
        .unwrap();
    let forked = engine.thread(ThreadId::new(fork)).await.unwrap().unwrap();
    assert_eq!(forked.fork_source_thread_id.as_ref().map(|id| id.as_str()), Some(source));
    assert_eq!(forked.project_id.as_str(), "project-1");
    assert_eq!(forked.worktree_path.as_deref(), Some(workspace.path().to_str().unwrap()));
    assert_eq!(forked.title, format!("{} (2)", done.title));
    assert_eq!(forked.messages.len(), imported.len());
    assert!(forked.messages.iter().all(|m| m.source == OrchestrationMessageSource::ForkImport && m.turn_id.is_none()));
    assert!(forked.session.is_none(), "a fork starts no CLI until its first turn");
    // The next fork of the lineage numbers on; a fork must stay in its source's project.
    engine.dispatch(fork_thread("thread-fork-2", fork, "project-1", "claudeAgent", "haiku", workspace.path(), vec![])).await.unwrap();
    assert_eq!(engine.thread(ThreadId::new("thread-fork-2")).await.unwrap().unwrap().title, format!("{} (3)", done.title));
    let refused = engine
        .dispatch(fork_thread("thread-fork-x", source, "project-2", "claudeAgent", "haiku", workspace.path(), vec![]))
        .await
        .unwrap_err();
    assert!(matches!(&refused, ChatError::Invalid(detail) if detail == &format!("Source thread '{source}' belongs to a different project.")), "{refused}");
    let missing = engine
        .dispatch(fork_thread("thread-fork-y", "thread-none", "project-1", "claudeAgent", "haiku", workspace.path(), vec![]))
        .await
        .unwrap_err();
    assert!(matches!(missing, ChatError::Invalid(_)));
    assert!(engine.thread(ThreadId::new("thread-fork-x")).await.unwrap().is_none());
    // A fork into a new worktree (Synara's "Fork Into New Worktree": worktree mode, no path yet)
    // is refused: nothing here makes the worktree.
    let mut into_worktree = serde_json::to_value(fork_thread("thread-fork-w", source, "project-1", "claudeAgent", "haiku", workspace.path(), vec![])).unwrap();
    into_worktree["envMode"] = json!("worktree");
    into_worktree["worktreePath"] = Value::Null;
    let refused = engine.dispatch(command(into_worktree)).await.unwrap_err();
    assert!(
        matches!(&refused, ChatError::Invalid(detail) if detail.contains("cannot be forked into a new worktree")),
        "{refused}"
    );
    assert!(engine.thread(ThreadId::new("thread-fork-w")).await.unwrap().is_none());

    // Its first turn forks the source's conversation: the CLI resumes the source's session with
    // `--fork-session` under a new session id of the fork's own.
    engine.dispatch(turn_start(fork, "msg-f1", "And again", "queue")).await.unwrap();
    let child = timeout(WAIT, spawner.next()).await.expect("the fork started no CLI");
    let args = child.spec.args.clone();
    assert_eq!(arg_value(&args, "--resume"), Some(source_session.as_str()), "{args:?}");
    assert!(args.iter().any(|arg| arg == "--fork-session"), "{args:?}");
    assert_eq!(arg_value(&args, "--resume-session-at"), None, "{args:?}");
    let fork_session = arg_value(&args, "--session-id").expect("a session id of the fork's own").to_owned();
    assert_ne!(fork_session, source_session);
    assert_eq!(child.spec.cwd.as_deref(), Some(workspace.path()));
    let mut fork_cli = ClaudeCli { stdin: BufReader::new(child.stdin).lines(), stdout: child.stdout };
    let user = fork_cli.read_user_message().await;
    assert_eq!(user["message"]["content"][0]["text"], "And again");
    write_claude_turn_as(&engine, &mut fork_cli, fork, &fork_session).await;
    wait_for(&engine, fork, "the fork's turn", |t| turn_completed(t) && t.messages.len() > imported.len() + 1).await;
    // The source is untouched by its fork.
    assert_eq!(engine.thread(ThreadId::new(source)).await.unwrap().unwrap().messages, done.messages);

    // Once the fork has a conversation of its own, its next CLI resumes that one, unforked.
    drop(fork_cli);
    let _ = child.exit.send(Some(0));
    wait_for(&engine, fork, "the fork's CLI to end", |t| {
        t.session.as_ref().is_some_and(|s| s.status == OrchestrationSessionStatus::Stopped)
    })
    .await;
    engine.dispatch(turn_start(fork, "msg-f2", "Once more", "queue")).await.unwrap();
    let again = timeout(WAIT, spawner.next()).await.expect("the fork started no second CLI");
    assert_eq!(arg_value(&again.spec.args, "--resume"), Some(fork_session.as_str()), "{:?}", again.spec.args);
    assert!(!again.spec.args.iter().any(|arg| arg == "--fork-session"));
    engine.shutdown().await;
}

/// A fork forks its source once: when its own first session binds. A revert that takes the fork
/// back to before its first turn clears its conversation, but not that: its next session, even
/// after a restart, starts a conversation of its own rather than forking the source again.
#[tokio::test]
async fn a_fork_reverted_to_its_start_does_not_fork_its_source_again() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let source = "thread-fork-revert-source";
    let (_source_cli, _source_exit) = thread_after_one_turn(&engine, &spawner, workspace.path(), source).await;
    let done = engine.thread(ThreadId::new(source)).await.unwrap().unwrap();

    let fork = "thread-fork-revert";
    let imported = imported_messages(&done);
    engine
        .dispatch(fork_thread(fork, source, "project-1", "claudeAgent", "haiku", workspace.path(), imported.clone()))
        .await
        .unwrap();
    engine.dispatch(turn_start(fork, "msg-f1", "And again", "queue")).await.unwrap();
    let child = timeout(WAIT, spawner.next()).await.expect("the fork started no CLI");
    assert!(child.spec.args.iter().any(|arg| arg == "--fork-session"), "{:?}", child.spec.args);
    let source_cursor = arg_value(&child.spec.args, "--resume").expect("the source's conversation").to_owned();
    let fork_session = arg_value(&child.spec.args, "--session-id").unwrap().to_owned();
    let mut fork_cli = ClaudeCli { stdin: BufReader::new(child.stdin).lines(), stdout: child.stdout };
    fork_cli.read_user_message().await;
    write_claude_turn_as(&engine, &mut fork_cli, fork, &fork_session).await;
    wait_for(&engine, fork, "the fork's checkpoint", |t| {
        turn_completed(t) && t.checkpoints.iter().any(|c| c.checkpoint_turn_count == 1)
    })
    .await;

    // Back to before the fork's first turn: its conversation is forgotten and its CLI stopped.
    engine
        .dispatch(command(json!({
            "type": "thread.checkpoint.revert",
            "commandId": "revert-fork",
            "threadId": fork,
            "turnCount": 0,
            "createdAt": T0,
        })))
        .await
        .unwrap();
    let reverted = wait_for(&engine, fork, "the revert", |t| {
        t.activities.iter().any(|a| a.kind == "checkpoint.revert.succeeded" || a.kind == "checkpoint.revert.failed")
    })
    .await;
    assert!(
        reverted.activities.iter().any(|a| a.kind == "checkpoint.revert.succeeded"),
        "{:#?}",
        reverted.activities.iter().map(|a| (&a.kind, &a.payload)).collect::<Vec<_>>()
    );
    fork_cli.expect_closed().await;
    let _ = child.exit.send(Some(0));
    engine.shutdown().await;

    // A new engine on the same data: the fork still knows it was bound.
    let (engine, _) = start(data.path(), &spawner).await;
    engine.dispatch(turn_start(fork, "msg-f2", "Once more", "queue")).await.unwrap();
    let again = timeout(WAIT, spawner.next()).await.expect("the fork started no second CLI");
    let args = &again.spec.args;
    assert!(!args.iter().any(|arg| arg == "--fork-session"), "{args:?}");
    assert_ne!(arg_value(args, "--resume"), Some(source_cursor.as_str()), "{args:?}");
    assert_eq!(arg_value(args, "--resume"), None, "a conversation of its own, started anew: {args:?}");
    engine.shutdown().await;
}

#[tokio::test]
async fn a_codex_fork_opens_its_thread_with_thread_fork() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let source = "thread-codex-source";
    engine.dispatch(create_thread(source, "codex", "gpt-6-astra", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(source, "msg-1", "Run the shell command `echo hi > codex.txt`, then reply with one word.", "queue")).await.unwrap();
    let child = timeout(WAIT, spawner.next()).await.expect("the engine started no CLI");
    let cli = CodexCli { from_engine: BufReader::new(child.stdin).lines(), to_engine: child.stdout };
    let script = tokio::spawn(cli.play(child.exit));
    let request_id = pending_approval(&wait_for(&engine, source, "the approval", |t| pending_approval(t).is_some()).await).unwrap();
    engine.dispatch(approve(source, &request_id)).await.unwrap();
    let done = wait_for(&engine, source, "the turn's end", turn_completed).await;

    let fork = "thread-codex-fork";
    engine
        .dispatch(fork_thread(fork, source, "project-1", "codex", "gpt-6-astra", workspace.path(), imported_messages(&done)))
        .await
        .unwrap();
    engine.dispatch(turn_start(fork, "msg-f1", "Now say two words.", "queue")).await.unwrap();
    let child = timeout(WAIT, spawner.next()).await.expect("the fork started no CLI");
    assert_eq!(child.spec.program, "codex");
    let mut cli = CodexCli { from_engine: BufReader::new(child.stdin).lines(), to_engine: child.stdout };
    let initialize = cli.expect_request("initialize").await;
    let recorded: Value = serde_json::from_str(CODEX_FIXTURE.lines().find(|l| l.starts_with("{\"id\":1,")).unwrap()).unwrap();
    cli.write(&json!({ "id": initialize["id"], "result": recorded["result"] })).await;
    // The source's Codex thread is forked, not resumed or started anew.
    let open = cli.expect_request("thread/fork").await;
    assert_eq!(open["params"]["threadId"], "01a10cd4-2005-7d13-9f55-5688b88f0ee2");
    assert_eq!(open["params"]["excludeTurns"], true);
    cli.write(&json!({ "id": open["id"], "result": { "thread": { "id": "fork-codex-thread" }, "model": "gpt-6-astra" } })).await;
    let turn = cli.expect_request("turn/start").await;
    assert_eq!(turn["params"]["threadId"], "fork-codex-thread");
    engine.shutdown().await;
    let _ = timeout(WAIT, script).await;
}

#[tokio::test]
async fn a_codex_turn_with_a_review_target_runs_a_native_review() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-codex-review";
    engine.dispatch(create_thread(thread, "codex", "gpt-6-astra", workspace.path())).await.unwrap();
    // The page's /review: a turn whose message names the review and carries its target.
    let mut review = serde_json::to_value(turn_start(thread, "msg-r1", "Review current changes", "queue")).unwrap();
    review["reviewTarget"] = json!({ "type": "uncommittedChanges" });
    engine.dispatch(command(review)).await.unwrap();

    let child = timeout(WAIT, spawner.next()).await.expect("the engine started no CLI");
    let mut cli = CodexCli { from_engine: BufReader::new(child.stdin).lines(), to_engine: child.stdout };
    let recorded = |id: i64| -> Value {
        serde_json::from_str(CODEX_FIXTURE.lines().find(|l| l.starts_with(&format!("{{\"id\":{id},"))).unwrap()).unwrap()
    };
    let initialize = cli.expect_request("initialize").await;
    cli.write(&json!({ "id": initialize["id"], "result": recorded(1)["result"] })).await;
    let open = cli.expect_request("thread/start").await;
    cli.write(&json!({ "id": open["id"], "result": recorded(2)["result"] })).await;
    let provider_thread = recorded(2)["result"]["thread"]["id"].clone();
    // A review, not a message: `review/start` inline on the session's thread.
    let start = cli.expect_request("review/start").await;
    assert_eq!(start["params"]["threadId"], provider_thread);
    assert_eq!(start["params"]["delivery"], "inline");
    assert_eq!(start["params"]["target"], json!({ "type": "uncommittedChanges" }));
    // As codex 0.160 runs a review (recorded live): the review's turn, an inner turn that starts
    // and never completes, every item routed to the review's turn, the result as
    // `exitedReviewMode`, then an agent message repeating it, then the review's turn completes.
    let turn = "review-turn-1";
    cli.write(&json!({ "id": start["id"], "result": { "turn": { "id": turn, "items": [], "status": "inProgress" } } })).await;
    cli.write(&json!({ "method": "item/started", "params": { "threadId": provider_thread, "turnId": turn, "item": { "type": "enteredReviewMode", "id": "entered-1", "review": "current changes" } } })).await;
    cli.write(&json!({ "method": "turn/started", "params": { "threadId": provider_thread, "turn": { "id": "inner-turn", "status": "inProgress" } } })).await;
    wait_for(&engine, thread, "the review to run", running).await;
    let findings = "No issues found in the uncommitted changes.";
    cli.write(&json!({ "method": "item/completed", "params": { "threadId": provider_thread, "turnId": turn, "item": { "type": "exitedReviewMode", "id": "exited-1", "review": findings } } })).await;
    let echo = json!({ "type": "agentMessage", "id": "msg-echo", "text": findings, "phase": "final_answer" });
    cli.write(&json!({ "method": "item/started", "params": { "threadId": provider_thread, "turnId": turn, "item": echo } })).await;
    cli.write(&json!({ "method": "item/agentMessage/delta", "params": { "threadId": provider_thread, "turnId": turn, "itemId": "msg-echo", "delta": findings } })).await;
    cli.write(&json!({ "method": "item/completed", "params": { "threadId": provider_thread, "turnId": turn, "item": echo } })).await;
    let done = wait_for(&engine, thread, "the review's end", turn_completed).await;
    cli.write(&json!({ "method": "turn/completed", "params": { "threadId": provider_thread, "turn": { "id": turn, "status": "completed" } } })).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let done = engine.thread(ThreadId::new(thread)).await.unwrap().unwrap_or(done);
    let answers: Vec<_> = done.messages.iter().filter(|m| m.role == OrchestrationMessageRole::Assistant).collect();
    assert_eq!(answers.len(), 1, "the review is drawn once: {answers:#?}");
    assert!(answers[0].text.contains(findings));
    assert_eq!(answers[0].turn_id.as_ref().map(|t| t.as_str()), Some(turn));
    assert_eq!(done.latest_turn.as_ref().map(|t| t.turn_id.as_str()), Some(turn));
    engine.shutdown().await;
}

// --- diffs, shells and attachments ---

#[tokio::test]
async fn turn_and_thread_diffs_come_from_the_checkpoint_refs() {
    use cascade_chat::{
        checkpointing::diff_query::CheckpointDiffError,
        contracts::orchestration::{OrchestrationGetFullThreadDiffInput, OrchestrationGetTurnDiffInput},
    };
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-diff";
    let (_cli, _exit) = thread_after_one_turn(&engine, &spawner, workspace.path(), thread).await;
    let turn = |from, to| OrchestrationGetTurnDiffInput {
        thread_id: ThreadId::new(thread),
        from_turn_count: from,
        to_turn_count: to,
        ignore_whitespace: None,
    };

    let diff = engine.turn_diff(turn(0, 1)).await.unwrap();
    assert_eq!((diff.from_turn_count, diff.to_turn_count), (0, 1));
    assert!(diff.diff.contains("diff --git a/probe.txt b/probe.txt"), "{}", diff.diff);
    assert!(diff.diff.contains("+hi"), "{}", diff.diff);
    assert!(!diff.diff.contains("README.md"), "the baseline already had it: {}", diff.diff);
    let full = engine
        .full_thread_diff(OrchestrationGetFullThreadDiffInput { thread_id: ThreadId::new(thread), to_turn_count: 1, ignore_whitespace: Some(false) })
        .await
        .unwrap();
    assert_eq!(full.diff, diff.diff);
    assert_eq!(serde_json::to_value(&full).unwrap()["fromTurnCount"], 0);

    assert_eq!(engine.turn_diff(turn(1, 1)).await.unwrap().diff, "");
    assert!(matches!(
        engine.turn_diff(turn(0, 2)).await,
        Err(CheckpointDiffError::Unavailable { turn_count: 2, ref detail }) if detail == "Turn diff range exceeds current turn count: requested 2, current 1."
    ));
    assert!(matches!(engine.turn_diff(turn(1, 0)).await, Err(CheckpointDiffError::Invariant(_))));
    let missing = OrchestrationGetTurnDiffInput { thread_id: ThreadId::new("thread-none"), ..turn(0, 1) };
    assert_eq!(engine.turn_diff(missing).await, Err(CheckpointDiffError::Invariant("Thread 'thread-none' not found.".into())));
    engine.shutdown().await;
}

#[tokio::test]
async fn the_shell_snapshot_lists_every_thread() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let (engine, _) = start(data.path(), &ScriptedSpawner::new()).await;
    let first = engine.dispatch(create_thread("thread-a", "claudeAgent", "haiku", workspace.path())).await.unwrap();
    let second = engine.dispatch(create_thread("thread-b", "codex", "gpt-6-astra", workspace.path())).await.unwrap();
    let snapshot = engine.shell_snapshot().await.unwrap();
    let ids: Vec<&str> = snapshot.threads.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(ids.len(), 2);
    assert!(ids.contains(&"thread-a") && ids.contains(&"thread-b"));
    assert_eq!(snapshot.snapshot_sequence, first.sequence + second.sequence);
    let wire = serde_json::to_value(&snapshot).unwrap();
    assert_eq!(wire["spaces"], json!([]));
    assert_eq!(wire["projects"], json!([]));
    assert!(wire["updatedAt"].is_string());
    engine.shutdown().await;

    // After a restart nothing is in memory: every sequence comes from the store, in one read.
    let (engine, _) = start(data.path(), &ScriptedSpawner::new()).await;
    let third = engine.dispatch(create_thread("thread-c", "claudeAgent", "haiku", workspace.path())).await.unwrap();
    let snapshot = engine.shell_snapshot().await.unwrap();
    assert_eq!(snapshot.threads.len(), 3);
    assert_eq!(snapshot.snapshot_sequence, first.sequence + second.sequence + third.sequence);
    engine.shutdown().await;
}

#[tokio::test]
async fn a_saved_attachment_is_read_back_by_its_id_alone() {
    let data = tempfile::tempdir().unwrap();
    let (engine, _) = start(data.path(), &ScriptedSpawner::new()).await;
    let saved = engine
        .save_attachment(ThreadId::new("Thread One"), "shot.png".into(), "image/png".into(), b"\x89PNG".to_vec())
        .await
        .unwrap();
    let id = serde_json::to_value(&saved).unwrap()["id"].as_str().unwrap().to_owned();
    assert!(id.starts_with("thread-one-"), "{id}");
    let (path, bytes) = engine.read_attachment(id.clone()).await.unwrap().unwrap();
    assert_eq!(bytes, b"\x89PNG");
    assert_eq!(path.extension().unwrap(), "png");
    std::fs::write(data.path().join("secret.txt"), "no").unwrap();
    for refused in ["../secret", "secret", &format!("{id}.png"), &format!("../attachments/{id}"), ""] {
        assert!(engine.read_attachment(refused.to_owned()).await.unwrap().is_none(), "{refused}");
    }
    engine.shutdown().await;
}

#[tokio::test]
async fn a_claude_subagent_gets_a_read_only_child_thread() {
    const SUBAGENT_FIXTURE: &str = include_str!("fixtures/claude-turn-with-subagent.jsonl");
    const AGENT: &str = "toolu_01UURA7ASnZqors4Psep6oL5";
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, published) = start(data.path(), &spawner).await;
    let thread = "thread-parent";
    let child = format!("subagent:{thread}:{AGENT}");

    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Use the Agent tool to list the files", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    let lines: Vec<&str> = SUBAGENT_FIXTURE.lines().filter(|l| !l.trim().is_empty()).collect();
    let approval = lines.iter().position(|l| l.contains("\"can_use_tool\"")).unwrap();
    cli.write_lines(&lines[..=approval]).await;

    // The subagent's Bash approval waits on the parent, where the person answers it.
    let request_id = pending_approval(&wait_for(&engine, thread, "the approval", |t| pending_approval(t).is_some()).await).unwrap();
    let running_child = wait_for(&engine, &child, "the child to run", running).await;
    assert_eq!(pending_approval(&running_child), None);
    engine.dispatch(approve(thread, &request_id)).await.unwrap();
    cli.read_until("the approval response", |v| v["type"] == "control_response").await;
    cli.write_lines(&lines[approval + 1..]).await;
    let parent = wait_for(&engine, thread, "the parent's turn", turn_completed).await;

    // The child: made from the Task tool, linked to its parent, holding the subagent's work.
    let done = wait_for(&engine, &child, "the child's turn", |t| {
        t.latest_turn.as_ref().is_some_and(|turn| turn.state == OrchestrationLatestTurnState::Completed)
    })
    .await;
    assert_eq!(done.parent_thread_id.as_ref().map(ThreadId::as_str), Some(thread));
    assert_eq!(done.project_id, parent.project_id);
    assert_eq!(done.subagent_nickname.as_deref(), Some("List files in current directory"));
    assert_eq!(done.subagent_role.as_deref(), Some("general-purpose"));
    assert_eq!(done.title, "List files in current directory [general-purpose]");
    assert_eq!(serde_json::to_value(done.creation_source).unwrap(), "provider_native");
    assert_eq!(done.worktree_path, parent.worktree_path);
    let child_text: Vec<&str> = done
        .messages
        .iter()
        .filter(|m| m.role == OrchestrationMessageRole::Assistant)
        .map(|m| m.text.as_str())
        .collect();
    assert_eq!(child_text.len(), 1, "{child_text:?}");
    assert!(child_text[0].contains("a.txt"), "{child_text:?}");
    assert!(
        done.activities.iter().any(|a| a.kind == "tool.completed" && a.payload["itemType"] == "command_execution"),
        "{:?}",
        done.activities.iter().map(|a| &a.kind).collect::<Vec<_>>()
    );

    // The parent keeps the Task tool as one row naming the child, and only its own words.
    let parent_text: Vec<&str> =
        parent.messages.iter().filter(|m| m.role == OrchestrationMessageRole::Assistant).map(|m| m.text.as_str()).collect();
    assert_eq!(parent_text.len(), 1, "{parent_text:?}");
    assert!(parent_text[0].starts_with("The directory contains five files"));
    let collab = parent
        .activities
        .iter()
        .find(|a| a.kind == "tool.completed" && a.payload["itemType"] == "collab_agent_tool_call")
        .expect("the Task tool's row");
    assert_eq!(collab.payload["data"]["receiverThreadId"], AGENT);
    assert!(!parent.activities.iter().any(|a| a.payload["itemType"] == "command_execution"));

    // Lists see it with its parent, and the app hears of it.
    let shells = engine.shells(None).await.unwrap();
    let listed = shells.iter().find(|s| s.id.as_str() == child).expect("the child is listed");
    assert_eq!(listed.parent_thread_id.as_ref().map(ThreadId::as_str), Some(thread));
    assert!(published.lock().unwrap().iter().any(|e| matches!(e, ChatEngineEvent::Shell { shell } if shell.id.as_str() == child)));

    // Nothing is sent from the child: it follows its parent's agent.
    let refused = engine.dispatch(turn_start(&child, "msg-2", "hello", "queue")).await;
    assert!(matches!(refused, Err(ChatError::Invalid(_))), "{refused:?}");

    // Archiving, restoring and deleting the parent take the child along.
    engine
        .dispatch(command(json!({ "type": "thread.archive", "commandId": "archive", "threadId": thread })))
        .await
        .unwrap();
    assert!(engine.thread(ThreadId::new(child.clone())).await.unwrap().unwrap().archived_at.is_some());
    engine
        .dispatch(command(json!({ "type": "thread.unarchive", "commandId": "unarchive", "threadId": thread })))
        .await
        .unwrap();
    assert!(engine.thread(ThreadId::new(child.clone())).await.unwrap().unwrap().archived_at.is_none());
    engine.dispatch(command(json!({ "type": "thread.delete", "commandId": "delete", "threadId": thread }))).await.unwrap();
    assert!(engine.thread(ThreadId::new(child.clone())).await.unwrap().is_none());
    engine.shutdown().await;
}

const SUBAGENT_FIXTURE: &str = include_str!("fixtures/claude-turn-with-subagent.jsonl");
const SUBAGENT_TOOL: &str = "toolu_01UURA7ASnZqors4Psep6oL5";

#[tokio::test]
async fn a_running_subagent_thread_is_settled_when_the_engine_starts_again() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-parent-restart";
    let child = format!("subagent:{thread}:{SUBAGENT_TOOL}");
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Use the Agent tool to list the files", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    let lines: Vec<&str> = SUBAGENT_FIXTURE.lines().filter(|l| !l.trim().is_empty()).collect();
    let approval = lines.iter().position(|l| l.contains("\"can_use_tool\"")).unwrap();
    cli.write_lines(&lines[..=approval]).await;
    wait_for(&engine, &child, "the child to run", running).await;
    engine.shutdown().await;

    // The app quit mid-subagent: the child is saved running, and is settled with its parent.
    let (reopened, _) = start(data.path(), &ScriptedSpawner::new()).await;
    let after = reopened.thread(ThreadId::new(child.clone())).await.unwrap().unwrap();
    let session = after.session.clone().unwrap();
    assert_eq!(session.status, OrchestrationSessionStatus::Stopped);
    assert_eq!(session.active_turn_id, None);
    assert_eq!(after.latest_turn.unwrap().state, OrchestrationLatestTurnState::Interrupted);
    assert!(after.messages.iter().all(|m| !m.streaming));
    reopened.shutdown().await;
}

#[tokio::test]
async fn a_parent_turn_shows_at_most_twenty_subagent_threads() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-many-subagents";
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Spawn 21 agents", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    let lines: Vec<&str> = SUBAGENT_FIXTURE.lines().filter(|l| !l.trim().is_empty()).collect();
    let line = |needle: &str| *lines.iter().find(|l| l.contains(needle)).unwrap();
    let tool_start = lines.iter().position(|l| l.contains("\"content_block_start\",\"index\":1")).unwrap();
    let tool_message = line("\"wire_tool_inputs\"");
    let task_started = line("\"subtype\":\"task_started\"");
    let prompt = line("\"task_description\"");
    let child_text = *lines.iter().find(|l| l.contains("\"type\":\"text\",\"text\":\"The current working directory")).unwrap();

    // One assistant message with 21 Task tools, each its own block.
    cli.write_lines(&lines[..tool_start]).await;
    let tool = |i: usize| format!("toolu_many_{i:02}");
    for i in 0..21 {
        let index = i + 1;
        let id = tool(i);
        cli.write_line(&lines[tool_start].replace(SUBAGENT_TOOL, &id).replace("\"index\":1", &format!("\"index\":{index}")).replace("\"uuid\":\"", &format!("\"uuid\":\"s{i}-"))).await;
        cli.write_line(&tool_message.replace(SUBAGENT_TOOL, &id).replace("\"uuid\":\"", &format!("\"uuid\":\"m{i}-"))).await;
        cli.write_line(&format!(
            r#"{{"type":"stream_event","event":{{"type":"content_block_stop","index":{index}}},"session_id":"a67cccb5-1155-486e-ba1f-63ee053c5e97","parent_tool_use_id":null,"uuid":"stop-{i}"}}"#
        ))
        .await;
    }
    let capped = wait_for(&engine, thread, "the cap notice", |t| {
        t.activities.iter().any(|a| a.kind == "subagent.materialization.capped")
    })
    .await;
    let parent_turn = capped.session.as_ref().and_then(|s| s.active_turn_id.clone()).expect("the parent's turn runs");

    // The 21st subagent runs anyway: its own events, under its own turn, make no thread either.
    let last = tool(20);
    for template in [task_started, prompt, child_text] {
        cli.write_line(&template.replace(SUBAGENT_TOOL, &last).replace("\"uuid\":\"", "\"uuid\":\"last-")).await;
    }
    cli.write_line(&claude_result("result-many", "success")).await;
    wait_for(&engine, thread, "the parent's turn", |t| t.session.as_ref().is_some_and(|s| s.active_turn_id.is_none())).await;

    let children: Vec<_> = engine
        .shells(None)
        .await
        .unwrap()
        .into_iter()
        .filter(|s| s.parent_thread_id.as_ref().map(ThreadId::as_str) == Some(thread))
        .collect();
    assert_eq!(children.len(), 20, "{:?}", children.iter().map(|c| c.id.as_str()).collect::<Vec<_>>());
    assert!(children.iter().all(|c| c.source_turn_id.as_ref() == Some(&parent_turn)));
    assert!(engine.thread(ThreadId::new(format!("subagent:{thread}:{last}"))).await.unwrap().is_none());
    engine.shutdown().await;
}

#[tokio::test]
async fn archiving_a_parent_succeeds_when_a_subagent_thread_cannot_follow() {
    let data = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let spawner = ScriptedSpawner::new();
    let (engine, _) = start(data.path(), &spawner).await;
    let thread = "thread-parent-archive";
    let child = format!("subagent:{thread}:{SUBAGENT_TOOL}");
    engine.dispatch(create_thread(thread, "claudeAgent", "haiku", workspace.path())).await.unwrap();
    engine.dispatch(turn_start(thread, "msg-1", "Use the Agent tool to list the files", "queue")).await.unwrap();
    let (mut cli, _exit) = ClaudeCli::spawned(&spawner).await;
    cli.read_user_message().await;
    let lines: Vec<&str> = SUBAGENT_FIXTURE.lines().filter(|l| !l.trim().is_empty()).collect();
    let approval = lines.iter().position(|l| l.contains("\"can_use_tool\"")).unwrap();
    cli.write_lines(&lines[..=approval]).await;
    let request_id = pending_approval(&wait_for(&engine, thread, "the approval", |t| pending_approval(t).is_some()).await).unwrap();
    engine.dispatch(approve(thread, &request_id)).await.unwrap();
    cli.read_until("the approval response", |v| v["type"] == "control_response").await;
    cli.write_lines(&lines[approval + 1..]).await;
    wait_for(&engine, thread, "the parent's turn", turn_completed).await;
    wait_for(&engine, &child, "the child's turn", |t| t.latest_turn.as_ref().is_some_and(|l| l.state == OrchestrationLatestTurnState::Completed)).await;
    engine.shutdown().await;

    // The child is listed but can no longer be read whole.
    let db = rusqlite::Connection::open(data.path().join("chat.db")).unwrap();
    assert!(db.execute("UPDATE messages SET json = '{' WHERE thread_id = ?1", [&child]).unwrap() > 0);
    drop(db);

    let (reopened, _) = start(data.path(), &ScriptedSpawner::new()).await;
    reopened
        .dispatch(command(json!({ "type": "thread.archive", "commandId": "archive", "threadId": thread })))
        .await
        .expect("the parent's archive is not undone by its subagent");
    assert!(reopened.thread(ThreadId::new(thread)).await.unwrap().unwrap().archived_at.is_some());
    reopened.shutdown().await;
}
