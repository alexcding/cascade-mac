//! The iOS simulator backend, ported from Synara's `IosSimulatorBackend*.test.ts` (the behavioural
//! tests: screenshots, recordings, simctl commands, Xcode discovery, degraded capabilities,
//! reboot recovery, helper processes). The pure-function describes (device parsing, accessibility
//! tree normalization, PNG dimensions, candidate ordering, stale-descriptor detection) are ported
//! in `ios_parsing.rs`, and "device helper source resolution" has no counterpart: Cascade embeds
//! the helper's sources.
//!
//! The seams: short commands (`xcrun`, `xcodebuild`, `xcode-select`, `sips`, ...) are answered by
//! a `cli::ScriptedRunner`; the helper and its `--probe` are played over a `ScriptedSpawner`, whose
//! far side here speaks the helper's JSON-RPC; recordings come from a fake `RecordingSpawner`.
//! Synara's tests stub the `HelperClient` in most places; here the real client runs against the
//! scripted process, so the attach cache and the wire are exercised too.

use std::{
    collections::BTreeMap,
    ffi::OsString,
    future::Future,
    io,
    path::{Path, PathBuf},
    pin::pin,
    sync::{
        atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use base64::Engine as _;
use cascade_chat::provider::process::{ScriptedChild, ScriptedSpawner, SpawnSpec};
use futures_util::FutureExt as _;
use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream},
    sync::{oneshot, Notify},
};

use crate::{
    cli::{self, Failed, ScriptedRunner},
    device::{
        backend::{
            DeviceAppearance, DeviceConfiguration, DeviceLaunchOptions, DeviceListOptions, DeviceLogLevel,
            DeviceLogQuery, DevicePrivacyAction, DeviceScreenshotOptions,
        },
        cache::{device_helper_cache_key, vendored_source_revision, DEVICE_HELPER_BINARY_NAME},
        capabilities::probe_payload,
        contracts::{DeviceAvailability, DeviceCapabilityId, DeviceCapabilityStatus, DeviceHardwareButton},
        ios_simulator::{
            select_recording_directory, IosSimulatorBackend, IosSimulatorOptions, RecordingChild, RecordingSpawner,
        },
    },
};

const DEVICE: &str = "AAAA-1111";
const XCODE_DIR: &str = "/Applications/Xcode.app/Contents/Developer";
const XCODE_VERSION: &str = "Xcode 26.3\nBuild version 17D1";
const NOT_DELIVERED: &str =
    "1 HID event(s) were not delivered to the simulator: nothing was sent: input unavailable; inspect and retry";

// ── Scripting the short commands ───────────────────────────────────────

fn ok(stdout: &str) -> Option<Result<Vec<u8>, Failed>> {
    Some(Ok(stdout.as_bytes().to_vec()))
}

/// A non-zero exit whose stderr is `stderr`.
fn refused(stderr: &str) -> Option<Result<Vec<u8>, Failed>> {
    Some(Err(Failed::from(stderr)))
}

fn words(args: &[OsString]) -> Vec<String> {
    args.iter().map(|arg| arg.to_string_lossy().into_owned()).collect()
}

fn device_list() -> String {
    json!({
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                { "udid": DEVICE, "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true },
            ],
        },
    })
    .to_string()
}

/// What a healthy machine answers, after whatever the test scripted first: the machine-wide
/// Xcode, `xcodebuild -version`, and the one device for `simctl list devices`.
fn with_defaults(runner: ScriptedRunner) -> ScriptedRunner {
    runner
        .on("xcode-select", |_| ok(&format!("{XCODE_DIR}\n")))
        .on("xcodebuild", |_| ok(XCODE_VERSION))
        .on("xcrun", |args| {
            if words(args).iter().any(|arg| arg == "devices") {
                ok(&device_list())
            } else {
                ok("")
            }
        })
}

/// The `simctl` commands asked of `xcrun`, without the `simctl`, and the environment each ran with.
fn simctl_calls(runner: &ScriptedRunner) -> Vec<(Vec<String>, Vec<(String, String)>)> {
    runner
        .asked
        .lock()
        .unwrap()
        .iter()
        .filter(|call| call.program == "xcrun")
        .map(|call| (words(&call.args)[1..].to_vec(), call.env.clone()))
        .collect()
}

fn millis(iso: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(iso).unwrap().timestamp_millis()
}

// ── The helper process, played from the other end of its pipes ─────────

enum Reply {
    Ok(Value),
    Error(i64, String),
    /// Never answered: a helper stalled on the request.
    Hang,
}

impl Reply {
    fn fail(message: &str) -> Self {
        Reply::Error(-32000, message.to_owned())
    }
}

type Handler = Box<dyn FnMut(&str, &Value) -> Reply + Send>;

fn attach_reply() -> Value {
    json!({
        "pointWidth": 393,
        "pointHeight": 852,
        "pixelWidth": 1179,
        "pixelHeight": 2556,
        "scale": 3,
        "capabilities": { "input": true, "accessibility": true },
    })
}

fn default_reply(method: &str) -> Reply {
    Reply::Ok(match method {
        "attach" => attach_reply(),
        "text" => json!({ "ok": true, "skipped": 0 }),
        "describe-ui" => json!({ "tree": { "role": "Application" } }),
        "stream.start" | "stream.stop" => json!({}),
        _ => json!({ "ok": true }),
    })
}

/// What the test sees of the helper: every spawn, every request, and how many of its stdins closed.
struct HelperSide {
    spawns: Mutex<Vec<SpawnSpec>>,
    requests: Mutex<Vec<(String, Value)>>,
    closed: AtomicUsize,
    probe: Mutex<String>,
    handler: Mutex<Handler>,
}

impl HelperSide {
    fn on_request(&self, handler: impl FnMut(&str, &Value) -> Reply + Send + 'static) {
        *self.handler.lock().unwrap() = Box::new(handler);
    }

    fn set_probe(&self, capabilities: &[(DeviceCapabilityId, Value)]) {
        let ok = capabilities.iter().all(|(_, value)| value == &json!("ok"));
        let toolchain = json!({ "xcodeVersion": "26.3", "xcodeBuild": "17D1", "macOS": "Version 26.3" });
        *self.probe.lock().unwrap() = probe_payload(ok, capabilities, toolchain).to_string();
    }

    fn requests_named(&self, method: &str) -> Vec<Value> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(name, _)| name == method)
            .map(|(_, params)| params.clone())
            .collect()
    }

    fn count(&self, method: &str) -> usize {
        self.requests_named(method).len()
    }

    fn probes(&self) -> Vec<SpawnSpec> {
        self.spawns.lock().unwrap().iter().filter(|spec| is_probe(spec)).cloned().collect()
    }

    /// Helper processes, probes excluded.
    fn helper_spawns(&self) -> usize {
        self.spawns.lock().unwrap().iter().filter(|spec| !is_probe(spec)).count()
    }
}

fn is_probe(spec: &SpawnSpec) -> bool {
    spec.args.iter().any(|arg| arg == "--probe")
}

fn all_ok() -> Vec<(DeviceCapabilityId, Value)> {
    DeviceCapabilityId::ALL.iter().map(|&id| (id, json!("ok"))).collect()
}

/// Every capability fine but `id`, which is missing `symbol`.
fn broken(id: DeviceCapabilityId, symbol: &str) -> Vec<(DeviceCapabilityId, Value)> {
    all_ok()
        .into_iter()
        .map(|(candidate, value)| if candidate == id { (candidate, json!({ "missingSymbol": symbol })) } else { (candidate, value) })
        .collect()
}

