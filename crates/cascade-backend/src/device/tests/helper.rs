//! Ported from Synara's `apps/server/src/device/helperClient.test.ts` ("helper stdio control
//! channel", "device point bounds"), plus the attach, stream and line-framer behaviour the Rust port
//! has on top. The helper process is played from the other end of a `ScriptedSpawner`'s pipes.

use std::{
    future::Future,
    io,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex},
    time::Duration,
};

use cascade_chat::provider::process::{ChildProcess, ScriptedChild, ScriptedSpawner, SpawnSpec, Spawner};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    sync::{broadcast, mpsc, oneshot},
    task::JoinHandle,
};

use crate::device::{
    backend::DeviceFrameRecord,
    frame::{encode_device_frame, encode_length_prefixed_record, DeviceFrame, DeviceFrameHeader},
    helper::{
        methods, ControlLineFramer, DeviceHelperError, HelperClient, HelperClientOptions, HelperExitListener,
        HelperLaunch, MAX_CONTROL_LINE_BYTES,
    },
};

const DEVICE: &str = "FAKE-0001";

// ── The helper's side of the pipes ──────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct Request {
    id: i64,
    method: String,
    params: Value,
}

type Task = Pin<Box<dyn Future<Output = ()> + Send>>;

enum Reply {
    /// Bytes on stdout after a delay.
    Write { delay: Duration, bytes: Vec<u8> },
    /// The process ends with this code.
    Exit(Option<i32>),
    /// Something the helper does on its own (connect to the frame socket).
    Task(Task),
}

fn line(value: Value) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(&value).unwrap();
    bytes.push(b'\n');
    bytes
}

fn write(bytes: Vec<u8>) -> Reply {
    Reply::Write { delay: Duration::ZERO, bytes }
}

fn ok(request: &Request, result: Value) -> Reply {
    write(line(json!({ "jsonrpc": "2.0", "id": request.id, "result": result })))
}

fn fail(request: &Request, code: i64, message: &str) -> Reply {
    write(line(json!({ "jsonrpc": "2.0", "id": request.id, "error": { "code": code, "message": message } })))
}

type Handler = Box<dyn FnMut(&Request) -> Vec<Reply> + Send>;
type ExitSlot = Arc<Mutex<Option<oneshot::Sender<Option<i32>>>>>;

struct Harness {
    client: HelperClient,
    requests: Arc<Mutex<Vec<Request>>>,
    exits: mpsc::UnboundedReceiver<String>,
    frames: broadcast::Sender<DeviceFrameRecord>,
    exit: ExitSlot,
    child_spec: Arc<Mutex<Option<SpawnSpec>>>,
    play: JoinHandle<()>,
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.play.abort();
    }
}

impl Harness {
    fn requests(&self) -> Vec<Request> {
        self.requests.lock().unwrap().clone()
    }

    fn methods(&self) -> Vec<String> {
        self.requests().into_iter().map(|request| request.method).collect()
    }

    /// The process ends by itself, as the helper dying would.
    fn exit(&self, code: Option<i32>) {
        let sender = self.exit.lock().unwrap().take().expect("a helper process is running");
        let _ = sender.send(code);
    }

    async fn next_exit(&mut self) -> String {
        tokio::time::timeout(Duration::from_secs(5), self.exits.recv())
            .await
            .expect("on_exit was called")
            .expect("on_exit channel open")
    }
}

fn harness(request_timeout: Duration, handler: impl FnMut(&Request) -> Vec<Reply> + Send + 'static) -> Harness {
    harness_with(HelperLaunch { command: "fake-helper".into(), ..HelperLaunch::default() }, request_timeout, handler)
}

fn harness_with(
    launch: HelperLaunch,
    request_timeout: Duration,
    handler: impl FnMut(&Request) -> Vec<Reply> + Send + 'static,
) -> Harness {
    let spawner = ScriptedSpawner::new();
    let (frames, _) = broadcast::channel(16);
    let (exit_sender, exits) = mpsc::unbounded_channel();
    let on_exit: HelperExitListener = Arc::new(move |reason| {
        let _ = exit_sender.send(reason);
    });
    let client = HelperClient::new(HelperClientOptions {
        spawner: Arc::new(spawner.clone()),
        launch,
        request_timeout,
        frames: frames.clone(),
        on_exit: Some(on_exit),
    });
    let requests = Arc::new(Mutex::new(Vec::new()));
    let exit: ExitSlot = Arc::default();
    let child_spec = Arc::new(Mutex::new(None));
    let play = tokio::spawn(play(spawner, requests.clone(), exit.clone(), child_spec.clone(), Box::new(handler)));
    Harness { client, requests, exits, frames, exit, child_spec, play }
}

