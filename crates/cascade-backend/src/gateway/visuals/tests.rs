//! Synara `inlineVisualTools.test.ts`, case for case, against the publication apart from the
//! engine (its append scripted), then the tool end to end through `POST /mcp` with a chat's turn
//! running, `orchestration.getInlineVisual`, and the thread's deletion.

use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use serde_json::{json, Value};

use super::*;

const THREAD: &str = "thread-visuals";

fn text(result: &ToolResult) -> String {
    result.content[0]["text"].as_str().unwrap_or_default().to_owned()
}

fn html(label: &str) -> String {
    format!("<!doctype html><svg width=\"200\" height=\"80\"><text x=\"4\" y=\"40\">{label}</text></svg>")
}

/// How the scripted engine answers an append.
#[derive(Clone, Copy, PartialEq)]
enum Answer {
    Record,
    Fail,
    TurnStopped,
}

struct Harness {
    dir: tempfile::TempDir,
    publisher: Publisher,
    appended: Arc<Mutex<Vec<Appended>>>,
    answer: Mutex<Answer>,
}

impl Harness {
    fn new() -> Self {
        Self { dir: tempfile::tempdir().unwrap(), publisher: Publisher::default(), appended: Arc::default(), answer: Mutex::new(Answer::Record) }
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    async fn call_in(&self, turn: &str, args: Value) -> ToolResult {
        let answer = *self.answer.lock().unwrap();
        let appended = self.appended.clone();
        self.publisher
            .publish(self.root().to_path_buf(), THREAD, turn, &args, |entry| async move {
                match answer {
                    Answer::Record => {
                        appended.lock().unwrap().push(entry);
                        Ok(())
                    }
                    Answer::Fail => Err(AppendError::Failed("dispatch failed".into())),
                    Answer::TurnStopped => Err(AppendError::TurnInactive("The turn is no longer active.".into())),
                }
            })
            .await
    }

    async fn call(&self, args: Value) -> ToolResult {
        self.call_in("turn-1", args).await
    }

    fn stored_files(&self) -> Vec<String> {
        let directory = store::thread_directory(self.root(), THREAD).unwrap();
        let mut names: Vec<String> = std::fs::read_dir(directory)
            .map(|entries| entries.flatten().map(|entry| entry.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        names.sort();
        names
    }

    fn appended(&self) -> Vec<Appended> {
        self.appended.lock().unwrap().clone()
    }

    fn set(&self, answer: Answer) {
        *self.answer.lock().unwrap() = answer;
    }
}

fn visual_id(result: &ToolResult) -> String {
    let parsed: Value = serde_json::from_str(&text(result)).unwrap_or_else(|_| panic!("not a result: {}", text(result)));
    parsed["visualId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn stores_the_page_and_records_it_on_the_callers_running_turn() {
    let harness = Harness::new();
    let page = html("Revenue by quarter — €");
    let result = harness.call(json!({ "title": "  Revenue\tby\nquarter ", "html": page })).await;
    assert!(!result.is_error, "{}", text(&result));
    let id = visual_id(&result);
    assert!(store::is_visual_id(&id), "{id}");
    let appended = harness.appended();
    assert_eq!(
        appended,
        vec![Appended {
            thread_id: THREAD.into(),
            turn_id: "turn-1".into(),
            digest: id[4..].to_owned(),
            payload: json!({
                "visualId": id,
                "format": "html",
                "title": "Revenue by quarter",
                "height": 320,
                "byteLength": page.len(),
                "sha256": store::sha256_hex(page.as_bytes()),
            }),
        }]
    );
    assert_eq!(store::read(harness.root(), THREAD, &id).unwrap(), Some(page));
    let reply: Value = serde_json::from_str(&text(&result)).unwrap();
    assert_eq!(reply["embed"], format!("```synara-visual\n{id}\n```"));
}

#[tokio::test]
async fn refuses_invalid_input_before_storing_anything() {
    let harness = Harness::new();
    // 100k three-byte characters stay under a character limit but exceed 256 KiB.
    let oversized = format!("<p>{}</p>", "€".repeat(100_000));
    for (args, message) in [
        (json!({ "title": "Big", "html": oversized }), "the limit is 256 KiB"),
        (json!({ "title": " \n ", "html": html("x") }), "\"title\" must be a non-empty string"),
        (json!({ "title": "t".repeat(121), "html": html("x") }), "at most 120 characters"),
        (json!({ "title": "Blank", "html": "   " }), "\"html\" must be a non-empty HTML document"),
        (json!({ "title": "Height", "html": html("x"), "height": "tall" }), "\"height\" must be a number"),
    ] {
        let result = harness.call(args.clone()).await;
        assert!(result.is_error, "{}", &args.to_string()[..80.min(args.to_string().len())]);
        assert!(text(&result).contains(message), "{} lacks {message}", text(&result));
    }
    assert!(harness.appended().is_empty());
    assert!(harness.stored_files().is_empty());
}

#[tokio::test]
async fn stores_a_component_spec_as_normalized_json_with_an_estimated_height() {
    let harness = Harness::new();
    let result = harness
        .call(json!({
            "title": "Latency",
            "blocks": [
                { "type": "stats", "items": [{ "label": "p95", "value": " 120 ms ", "trend": "down", "extra": 1 }] },
                { "type": "bar-chart", "unit": "ms", "items": [
                    { "label": "api", "value": 120, "highlight": true },
                    { "label": "db", "value": 40 },
                ] },
            ],
        }))
        .await;
    assert!(!result.is_error, "{}", text(&result));
    let stored = store::read(harness.root(), THREAD, &visual_id(&result)).unwrap().unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&stored).unwrap(),
        json!({ "blocks": [
            { "type": "stats", "items": [{ "label": "p95", "value": "120 ms", "trend": "down" }] },
            { "type": "bar-chart", "unit": "ms", "items": [
                { "label": "api", "value": 120, "highlight": true },
                { "label": "db", "value": 40 },
            ] },
        ] })
    );
    let appended = harness.appended();
    assert_eq!(appended[0].payload["format"], "components");
    assert_eq!(appended[0].payload["byteLength"], stored.len());
    // Stats tile plus two bars and the gap between them.
    assert_eq!(appended[0].payload["height"], 88 + 16 + 56);
}

#[tokio::test]
async fn refuses_specs_that_would_not_render_as_meant_naming_the_block() {
    let harness = Harness::new();
    let calculator = |formula: &str| {
        json!({
            "type": "calculator",
            "inputs": [{ "id": "total", "label": "Total", "value": 100 }],
            "outputs": [{ "label": "Each", "formula": formula }],
        })
    };
    for (args, message) in [
        (json!({ "title": "Both", "html": html("x"), "blocks": [] }), "exactly one of \"blocks\" or \"html\""),
        (json!({ "title": "None" }), "exactly one of \"blocks\" or \"html\""),
        (json!({ "title": "Empty", "blocks": [] }), "at least 1"),
        (json!({ "title": "Unknown", "blocks": [{ "type": "pie" }] }), "Block types: markdown"),
        (
            json!({ "title": "Ragged", "blocks": [{ "type": "table", "columns": [{ "label": "A" }], "rows": [[1, 2]] }] }),
            "row 0 has 2 cells for 1 columns\n  at blocks[0]",
        ),
        (
            json!({ "title": "Series", "blocks": [{ "type": "line-chart", "labels": ["a", "b", "c"], "series": [{ "name": "s", "values": [1, 2] }] }] }),
            "series 0 \"s\" has 2 values for 3 labels",
        ),
        (json!({ "title": "Formula", "blocks": [calculator("total / people")] }), "formula of \"Each\": unknown input \"people\""),
        (
            json!({ "title": "Order", "blocks": [{
                "type": "calculator",
                "inputs": [{ "id": "total", "label": "Total", "value": 100 }],
                "outputs": [
                    { "label": "Twice", "formula": "half * 4" },
                    { "id": "half", "label": "Half", "formula": "total / 2" },
                ],
            }] }),
            "formula of \"Twice\": unknown input \"half\"",
        ),
        (
            json!({ "title": "Clash", "blocks": [{
                "type": "calculator",
                "inputs": [{ "id": "total", "label": "Total", "value": 100 }],
                "outputs": [{ "id": "total", "label": "Again", "formula": "total" }],
            }] }),
            "id \"total\" is used twice",
        ),
        (
            json!({ "title": "Nested", "blocks": [{ "type": "tabs", "tabs": [
                { "label": "A", "blocks": [{ "type": "markdown", "text": "a" }] },
                { "label": "B", "blocks": [calculator("eval(total)")] },
            ] }] }),
            "at blocks[0].tabs[1].blocks[0]",
        ),
        // Shapes the schema refuses, beyond Synara's cases.
        (json!({ "title": "Tone", "blocks": [{ "type": "callout", "tone": "loud", "text": "x" }] }), "blocks[0].tone"),
        (json!({ "title": "Null", "blocks": [{ "type": "stats", "items": [{ "label": "a", "value": "1", "detail": null }] }] }), "blocks[0].items[0].detail"),
        (json!({ "title": "Deep", "blocks": [{ "type": "tabs", "tabs": [
            { "label": "A", "blocks": [{ "type": "tabs", "tabs": [] }] },
            { "label": "B", "blocks": [{ "type": "markdown", "text": "b" }] },
        ] }] }), "except tabs"),
    ] {
        let result = harness.call(args.clone()).await;
        assert!(result.is_error, "{args}");
        assert!(text(&result).contains(message), "{:?} lacks {message:?}", text(&result));
    }
    assert!(harness.appended().is_empty());
    assert!(harness.stored_files().is_empty());
}

#[tokio::test]
async fn clamps_the_reserved_height_to_the_frame_bounds() {
    let harness = Harness::new();
    harness.call(json!({ "title": "Short", "html": html("a"), "height": 10 })).await;
    harness.call(json!({ "title": "Tall", "html": html("b"), "height": 9_000 })).await;
    let heights: Vec<Value> = harness.appended().iter().map(|entry| entry.payload["height"].clone()).collect();
    assert_eq!(heights, [json!(80), json!(1600)]);
}

#[tokio::test]
async fn adds_no_row_and_keeps_no_file_when_the_turn_stopped_while_the_page_was_saved() {
    let harness = Harness::new();
    harness.set(Answer::TurnStopped);
    let result = harness.call(json!({ "title": "Late", "html": html("late") })).await;
    assert!(result.is_error);
    assert!(text(&result).contains("no longer active"));
    assert!(harness.appended().is_empty());
    assert!(harness.stored_files().is_empty());
}

#[tokio::test]
async fn removes_a_page_whose_row_could_not_be_recorded_but_never_a_retried_page() {
    let harness = Harness::new();
    harness.set(Answer::Fail);
    let failed = harness.call(json!({ "title": "Lost", "html": html("lost") })).await;
    assert!(failed.is_error);
    assert!(text(&failed).contains("could not be shown: dispatch failed"));
    assert!(harness.stored_files().is_empty());

    harness.set(Answer::Record);
    let shown = harness.call(json!({ "title": "Kept", "html": html("kept") })).await;
    let id = visual_id(&shown);
    // An identical retry reuses the id; its failure must not delete the page the first,
    // successful call already shows.
    harness.set(Answer::Fail);
    let retry = harness.call(json!({ "title": "Kept", "html": html("kept") })).await;
    assert!(retry.is_error);
    assert_eq!(harness.stored_files(), [format!("{id}.html")]);
    assert_eq!(harness.appended().len(), 1);
}

#[tokio::test]
async fn repeats_an_identical_call_as_the_same_visual_and_caps_distinct_visuals_per_turn() {
    let harness = Harness::new();
    let first = visual_id(&harness.call(json!({ "title": "Same", "html": html("same") })).await);
    let again = visual_id(&harness.call(json!({ "title": "Same", "html": html("same") })).await);
    assert_eq!(again, first);
    let appended = harness.appended();
    assert_eq!(appended[1].digest, appended[0].digest);

    for index in 1..PER_TURN_LIMIT {
        let result = harness.call(json!({ "title": format!("Chart {index}"), "html": html(&index.to_string()) })).await;
        assert!(!result.is_error, "{}", text(&result));
    }
    let over = harness.call(json!({ "title": "One more", "html": html("more") })).await;
    assert!(over.is_error);
    assert!(text(&over).contains(&format!("already shows {PER_TURN_LIMIT} visuals")));
    // A retry of an already shown visual is still answered at the cap.
    assert!(!harness.call(json!({ "title": "Same", "html": html("same") })).await.is_error);
    // The cap is per turn.
    let next_turn = harness.call_in("turn-2", json!({ "title": "One more", "html": html("more") })).await;
    assert!(!next_turn.is_error, "{}", text(&next_turn));
}

#[tokio::test]
async fn keeps_a_successful_visual_when_an_identical_overlapping_retry_fails() {
    let harness = Arc::new(Harness::new());
    let args = json!({ "title": "Shared", "html": html("Shared") });
    let appended = harness.appended.clone();
    let succeeding = {
        let (harness, args, appended) = (harness.clone(), args.clone(), appended.clone());
        tokio::spawn(async move {
            harness
                .publisher
                .publish(harness.root().to_path_buf(), THREAD, "turn-1", &args, |entry| async move {
                    appended.lock().unwrap().push(entry);
                    Ok(())
                })
                .await
        })
    };
    let failing = {
        let (harness, args) = (harness.clone(), args.clone());
        tokio::spawn(async move {
            harness
                .publisher
                .publish(harness.root().to_path_buf(), THREAD, "turn-1", &args, |_| async {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    Err(AppendError::TurnInactive("stopped".into()))
                })
                .await
        })
    };
    let (success, failure) = (succeeding.await.unwrap(), failing.await.unwrap());
    assert!(!success.is_error);
    assert!(failure.is_error);
    let appended = harness.appended();
    assert_eq!(appended.len(), 1);
    let id = appended[0].payload["visualId"].as_str().unwrap();
    assert_eq!(store::read(harness.root(), THREAD, id).unwrap().as_deref(), args["html"].as_str());
}

/// The tool through the gateway: offered to a chat with its instructions, refused without a
/// running turn, recorded on the running turn's thread, read back over the chat RPC, and gone with
/// the thread.
mod end_to_end {
    use axum::{
        body::{to_bytes, Body},
        http::{Request, StatusCode},
        Router,
    };
    use cascade_chat::{provider::process::ScriptedSpawner, AgentGateway, ChatEngineConfig};
    use tokio::{
        io::{AsyncBufReadExt, BufReader},
        time::timeout,
    };
    use tower::ServiceExt;

    use super::*;

    const WAIT: Duration = Duration::from_secs(10);
    const T0: &str = "2026-10-05T10:00:00.000Z";

    async fn post(router: &Router, path: &str, token: Option<&str>, body: Value) -> (StatusCode, Value) {
        let mut request = Request::post(path).header("content-type", "application/json");
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let response = router.clone().oneshot(request.body(Body::from(body.to_string())).unwrap()).await.unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
    }

    async fn call_tool(router: &Router, token: &str, arguments: Value) -> Value {
        let (status, body) = post(
            router,
            crate::gateway::MCP_PATH,
            Some(token),
            json!({ "jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": { "name": TOOL_NAME, "arguments": arguments } }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["result"].clone()
    }

    async fn rpc(router: &Router, method: &str, params: Value) -> (StatusCode, Value) {
        post(router, "/api/chat/rpc", None, json!({ "method": method, "params": params })).await
    }

    async fn thread(router: &Router, id: &str) -> Value {
        rpc(router, "orchestration.getThreadDetailSnapshot", json!({ "threadId": id })).await.1["result"]["thread"].clone()
    }

    #[tokio::test]
    async fn a_chats_agent_shows_a_visual_on_its_running_turn_and_the_page_reads_it() {
        let dir = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let spawner = ScriptedSpawner::new();
        let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        state.gateway.configure(4321, dir.path()).unwrap();
        state.gateway.register_all();
        let config = ChatEngineConfig {
            data_dir: dir.path().join("chat"),
            spawner: Arc::new(spawner.clone()),
            adapters: None,
            publish: crate::chat::publisher(state.events.clone()),
            git: None,
            text_generation: None,
            agent_gateway: Some(state.gateway.clone()),
        };
        crate::chat::start_with(&state, config).await.unwrap();
        let router = crate::build_app(state.clone());

        let create = json!({ "command": {
            "type": "thread.create", "commandId": "create-v", "threadId": "chat-v",
            "projectId": cascade_chat::STANDALONE_PROJECT_ID, "title": "New chat",
            "modelSelection": { "provider": "claudeAgent", "model": "claude-opus-4-6" },
            "runtimeMode": "approval-required", "branch": null, "worktreePath": null,
            "workingDirectory": work.path().to_string_lossy(), "createdAt": T0,
        }});
        assert_eq!(rpc(&router, "orchestration.dispatchCommand", create).await.0, StatusCode::OK);
        let token = state.gateway.connection(&cascade_chat::contracts::base::ThreadId::new("chat-v")).unwrap().bearer_token;

        // Offered to the chat, with Synara's policy line as the server's instructions.
        let (_, listed) = post(&router, crate::gateway::MCP_PATH, Some(&token), json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" })).await;
        assert_eq!(listed["result"]["tools"][0]["name"], TOOL_NAME);
        let (_, initialized) =
            post(&router, crate::gateway::MCP_PATH, Some(&token), json!({ "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {} })).await;
        assert_eq!(initialized["result"]["instructions"], INSTRUCTIONS);

        let blocks = json!({ "title": "Latency", "blocks": [{ "type": "stats", "items": [{ "label": "p95", "value": "120 ms" }] }] });
        // No turn runs: refused, nothing recorded.
        let refused = call_tool(&router, &token, blocks.clone()).await;
        assert_eq!(refused["isError"], true);
        assert!(refused["content"][0]["text"].as_str().unwrap().contains("caller_turn_inactive"));

        let turn = json!({ "command": {
            "type": "thread.turn.start", "commandId": "turn-v", "threadId": "chat-v",
            "message": { "messageId": "message-v", "role": "user", "text": "chart it", "attachments": [] },
            "assistantDeliveryMode": "streaming", "dispatchMode": "queue",
            "runtimeMode": "approval-required", "interactionMode": "default", "createdAt": T0,
        }});
        assert_eq!(rpc(&router, "orchestration.dispatchCommand", turn).await.0, StatusCode::OK);
        let child = timeout(WAIT, spawner.next()).await.expect("the engine started the CLI");
        let mut stdin = BufReader::new(child.stdin).lines();
        timeout(WAIT, async {
            while let Some(line) = stdin.next_line().await.unwrap() {
                if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["type"] == "user") {
                    return;
                }
            }
        })
        .await
        .expect("the turn's message reached the CLI");
        let running_turn = timeout(WAIT, async {
            loop {
                let latest = thread(&router, "chat-v").await["latestTurn"].clone();
                if latest["state"] == "running" {
                    return latest["turnId"].as_str().unwrap().to_owned();
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("the turn runs");

        let shown = call_tool(&router, &token, blocks).await;
        assert!(shown.get("isError").is_none(), "{shown}");
        let reply: Value = serde_json::from_str(shown["content"][0]["text"].as_str().unwrap()).unwrap();
        let id = reply["visualId"].as_str().unwrap().to_owned();

        let activities = thread(&router, "chat-v").await["activities"].clone();
        let row = activities.as_array().unwrap().iter().find(|a| a["kind"] == ACTIVITY_KIND).cloned().expect("a visual.shown row");
        assert_eq!(row["turnId"], running_turn.as_str());
        assert_eq!(row["summary"], "Visual: Latency");
        assert_eq!(row["payload"]["visualId"], id.as_str());
        assert_eq!(row["payload"]["format"], "components");

        let (status, read) = rpc(&router, "orchestration.getInlineVisual", json!({ "threadId": "chat-v", "visualId": id })).await;
        assert_eq!(status, StatusCode::OK, "{read}");
        assert_eq!(read["result"]["visualId"], id.as_str());
        let spec: Value = serde_json::from_str(read["result"]["html"].as_str().unwrap()).unwrap();
        assert_eq!(spec["blocks"][0]["items"][0]["value"], "120 ms");
        let (status, missing) =
            rpc(&router, "orchestration.getInlineVisual", json!({ "threadId": "chat-other", "visualId": id })).await;
        assert_eq!((status, missing["error"]["code"].as_str()), (StatusCode::NOT_FOUND, Some("inline-visual-missing")));

        // The thread's deletion takes its visuals along.
        let folder = store::thread_directory(&state.chat.attachments_dir().unwrap(), "chat-v").unwrap();
        assert!(folder.is_dir());
        let delete = json!({ "command": { "type": "thread.delete", "commandId": "delete-v", "threadId": "chat-v" } });
        assert_eq!(rpc(&router, "orchestration.dispatchCommand", delete).await.0, StatusCode::OK);
        timeout(WAIT, async {
            while folder.exists() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("the deleted thread's visuals were removed");
        drop(child.stdout);
        state.chat.shutdown().await;
    }

    #[tokio::test]
    async fn a_terminal_is_not_offered_the_tool() {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let caller = Caller::Terminal { run_id: "run-1".into(), cwd: None };
        assert!(!ShowVisual::default().offered_to(&state, &caller));
    }
}