/// Answers each spawn the backend makes: `--probe` prints its payload and exits; the long-lived
/// helper answers JSON-RPC lines until its stdin closes.
fn play_helper(spawner: ScriptedSpawner, side: Arc<HelperSide>) {
    tokio::spawn(async move {
        loop {
            let ScriptedChild { spec, stdin, mut stdout, exit } = spawner.next().await;
            side.spawns.lock().unwrap().push(spec.clone());
            let side = side.clone();
            tokio::spawn(async move {
                if is_probe(&spec) {
                    let payload = side.probe.lock().unwrap().clone();
                    let _ = stdout.write_all(format!("{payload}\n").as_bytes()).await;
                    drop(stdout);
                    let _ = exit.send(Some(0));
                    return;
                }
                let mut lines = BufReader::new(stdin).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
                    let method = request["method"].as_str().unwrap_or_default().to_owned();
                    let params = request["params"].clone();
                    side.requests.lock().unwrap().push((method.clone(), params.clone()));
                    let reply = (side.handler.lock().unwrap())(&method, &params);
                    let answer = match reply {
                        Reply::Hang => continue,
                        Reply::Ok(result) => json!({ "jsonrpc": "2.0", "id": request["id"], "result": result }),
                        Reply::Error(code, message) => {
                            json!({ "jsonrpc": "2.0", "id": request["id"], "error": { "code": code, "message": message } })
                        }
                    };
                    if stdout.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
                        break;
                    }
                }
                side.closed.fetch_add(1, Ordering::SeqCst);
                let _ = exit.send(Some(0));
            });
        }
    });
}

// ── Recordings ─────────────────────────────────────────────────────────

/// A `simctl io recordVideo` that stays up until it is signalled: SIGINT finishes it, as it does
/// the real one.
struct FakeRecording {
    signals: Mutex<Vec<&'static str>>,
    stderr: Mutex<Option<DuplexStream>>,
    exit: Mutex<Option<oneshot::Sender<Option<i32>>>>,
}

impl FakeRecording {
    fn say(&self, text: &str) {
        if let Some(stderr) = self.stderr.lock().unwrap().as_mut() {
            stderr.write_all(text.as_bytes()).now_or_never().expect("room in the pipe").unwrap();
        }
    }

    fn finish(&self, code: i32) {
        drop(self.stderr.lock().unwrap().take());
        if let Some(exit) = self.exit.lock().unwrap().take() {
            let _ = exit.send(Some(code));
        }
    }

    fn signals(&self) -> Vec<&'static str> {
        self.signals.lock().unwrap().clone()
    }
}

struct FakeRecorder {
    /// Whether a new recording writes its file and says "Recording started" as it spawns.
    auto_start: AtomicBool,
    children: Mutex<Vec<Arc<FakeRecording>>>,
    calls: Mutex<Vec<Vec<String>>>,
}

impl FakeRecorder {
    fn child(&self, index: usize) -> Option<Arc<FakeRecording>> {
        self.children.lock().unwrap().get(index).cloned()
    }

    fn call(&self, index: usize) -> Vec<String> {
        self.calls.lock().unwrap()[index].clone()
    }
}

impl RecordingSpawner for FakeRecorder {
    fn spawn(&self, args: &[String]) -> io::Result<RecordingChild> {
        let (stderr, reader) = tokio::io::duplex(64 * 1024);
        let (exit, exited) = oneshot::channel();
        let recording = Arc::new(FakeRecording {
            signals: Mutex::new(Vec::new()),
            stderr: Mutex::new(Some(stderr)),
            exit: Mutex::new(Some(exit)),
        });
        self.children.lock().unwrap().push(recording.clone());
        self.calls.lock().unwrap().push(args.to_vec());
        if self.auto_start.load(Ordering::SeqCst) {
            std::fs::write(args.last().unwrap(), "fake h264 video").unwrap();
            recording.say("Recording started\n");
        }
        let (interrupted, killed) = (recording.clone(), recording);
        Ok(RecordingChild {
            stderr: Box::pin(reader),
            exited: Box::pin(async move { exited.await.unwrap_or(None) }),
            interrupt: Box::new(move || {
                interrupted.signals.lock().unwrap().push("SIGINT");
                interrupted.finish(0);
            }),
            kill: Box::new(move || {
                killed.signals.lock().unwrap().push("SIGKILL");
                killed.finish(0);
            }),
        })
    }
}

/// Drives `pending` (which must not finish) until `ready` holds.
async fn drive_until<F>(pending: &mut F, mut ready: impl FnMut() -> bool)
where
    F: Future + Unpin,
    F::Output: std::fmt::Debug,
{
    for _ in 0..1_000 {
        if ready() {
            return;
        }
        if let Ok(output) = tokio::time::timeout(Duration::from_millis(2), &mut *pending).await {
            panic!("finished before the test let it: {output:?}");
        }
    }
    panic!("the condition never held");
}

// ── The rig ────────────────────────────────────────────────────────────

struct Rig {
    cache: tempfile::TempDir,
    recordings: tempfile::TempDir,
    spawner: ScriptedSpawner,
    helper: Arc<HelperSide>,
    recorder: Arc<FakeRecorder>,
    clock: Arc<AtomicI64>,
}

impl Rig {
    /// Needs a runtime: the helper's far end is a task.
    fn new() -> Self {
        let spawner = ScriptedSpawner::new();
        let helper = Arc::new(HelperSide {
            spawns: Mutex::new(Vec::new()),
            requests: Mutex::new(Vec::new()),
            closed: AtomicUsize::new(0),
            probe: Mutex::new(String::new()),
            handler: Mutex::new(Box::new(|method, _| default_reply(method))),
        });
        helper.set_probe(&all_ok());
        play_helper(spawner.clone(), helper.clone());
        Self {
            cache: tempfile::tempdir().unwrap(),
            recordings: tempfile::tempdir().unwrap(),
            spawner,
            helper,
            recorder: Arc::new(FakeRecorder {
                auto_start: AtomicBool::new(true),
                children: Mutex::new(Vec::new()),
                calls: Mutex::new(Vec::new()),
            }),
            clock: Arc::new(AtomicI64::new(millis("2026-08-04T12:00:00.000Z"))),
        }
    }

    fn options(&self) -> IosSimulatorOptions {
        let clock = self.clock.clone();
        IosSimulatorOptions {
            platform: "darwin".into(),
            spawner: Arc::new(self.spawner.clone()),
            recording_spawner: self.recorder.clone(),
            helper_cache_root: self.cache.path().to_path_buf(),
            recording_directory: Some(self.recordings.path().to_path_buf()),
            developer_dir_override: None,
            // The spawn is the binary itself, not `sandbox-exec` around it.
            sandbox_opt_out: Some("1".into()),
            list_applications: Arc::new(Vec::new),
            xcode_bundle_usable: Arc::new(|_| true),
            diagnostic_reports: self.cache.path().join("reports"),
            request_timeout: Duration::from_secs(5),
            now: Arc::new(move || clock.load(Ordering::SeqCst)),
        }
    }

    fn backend(&self) -> Arc<IosSimulatorBackend> {
        IosSimulatorBackend::new(self.options())
    }

    fn helper_binary(&self) -> PathBuf {
        let key = device_helper_cache_key(XCODE_VERSION, Some(&vendored_source_revision())).unwrap();
        self.cache.path().join(key).join(DEVICE_HELPER_BINARY_NAME)
    }

    /// Puts a "built" helper where the backend's cache lookup will find it.
    fn install_helper(&self) -> PathBuf {
        let binary = self.helper_binary();
        std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
        std::fs::write(&binary, "#!/bin/sh\n").unwrap();
        binary
    }
}

// ── Saving a screenshot ────────────────────────────────────────────────

mod screenshots {
    use super::*;