async fn play(
    spawner: ScriptedSpawner,
    log: Arc<Mutex<Vec<Request>>>,
    exit_slot: ExitSlot,
    child_spec: Arc<Mutex<Option<SpawnSpec>>>,
    mut handler: Handler,
) {
    let ScriptedChild { spec, stdin, stdout, exit } = spawner.next().await;
    *child_spec.lock().unwrap() = Some(spec);
    *exit_slot.lock().unwrap() = Some(exit);
    let stdout = Arc::new(tokio::sync::Mutex::new(stdout));
    let mut lines = BufReader::new(stdin).lines();
    while let Ok(Some(text)) = lines.next_line().await {
        let value: Value = serde_json::from_str(&text).expect("the client writes one JSON request per line");
        assert_eq!(value["jsonrpc"], "2.0");
        let request = Request {
            id: value["id"].as_i64().expect("integer id"),
            method: value["method"].as_str().expect("method").to_owned(),
            params: value["params"].clone(),
        };
        log.lock().unwrap().push(request.clone());
        for reply in handler(&request) {
            match reply {
                Reply::Write { delay, bytes } => {
                    let stdout = stdout.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(delay).await;
                        let mut stdout = stdout.lock().await;
                        let _ = stdout.write_all(&bytes).await;
                        let _ = stdout.flush().await;
                    });
                }
                Reply::Exit(code) => {
                    if let Some(sender) = exit_slot.lock().unwrap().take() {
                        let _ = sender.send(code);
                    }
                }
                Reply::Task(task) => {
                    tokio::spawn(task);
                }
            }
        }
    }
    // stdin closed: the client asked the helper to leave. The test owns when the exit is told.
    std::future::pending::<()>().await;
}

const SHORT: Duration = Duration::from_millis(200);
const LONG: Duration = Duration::from_secs(10);

/// An `attach` answer for the 402x874 point, 3x phone the bounds tests use.
fn phone() -> Value {
    json!({
        "pixelWidth": 1206, "pixelHeight": 2622, "pointWidth": 402, "pointHeight": 874, "scale": 3,
        "capabilities": { "input": true, "accessibility": true },
    })
}

/// A helper that answers every request with `result: "ok"`, and `attach` with the phone.
fn answering() -> impl FnMut(&Request) -> Vec<Reply> + Send + 'static {
    |request| {
        let result = if request.method == methods::ATTACH { phone() } else { json!("ok") };
        vec![ok(request, result)]
    }
}

fn error_of(result: Result<impl std::fmt::Debug, DeviceHelperError>) -> DeviceHelperError {
    result.expect_err("the call fails")
}

// ── helper stdio control channel ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn correlates_responses_and_maps_helper_error_codes() {
    let h = harness(LONG, |request| match request.method.as_str() {
        "echo" => vec![Reply::Write {
            delay: Duration::from_millis(request.params["delay"].as_u64().unwrap()),
            bytes: line(json!({ "id": request.id, "result": request.params["value"] })),
        }],
        "fail" => vec![fail(request, 17, "helper rejected")],
        _ => vec![],
    });

    let (slow, fast) = tokio::join!(
        h.client.request("echo", json!({ "value": "slow", "delay": 100 })),
        h.client.request("echo", json!({ "value": "fast", "delay": 0 })),
    );
    assert_eq!(slow.unwrap(), json!("slow"));
    assert_eq!(fast.unwrap(), json!("fast"));

    let error = error_of(h.client.request("fail", Value::Null).await);
    assert_eq!(error, DeviceHelperError::new("helper_17", "helper rejected"));
    h.client.dispose().await;
}

#[tokio::test]
async fn writes_json_rpc_requests_with_integer_ids_from_one() {
    let h = harness(LONG, answering());

    h.client.request("ping", Value::Null).await.unwrap();
    h.client.request("list", json!({ "a": 1 })).await.unwrap();

    let requests = h.requests();
    assert_eq!(requests.iter().map(|request| request.id).collect::<Vec<_>>(), [1, 2]);
    assert_eq!(requests[0].method, "ping");
    // No params is an empty object, as the helper's decoder wants an object.
    assert_eq!(requests[0].params, json!({}));
    assert_eq!(requests[1].params, json!({ "a": 1 }));
    h.client.dispose().await;
}

#[tokio::test]
async fn an_error_without_a_code_or_message_still_fails_the_request() {
    let h = harness(LONG, |request| {
        vec![write(line(json!({ "id": request.id, "error": {} })))]
    });

    let error = error_of(h.client.request("odd", Value::Null).await);
    assert_eq!(error, DeviceHelperError::new("helper_error", "Device helper reported an error"));
    h.client.dispose().await;
}

#[tokio::test]
async fn reports_helper_timeout_when_a_control_request_receives_no_response() {
    let h = harness(SHORT, |_| vec![]);

    let error = error_of(h.client.request("never", Value::Null).await);
    assert_eq!(error.code, "helper_timeout");
    assert_eq!(error.message, "Device helper never timed out.");
    h.client.dispose().await;
}

#[tokio::test]
async fn a_timeout_names_the_sandbox_profile_the_helper_runs_under() {
    let launch = HelperLaunch {
        command: "sandbox-exec".into(),
        profile_path: Some(PathBuf::from("/tmp/helper.sb")),
        ..HelperLaunch::default()
    };
    let h = harness_with(launch, SHORT, |_| vec![]);

    let error = error_of(h.client.request("never", Value::Null).await);
    assert_eq!(error.code, "helper_timeout");
    assert!(error.message.starts_with("Device helper never timed out."), "{}", error.message);
    assert!(error.message.contains("Seatbelt profile at /tmp/helper.sb"), "{}", error.message);
    h.client.dispose().await;
}

