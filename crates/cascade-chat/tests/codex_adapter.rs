//! The Codex adapter against a recorded `codex app-server` session
//! (`fixtures/codex-turn-with-approval.jsonl`: one turn that runs a shell command after an
//! approval), replayed through a scripted process, and once against the real CLI (ignored).

use std::{sync::Arc, time::Duration};

use cascade_chat::{
    contracts::{
        base::{ApprovalRequestId, ThreadId},
        orchestration::{ProviderApprovalDecision, RuntimeMode},
        provider::{ProviderSendTurnInput, ProviderSessionStartInput},
        provider_runtime::{ProviderRuntimeEvent, ProviderRuntimeEventBody, RuntimeSessionExitKind},
    },
    provider::{
        adapter::ProviderAdapter,
        codex::CodexAdapter,
        process::{ProcessSpawner, ScriptedChild, ScriptedSpawner},
    },
};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines},
    sync::mpsc,
    time::timeout,
};

const FIXTURE: &str = include_str!("fixtures/codex-turn-with-approval.jsonl");
const PROMPT: &str = "Run the shell command `echo hi > codex.txt`, then reply with one word.";
const WAIT: Duration = Duration::from_secs(10);

fn start_input(thread_id: &ThreadId, cwd: &str, runtime_mode: RuntimeMode) -> ProviderSessionStartInput {
    ProviderSessionStartInput {
        thread_id: thread_id.clone(),
        provider: None,
        lifecycle_generation: None,
        provider_instance_id: None,
        cwd: Some(cwd.to_string()),
        model_selection: None,
        resume_cursor: None,
        fork_source_resume_cursor: None,
        approval_policy: None,
        sandbox_mode: None,
        provider_options: None,
        auto_approve_synara_tools: None,
        runtime_mode,
    }
}

fn turn_input(thread_id: &ThreadId) -> ProviderSendTurnInput {
    ProviderSendTurnInput {
        thread_id: thread_id.clone(),
        input: Some(PROMPT.to_string()),
        attachments: None,
        skills: None,
        mentions: None,
        model_selection: None,
        interaction_mode: None,
    }
}

fn event_type(event: &ProviderRuntimeEvent) -> String {
    serde_json::to_value(event).unwrap()["type"].as_str().unwrap().to_string()
}

/// Receives events until one of type `kind` arrives, returning everything received.
async fn events_until(events: &mut mpsc::Receiver<ProviderRuntimeEvent>, kind: &str, wait: Duration) -> Vec<ProviderRuntimeEvent> {
    let mut seen = Vec::new();
    loop {
        let event = timeout(wait, events.recv())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {kind}; saw {:?}", seen.iter().map(event_type).collect::<Vec<_>>()))
            .unwrap_or_else(|| panic!("event stream ended before {kind}"));
        let done = event_type(&event) == kind;
        seen.push(event);
        if done {
            return seen;
        }
    }
}

/// The CLI's side of the scripted process.
struct ScriptedCli {
    from_adapter: Lines<BufReader<DuplexStream>>,
    to_adapter: DuplexStream,
    /// Everything the adapter wrote, in order.
    written: Vec<Value>,
}

impl ScriptedCli {
    fn new(child: ScriptedChild) -> (Self, tokio::sync::oneshot::Sender<Option<i32>>) {
        let cli = Self { from_adapter: BufReader::new(child.stdin).lines(), to_adapter: child.stdout, written: Vec::new() };
        (cli, child.exit)
    }

    async fn read(&mut self) -> Option<Value> {
        let line = timeout(WAIT, self.from_adapter.next_line()).await.expect("adapter went quiet").unwrap()?;
        let message: Value = serde_json::from_str(&line).unwrap();
        self.written.push(message.clone());
        Some(message)
    }

    async fn write(&mut self, message: &Value) {
        let mut line = serde_json::to_vec(message).unwrap();
        line.push(b'\n');
        self.to_adapter.write_all(&line).await.unwrap();
    }

    /// Reads until the adapter sends a request for `method`, answering requests the recording
    /// has no response for (`account/read`) with an error.
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