    fn screenshot_png() -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
            .unwrap()
    }

    /// A runner whose `simctl io <udid> screenshot <path>` writes a real PNG to the path.
    fn runner() -> Arc<ScriptedRunner> {
        Arc::new(with_defaults(ScriptedRunner::new().on("xcrun", |args| {
            let args = words(args);
            if args.iter().any(|arg| arg == "screenshot") {
                std::fs::write(args.last().unwrap(), screenshot_png()).unwrap();
                return ok("");
            }
            None
        })))
    }

    #[tokio::test]
    async fn writes_the_png_beside_the_recordings_and_reports_its_path() {
        let rig = Rig::new();
        let backend = rig.backend();

        let shot = cli::scoped(runner(), async {
            backend.screenshot(DEVICE, DeviceScreenshotOptions { save: true, ..Default::default() }).await.unwrap()
        })
        .await;

        // The pane's save button has to land in the directory the record button writes to.
        let expected = rig.recordings.path().join("simulator-iphone-17-pro-2026-08-04T12-00-00-000Z.png");
        assert_eq!(shot.result.path.as_deref(), Some(expected.to_str().unwrap()));
        assert_eq!(std::fs::read(&expected).unwrap(), screenshot_png());
        // Saving still returns the bytes, so an agent can read the screen.
        let engine = base64::engine::general_purpose::STANDARD;
        assert_eq!(engine.decode(&shot.result.bytes_base64).unwrap(), screenshot_png());
        assert_eq!(shot.result.mime_type, "image/png");
        assert_eq!((shot.result.width, shot.result.height), (1, 1));
    }

    #[tokio::test]
    async fn writes_nothing_when_the_caller_only_wants_the_bytes() {
        let rig = Rig::new();
        let backend = rig.backend();

        let shot = cli::scoped(runner(), async { backend.screenshot(DEVICE, DeviceScreenshotOptions::default()).await.unwrap() }).await;

        // The composer attachment and the agent's tool take this path; neither litters the Desktop.
        assert_eq!(shot.result.path, None);
        assert_eq!(std::fs::read_dir(rig.recordings.path()).unwrap().count(), 0);
    }
}

// ── Simulator screen recording ─────────────────────────────────────────

mod recording {
    use super::*;

    fn runner() -> Arc<ScriptedRunner> {
        Arc::new(with_defaults(ScriptedRunner::new()))
    }

    #[tokio::test]
    async fn starts_an_h264_simctl_recording_and_waits_for_its_first_frame() {
        let rig = Rig::new();
        rig.recorder.auto_start.store(false, Ordering::SeqCst);
        let backend = rig.backend();

        cli::scoped(runner(), async {
            let mut starting = pin!(backend.start_recording(DEVICE));
            drive_until(&mut starting, || rig.recorder.child(0).is_some()).await;
            // Spawned, but nothing has said it recorded yet.
            assert!(tokio::time::timeout(Duration::from_millis(50), &mut starting).await.is_err());

            let output = rig.recorder.call(0).last().unwrap().clone();
            std::fs::write(&output, "fake h264 video").unwrap();
            rig.clock.fetch_add(2_000, Ordering::SeqCst);
            rig.recorder.child(0).unwrap().say("Recording started\n");
            let result = starting.await.unwrap();

            assert_eq!(
                rig.recorder.call(0),
                ["simctl", "io", DEVICE, "recordVideo", "--codec=h264", result.path.as_str()]
            );
            let path = Path::new(&result.path);
            assert_eq!(path.parent().unwrap(), rig.recordings.path());
            let name = path.file_name().unwrap().to_string_lossy();
            assert!(
                name.starts_with("simulator-iphone-17-pro-") && name.ends_with(".mp4"),
                "unexpected name {name}"
            );
            assert_eq!(result.started_at, "2026-08-04T12:00:02.000Z");

            backend.stop_recording(DEVICE).await.unwrap();
        })
        .await;
    }

    #[tokio::test]
    async fn uses_sigint_and_waits_for_simctl_to_finalise_before_reporting_the_file() {
        let rig = Rig::new();
        let backend = rig.backend();

        cli::scoped(runner(), async {
            let started = backend.start_recording(DEVICE).await.unwrap();

            let stopped = backend.stop_recording(DEVICE).await.unwrap();

            assert_eq!(rig.recorder.child(0).unwrap().signals(), ["SIGINT"]);
            assert_eq!(stopped.udid, DEVICE);
            assert_eq!(stopped.path, started.path);
            assert_eq!(stopped.size_bytes, "fake h264 video".len() as u64);
        })
        .await;
    }

    #[tokio::test]
    async fn shares_finalisation_when_two_stops_arrive_while_recording_is_still_starting() {
        let rig = Rig::new();
        rig.recorder.auto_start.store(false, Ordering::SeqCst);
        let backend = rig.backend();

        cli::scoped(runner(), async {
            let mut starting = pin!(backend.start_recording(DEVICE));
            drive_until(&mut starting, || rig.recorder.child(0).is_some()).await;
            let mut first_stop = pin!(backend.stop_recording(DEVICE));
            let mut second_stop = pin!(backend.stop_recording(DEVICE));
            // Both are waiting on the start.
            assert!(tokio::time::timeout(Duration::from_millis(20), &mut first_stop).await.is_err());
            assert!(tokio::time::timeout(Duration::from_millis(20), &mut second_stop).await.is_err());
            std::fs::write(rig.recorder.call(0).last().unwrap(), "fake h264 video").unwrap();

            rig.recorder.child(0).unwrap().say("Recording started\n");
            let (started, first, second) = tokio::join!(starting, first_stop, second_stop);
            started.unwrap();
            let (first, second) = (first.unwrap(), second.unwrap());

            assert_eq!(rig.recorder.child(0).unwrap().signals(), ["SIGINT"]);
            assert_eq!(second, first);
        })
        .await;
    }

    #[tokio::test]
    async fn keeps_an_existing_timestamped_file_and_chooses_a_unique_path() {
        let rig = Rig::new();
        rig.clock.store(millis("2026-08-04T12:34:56.789Z"), Ordering::SeqCst);
        let backend = rig.backend();
        let occupied = rig.recordings.path().join("simulator-iphone-17-pro-2026-08-04T12-34-56-789Z.mp4");
        std::fs::write(&occupied, "keep me").unwrap();

        cli::scoped(runner(), async {
            let started = backend.start_recording(DEVICE).await.unwrap();
            backend.stop_recording(DEVICE).await.unwrap();

            assert_ne!(Path::new(&started.path), occupied);
        })
        .await;
        assert_eq!(std::fs::read_to_string(&occupied).unwrap(), "keep me");
    }