#[tokio::test]
async fn a_response_after_its_request_timed_out_is_ignored() {
    let h = harness(SHORT, |request| match request.method.as_str() {
        "slow" => vec![Reply::Write {
            delay: Duration::from_millis(500),
            bytes: line(json!({ "id": request.id, "result": "late" })),
        }],
        _ => vec![ok(request, json!("ok"))],
    });

    assert_eq!(error_of(h.client.request("slow", Value::Null).await).code, "helper_timeout");
    // The late answer lands while the next request is in flight, under another id.
    assert_eq!(h.client.request("next", Value::Null).await.unwrap(), json!("ok"));
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(h.client.request("again", Value::Null).await.unwrap(), json!("ok"));
    h.client.dispose().await;
}

#[tokio::test]
async fn reports_the_existing_error_for_an_oversized_control_line() {
    let h = harness(LONG, |_| vec![write(vec![b'x'; MAX_CONTROL_LINE_BYTES + 1])]);

    let error = error_of(h.client.request("oversized", Value::Null).await);
    assert_eq!(
        error,
        DeviceHelperError::new("helper_protocol_error", "Device helper control line exceeded limit")
    );
    h.client.dispose().await;
}

#[tokio::test]
async fn keeps_serving_requests_after_an_oversized_control_line() {
    let h = harness(LONG, |request| {
        if request.method == "oversized" {
            let mut bytes = vec![b'x'; MAX_CONTROL_LINE_BYTES + 1];
            bytes.push(b'\n');
            return vec![write(bytes)];
        }
        vec![ok(request, json!("ok"))]
    });

    assert_eq!(error_of(h.client.request("oversized", Value::Null).await).code, "helper_protocol_error");
    // A protocol error costs the in-flight response, not the write path: the helper is still
    // running and the next call has to reach it.
    assert_eq!(h.client.request("after", Value::Null).await.unwrap(), json!("ok"));
    assert!(h.client.running());
    h.client.dispose().await;
}

#[tokio::test]
async fn ignores_an_undecodable_control_line_without_losing_the_response_beside_it() {
    let h = harness(LONG, |request| {
        // Helper diagnostics that are not valid UTF-8, then the real response, in one write.
        let mut bytes = vec![0xff, 0xfe, 0x0a];
        bytes.extend(line(json!({ "id": request.id, "result": "survived" })));
        vec![write(bytes)]
    });

    assert_eq!(h.client.request("noisy", Value::Null).await.unwrap(), json!("survived"));
    h.client.dispose().await;
}

#[tokio::test]
async fn ignores_diagnostics_and_notifications_beside_the_response() {
    let h = harness(LONG, |request| {
        let mut bytes = b"starting up\n".to_vec();
        bytes.extend(line(json!({ "jsonrpc": "2.0", "method": "ready", "params": {} })));
        bytes.extend(b"\n   \n".iter());
        bytes.extend(line(json!({ "id": request.id + 100, "result": "someone else's" })));
        bytes.extend(line(json!({ "id": request.id, "result": "mine" })));
        vec![write(bytes)]
    });

    assert_eq!(h.client.request("ping", Value::Null).await.unwrap(), json!("mine"));
    h.client.dispose().await;
}

#[tokio::test]
async fn stays_disposed_instead_of_spawning_a_new_helper_on_the_next_request() {
    let h = harness(LONG, |request| vec![ok(request, json!(1))]);
    assert_eq!(h.client.request("ping", Value::Null).await.unwrap(), json!(1));
    h.client.dispose().await;

    let error = error_of(h.client.request("ping", Value::Null).await);
    assert_eq!(error, DeviceHelperError::new("helper_disposed", "Device helper was shut down"));
    assert!(!h.client.running());
    assert_eq!(error_of(h.client.start()).code, "helper_disposed");
    // The one helper was the only one ever spawned.
    assert_eq!(h.methods(), ["ping"]);
}

#[tokio::test]
async fn a_request_started_after_dispose_never_spawns_a_helper() {
    let spawner = ScriptedSpawner::new();
    let (frames, _) = broadcast::channel(16);
    let client = HelperClient::new(HelperClientOptions {
        spawner: Arc::new(spawner.clone()),
        launch: HelperLaunch { command: "fake-helper".into(), ..HelperLaunch::default() },
        request_timeout: SHORT,
        frames,
        on_exit: None,
    });

    client.dispose().await;

    assert_eq!(error_of(client.request("ping", Value::Null).await).code, "helper_disposed");
    assert!(tokio::time::timeout(Duration::from_millis(100), spawner.next()).await.is_err());
}

#[tokio::test]
async fn dispose_closes_stdin_and_fails_what_is_in_flight() {
    let h = harness(LONG, |_| vec![]);
    let client = h.client.clone();
    let pending = tokio::spawn(async move { client.request("never", Value::Null).await });
    // Wait until the helper has the request.
    while h.requests().is_empty() {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }

    h.client.dispose().await;

    let error = error_of(pending.await.unwrap());
    assert_eq!(error, DeviceHelperError::new("helper_disposed", "Device helper was shut down"));
    assert!(!h.client.running());
}