    /// Plays the recording, pausing at each response until the adapter has asked for it, and
    /// at the approval until the adapter has answered it. Ends when the adapter closes stdin.
    async fn play(mut self, exit: tokio::sync::oneshot::Sender<Option<i32>>) -> Vec<Value> {
        let recorded_methods = [(1, "initialize"), (2, "thread/start"), (3, "turn/start")];
        for line in FIXTURE.lines().filter(|line| !line.trim().is_empty()) {
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
        self.written
    }
}

#[tokio::test]
async fn replays_a_recorded_turn_with_an_approval() {
    let recorded: Vec<Value> = FIXTURE.lines().filter(|line| !line.trim().is_empty()).map(|line| serde_json::from_str(line).unwrap()).collect();
    let provider_thread_id = recorded[2]["result"]["thread"]["id"].as_str().unwrap().to_string();
    let provider_turn_id = recorded.iter().find(|message| message["id"] == 3).unwrap()["result"]["turn"]["id"]
        .as_str()
        .unwrap()
        .to_string();

    let spawner = ScriptedSpawner::new();
    let thread_id = ThreadId::new("thread-codex-replay");
    let (sink, mut events) = mpsc::channel(4096);
    let handle = CodexAdapter::new().start_session(
        start_input(&thread_id, "/tmp/probe", RuntimeMode::ApprovalRequired),
        sink,
        Arc::new(spawner.clone()),
    );
    let child = timeout(WAIT, spawner.next()).await.unwrap();
    assert_eq!(child.spec.program, "codex");
    assert_eq!(child.spec.args, ["app-server"]);
    let (cli, exit) = ScriptedCli::new(child);
    let script = tokio::spawn(cli.play(exit));

    let mut seen = events_until(&mut events, "session.started", WAIT).await;

    let started = handle.send_turn(turn_input(&thread_id)).await.unwrap();
    assert_eq!(started.thread_id, thread_id);
    assert_eq!(started.turn_id.as_str(), provider_turn_id);
    assert_eq!(started.resume_cursor, Some(json!({ "threadId": provider_thread_id })));

    let until_request = events_until(&mut events, "request.opened", WAIT).await;
    let request = until_request.last().unwrap().clone();
    seen.extend(until_request);
    let ProviderRuntimeEventBody::RequestOpened(opened) = &request.body else { unreachable!() };
    assert_eq!(serde_json::to_value(opened.request_type).unwrap(), "command_execution_approval");
    assert_eq!(opened.detail.as_deref(), Some("/bin/zsh -lc 'echo hi > codex.txt'"));
    assert_eq!(request.turn_id.as_ref().map(|turn| turn.as_str()), Some(provider_turn_id.as_str()));
    let request_id = request.request_id.clone().expect("an approval carries its request id");

    handle
        .respond_to_request(ApprovalRequestId::new(request_id.as_str()), ProviderApprovalDecision::Accept)
        .await
        .unwrap();
    seen.extend(events_until(&mut events, "turn.completed", WAIT).await);

    let ProviderRuntimeEventBody::TurnCompleted(completed) = &seen.last().unwrap().body else { unreachable!() };
    assert_eq!(serde_json::to_value(completed.state).unwrap(), "completed");
    let resolved = seen
        .iter()
        .find_map(|event| match &event.body {
            ProviderRuntimeEventBody::RequestResolved(resolved) if resolved.decision.is_some() => Some((event, resolved)),
            _ => None,
        })
        .expect("the decision is reported");
    assert_eq!(resolved.0.request_id, Some(request_id));
    assert_eq!(resolved.1.decision.as_deref(), Some("accept"));
    let text: String = seen
        .iter()
        .filter_map(|event| match &event.body {
            ProviderRuntimeEventBody::ContentDelta(delta) => Some(delta.delta.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(text, "I’ll run the command now.\nDone");

    // The canonical events, in order, ending in turn.completed.
    let kinds: Vec<String> = seen.iter().map(event_type).collect();
    let expected = [
        "session.state.changed",
        "session.state.changed",
        "session.started",
        "thread.started",
        "turn.started",
        "hook.started",
        "hook.completed",
        "item.started",
        "item.completed",
        "item.started",
        "content.delta",
        "item.completed",
        "item.started",
        "request.opened",
        "request.resolved",
        "request.resolved",
        "item.completed",
        "thread.token-usage.updated",
        "account.rate-limits.updated",
        "content.delta",
        "thread.state.changed",
        "turn.completed",
    ];
    let mut cursor = kinds.iter();
    for kind in expected {
        assert!(cursor.any(|seen| seen == kind), "{kind} missing or out of order in {kinds:?}");
    }
    assert!(!kinds.iter().any(|kind| kind == "runtime.error"), "{kinds:?}");
    assert_eq!(kinds.last().map(String::as_str), Some("turn.completed"));

    handle.stop().await.unwrap();
    let after_stop = events_until(&mut events, "session.exited", WAIT).await;
    let ProviderRuntimeEventBody::SessionExited(exited) = &after_stop.last().unwrap().body else { unreachable!() };
    assert_eq!(exited.exit_kind, Some(RuntimeSessionExitKind::Graceful));
    assert!(timeout(WAIT, events.recv()).await.unwrap().is_none(), "nothing follows session.exited");
    assert!(!handle.is_alive());

    // What the adapter wrote: the handshake, the thread, the turn, then the decision.
    let written = timeout(WAIT, script).await.unwrap().unwrap();
    let shape: Vec<String> = written
        .iter()
        .map(|message| match message.get("method").and_then(Value::as_str) {
            Some(method) => method.to_string(),
            None => format!("response:{}", message["id"]),
        })
        .collect();
    assert_eq!(shape, ["initialize", "initialized", "account/read", "thread/start", "turn/start", "response:0"]);
    let thread_start = &written[3]["params"];
    assert_eq!(thread_start["approvalPolicy"], "untrusted");
    assert_eq!(thread_start["approvalsReviewer"], "user");
    assert_eq!(thread_start["sandbox"], "read-only");
    assert_eq!(thread_start["cwd"], "/tmp/probe");
    assert_eq!(written[0]["params"]["capabilities"]["experimentalApi"], true);
    let turn_start = &written[4]["params"];
    assert_eq!(turn_start["threadId"], provider_thread_id.as_str());
    assert_eq!(turn_start["input"], json!([{ "type": "text", "text": PROMPT, "text_elements": [] }]));
    assert_eq!(turn_start["sandboxPolicy"], json!({ "type": "readOnly" }));
    assert_eq!(turn_start["model"], "gpt-6-astra", "the model Codex chose at thread start");
}

#[tokio::test]
async fn a_session_whose_cli_cannot_start_reports_its_end() {
    struct Missing;
    impl cascade_chat::provider::process::Spawner for Missing {
        fn spawn(
            &self,
            _: &cascade_chat::provider::process::SpawnSpec,
        ) -> std::io::Result<cascade_chat::provider::process::ChildProcess> {
            Err(std::io::Error::new(std::io::ErrorKind::NotFound, "no codex"))
        }
    }
    let thread_id = ThreadId::new("thread-missing");
    let (sink, mut events) = mpsc::channel(64);
    let handle = CodexAdapter::new().start_session(start_input(&thread_id, "/tmp", RuntimeMode::FullAccess), sink, Arc::new(Missing));
    let seen = events_until(&mut events, "session.exited", WAIT).await;
    let kinds: Vec<String> = seen.iter().map(event_type).collect();
    assert_eq!(kinds, ["runtime.error", "session.exited"]);
    assert!(handle.send_turn(turn_input(&thread_id)).await.is_err());
}

/// One real turn against the installed `codex app-server`, in a scratch folder. Run with
/// `cargo test --test codex_adapter -- --ignored`; set `CASCADE_CODEX_LIVE_DIR` to choose where
/// the scratch folder goes.
#[tokio::test]
#[ignore]
async fn live_turn_against_codex_app_server() {
    let parent = std::env::var("CASCADE_CODEX_LIVE_DIR").unwrap_or_else(|_| "/private/tmp/claude-501".into());
    let dir = tempfile::tempdir_in(parent).unwrap();
    let cwd = dir.path().to_string_lossy().into_owned();
    let thread_id = ThreadId::new("thread-codex-live");
    let (sink, mut events) = mpsc::channel(4096);
    let handle = CodexAdapter::new().start_session(
        start_input(&thread_id, &cwd, RuntimeMode::ApprovalRequired),
        sink,
        Arc::new(ProcessSpawner),
    );
    let live_wait = Duration::from_secs(180);
    events_until(&mut events, "session.started", live_wait).await;
    handle.send_turn(turn_input(&thread_id)).await.unwrap();
    let mut seen = Vec::new();
    loop {
        let event = timeout(live_wait, events.recv()).await.expect("codex went quiet").expect("session ended");
        let kind = event_type(&event);
        if kind == "request.opened" {
            let request_id = event.request_id.clone().unwrap();
            handle.respond_to_request(ApprovalRequestId::new(request_id.as_str()), ProviderApprovalDecision::Accept).await.unwrap();
        }
        seen.push(kind.clone());
        if kind == "turn.completed" {
            break;
        }
    }
    eprintln!("live events: {seen:?}");
    assert_eq!(std::fs::read_to_string(dir.path().join("codex.txt")).unwrap().trim(), "hi");
    handle.stop().await.unwrap();
    events_until(&mut events, "session.exited", live_wait).await;
}