    #[test]
    fn falls_back_when_an_earlier_recording_directory_exists_but_is_not_writable() {
        use std::os::unix::fs::PermissionsExt;
        // Root writes anywhere, so there is no unwritable directory to fall back from.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let desktop = root.path().join("Desktop");
        let downloads = root.path().join("Downloads");
        std::fs::create_dir(&desktop).unwrap();
        std::fs::create_dir(&downloads).unwrap();
        std::fs::set_permissions(&desktop, std::fs::Permissions::from_mode(0o500)).unwrap();

        let selected = select_recording_directory(&[desktop.clone(), downloads.clone()], &std::env::temp_dir());

        std::fs::set_permissions(&desktop, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(selected, downloads);
    }

    #[tokio::test]
    async fn surfaces_stderr_when_simctl_exits_before_recording_begins() {
        let rig = Rig::new();
        rig.recorder.auto_start.store(false, Ordering::SeqCst);
        let backend = rig.backend();

        cli::scoped(runner(), async {
            let mut starting = pin!(backend.start_recording(DEVICE));
            drive_until(&mut starting, || rig.recorder.child(0).is_some()).await;

            let child = rig.recorder.child(0).unwrap();
            child.say("Invalid device state");
            child.finish(1);

            let error = starting.await.unwrap_err();
            assert!(error.message.contains("Invalid device state"), "{}", error.message);
        })
        .await;
    }

    #[tokio::test]
    async fn interrupts_an_in_flight_recording_when_the_backend_disposes() {
        let rig = Rig::new();
        let backend = rig.backend();

        cli::scoped(runner(), async {
            backend.start_recording(DEVICE).await.unwrap();

            backend.dispose().await;

            assert_eq!(rig.recorder.child(0).unwrap().signals(), ["SIGINT"]);
        })
        .await;
    }

    #[tokio::test]
    async fn a_stop_whose_caller_stopped_waiting_still_finishes_and_forgets_itself() {
        let rig = Rig::new();
        let backend = rig.backend();

        cli::scoped(runner(), async {
            let first = backend.start_recording(DEVICE).await.unwrap();
            {
                // An agent turn interrupted mid-stop: polled once, then dropped.
                let mut stopping = pin!(backend.stop_recording(DEVICE));
                assert!((&mut stopping).now_or_never().is_none());
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
            assert_eq!(rig.recorder.child(0).unwrap().signals(), ["SIGINT"]);

            // The next recording is stopped for itself, not answered with the old stop.
            let second = backend.start_recording(DEVICE).await.unwrap();
            let stopped = backend.stop_recording(DEVICE).await.unwrap();
            assert_ne!(second.path, first.path);
            assert_eq!(stopped.path, second.path);
            assert_eq!(rig.recorder.child(1).unwrap().signals(), ["SIGINT"]);
        })
        .await;
    }

    #[tokio::test]
    async fn a_start_whose_caller_stopped_waiting_still_finishes_and_forgets_itself() {
        let rig = Rig::new();
        rig.recorder.auto_start.store(false, Ordering::SeqCst);
        let backend = rig.backend();

        cli::scoped(runner(), async {
            {
                let mut starting = pin!(backend.start_recording(DEVICE));
                drive_until(&mut starting, || rig.recorder.child(0).is_some()).await;
            }
            std::fs::write(rig.recorder.call(0).last().unwrap(), "fake h264 video").unwrap();
            rig.recorder.child(0).unwrap().say("Recording started\n");
            tokio::time::sleep(Duration::from_millis(50)).await;

            // The start went on without its caller, so the recording can be stopped, and the
            // device does not read as recording afterwards.
            backend.stop_recording(DEVICE).await.unwrap();
            assert_eq!(rig.recorder.child(0).unwrap().signals(), ["SIGINT"]);
            rig.recorder.auto_start.store(true, Ordering::SeqCst);
            backend.start_recording(DEVICE).await.expect("a new recording starts");
            backend.stop_recording(DEVICE).await.unwrap();
        })
        .await;
    }
}

// ── The simctl commands behind launch, configure and the keyboard ──────

mod simctl {
    use super::*;

    /// A backend pinned to Xcode by `DEVELOPER_DIR`, over a runner that answers every `xcrun` with
    /// `answer`, so the exact arguments can be read back.
    fn rig_answering(answer: impl Fn(&[String]) -> Option<Result<Vec<u8>, Failed>> + Send + Sync + 'static) -> (Rig, Arc<IosSimulatorBackend>, Arc<ScriptedRunner>) {
        let rig = Rig::new();
        let mut options = rig.options();
        options.developer_dir_override = Some(XCODE_DIR.into());
        let backend = IosSimulatorBackend::new(options);
        let runner = Arc::new(
            ScriptedRunner::new()
                .on("xcrun", move |args| answer(&words(args)))
                .on("/usr/libexec/PlistBuddy", |_| ok("com.example.shop\n")),
        );
        (rig, backend, runner)
    }

    #[tokio::test]
    async fn launch_restarts_the_app_without_redirecting_its_output_and_passes_environment_through_simctl_child() {
        let (_rig, backend, runner) = rig_answering(|_| ok("com.example.shop: 4242"));
        let options = DeviceLaunchOptions {
            terminate_existing: true,
            environment: BTreeMap::from([("UITESTS".to_owned(), "1".to_owned())]),
        };

        let launched = cli::scoped(runner.clone(), async {
            backend.launch(DEVICE, "com.example.shop", &["-flag".to_owned()], &options).await.unwrap()
        })
        .await;

        assert_eq!(launched.pid, Some(4242));
        let calls = simctl_calls(&runner);
        let (args, env) = calls.iter().find(|(args, _)| args[0] == "launch").unwrap();
        assert_eq!(args[1], "--terminate-running-process");
        assert!(!args.iter().any(|arg| arg.starts_with("--stdout=") || arg.starts_with("--stderr=")));
        assert_eq!(args[args.len() - 3..], [DEVICE, "com.example.shop", "-flag"]);
        let env: BTreeMap<_, _> = env.iter().cloned().collect();
        assert_eq!(env.get("SIMCTL_CHILD_UITESTS").map(String::as_str), Some("1"));
        // The toolchain pin survives the extra variables.
        assert_eq!(env.get("DEVELOPER_DIR").map(String::as_str), Some(XCODE_DIR));
    }

    #[tokio::test]
    async fn configure_maps_each_setting_onto_its_simctl_command() {
        let (_rig, backend, runner) = rig_answering(|_| ok(""));

        cli::scoped(runner.clone(), async {
            backend.configure(DEVICE, &DeviceConfiguration::Appearance(DeviceAppearance::Dark)).await.unwrap();
            backend
                .configure(DEVICE, &DeviceConfiguration::ContentSize { category: "accessibility-large".into() })
                .await
                .unwrap();
            backend.configure(DEVICE, &DeviceConfiguration::Location { latitude: 45.46, longitude: 9.19 }).await.unwrap();
            backend.configure(DEVICE, &DeviceConfiguration::LocationClear).await.unwrap();
            backend
                .configure(
                    DEVICE,
                    &DeviceConfiguration::Privacy {
                        action: DevicePrivacyAction::Grant,
                        service: "photos".into(),
                        bundle_id: Some("com.example.shop".into()),
                    },
                )
                .await
                .unwrap();
        })
        .await;

        let commands: Vec<Vec<String>> = simctl_calls(&runner).into_iter().map(|(args, _)| args).collect();
        assert_eq!(
            commands,
            [
                vec!["ui", DEVICE, "appearance", "dark"],
                vec!["ui", DEVICE, "content_size", "accessibility-large"],
                vec!["location", DEVICE, "set", "45.46,9.19"],
                vec!["location", DEVICE, "clear"],
                vec!["privacy", DEVICE, "grant", "photos", "com.example.shop"],
            ]
        );
    }

    #[tokio::test]
    async fn configure_reports_simctls_own_refusal() {
        let (_rig, backend, runner) = rig_answering(|_| refused("failed"));

        let error = cli::scoped(runner, async {
            backend.configure(DEVICE, &DeviceConfiguration::Appearance(DeviceAppearance::Dark)).await.unwrap_err()
        })
        .await;

        assert!(error.message.contains("simctl ui failed: failed"), "{}", error.message);
    }

    fn keyboards(answer: &'static str) -> impl Fn(&[String]) -> Option<Result<Vec<u8>, Failed>> + Send + Sync {
        move |args| if args.iter().any(|arg| arg == "AppleKeyboards") { ok(answer) } else { ok("") }
    }

    #[tokio::test]
    async fn keyboard_layout_is_us_when_the_first_keyboard_is_en_us() {
        let (_rig, backend, runner) = rig_answering(keyboards("(\n    \"en_US@sw=QWERTY;hw=Automatic\",\n    \"emoji@sw=Emoji\"\n)"));

        assert!(cli::scoped(runner, backend.uses_us_keyboard_layout(DEVICE)).await);
    }

    #[tokio::test]
    async fn keyboard_layout_is_not_us_for_an_italian_keyboard_and_falls_back_to_the_locale_with_none_set() {
        let (_rig, italian, runner) = rig_answering(keyboards("(\n    \"it_IT@sw=QWERTY;hw=Automatic\"\n)"));
        assert!(!cli::scoped(runner, italian.uses_us_keyboard_layout(DEVICE)).await);

        let (_rig, locale_only, runner) = rig_answering(|args| {
            if args.iter().any(|arg| arg == "AppleKeyboards") {
                refused("failed")
            } else {
                ok("it_IT\n")
            }
        });
        assert!(!cli::scoped(runner, locale_only.uses_us_keyboard_layout(DEVICE)).await);

        let (_rig, us_locale, runner) = rig_answering(|args| {
            if args.iter().any(|arg| arg == "AppleKeyboards") {
                refused("failed")
            } else {
                ok("en_US\n")
            }
        });
        assert!(cli::scoped(runner, us_locale.uses_us_keyboard_layout(DEVICE)).await);
    }

    #[tokio::test]
    async fn keyboard_layout_asks_the_simulator_once_per_boot() {
        let (_rig, backend, runner) = rig_answering(|_| ok("(\"en_US@hw=Automatic\")"));

        cli::scoped(runner.clone(), async {
            backend.uses_us_keyboard_layout(DEVICE).await;
            backend.uses_us_keyboard_layout(DEVICE).await;
        })
        .await;

        let asked = simctl_calls(&runner).iter().filter(|(args, _)| args.iter().any(|arg| arg == "AppleKeyboards")).count();
        assert_eq!(asked, 1);
    }

    const SHUT_DOWN: &str = "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to lookup in current state: Shutdown";

    #[tokio::test]
    async fn a_command_for_a_shut_down_simulator_says_to_boot_it_instead_of_passing_on_the_lookup_error() {
        let (_rig, backend, runner) = rig_answering(|_| refused(SHUT_DOWN));

        cli::scoped(runner, async {
            let install = backend.install(DEVICE, "/tmp/Missing.app").await.unwrap_err();
            assert!(install.message.contains("simulator is not booted"), "{}", install.message);
            let launch = backend.launch(DEVICE, "com.example.shop", &[], &DeviceLaunchOptions::default()).await.unwrap_err();
            assert!(launch.message.contains("simulator is not booted. Boot it with device_boot"), "{}", launch.message);
        })
        .await;
    }

    #[tokio::test]
    async fn a_shut_down_devices_app_is_not_reported_as_not_installed() {
        let (_rig, backend, runner) = rig_answering(|_| refused(SHUT_DOWN));
        let query = DeviceLogQuery {
            bundle_id: "com.example.shop".into(),
            since_seconds: 60,
            level: DeviceLogLevel::Default,
            contains: None,
            limit: 10,
        };

        let error = cli::scoped(runner, async { backend.read_logs(DEVICE, &query).await.unwrap_err() }).await;

        assert!(error.message.contains("not booted"), "{}", error.message);
    }
}

// ── The Xcode toolchain a run is pinned to ─────────────────────────────

mod toolchain {
    use super::*;

    const BETA_DIR: &str = "/Applications/Xcode-beta.app/Contents/Developer";
    const STABLE_DIR: &str = XCODE_DIR;
    const CLT_DIR: &str = "/Library/Developer/CommandLineTools";

    struct Setup {
        /// `DEVELOPER_DIR` as the process has it.
        env: Option<&'static str>,
        /// What `xcode-select -p` reports.
        selected: &'static str,
        /// The `/Applications` listing discovery sees.
        applications: &'static [&'static str],
    }

    impl Default for Setup {
        fn default() -> Self {
            Self { env: None, selected: STABLE_DIR, applications: &[] }
        }
    }

    /// The `DEVELOPER_DIR` the first simctl command ran with, and whether `xcode-select` was asked.
    async fn listing_toolchain(setup: Setup) -> (Option<String>, bool) {
        let rig = Rig::new();
        let mut options = rig.options();
        options.developer_dir_override = setup.env.map(str::to_owned);
        let applications: Vec<String> = setup.applications.iter().map(|name| name.to_string()).collect();
        options.list_applications = Arc::new(move || applications.clone());
        let backend = IosSimulatorBackend::new(options);
        let selected = setup.selected;
        let runner = Arc::new(
            ScriptedRunner::new()
                .on("xcode-select", move |_| ok(&format!("{selected}\n")))
                .on("xcodebuild", |_| ok(XCODE_VERSION))
                .on("xcrun", |_| ok("{}")),
        );

        cli::scoped(runner.clone(), backend.list_devices(DeviceListOptions::default())).await;

        let asked_selection = runner.asked.lock().unwrap().iter().any(|call| call.program == "xcode-select");
        let developer_dir = simctl_calls(&runner)
            .first()
            .and_then(|(_, env)| env.iter().find(|(key, _)| key == "DEVELOPER_DIR").map(|(_, value)| value.clone()));
        (developer_dir, asked_selection)
    }

    #[tokio::test]
    async fn targets_the_beta_named_by_developer_dir_rather_than_the_machine_wide_selection() {
        // Pointing one process at a beta is how a beta is tried at all; changing the machine-wide
        // selection would move every other build onto it too.
        let (developer_dir, asked_selection) = listing_toolchain(Setup { env: Some(BETA_DIR), ..Setup::default() }).await;

        assert_eq!(developer_dir.as_deref(), Some(BETA_DIR));
        // The override answers on its own; asking the machine would return stable.
        assert!(!asked_selection);
    }

    #[tokio::test]
    async fn falls_back_to_the_machine_wide_selection_when_the_variable_is_unset() {
        let (developer_dir, _) = listing_toolchain(Setup::default()).await;

        assert_eq!(developer_dir.as_deref(), Some(STABLE_DIR));
    }

    #[tokio::test]
    async fn ignores_an_empty_variable_instead_of_pinning_to_nothing() {
        let (developer_dir, _) = listing_toolchain(Setup { env: Some("   "), ..Setup::default() }).await;

        assert_eq!(developer_dir.as_deref(), Some(STABLE_DIR));
    }

    #[tokio::test]
    async fn finds_a_beta_only_xcode_when_xcode_select_points_at_command_line_tools() {
        // The macOS default after installing git: CommandLineTools selected, a full Xcode
        // installed but never `xcode-select -s`'d. Discovery uses it without a setting.
        let (developer_dir, _) = listing_toolchain(Setup {
            selected: CLT_DIR,
            applications: &["Safari.app", "Xcode-beta.app"],
            ..Setup::default()
        })
        .await;

        assert_eq!(developer_dir.as_deref(), Some(BETA_DIR));
    }

    #[tokio::test]
    async fn keeps_the_command_line_tools_selection_when_no_xcode_bundle_exists() {
        // Nothing to discover: the checklist still needs the selected path to say "install Xcode",
        // not a missing one that reads as no toolchain.
        let (developer_dir, _) =
            listing_toolchain(Setup { selected: CLT_DIR, applications: &["Safari.app"], ..Setup::default() }).await;

        assert_eq!(developer_dir.as_deref(), Some(CLT_DIR));
    }

    #[tokio::test]
    async fn does_not_second_guess_an_explicit_full_xcode_selection() {
        let (developer_dir, _) = listing_toolchain(Setup {
            selected: BETA_DIR,
            applications: &["Xcode.app", "Xcode-beta.app"],
            ..Setup::default()
        })
        .await;

        assert_eq!(developer_dir.as_deref(), Some(BETA_DIR));
    }
}

// ── Capabilities and degraded operation ────────────────────────────────

mod capabilities {
    use super::*;