#[tokio::test]
async fn does_not_report_the_exit_of_a_helper_it_disposed() {
    let mut h = harness(LONG, |request| vec![ok(request, json!("ok"))]);
    assert_eq!(h.client.request("ping", Value::Null).await.unwrap(), json!("ok"));

    h.client.dispose().await;
    // The process reports the end that dispose asked for.
    h.exit(None);

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(h.exits.try_recv().is_err(), "a disposed helper's exit is not the owner's news");
}

#[tokio::test]
async fn rejects_a_pending_request_when_the_helper_exits() {
    let mut h = harness(LONG, |_| vec![Reply::Exit(Some(7))]);

    let error = error_of(h.client.request("exit", Value::Null).await);
    assert_eq!(error, DeviceHelperError::new("helper_exited", "device helper exited (code=7, signal=null)"));

    // The owner hears of it once, with the same reason.
    assert_eq!(h.next_exit().await, "device helper exited (code=7, signal=null)");
    assert!(!h.client.running());
    // A dead helper is not respawned behind the owner's back.
    assert_eq!(error_of(h.client.request("again", Value::Null).await).code, "helper_unavailable");
    h.client.dispose().await;
}

#[tokio::test]
async fn an_exit_by_signal_has_no_code() {
    let mut h = harness(LONG, |_| vec![Reply::Exit(None)]);

    let error = error_of(h.client.request("exit", Value::Null).await);
    assert_eq!(error.code, "helper_exited");
    assert_eq!(h.next_exit().await, "device helper exited (code=null, signal=unknown)");
    h.client.dispose().await;
}

#[tokio::test]
async fn an_exit_forgets_the_attachment() {
    let mut h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();
    assert!(h.client.attached_device().is_some());

    h.exit(Some(1));
    h.next_exit().await;

    assert_eq!(h.client.attached_device(), None);
    h.client.dispose().await;
}

#[tokio::test]
async fn starts_the_launch_command_with_its_args_and_env() {
    let launch = HelperLaunch {
        command: "/usr/bin/sandbox-exec".into(),
        args: vec!["-f".into(), "profile.sb".into(), "helper".into()],
        env: vec![("SYNARA".into(), "1".into())],
        profile_path: None,
    };
    let h = harness_with(launch, LONG, answering());
    h.client.request("ping", Value::Null).await.unwrap();

    let spec = h.child_spec.lock().unwrap().clone().expect("spawned");
    assert_eq!(spec.program, "/usr/bin/sandbox-exec");
    assert_eq!(spec.args, ["-f", "profile.sb", "helper"]);
    assert_eq!(spec.env, [("SYNARA".to_owned(), "1".to_owned())]);
    h.client.dispose().await;
}

#[tokio::test]
async fn a_helper_that_cannot_be_spawned_is_a_spawn_failure() {
    struct Failing;
    impl Spawner for Failing {
        fn spawn(&self, _: &SpawnSpec) -> io::Result<ChildProcess> {
            Err(io::Error::new(io::ErrorKind::NotFound, "no such helper"))
        }
    }
    let (frames, _) = broadcast::channel(16);
    let client = HelperClient::new(HelperClientOptions {
        spawner: Arc::new(Failing),
        launch: HelperLaunch::default(),
        request_timeout: SHORT,
        frames,
        on_exit: None,
    });

    let error = error_of(client.request("ping", Value::Null).await);
    assert_eq!(error, DeviceHelperError::new("helper_spawn_failed", "no such helper"));
    assert!(!client.running());
}

// ── attach ──────────────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn attach_reads_geometry_and_capabilities() {
    let h = harness(LONG, answering());

    let attachment = h.client.attach(DEVICE, false).await.unwrap();

    assert_eq!(attachment.udid, DEVICE);
    assert_eq!((attachment.point_width, attachment.point_height), (402.0, 874.0));
    assert_eq!((attachment.pixel_width, attachment.pixel_height), (1206.0, 2622.0));
    assert_eq!(attachment.scale, 3.0);
    assert!(attachment.input_available);
    assert!(attachment.accessibility_available);
    assert_eq!(h.client.attached_device(), Some(attachment));
    assert_eq!(h.requests()[0].params, json!({ "udid": DEVICE }));
    h.client.dispose().await;
}

#[tokio::test]
async fn attach_derives_points_from_pixels_and_defaults_the_rest() {
    let h = harness(LONG, |request| {
        vec![ok(request, json!({ "pixelWidth": 1206, "pixelHeight": 2622 }))]
    });

    let attachment = h.client.attach(DEVICE, false).await.unwrap();

    assert_eq!(attachment.scale, 3.0);
    assert_eq!((attachment.point_width, attachment.point_height), (402.0, 874.0));
    assert!(!attachment.input_available);
    assert!(!attachment.accessibility_available);
    h.client.dispose().await;
}

#[tokio::test]
async fn attach_takes_each_capability_only_when_it_is_exactly_true() {
    let h = harness(LONG, |request| {
        vec![ok(
            request,
            json!({
                "pointWidth": 100, "pointHeight": 200,
                "capabilities": { "input": true, "accessibility": "yes" },
            }),
        )]
    });

    let attachment = h.client.attach(DEVICE, false).await.unwrap();

    assert!(attachment.input_available);
    assert!(!attachment.accessibility_available);
    // Without a pixel size the scale default (3) still applies, and the points stand as given.
    assert_eq!(attachment.scale, 3.0);
    assert_eq!((attachment.point_width, attachment.point_height), (100.0, 200.0));
    h.client.dispose().await;
}

#[tokio::test]
async fn attach_ignores_geometry_that_is_not_a_number() {
    let h = harness(LONG, |request| {
        vec![ok(request, json!({ "pixelWidth": "1206", "pixelHeight": 600, "scale": 2, "pointWidth": null }))]
    });

    let error = error_of(h.client.attach(DEVICE, false).await);
    // Width falls back to 0 pixels, so no usable width remains.
    assert_eq!(error.code, "helper_malformed_response");
    h.client.dispose().await;
}

#[tokio::test]
async fn attach_is_cached_for_the_same_device() {
    let h = harness(LONG, answering());

    let first = h.client.attach(DEVICE, false).await.unwrap();
    let second = h.client.attach(DEVICE, false).await.unwrap();

    assert_eq!(first, second);
    assert_eq!(h.methods(), ["attach"]);
    h.client.dispose().await;
}

#[tokio::test]
async fn attaching_another_device_replaces_the_attachment() {
    let h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();

    let other = h.client.attach("FAKE-0002", false).await.unwrap();

    assert_eq!(other.udid, "FAKE-0002");
    assert_eq!(h.client.attached_device().unwrap().udid, "FAKE-0002");
    assert_eq!(h.methods(), ["attach", "attach"]);
    // Back to the first one asks again: the helper holds one attachment.
    h.client.attach(DEVICE, false).await.unwrap();
    assert_eq!(h.methods(), ["attach", "attach", "attach"]);
    h.client.dispose().await;
}

#[tokio::test]
async fn force_attach_asks_the_helper_again() {
    let h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();

    h.client.attach(DEVICE, true).await.unwrap();

    assert_eq!(h.methods(), ["attach", "attach"]);
    h.client.dispose().await;
}

#[tokio::test]
async fn attach_rejects_a_helper_that_reports_no_screen_geometry() {
    let h = harness(LONG, |request| vec![ok(request, json!({}))]);

    let error = error_of(h.client.attach(DEVICE, false).await);

    assert_eq!(
        error,
        DeviceHelperError::new("helper_malformed_response", "Device helper reported no usable screen geometry")
    );
    assert_eq!(h.client.attached_device(), None);
    h.client.dispose().await;
}

#[tokio::test]
async fn attach_rejects_a_zero_point_size_even_with_pixels() {
    let h = harness(LONG, |request| {
        vec![ok(request, json!({ "pixelWidth": 1206, "pixelHeight": 2622, "pointWidth": 0, "pointHeight": 874 }))]
    });

    assert_eq!(error_of(h.client.attach(DEVICE, false).await).code, "helper_malformed_response");
    h.client.dispose().await;
}

#[tokio::test]
async fn a_failed_reattach_does_not_leave_the_dead_attachment_behind() {
    let mut calls = 0;
    let h = harness(LONG, move |request| {
        calls += 1;
        if calls == 1 {
            vec![ok(request, phone())]
        } else {
            vec![fail(request, -32000, "device is shut down")]
        }
    });
    h.client.attach(DEVICE, false).await.unwrap();
    assert!(h.client.attached_device().is_some());

    let error = error_of(h.client.attach(DEVICE, true).await);

    assert_eq!(error, DeviceHelperError::new("helper_-32000", "device is shut down"));
    assert_eq!(h.client.attached_device(), None);
    // Nothing to normalize against once the attachment is gone.
    assert_eq!(error_of(h.client.normalize(1.0, 1.0)).code, "helper_not_attached");
    h.client.dispose().await;
}

#[tokio::test]
async fn invalidate_attachment_forgets_the_device_so_the_next_attach_asks_again() {
    let h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();

    h.client.invalidate_attachment(DEVICE);

    assert_eq!(h.client.attached_device(), None);
    h.client.attach(DEVICE, false).await.unwrap();
    assert_eq!(h.methods(), ["attach", "attach"]);
    h.client.dispose().await;
}

#[tokio::test]
async fn invalidate_attachment_leaves_another_devices_attachment_alone() {
    let h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();

    h.client.invalidate_attachment("FAKE-0002");

    assert_eq!(h.client.attached_device().unwrap().udid, DEVICE);
    h.client.attach(DEVICE, false).await.unwrap();
    assert_eq!(h.methods(), ["attach"]);
    h.client.dispose().await;
}

#[tokio::test]
async fn dispose_forgets_the_attachment() {
    let h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();

    h.client.dispose().await;

    assert_eq!(h.client.attached_device(), None);
}

// ── device point bounds ─────────────────────────────────────────────────────────────────────────

/// A client attached to the 402x874 point phone, so `normalize` can be exercised.
async fn attached() -> Harness {
    let h = harness(LONG, answering());
    h.client.attach(DEVICE, false).await.unwrap();
    h
}

fn bounds_message(result: Result<(f64, f64), DeviceHelperError>) -> String {
    let error = result.expect_err("out of bounds");
    assert_eq!(error.code, "device_coordinate_out_of_bounds");
    error.message
}