    /// A rig whose cache holds a built helper and whose `--probe` reports `capabilities`.
    fn rig_with(capabilities: &[(DeviceCapabilityId, Value)]) -> (Rig, Arc<IosSimulatorBackend>) {
        let rig = Rig::new();
        rig.install_helper();
        rig.helper.set_probe(capabilities);
        let backend = rig.backend();
        (rig, backend)
    }

    fn runner() -> Arc<ScriptedRunner> {
        Arc::new(with_defaults(ScriptedRunner::new()))
    }

    #[tokio::test]
    async fn availability_is_available_when_every_capability_passes() {
        let (_rig, backend) = rig_with(&all_ok());

        let availability = cli::scoped(runner(), backend.availability()).await;

        assert!(matches!(availability, DeviceAvailability::Available { .. }), "{availability:?}");
    }

    #[tokio::test]
    async fn availability_is_degraded_not_setup_required_when_one_capability_fails() {
        let (_rig, backend) = rig_with(&broken(DeviceCapabilityId::Accessibility, "AXPTranslator"));

        let availability = cli::scoped(runner(), backend.availability()).await;

        let DeviceAvailability::Degraded { capabilities, toolchain } = availability else {
            panic!("expected degraded, got {availability:?}");
        };
        let failing: Vec<DeviceCapabilityStatus> = capabilities.into_iter().filter(|capability| !capability.ok).collect();
        assert_eq!(
            failing,
            [DeviceCapabilityStatus {
                id: DeviceCapabilityId::Accessibility,
                ok: false,
                missing_symbol: Some("AXPTranslator".into()),
                detail: None,
            }]
        );
        assert_eq!(toolchain.unwrap().xcode_version.as_deref(), Some("26.3"));
    }

    #[tokio::test]
    async fn probes_once_per_helper_binary_rather_than_on_every_availability_check() {
        let (rig, backend) = rig_with(&all_ok());

        cli::scoped(runner(), async {
            backend.availability().await;
            backend.availability().await;
        })
        .await;

        // The answer only changes when the toolchain does, and that produces a different binary path.
        let probes = rig.helper.probes();
        assert_eq!(probes.len(), 1);
        assert_eq!(probes[0].args, ["--probe"]);
        assert_eq!(Path::new(&probes[0].program), rig.helper_binary());
    }

    #[tokio::test]
    async fn input_while_dtuhidd_starts_retries_on_the_same_attachment_instead_of_restarting_the_warm_up() {
        let (rig, backend) = rig_with(&all_ok());
        let failures = Arc::new(AtomicUsize::new(1));
        rig.helper.on_request(move |method, _| {
            if method == "tap" && failures.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| left.checked_sub(1)).is_ok() {
                return Reply::fail(
                    "1 HID event(s) were not delivered to the simulator: nothing was sent: the simulator's input service (dtuhidd) is still starting; inspect before retry",
                );
            }
            default_reply(method)
        });

        cli::scoped(runner(), backend.tap(DEVICE, 10.0, 10.0, None)).await.unwrap();

        assert_eq!(rig.helper.count("tap"), 2);
        // No forced re-attach: the one attach is the first.
        assert_eq!(rig.helper.count("attach"), 1);
    }

    #[tokio::test]
    async fn types_long_text_in_chunks_that_each_fit_inside_one_rpc_deadline() {
        let (rig, backend) = rig_with(&all_ok());

        let outcome = cli::scoped(runner(), backend.type_text(DEVICE, &"a".repeat(300))).await.unwrap();

        assert_eq!(outcome.skipped, 0);
        // ~36 ms a keystroke against a 15 s deadline: a 300-character string sent whole timed out,
        // and the retry typed it twice.
        let chunks: Vec<usize> =
            rig.helper.requests_named("text").iter().map(|params| params["text"].as_str().unwrap().len()).collect();
        assert_eq!(chunks, [120, 120, 60]);
    }

    #[tokio::test]
    async fn describe_ui_fails_with_the_capability_and_the_xcode_that_broke_it() {
        let (_rig, backend) = rig_with(&broken(DeviceCapabilityId::Accessibility, "AXPTranslator"));

        let error = cli::scoped(runner(), backend.describe_ui(DEVICE)).await.unwrap_err();

        assert!(
            error.message.contains("Accessibility inspection is unavailable with Xcode 26.3 (17D1)"),
            "{}",
            error.message
        );
        assert!(error.message.contains("AXPTranslator"), "{}", error.message);
    }

    #[tokio::test]
    async fn input_keeps_working_when_only_accessibility_is_broken() {
        let (_rig, backend) = rig_with(&broken(DeviceCapabilityId::Accessibility, "AXPTranslator"));

        cli::scoped(runner(), async {
            backend.tap(DEVICE, 10.0, 10.0, None).await.unwrap();
            assert_eq!(backend.type_text(DEVICE, "hello").await.unwrap().skipped, 0);
        })
        .await;
    }

    #[tokio::test]
    async fn presses_every_button_the_chassis_draws() {
        let (rig, backend) = rig_with(&all_ok());

        cli::scoped(runner(), async {
            for button in [
                DeviceHardwareButton::Home,
                DeviceHardwareButton::Lock,
                DeviceHardwareButton::VolumeUp,
                DeviceHardwareButton::VolumeDown,
            ] {
                backend.press_button(DEVICE, button).await.unwrap();
            }
        })
        .await;

        let names: Vec<String> =
            rig.helper.requests_named("button").iter().map(|params| params["name"].as_str().unwrap().to_owned()).collect();
        assert_eq!(names, ["home", "lock", "volume-up", "volume-down"]);
    }

    #[tokio::test]
    async fn a_broken_input_path_fails_tap_precisely_while_accessibility_keeps_working() {
        let (_rig, backend) = rig_with(&broken(DeviceCapabilityId::Hid, "IndigoHIDMessageForButton"));

        cli::scoped(runner(), async {
            let error = backend.tap(DEVICE, 1.0, 1.0, None).await.unwrap_err();
            assert!(error.message.contains("Touch and keyboard input is unavailable"), "{}", error.message);
            assert!(error.message.contains("IndigoHIDMessageForButton"), "{}", error.message);
            assert_eq!(backend.describe_ui(DEVICE).await.unwrap().udid, DEVICE);
        })
        .await;
    }

    #[tokio::test]
    async fn a_broken_framebuffer_capability_gates_streaming_alone() {
        // Screenshots run on `simctl io`, so they are deliberately not gated on the helper's
        // framebuffer capability.
        let (_rig, backend) = rig_with(&broken(DeviceCapabilityId::Framebuffer, "SimServiceContext"));

        let error = cli::scoped(runner(), backend.attach_stream(DEVICE)).await.unwrap_err();

        assert!(error.message.contains("Screen capture is unavailable"), "{}", error.message);
    }

    /// `xcodebuild -version` timing out on its `nth` call (1-based), answering otherwise.
    fn xcodebuild_timing_out_on(nth: usize) -> Arc<ScriptedRunner> {
        let calls = AtomicUsize::new(0);
        Arc::new(with_defaults(ScriptedRunner::new().on("xcodebuild", move |_| {
            if calls.fetch_add(1, Ordering::SeqCst) + 1 == nth {
                Some(Err(Failed::timed_out("xcodebuild", Duration::from_secs(20))))
            } else {
                ok(XCODE_VERSION)
            }
        })))
    }