#[tokio::test]
async fn maps_in_bounds_device_points_onto_the_unit_range_the_helper_wants() {
    let h = attached().await;

    assert_eq!(h.client.normalize(201.0, 437.0).unwrap(), (0.5, 0.5));
    assert_eq!(h.client.normalize(0.0, 0.0).unwrap(), (0.0, 0.0));
    assert_eq!(h.client.normalize(402.0, 874.0).unwrap(), (1.0, 1.0));
    h.client.dispose().await;
}

#[tokio::test]
async fn normalize_needs_an_attachment() {
    let h = harness(LONG, answering());

    let error = error_of(h.client.normalize(1.0, 1.0));

    assert_eq!(error, DeviceHelperError::new("helper_not_attached", "Device helper is not attached to a device"));
    h.client.dispose().await;
}

#[tokio::test]
async fn rejects_a_coordinate_past_the_right_edge_instead_of_clamping_it() {
    // 1019 is a frame pixel on a 1206px canvas. Clamping pinned this to the screen edge and
    // reported success, which hid the whole pixel-vs-point bug.
    let h = attached().await;

    assert!(bounds_message(h.client.normalize(1019.0, 400.0)).contains("outside the screen bounds"));
    h.client.dispose().await;
}

#[tokio::test]
async fn rejects_a_coordinate_past_the_bottom_edge() {
    let h = attached().await;

    assert!(bounds_message(h.client.normalize(200.0, 2000.0)).contains("outside the screen bounds"));
    h.client.dispose().await;
}

#[tokio::test]
async fn rejects_negative_and_non_finite_coordinates() {
    let h = attached().await;

    assert!(bounds_message(h.client.normalize(-1.0, 100.0)).contains("outside the screen bounds"));
    assert!(bounds_message(h.client.normalize(100.0, f64::NAN)).contains("outside the screen bounds"));
    assert!(bounds_message(h.client.normalize(f64::INFINITY, 100.0)).contains("outside the screen bounds"));
    h.client.dispose().await;
}

#[tokio::test]
async fn names_the_valid_bounds_and_the_scale_so_the_caller_can_see_the_mistake() {
    // "1019 is outside 0..402 (402x874 at 3x)" makes the scale factor obvious.
    let h = attached().await;

    let message = bounds_message(h.client.normalize(1019.0, 400.0));

    assert_eq!(
        message,
        "Device x=1019 is outside the screen bounds 0..402 device points (402x874 points at 3x; pass device \
         points, not frame pixels)."
    );
    assert!(message.contains("0..402"));
    assert!(message.contains("402x874 points at 3x"));
    assert!(message.contains("not frame pixels"));
    h.client.dispose().await;
}

#[tokio::test]
async fn the_bounds_message_names_the_axis_and_prints_values_as_javascript_does() {
    let h = attached().await;

    assert!(bounds_message(h.client.normalize(10.0, 874.5)).starts_with("Device y=874.5 is outside"));
    assert!(bounds_message(h.client.normalize(-1.0, 10.0)).starts_with("Device x=-1 is outside"));
    assert!(bounds_message(h.client.normalize(10.0, f64::NAN)).starts_with("Device y=NaN is outside"));
    h.client.dispose().await;
}

// ── frames ──────────────────────────────────────────────────────────────────────────────────────

fn envelope(device_id: &str, sequence: u32, keyframe: bool, payload: &[u8]) -> Vec<u8> {
    encode_length_prefixed_record(
        &encode_device_frame(&DeviceFrame {
            header: DeviceFrameHeader {
                device_id: device_id.into(),
                sequence,
                timestamp_ms: 100.0,
                keyframe,
                codec_config: false,
            },
            payload: payload.to_vec(),
        })
        .unwrap(),
    )
}