    #[tokio::test]
    async fn recovers_once_xcodebuild_answers_again_and_the_cached_helper_is_still_there() {
        // The first `xcodebuild -version` is the one inside the agent's first tap (the capability
        // probe resolving the helper cache key); it times out once.
        let (_rig, backend) = rig_with(&all_ok());

        cli::scoped(xcodebuild_timing_out_on(1), async {
            // The very same tap then finds the cached helper and works.
            backend.tap(DEVICE, 10.0, 10.0, None).await.unwrap();

            // Every later xcodebuild call succeeds and the binary is in the cache, so nothing is
            // left to report as broken.
            let availability = backend.availability().await;
            assert!(matches!(availability, DeviceAvailability::Available { .. }), "{availability:?}");
        })
        .await;
    }

    #[tokio::test]
    async fn recovers_when_the_transient_failure_hit_the_cache_key_probe_inside_availability() {
        // Call 1 is the license check (fine); call 2 resolves the helper cache key inside the same
        // availability() and fails once.
        let (_rig, backend) = rig_with(&all_ok());

        cli::scoped(xcodebuild_timing_out_on(2), async {
            backend.availability().await;

            for _ in 0..2 {
                let availability = backend.availability().await;
                assert!(matches!(availability, DeviceAvailability::Available { .. }), "{availability:?}");
            }
        })
        .await;
    }
}

// ── Reboots, undelivered input and the helper's lifetime ───────────────

mod helper_process {
    use super::*;

    /// A simulator the helper talks to. An attachment is bound to the boot it was made against: a
    /// stale one fails the way the real helper was observed to, until a fresh `attach` is sent.
    struct Simulator {
        boot: AtomicU64,
        /// Injections that report non-delivery before one lands.
        undeliverable: AtomicUsize,
        stream_starts: Mutex<Vec<&'static str>>,
    }

    impl Simulator {
        fn new() -> Arc<Self> {
            Arc::new(Self { boot: AtomicU64::new(1), undeliverable: AtomicUsize::new(0), stream_starts: Mutex::new(Vec::new()) })
        }

        fn reboot(&self) {
            self.boot.fetch_add(1, Ordering::SeqCst);
        }

        fn helper(self: &Arc<Self>) -> impl FnMut(&str, &Value) -> Reply + Send + 'static {
            let simulator = self.clone();
            let mut attached: Option<u64> = None;
            move |method, _| {
                let boot = simulator.boot.load(Ordering::SeqCst);
                match method {
                    "attach" => {
                        attached = Some(boot);
                        Reply::Ok(attach_reply())
                    }
                    "stream.start" => match attached {
                        None => Reply::fail("not attached to a simulator"),
                        Some(generation) if generation != boot => {
                            simulator.stream_starts.lock().unwrap().push("stale");
                            Reply::fail("display has no framebuffer surface yet")
                        }
                        Some(_) => {
                            simulator.stream_starts.lock().unwrap().push("ok");
                            Reply::Ok(json!({}))
                        }
                    },
                    "tap" | "swipe" | "key" | "text" | "button" => {
                        // A HID client bound to a boot that is gone accepts the call and delivers nothing.
                        if attached != Some(boot) {
                            return Reply::fail(NOT_DELIVERED);
                        }
                        if simulator.undeliverable.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| left.checked_sub(1)).is_ok() {
                            return Reply::fail(NOT_DELIVERED);
                        }
                        Reply::Ok(json!({ "ok": true, "skipped": 0 }))
                    }
                    other => default_reply(other),
                }
            }
        }
    }

    fn rig() -> (Rig, Arc<IosSimulatorBackend>, Arc<Simulator>) {
        let rig = Rig::new();
        rig.install_helper();
        let simulator = Simulator::new();
        rig.helper.on_request(simulator.helper());
        let backend = rig.backend();
        (rig, backend, simulator)
    }

    fn runner() -> Arc<ScriptedRunner> {
        Arc::new(with_defaults(ScriptedRunner::new()))
    }

    #[tokio::test]
    async fn re_attaches_after_a_cascade_driven_shutdown_and_reboot() {
        let (rig, backend, simulator) = rig();

        cli::scoped(runner(), async {
            backend.tap(DEVICE, 10.0, 10.0, None).await.unwrap();
            backend.shutdown(DEVICE).await.unwrap();
            simulator.reboot();
            backend.tap(DEVICE, 20.0, 20.0, None).await.unwrap();
        })
        .await;

        // The shutdown dropped the cached attachment, so this is a clean re-attach, not a forced
        // retry after a failed tap.
        assert_eq!(rig.helper.count("attach"), 2);
        assert_eq!(rig.helper.count("tap"), 2);
    }

    #[tokio::test]
    async fn recovers_when_the_device_was_rebooted_outside_cascade() {
        let (rig, backend, simulator) = rig();

        cli::scoped(runner(), async {
            backend.tap(DEVICE, 10.0, 10.0, None).await.unwrap();
            // No shutdown to observe: Simulator.app or the agent's own shell did it, so the only
            // signal is the failure itself.
            simulator.reboot();
            backend.tap(DEVICE, 20.0, 20.0, None).await.unwrap();
        })
        .await;

        // The refused tap, then a forced attach, then the tap again.
        assert_eq!(rig.helper.count("attach"), 2);
        assert_eq!(rig.helper.count("tap"), 3);
    }

    #[tokio::test]
    async fn survives_repeated_boot_attach_shutdown_cycles() {
        let (rig, backend, simulator) = rig();

        cli::scoped(runner(), async {
            for _ in 1..=3 {
                simulator.reboot();
                backend.tap(DEVICE, 5.0, 5.0, None).await.unwrap();
                backend.shutdown(DEVICE).await.unwrap();
            }
        })
        .await;

        // Every cycle worked, with one plain attach each; none fell into the permanent-failure
        // state that needs a forced one.
        assert_eq!(rig.helper.count("attach"), 3);
        assert_eq!(rig.helper.count("tap"), 3);
    }

    #[tokio::test]
    async fn a_boot_drops_the_attachment_a_shutdown_outside_cascade_left() {
        let (rig, backend, simulator) = rig();

        cli::scoped(runner(), async {
            backend.tap(DEVICE, 10.0, 10.0, None).await.unwrap();
            // xcodebuild test shut it down; Cascade boots it again.
            simulator.reboot();
            backend.boot(DEVICE).await.unwrap();
            backend.tap(DEVICE, 20.0, 20.0, None).await.unwrap();
        })
        .await;

        // A clean attach after the boot: no tap refused on the old boot's attachment first.
        assert_eq!(rig.helper.count("attach"), 2);
        assert_eq!(rig.helper.count("tap"), 2);
    }

    #[tokio::test]
    async fn a_helper_stalled_on_attach_is_replaced_and_the_attach_asked_again() {
        let rig = Rig::new();
        rig.install_helper();
        let attaches = Arc::new(AtomicUsize::new(0));
        let counted = attaches.clone();
        rig.helper.on_request(move |method, _| {
            // The first helper never answers its attach, as one that lived through a reboot did.
            if method == "attach" && counted.fetch_add(1, Ordering::SeqCst) == 0 {
                return Reply::Hang;
            }
            default_reply(method)
        });
        let mut options = rig.options();
        options.request_timeout = Duration::from_millis(200);
        let backend = IosSimulatorBackend::new(options);

        cli::scoped(runner(), backend.tap(DEVICE, 10.0, 10.0, None)).await.unwrap();

        assert_eq!(rig.helper.helper_spawns(), 2, "a second helper process");
        assert_eq!(attaches.load(Ordering::SeqCst), 2);
        assert_eq!(rig.helper.count("tap"), 1);
        // The stalled one was shut down, not left running beside the new one.
        for _ in 0..100 {
            if rig.helper.closed.load(Ordering::SeqCst) >= 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(rig.helper.closed.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn retries_an_attach_that_fails_on_a_dead_descriptor_with_a_forced_one() {
        let rig = Rig::new();
        rig.install_helper();
        let attaches = Arc::new(AtomicUsize::new(0));
        let counted = attaches.clone();
        rig.helper.on_request(move |method, _| {
            if method == "attach" && counted.fetch_add(1, Ordering::SeqCst) == 0 {
                return Reply::fail("display has no framebuffer surface yet");
            }
            default_reply(method)
        });
        let backend = rig.backend();

        cli::scoped(runner(), backend.tap(DEVICE, 10.0, 10.0, None)).await.unwrap();

        assert_eq!(attaches.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn surfaces_a_non_descriptor_failure_instead_of_retrying_it() {
        let rig = Rig::new();
        rig.install_helper();
        rig.helper.on_request(|method, _| match method {
            "attach" => Reply::fail("simulator is not booted"),
            other => default_reply(other),
        });
        let backend = rig.backend();

        let error = cli::scoped(runner(), backend.tap(DEVICE, 1.0, 1.0, None)).await.unwrap_err();

        assert!(error.message.contains("not booted"), "{}", error.message);
        assert_eq!(rig.helper.count("attach"), 1);
    }

    #[tokio::test]
    async fn rebinds_the_hid_client_and_retries_once_when_input_does_not_reach_the_guest() {
        let (rig, backend, simulator) = rig();

        cli::scoped(runner(), async {
            backend.tap(DEVICE, 10.0, 10.0, None).await.unwrap();
            assert_eq!(rig.helper.count("attach"), 1);

            // A stale HID client accepts the call but the event never lands.
            simulator.undeliverable.store(1, Ordering::SeqCst);
            backend.tap(DEVICE, 20.0, 20.0, None).await.unwrap();
        })
        .await;

        // The recovery forces an attach, so the retry lands on a freshly built HID client.
        assert_eq!(rig.helper.count("attach"), 2);
        assert_eq!(rig.helper.count("tap"), 3);
    }

    #[tokio::test]
    async fn surfaces_the_failure_when_the_retry_also_fails_to_deliver() {
        let (rig, backend, simulator) = rig();
        simulator.undeliverable.store(5, Ordering::SeqCst);

        let error = cli::scoped(runner(), backend.tap(DEVICE, 1.0, 1.0, None)).await.unwrap_err();

        assert!(error.message.contains("not delivered"), "{}", error.message);
        // One try and one retry, not a loop.
        assert_eq!(rig.helper.count("tap"), 2);
    }

    #[tokio::test]
    async fn starts_exactly_one_helper_for_two_concurrent_operations() {
        // The pane bringing its stream up while an agent's tap arrives is the everyday shape of this.
        let (rig, backend, _simulator) = rig();

        cli::scoped(runner(), async {
            let (stream, tap) = tokio::join!(backend.attach_stream(DEVICE), backend.tap(DEVICE, 10.0, 10.0, None));
            stream.unwrap();
            tap.unwrap();
        })
        .await;

        assert_eq!(rig.helper.helper_spawns(), 1);
    }

    #[tokio::test]
    async fn disposes_every_helper_it_started() {
        let (rig, backend, _simulator) = rig();

        cli::scoped(runner(), async {
            let (stream, tap) = tokio::join!(backend.attach_stream(DEVICE), backend.tap(DEVICE, 10.0, 10.0, None));
            stream.unwrap();
            tap.unwrap();
            backend.dispose().await;
        })
        .await;

        // A helper the backend no longer references is a live process nothing will ever stop: each
        // one's stdin, which is how it is asked to leave, has to have closed.
        let started = rig.helper.helper_spawns();
        for _ in 0..500 {
            if rig.helper.closed.load(Ordering::SeqCst) == started {
                return;
            }
            tokio::time::sleep(Duration::from_millis(4)).await;
        }
        panic!("{} of {started} helpers were left running", started - rig.helper.closed.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn builds_the_helper_once_for_two_concurrent_callers() {
        // Nothing cached: the build script stands in for the compile and writes the binary.
        let rig = Rig::new();
        let builds = Arc::new(AtomicUsize::new(0));
        let counted = builds.clone();
        let runner = Arc::new(with_defaults(ScriptedRunner::new().on("/bin/sh", move |args| {
            counted.fetch_add(1, Ordering::SeqCst);
            let output = PathBuf::from(&args[1]);
            std::fs::create_dir_all(&output).unwrap();
            std::fs::write(output.join(DEVICE_HELPER_BINARY_NAME), "#!/bin/sh\n").unwrap();
            ok("")
        })));
        let backend = rig.backend();

        cli::scoped(runner, async {
            let (first, second) = tokio::join!(backend.compile_helper_if_needed(), backend.compile_helper_if_needed());
            assert_eq!(first.unwrap(), second.unwrap());
        })
        .await;

        assert_eq!(builds.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn text_delivery_preserves_the_input_transport_after_a_non_retryable_refusal() {
        for failure in [
            "1 HID event(s) were not delivered: input may have been partially delivered; still starting; nothing was sent",
            "1 HID event(s) were not delivered: nothing was sent: long press cannot finish inside the input deadline",
        ] {
            let rig = Rig::new();
            rig.install_helper();
            rig.helper.on_request(move |method, _| match method {
                "text" => Reply::fail(failure),
                other => default_reply(other),
            });
            let backend = rig.backend();

            let error = cli::scoped(runner(), backend.type_text(DEVICE, "hello")).await.unwrap_err();

            assert_eq!(error.message, failure);
            assert_eq!(rig.helper.count("text"), 1, "{failure}");
            // No forced re-attach: the one attach is the first.
            assert_eq!(rig.helper.count("attach"), 1, "{failure}");
        }
    }

    #[tokio::test]
    async fn text_stops_before_the_next_chunk_when_its_future_is_dropped() {
        // Cancelling is dropping the future; Synara's AbortSignal has no other form here.
        let rig = Rig::new();
        rig.install_helper();
        let chunks = Arc::new(AtomicUsize::new(0));
        let typed = Arc::new(Notify::new());
        let (counted, notify) = (chunks.clone(), typed.clone());
        rig.helper.on_request(move |method, _| {
            if method == "text" {
                counted.fetch_add(1, Ordering::SeqCst);
                notify.notify_one();
            }
            default_reply(method)
        });
        let backend = rig.backend();

        let text = "a".repeat(241);
        cli::scoped(runner(), async {
            tokio::select! {
                biased;
                _ = typed.notified() => {}
                outcome = backend.type_text(DEVICE, &text) => panic!("typed it all: {outcome:?}"),
            }
            // Dropped with the first chunk in; a second would have followed it at once.
            tokio::time::sleep(Duration::from_millis(100)).await;
        })
        .await;

        assert_eq!(chunks.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn streams_again_after_the_simulator_was_rebooted_outside_cascade() {
        // Synara runs this through DeviceManager (detach, then attach the same udid); here the
        // backend's own attach_stream stands in for it.
        let (rig, backend, simulator) = rig();

        cli::scoped(runner(), async {
            backend.attach_stream(DEVICE).await.unwrap();
            assert_eq!(*simulator.stream_starts.lock().unwrap(), ["ok"]);

            // Cascade sees no shutdown, so the client still holds the attachment from boot 1.
            simulator.reboot();
            backend.detach_stream(DEVICE).await;
            backend.attach_stream(DEVICE).await.unwrap();
        })
        .await;

        // The stale attachment fails the stream start; a re-sent `attach` fixes it at once, where
        // retrying `stream.start` on the old one never would.
        assert_eq!(*simulator.stream_starts.lock().unwrap(), ["ok", "stale", "ok"]);
        assert_eq!(rig.helper.count("attach"), 2);
    }
}