/// What the helper does on `stream.start`: connect to the socket it was given and write `bytes`,
/// then keep the connection until this side closes it, which is told through `closed`.
fn connect_and_send(socket_path: String, chunks: Vec<Vec<u8>>, closed: oneshot::Sender<()>) -> Reply {
    Reply::Task(Box::pin(async move {
        let mut stream = tokio::net::UnixStream::connect(&socket_path).await.expect("the frame socket is listening");
        for chunk in chunks {
            stream.write_all(&chunk).await.unwrap();
            stream.flush().await.unwrap();
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let mut sink = [0u8; 64];
        while matches!(stream.read(&mut sink).await, Ok(read) if read > 0) {}
        let _ = closed.send(());
    }))
}

fn socket_directory(requests: &[Request]) -> PathBuf {
    let start = requests.iter().find(|request| request.method == methods::STREAM_START).expect("stream.start");
    Path::new(start.params["socketPath"].as_str().expect("socketPath")).parent().unwrap().to_path_buf()
}

#[tokio::test]
async fn streams_frames_tagged_with_the_device_and_the_envelope_stripped() {
    let access_unit = [0u8, 0, 0, 1, 0x67, 0x42, 0, 0x33];
    let next_unit = [9u8, 8, 7];
    let (closed_sender, closed) = oneshot::channel();
    let mut closed_sender = Some(closed_sender);
    // Two records in one write, the second split across two, and a third whole.
    let first_two = [envelope("ignored-id", 7, true, &access_unit), envelope("ignored-id", 8, false, &next_unit)[..6].to_vec()]
        .concat();
    let rest = envelope("ignored-id", 8, false, &next_unit)[6..].to_vec();
    let third = envelope("ignored-id", 9, false, &[1]);
    let h = harness(LONG, move |request| match request.method.as_str() {
        methods::ATTACH => vec![ok(request, phone())],
        methods::STREAM_START => {
            let socket_path = request.params["socketPath"].as_str().unwrap().to_owned();
            vec![
                ok(request, json!({})),
                connect_and_send(socket_path, vec![first_two.clone(), rest.clone(), third.clone()], closed_sender.take().unwrap()),
            ]
        }
        _ => vec![ok(request, json!({}))],
    });
    let mut frames = h.frames.subscribe();

    h.client.start_stream(DEVICE).await.unwrap();

    let mut received = Vec::new();
    for _ in 0..3 {
        received.push(tokio::time::timeout(Duration::from_secs(5), frames.recv()).await.expect("a frame").unwrap());
    }
    // The routing id is the device streamed for, not whatever the envelope said.
    assert!(received.iter().all(|record| &*record.udid == DEVICE));
    assert_eq!(received.iter().map(|record| record.frame.sequence).collect::<Vec<_>>(), [7, 8, 9]);
    assert_eq!(&*received[0].frame.data, &access_unit);
    assert_eq!(&*received[1].frame.data, &next_unit);
    assert!(received[0].frame.keyframe && !received[0].frame.codec_config);
    assert!(!received[1].frame.keyframe);
    assert_eq!(received[0].frame.timestamp_ms, 100.0);

    let directory = socket_directory(&h.requests());
    assert!(directory.join("frames.sock").exists());
    assert_eq!(h.methods(), ["attach", "stream.start"]);

    h.client.stop_stream().await;

    assert_eq!(h.methods(), ["attach", "stream.start", "stream.stop"]);
    assert!(!directory.exists(), "the socket folder is removed");
    // The connection the helper held is closed with the server.
    tokio::time::timeout(Duration::from_secs(5), closed).await.expect("the connection closes").unwrap();
    h.client.dispose().await;
}

#[tokio::test]
async fn a_desynced_frame_stream_is_dropped_and_a_bad_envelope_is_skipped() {
    let (closed_sender, closed) = oneshot::channel();
    let mut closed_sender = Some(closed_sender);
    let good = envelope(DEVICE, 1, true, &[5, 5]);
    let bad_envelope = encode_length_prefixed_record(b"not an envelope at all");
    let desync = vec![0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0];
    let h = harness(LONG, move |request| match request.method.as_str() {
        methods::ATTACH => vec![ok(request, phone())],
        methods::STREAM_START => {
            let socket_path = request.params["socketPath"].as_str().unwrap().to_owned();
            vec![
                ok(request, json!({})),
                connect_and_send(
                    socket_path,
                    vec![[bad_envelope.clone(), good.clone()].concat(), desync.clone()],
                    closed_sender.take().unwrap(),
                ),
            ]
        }
        _ => vec![ok(request, json!({}))],
    });
    let mut frames = h.frames.subscribe();

    h.client.start_stream(DEVICE).await.unwrap();

    let record = tokio::time::timeout(Duration::from_secs(5), frames.recv()).await.expect("a frame").unwrap();
    assert_eq!(record.frame.sequence, 1);
    // An implausible length prefix cannot resynchronize: the connection is cut, no garbage follows.
    tokio::time::timeout(Duration::from_secs(5), closed).await.expect("the connection is dropped").unwrap();
    assert!(frames.try_recv().is_err());
    h.client.dispose().await;
}

#[tokio::test]
async fn start_stream_attaches_first_and_hands_the_helper_its_socket() {
    let h = harness(LONG, answering());

    h.client.start_stream(DEVICE).await.unwrap();

    assert_eq!(h.methods(), ["attach", "stream.start"]);
    let requests = h.requests();
    assert_eq!(requests[0].params, json!({ "udid": DEVICE }));
    let socket_path = requests[1].params["socketPath"].as_str().unwrap().to_owned();
    assert!(socket_path.ends_with("/frames.sock"));
    assert!(socket_path.len() < 104, "a unix socket path must fit sockaddr_un: {socket_path}");
    assert!(Path::new(&socket_path).exists());
    h.client.dispose().await;
    assert!(!Path::new(&socket_path).exists(), "dispose closes the frame socket");
}

#[tokio::test]
async fn restarting_a_stream_stops_the_previous_one_first_and_uses_a_fresh_socket() {
    let h = harness(LONG, answering());
    h.client.start_stream(DEVICE).await.unwrap();
    let first = socket_directory(&h.requests());

    h.client.start_stream(DEVICE).await.unwrap();

    // The attachment was kept, the old stream stopped, a new one started.
    assert_eq!(h.methods(), ["attach", "stream.start", "stream.stop", "stream.start"]);
    let second = socket_directory(&h.requests()[2..]);
    assert_ne!(first, second);
    assert!(!first.exists());
    assert!(second.exists());
    h.client.dispose().await;
}

#[tokio::test]
async fn a_failed_stream_start_closes_the_socket_and_reports_the_helpers_error() {
    let h = harness(LONG, |request| match request.method.as_str() {
        methods::ATTACH => vec![ok(request, phone())],
        _ => vec![fail(request, -32001, "capture unavailable")],
    });

    let error = error_of(h.client.start_stream(DEVICE).await);

    assert_eq!(error, DeviceHelperError::new("helper_-32001", "capture unavailable"));
    assert!(!socket_directory(&h.requests()).exists());
    // There is no stream to stop now: stopping asks the helper nothing.
    h.client.stop_stream().await;
    assert_eq!(h.methods(), ["attach", "stream.start"]);
    h.client.dispose().await;
}

#[tokio::test]
async fn stop_stream_without_a_stream_asks_the_helper_nothing() {
    let h = harness(LONG, answering());

    h.client.stop_stream().await;

    assert!(h.requests().is_empty());
    assert!(!h.client.running(), "stopping does not spawn a helper");
    h.client.dispose().await;
}

// ── ControlLineFramer ───────────────────────────────────────────────────────────────────────────

fn lines(framer: &mut ControlLineFramer, chunk: &[u8]) -> (Vec<String>, bool) {
    framer.push(chunk)
}

#[test]
fn control_lines_split_across_chunks_are_reassembled() {
    let mut framer = ControlLineFramer::new(64);

    assert_eq!(lines(&mut framer, b"ab"), (vec![], false));
    assert_eq!(lines(&mut framer, b"c\nde"), (vec!["abc".to_owned()], false));
    assert_eq!(lines(&mut framer, b"f\n"), (vec!["def".to_owned()], false));
}

#[test]
fn control_lines_in_one_chunk_come_out_in_order_and_a_partial_line_waits() {
    let mut framer = ControlLineFramer::new(64);

    assert_eq!(lines(&mut framer, b"one\ntwo\n\nthr"), (vec!["one".into(), "two".into(), "".into()], false));
    assert_eq!(lines(&mut framer, b"ee\n"), (vec!["three".to_owned()], false));
}

#[test]
fn a_multibyte_character_split_across_chunks_is_kept() {
    let mut framer = ControlLineFramer::new(64);
    let bytes = "caf\u{e9}\n".as_bytes();

    assert_eq!(lines(&mut framer, &bytes[..4]), (vec![], false));
    assert_eq!(lines(&mut framer, &bytes[4..]), (vec!["caf\u{e9}".to_owned()], false));
}

#[test]
fn an_oversized_line_is_dropped_and_reported_while_the_next_line_survives() {
    let mut framer = ControlLineFramer::new(8);

    assert_eq!(lines(&mut framer, b"0123456789012\nok\n"), (vec!["ok".to_owned()], true));
}

#[test]
fn an_oversized_line_spanning_chunks_costs_exactly_that_line() {
    let mut framer = ControlLineFramer::new(8);

    // Reported when it crosses the cap, not again as its tail arrives.
    assert_eq!(lines(&mut framer, b"0123456789"), (vec![], true));
    assert_eq!(lines(&mut framer, b"more and more"), (vec![], false));
    assert_eq!(lines(&mut framer, b"still\nok\n"), (vec!["ok".to_owned()], false));
    assert_eq!(lines(&mut framer, b"after\n"), (vec!["after".to_owned()], false));
}

#[test]
fn a_line_exactly_at_the_cap_is_kept() {
    let mut framer = ControlLineFramer::new(8);

    assert_eq!(lines(&mut framer, b"12345678\n"), (vec!["12345678".to_owned()], false));
    assert_eq!(lines(&mut framer, b"123456789\n"), (vec![], true));
}

#[test]
fn an_undecodable_line_is_dropped_without_a_report_and_the_next_line_survives() {
    let mut framer = ControlLineFramer::new(64);

    let mut chunk = vec![0xff, 0xfe, 0x0a];
    chunk.extend_from_slice(b"good\n");
    assert_eq!(lines(&mut framer, &chunk), (vec!["good".to_owned()], false));
}

#[tokio::test]
async fn a_stream_started_over_another_closes_the_first_socket_and_its_folder() {
    // Two devices streamed at once: both pass `stop_stream` before either has a socket, so the
    // second must close the first rather than leak its listener and folder.
    let h = harness(LONG, |request| {
        let result = if request.method == methods::ATTACH { phone() } else { json!({}) };
        let delay = if request.method == methods::STREAM_START { Duration::from_millis(50) } else { Duration::ZERO };
        vec![Reply::Write {
            delay,
            bytes: line(json!({ "jsonrpc": "2.0", "id": request.id, "result": result })),
        }]
    });

    let (first, second) = tokio::join!(h.client.start_stream("DEVICE-A"), h.client.start_stream("DEVICE-B"));
    first.unwrap();
    second.unwrap();

    let folders: Vec<PathBuf> = h
        .requests()
        .iter()
        .filter(|request| request.method == methods::STREAM_START)
        .map(|request| Path::new(request.params["socketPath"].as_str().unwrap()).parent().unwrap().to_path_buf())
        .collect();
    assert_eq!(folders.len(), 2);
    let open: Vec<&PathBuf> = folders.iter().filter(|folder| folder.exists()).collect();
    assert_eq!(open.len(), 1, "only the current stream's socket folder is left: {folders:?}");

    h.client.stop_stream().await;
    assert!(folders.iter().all(|folder| !folder.exists()), "{folders:?}");
}
