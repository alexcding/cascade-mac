//! IosSimulatorBackend - the one `DeviceBackend` implementation today.
//!
//! Port of Synara's `apps/server/src/device/IosSimulatorBackend.ts`. Split by capability:
//!
//! - Discovery, boot/shutdown, install/launch/openurl, screenshots and screen recordings go through
//!   `xcrun simctl`, which is public, stable, and needs no permissions. Short commands run through
//!   `cli` (`process.rs`), so a test scripts them with `cli::ScriptedRunner`.
//! - Input injection, the accessibility tree and the video stream need private
//!   CoreSimulator/SimulatorKit APIs, so they go through the native helper (`helper.rs`),
//!   compiled on demand against the user's Xcode from the vendored sources (`cache.rs`) and run
//!   under its Seatbelt profile (`sandbox.rs`).
//!
//! Availability is modelled rather than inferred from errors: the pane renders a checklist
//! (`DeviceAvailability`) instead of a stack trace, so every probe here maps onto one setup step.

use std::{
    collections::{HashMap, HashSet},
    io,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};

use base64::Engine as _;
use cascade_chat::provider::process::{ExitFuture, SpawnSpec, Spawner};
use futures_util::{
    future::{FutureExt as _, Shared},
    TryFutureExt as _,
};
use regex::Regex;
use serde_json::{json, Value};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::{broadcast, watch, OnceCell},
};

use super::{
    backend::{
        fit_device_message, BoxFuture, DeviceBackend, DeviceBackendError, DeviceConfiguration, DeviceFrameRecord,
        DeviceKeyEvent, DeviceLaunchOptions, DeviceListOptions, DeviceLogQuery, DeviceLogResult, DevicePrivacyAction,
        DeviceResult, DeviceScreenshotCapture, DeviceScreenshotOptions, DeviceScreenshotResolution,
        DeviceStreamInterruption, DeviceSwipeGesture, DeviceTouchPhase, DeviceTypeTextOutcome,
    },
    cache::{
        device_helper_cache_key, device_helper_cache_root, key_directory, materialize_sources_blocking, vendored_source_revision,
        DEVICE_HELPER_BINARY_NAME, DEVICE_HELPER_SOURCE_FOLDER,
    },
    capabilities::{availability_from_probe, capability_unavailable_message, parse_helper_probe, HelperProbeResult},
    catalogue::{read_device_type_catalogue, DeviceTypeCatalogue},
    contracts::{
        DeviceAvailability, DeviceBootSource, DeviceCapabilityId, DeviceDescribeUiResult, DeviceDescriptor,
        DeviceGeometry, DeviceHardwareButton, DeviceInstallAppResult, DeviceKeyModifier, DeviceLaunchAppResult,
        DevicePlatform, DeviceRuntimeState, DeviceScreenshotResult, DeviceSetupStep, DeviceSetupStepId,
        DeviceStartRecordingResult, DeviceStopRecordingResult, DeviceUiFrame, DeviceUiNode, DeviceUiPoint,
    },
    helper::{methods, DeviceHelperError, HelperClient, HelperClientOptions, HelperLaunch, REQUEST_TIMEOUT},
    iso_from_millis,
    logs::{read_crash_reports, tail_lines, unified_log_arguments},
    process::{self, RunResult},
    sandbox::{opt_out_from_env, sandboxed_helper_command, HelperSandboxCommand, HelperSandboxContext, SANDBOX_OPT_OUT_ENV},
};

const SIMCTL_TIMEOUT: Duration = Duration::from_secs(30);
/// How long one `simctl list devices` answer serves repeat callers.
const DEVICE_LIST_CACHE: Duration = Duration::from_millis(1_500);
/// How long the machine-wide `xcode-select -p` answer is reused.
const XCODE_SELECT_CACHE: Duration = Duration::from_secs(15);
const BOOT_TIMEOUT: Duration = Duration::from_secs(120);
const PROBE_TIMEOUT: Duration = Duration::from_secs(30);
const BUILD_TIMEOUT: Duration = Duration::from_secs(300);
const RECORDING_START_TIMEOUT: Duration = Duration::from_secs(10);
const RECORDING_STOP_GRACE: Duration = Duration::from_secs(15);
const RECORDING_KILL_GRACE: Duration = Duration::from_secs(1);
const MAX_RECORDING_STDERR_LENGTH: usize = 64 * 1024;
/// Cap on what a screenshot read will take.
const MAX_SCREENSHOT_BYTES: u64 = 32 * 1024 * 1024;
/// Characters per `text` RPC. The helper paces keystrokes at roughly 36 ms each and every RPC
/// shares a 15 s deadline, so a long string sent whole timed out and the retry typed it twice.
pub const TEXT_CHUNK_LENGTH: usize = 120;
/// The contract's per-string cap; a long text view must not fail the whole read.
const UI_TEXT_MAX_LENGTH: usize = 1_024;

/// simctl commands that cannot change what `list devices` reports.
const READ_ONLY_SIMCTL_COMMANDS: [&str; 6] = ["list", "appinfo", "spawn", "location", "ui", "privacy"];

/// A long-lived `simctl io recordVideo`, which stops cleanly only on SIGINT.
pub struct RecordingChild {
    pub stderr: Pin<Box<dyn AsyncRead + Send>>,
    /// Resolves once the process has ended.
    pub exited: ExitFuture,
    /// SIGINT: finish the file and exit.
    pub interrupt: Box<dyn Fn() + Send + Sync>,
    /// SIGKILL, for one that did not.
    pub kill: Box<dyn Fn() + Send + Sync>,
}

/// Starts `xcrun <args>` for a recording; a test hands in its own.
pub trait RecordingSpawner: Send + Sync {
    fn spawn(&self, args: &[String]) -> io::Result<RecordingChild>;
}

/// Spawns `xcrun` as `cli` spawns every command: resolved on the search path, in a process group
/// of its own.
pub struct XcrunRecordingSpawner;

impl RecordingSpawner for XcrunRecordingSpawner {
    fn spawn(&self, args: &[String]) -> io::Result<RecordingChild> {
        let mut command = crate::cli::command("xcrun");
        command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped()).kill_on_drop(true);
        let mut child = command.spawn()?;
        let pid = child.id().map(|pid| pid as libc::pid_t);
        let stderr = child.stderr.take().expect("stderr is piped");
        let alive = Arc::new(AtomicBool::new(true));
        let signal = move |alive: &AtomicBool, kill: bool| {
            let Some(pid) = pid.filter(|_| alive.load(Ordering::SeqCst)) else { return };
            // SAFETY: signalling our own child (or its group, which `cli::command` made), only
            // while it has not been reaped, so the pid cannot have been reused.
            unsafe {
                if kill {
                    libc::killpg(pid, libc::SIGKILL);
                } else {
                    libc::kill(pid, libc::SIGINT);
                }
            }
        };
        let (interrupt_alive, kill_alive, exit_alive) = (alive.clone(), alive.clone(), alive);
        Ok(RecordingChild {
            stderr: Box::pin(stderr),
            exited: Box::pin(async move {
                let status = child.wait().await;
                exit_alive.store(false, Ordering::SeqCst);
                status.ok().and_then(|status| status.code())
            }),
            interrupt: Box::new(move || signal(&interrupt_alive, false)),
            kill: Box::new(move || signal(&kill_alive, true)),
        })
    }
}

pub type ListApplications = Arc<dyn Fn() -> Vec<String> + Send + Sync>;
pub type XcodeBundleUsable = Arc<dyn Fn(&Path) -> bool + Send + Sync>;
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

pub struct IosSimulatorOptions {
    /// `darwin` on a Mac, as Node names it; anything else reports `unsupported-platform`.
    pub platform: String,
    /// Starts the helper and its `--probe`.
    pub spawner: Arc<dyn Spawner>,
    pub recording_spawner: Arc<dyn RecordingSpawner>,
    /// Where helper builds are cached, one folder per key.
    pub helper_cache_root: PathBuf,
    /// Where recordings and saved screenshots go; Desktop, then Downloads, then the temporary
    /// folder when unset.
    pub recording_directory: Option<PathBuf>,
    /// `DEVELOPER_DIR` as this process has it: it wins over the machine-wide selection, which is
    /// how a beta Xcode is targeted.
    pub developer_dir_override: Option<String>,
    /// `CASCADE_DEVICE_HELPER_NO_SANDBOX` as this process has it.
    pub sandbox_opt_out: Option<String>,
    pub list_applications: ListApplications,
    pub xcode_bundle_usable: XcodeBundleUsable,
    /// `~/Library/Logs/DiagnosticReports`, where the host writes crash reports.
    pub diagnostic_reports: PathBuf,
    pub request_timeout: Duration,
    /// Milliseconds since the epoch.
    pub now: Clock,
}

impl IosSimulatorOptions {
    /// What the app runs with.
    pub fn production() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        Self {
            platform: if cfg!(target_os = "macos") { "darwin".into() } else { std::env::consts::OS.into() },
            spawner: Arc::new(crate::chat::CliSpawner),
            recording_spawner: Arc::new(XcrunRecordingSpawner),
            helper_cache_root: device_helper_cache_root(),
            recording_directory: None,
            developer_dir_override: std::env::var("DEVELOPER_DIR").ok(),
            sandbox_opt_out: opt_out_from_env(),
            list_applications: Arc::new(|| {
                std::fs::read_dir("/Applications")
                    .map(|entries| entries.flatten().map(|entry| entry.file_name().to_string_lossy().into_owned()).collect())
                    .unwrap_or_default()
            }),
            // `xcrun` is what every downstream command needs; its presence separates a full Xcode
            // from a leftover or half-deleted bundle.
            xcode_bundle_usable: Arc::new(|developer_dir| developer_dir.join("usr/bin/xcrun").exists()),
            diagnostic_reports: home.join("Library/Logs/DiagnosticReports"),
            request_timeout: REQUEST_TIMEOUT,
            now: Arc::new(super::now_millis),
        }
    }
}

type SharedStart = Shared<BoxFuture<'static, DeviceResult<DeviceStartRecordingResult>>>;
type SharedStop = Shared<BoxFuture<'static, DeviceResult<DeviceStopRecordingResult>>>;

#[derive(Clone, Default)]
struct RecordingProgress {
    stderr: String,
    exited: bool,
}

struct ActiveRecording {
    path: PathBuf,
    started_at_ms: Mutex<i64>,
    progress: watch::Receiver<RecordingProgress>,
    interrupt: Box<dyn Fn() + Send + Sync>,
    kill: Box<dyn Fn() + Send + Sync>,
}

impl ActiveRecording {
    fn exited(&self) -> bool {
        self.progress.borrow().exited
    }
}

struct ListCache {
    listed_at: Instant,
    generation: u64,
    devices: Vec<DeviceDescriptor>,
}

#[derive(Default)]
struct State {
    disposed: bool,
    /// The device the helper is streaming, so a helper death can name it.
    streaming_udid: Option<String>,
    warned_unsandboxed: bool,
    /// Geometry learned from helper attachments.
    device_geometry: HashMap<String, DeviceGeometry>,
    xcode_select: Option<(Instant, Option<String>)>,
    /// One `/Applications` scan per backend.
    xcode_discovery: Option<Option<String>>,
    /// Bumped by every simctl command that may change the device list.
    list_generation: u64,
    list_cache: Option<ListCache>,
    /// The helper and the number it was started as, so an old one's exit is not taken for the
    /// current one's.
    helper: Option<(u64, HelperClient)>,
    helpers_started: u64,
    helper_build_failure: Option<String>,
    /// Keyed on the binary, so a rebuilt helper is probed again rather than assumed.
    helper_probe: Option<(PathBuf, HelperProbeResult)>,
    /// Per-device answer to `uses_us_keyboard_layout`; dropped on boot and shutdown.
    keyboard_layouts: HashMap<String, bool>,
    /// `CFBundleExecutable` per udid and bundle.
    executables: HashMap<String, String>,
    recordings: HashMap<String, Arc<ActiveRecording>>,
    /// Starts and stops in flight, each with the number of the task that runs it.
    recording_starts: HashMap<String, (u64, SharedStart)>,
    recording_stops: HashMap<String, (u64, SharedStop)>,
    recording_tasks: u64,
    reserved_capture_paths: HashSet<PathBuf>,
}

pub struct IosSimulatorBackend {
    this: Weak<IosSimulatorBackend>,
    options: IosSimulatorOptions,
    state: Mutex<State>,
    /// Screen geometry and family per device type, read once and shared.
    device_types: OnceCell<DeviceTypeCatalogue>,
    /// Held while listing, so concurrent callers share one `simctl list`.
    list_lock: tokio::sync::Mutex<()>,
    /// Held while a helper starts, so two callers arriving together start one.
    helper_start: tokio::sync::Mutex<()>,
    /// Held while the helper builds, so concurrent callers share one compilation.
    helper_build: tokio::sync::Mutex<()>,
    frames: broadcast::Sender<DeviceFrameRecord>,
    interruptions: broadcast::Sender<DeviceStreamInterruption>,
}

/// How many frames a slow reader may fall behind before it loses some.
const FRAME_CHANNEL_CAPACITY: usize = 256;

impl IosSimulatorBackend {
    pub fn new(options: IosSimulatorOptions) -> Arc<Self> {
        let (frames, _) = broadcast::channel(FRAME_CHANNEL_CAPACITY);
        let (interruptions, _) = broadcast::channel(16);
        Arc::new_cyclic(|this| Self {
            this: this.clone(),
            options,
            state: Mutex::new(State::default()),
            device_types: OnceCell::new(),
            list_lock: tokio::sync::Mutex::new(()),
            helper_start: tokio::sync::Mutex::new(()),
            helper_build: tokio::sync::Mutex::new(()),
            frames,
            interruptions,
        })
    }

    fn darwin(&self) -> bool {
        self.options.platform == "darwin"
    }

    fn now(&self) -> i64 {
        (self.options.now)()
    }

    fn disposed_error() -> DeviceBackendError {
        DeviceBackendError::new("The iOS simulator backend is disposed")
    }

    // ── Availability ───────────────────────────────────────────────────

    pub async fn availability(&self) -> DeviceAvailability {
        if !self.darwin() {
            return DeviceAvailability::UnsupportedPlatform { platform: self.options.platform.clone() };
        }
        if let Some(message) = self.state.lock().unwrap().helper_build_failure.clone() {
            return DeviceAvailability::HelperUnavailable { message };
        }
        let step = |id, label: &str, done: bool, detail: &str| DeviceSetupStep {
            id,
            label: label.to_owned(),
            done,
            detail: (!done).then(|| detail.to_owned()),
        };
        let developer_dir = self.xcode_select_path().await;
        let xcode_installed = developer_dir.as_deref().is_some_and(|dir| !dir.contains("CommandLineTools"));
        let license_accepted = xcode_installed && self.xcode_license_accepted().await;
        let devices = if license_accepted { self.list_devices_unchecked().await } else { Vec::new() };
        let runtime_installed = has_bootable_ios_runtime(&devices);
        // The helper is built at first attach, so this reports the cache rather than compiling
        // during a routine availability probe.
        let helper_built = runtime_installed && self.cached_helper_path().await.is_some();
        let steps = vec![
            step(DeviceSetupStepId::InstallXcode, "Install Xcode", xcode_installed, "Install Xcode from the App Store, then open it once."),
            step(
                DeviceSetupStepId::SelectXcodeCommandLineTools,
                "Point the command line tools at Xcode",
                xcode_installed,
                "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer",
            ),
            step(DeviceSetupStepId::AcceptXcodeLicense, "Accept the Xcode license", license_accepted, "sudo xcodebuild -license accept"),
            step(
                DeviceSetupStepId::InstallIosRuntime,
                "Install an iOS simulator runtime",
                runtime_installed,
                "xcodebuild -downloadPlatform iOS",
            ),
            step(
                DeviceSetupStepId::BuildDeviceHelper,
                "Build the Cascade device helper",
                helper_built,
                "Built automatically the first time you attach a device.",
            ),
        ];
        if !steps.iter().all(|step| step.done) {
            return DeviceAvailability::SetupRequired { steps };
        }
        // Setup is complete; what remains is whether the private symbols the helper needs still
        // exist on this Xcode. A failure there is degraded, not setup-required.
        match self.probe_helper_capabilities().await {
            None => DeviceAvailability::available(),
            Some(probe) => availability_from_probe(&probe),
        }
    }

    /// The built helper's per-capability preflight, cached per binary: the answer only changes
    /// with the toolchain, and a new toolchain is a new cache key and so a new path. None when no
    /// helper is built yet.
    async fn probe_helper_capabilities(&self) -> Option<HelperProbeResult> {
        let binary = self.cached_helper_path().await?;
        if let Some((probed, result)) = &self.state.lock().unwrap().helper_probe {
            if *probed == binary {
                return Some(result.clone());
            }
        }
        // Confined exactly like the real run: a preflight under looser privileges would report
        // capabilities the sandboxed helper cannot deliver.
        let env = self.toolchain_env().await;
        let launch = self.sandbox_for(&binary, &["--probe".to_owned()]).await;
        let spec = SpawnSpec {
            program: launch.command,
            args: launch.args,
            cwd: None,
            env,
            env_remove: Vec::new(),
        };
        let probe = match run_once(self.options.spawner.as_ref(), &spec, PROBE_TIMEOUT).await {
            Ok(stdout) => parse_helper_probe(&stdout),
            // A helper that will not launch is reported through the same shape.
            Err(_) => HelperProbeResult {
                ok: false,
                capabilities: Vec::new(),
                toolchain: None,
                error: Some("The device helper could not be launched.".into()),
            },
        };
        self.state.lock().unwrap().helper_probe = Some((binary, probe.clone()));
        Some(probe)
    }

    /// Refuses when `capability` is broken on this machine, naming it and the Xcode it broke on.
    /// Operations backed by a working capability never call this, so one missing symbol cannot
    /// take the rest of the pane down.
    pub async fn assert_capability(&self, capability: DeviceCapabilityId) -> DeviceResult<()> {
        let Some(probe) = self.probe_helper_capabilities().await else { return Ok(()) };
        match probe.capabilities.iter().find(|entry| entry.id == capability) {
            Some(status) if !status.ok => {
                Err(DeviceBackendError::new(capability_unavailable_message(status, probe.toolchain.as_ref())))
            }
            _ => Ok(()),
        }
    }

    // ── Discovery and lifecycle ────────────────────────────────────────

    pub async fn list_devices(&self, options: DeviceListOptions) -> Vec<DeviceDescriptor> {
        let devices = self.list_devices_unchecked().await;
        if options.include_shutdown {
            devices
        } else {
            devices.into_iter().filter(|device| device.state != DeviceRuntimeState::Shutdown).collect()
        }
    }

    pub async fn boot(&self, udid: &str) -> DeviceResult<DeviceDescriptor> {
        self.state.lock().unwrap().keyboard_layouts.remove(udid);
        let result = self.simctl(&["boot", udid], BOOT_TIMEOUT, &[]).await?;
        // Booting an already-booted device is success: the pane and an agent can race on it.
        if !result.succeeded() && !regex_matches(r"(?i)current state: Booted", &result.stderr) {
            return Err(simctl_error("boot", &result));
        }
        self.simctl(&["bootstatus", udid], BOOT_TIMEOUT, &[]).await?;
        let devices = self.list_devices_unchecked().await;
        let mut device = devices
            .into_iter()
            .find(|candidate| candidate.udid == udid)
            .ok_or_else(|| DeviceBackendError::new(format!("Device {udid} disappeared after boot")))?;
        device.state = DeviceRuntimeState::Booted;
        Ok(device)
    }

    pub async fn shutdown(&self, udid: &str) -> DeviceResult<()> {
        self.stop_recording_for_lifecycle(udid).await;
        self.detach_stream(udid).await;
        // The helper outlives the simulator, and its attachment holds a display descriptor bound
        // to this boot; dropping it here makes the next attach rebind.
        let helper = self.current_helper();
        if let Some(helper) = helper {
            helper.invalidate_attachment(udid);
        }
        self.state.lock().unwrap().keyboard_layouts.remove(udid);
        let result = self.simctl(&["shutdown", udid], SIMCTL_TIMEOUT, &[]).await?;
        if !result.succeeded() && !regex_matches(r"(?i)current state: Shutdown", &result.stderr) {
            return Err(simctl_error("shutdown", &result));
        }
        Ok(())
    }

    pub async fn install(&self, udid: &str, app_path: &str) -> DeviceResult<DeviceInstallAppResult> {
        let bundle_id = read_bundle_identifier(app_path).await?;
        let result = self.simctl(&["install", udid, app_path], SIMCTL_TIMEOUT, &[]).await?;
        if !result.succeeded() {
            return Err(simctl_error("install", &result));
        }
        Ok(DeviceInstallAppResult { udid: udid.to_owned(), bundle_id })
    }

    pub async fn launch(
        &self,
        udid: &str,
        bundle_id: &str,
        arguments: &[String],
        options: &DeviceLaunchOptions,
    ) -> DeviceResult<DeviceLaunchAppResult> {
        // The app's stdout and stderr are not redirected into files or pipes whose reader
        // teardown could signal a still-running app.
        let environment: Vec<(String, String)> =
            options.environment.iter().map(|(key, value)| (format!("SIMCTL_CHILD_{key}"), value.clone())).collect();
        let mut args = vec!["launch".to_owned()];
        if options.terminate_existing {
            args.push("--terminate-running-process".into());
        }
        args.push(udid.to_owned());
        args.push(bundle_id.to_owned());
        args.extend(arguments.iter().cloned());
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let result = self.simctl(&args, SIMCTL_TIMEOUT, &environment).await?;
        if !result.succeeded() {
            return Err(simctl_error("launch", &result));
        }
        // `simctl launch` prints `<bundleId>: <pid>`.
        let pid = Regex::new(r":\s*(\d+)\s*$")
            .expect("valid pattern")
            .captures(result.stdout.trim())
            .and_then(|captures| captures[1].parse().ok());
        Ok(DeviceLaunchAppResult { udid: udid.to_owned(), bundle_id: bundle_id.to_owned(), pid })
    }

    pub async fn open_url(&self, udid: &str, url: &str) -> DeviceResult<()> {
        let result = self.simctl(&["openurl", udid, url], SIMCTL_TIMEOUT, &[]).await?;
        if !result.succeeded() {
            return Err(simctl_error("openurl", &result));
        }
        Ok(())
    }

    pub async fn screenshot(&self, udid: &str, options: DeviceScreenshotOptions) -> DeviceResult<DeviceScreenshotCapture> {
        // Captured to a temporary file either way, because `simctl io screenshot` only writes to a
        // path; one the caller wants kept is copied next to the recordings afterwards.
        let directory = TemporaryDirectory::new("cascade-device-")
            .map_err(|error| DeviceBackendError::new(format!("Could not create a screenshot folder: {error}")))?;
        let file = directory.0.join("screenshot.png");
        self.capture_screenshot(udid, &file).await?;
        // Up to 32 MiB, so read off the runtime's workers.
        let full = blocking({
            let file = file.clone();
            move || {
                let size = std::fs::metadata(&file)
                    .map_err(|error| DeviceBackendError::new(format!("Screenshot was not written: {error}")))?
                    .len();
                if size > MAX_SCREENSHOT_BYTES {
                    return Err(DeviceBackendError::new("Screenshot exceeded the maximum supported size"));
                }
                std::fs::read(&file).map_err(|error| DeviceBackendError::new(format!("Could not read the screenshot: {error}")))
            }
        })
        .await?;
        let saved = if options.save { Some(self.save_screenshot_file(udid, &full).await?) } else { None };
        let points = if options.resolution == DeviceScreenshotResolution::Points {
            let scaled = self.scale_to_points(udid, &file, &directory.0).await;
            if scaled.is_none() {
                return Err(DeviceBackendError::new(
                    "Could not produce a screenshot in device-point coordinates. Describe the UI for tap points instead.",
                ));
            }
            scaled
        } else {
            None
        };
        let sized = points.unwrap_or_else(|| full.clone());
        if let (DeviceScreenshotResolution::Points, Some(max)) = (options.resolution, options.max_inline_bytes) {
            if sized.len() > max {
                return Err(DeviceBackendError::new(
                    "Point-resolution screenshot exceeds the inline image limit; use device_describe_ui for coordinates.",
                ));
            }
        }
        // Inline consumers (agent tool results) ride frames with byte caps, so an oversized shot
        // is resampled rather than refused.
        let bytes = match options.max_inline_bytes {
            Some(max) if sized.len() > max => resample_screenshot_png(&file, &directory.0, max).await?,
            _ => sized,
        };
        let (width, height) = read_png_dimensions(&bytes).unwrap_or((1, 1));
        let engine = base64::engine::general_purpose::STANDARD;
        Ok(DeviceScreenshotCapture {
            result: DeviceScreenshotResult {
                udid: udid.to_owned(),
                name: format!("simulator-{udid}.png"),
                mime_type: "image/png".into(),
                width,
                height,
                size_bytes: bytes.len(),
                bytes_base64: engine.encode(&bytes),
                captured_at: iso_from_millis(super::now_millis()),
                path: saved.map(|path| path.to_string_lossy().into_owned()),
            },
            proof_bytes_base64: options.proof.then(|| engine.encode(&full)),
        })
    }

    /// Through the attached helper when it can, which reads the framebuffer in-process (~40 ms),
    /// and through `simctl io` otherwise (~430 ms, but public API that survives a broken
    /// framebuffer path).
    async fn capture_screenshot(&self, udid: &str, file: &Path) -> DeviceResult<()> {
        let helper = self.current_helper();
        if let Some(helper) = helper {
            if helper.running() && helper.attached_device().is_some_and(|attachment| attachment.udid == udid) {
                let path = file.to_string_lossy();
                if self.helper_request(methods::SCREENSHOT, json!({ "path": path })).await.is_ok() {
                    return Ok(());
                }
            }
        }
        let path = file.to_string_lossy();
        let result = self.simctl(&["io", udid, "screenshot", &path], SIMCTL_TIMEOUT, &[]).await?;
        if !result.succeeded() {
            return Err(simctl_error("screenshot", &result));
        }
        Ok(())
    }

    /// Resampled to the screen's size in points, so a coordinate read off the image is the point
    /// a tap takes. None when the point size is unknown or `sips` fails.
    async fn scale_to_points(&self, udid: &str, source: &Path, directory: &Path) -> Option<Vec<u8>> {
        let known = self.state.lock().unwrap().device_geometry.get(udid).copied();
        let geometry = match known {
            Some(geometry) => geometry,
            None => self.catalogue_geometry(udid).await?,
        };
        let target = directory.join("screenshot-points.png");
        let args = vec![
            "-z".to_owned(),
            super::ui_snapshot::js_round(geometry.point_height).to_string(),
            super::ui_snapshot::js_round(geometry.point_width).to_string(),
            source.to_string_lossy().into_owned(),
            "--out".to_owned(),
            target.to_string_lossy().into_owned(),
        ];
        let result = process::run("/usr/bin/sips", &args, Duration::from_secs(10), &[]).await.ok()?;
        if !result.succeeded() {
            return None;
        }
        blocking(move || std::fs::read(&target).ok()).await
    }

    async fn catalogue_geometry(&self, udid: &str) -> Option<DeviceGeometry> {
        self.list_devices_unchecked().await.into_iter().find(|device| device.udid == udid)?.geometry
    }

    /// Keeps a screenshot where recordings go, named the same way.
    async fn save_screenshot_file(&self, udid: &str, bytes: &[u8]) -> DeviceResult<PathBuf> {
        let name = self.device_name(udid).await;
        let target = self.next_capture_path(&name, &iso_from_millis(self.now()), "png")?;
        let written = blocking({
            let (target, bytes) = (target.clone(), bytes.to_vec());
            move || std::fs::write(&target, bytes)
        })
        .await;
        // The reservation only guards two captures in one millisecond choosing one name; the
        // file on disk owns it from here.
        self.state.lock().unwrap().reserved_capture_paths.remove(&target);
        written.map_err(|error| DeviceBackendError::new(format!("Could not save the screenshot to {}: {error}", target.display())))?;
        Ok(target)
    }

    async fn device_name(&self, udid: &str) -> String {
        self.list_devices_unchecked()
            .await
            .into_iter()
            .find(|device| device.udid == udid)
            .map(|device| device.name)
            .unwrap_or_else(|| udid.to_owned())
    }

    pub async fn start_recording(&self, udid: &str) -> DeviceResult<DeviceStartRecordingResult> {
        let this = self.this.upgrade().ok_or_else(Self::disposed_error)?;
        let starting = {
            let mut state = self.state.lock().unwrap();
            if state.disposed {
                return Err(Self::disposed_error());
            }
            if state.recordings.contains_key(udid) || state.recording_starts.contains_key(udid) {
                return Err(DeviceBackendError::new(format!("Device {udid} is already recording")));
            }
            state.recording_tasks += 1;
            let token = state.recording_tasks;
            let owned = udid.to_owned();
            // A task of its own, which takes its own entry out when it ends: a caller that stops
            // waiting (an interrupted agent turn) must not leave the start behind, or the device
            // would read as recording until dispose.
            let task = spawn_inheriting(async move {
                let result = this.clone().start_recording_process(&owned).await;
                let mut state = this.state.lock().unwrap();
                if state.recording_starts.get(&owned).is_some_and(|(current, _)| *current == token) {
                    state.recording_starts.remove(&owned);
                }
                result
            });
            let starting: SharedStart = task.map(joined).boxed().shared();
            // Inserted under the lock the task takes to remove it, so it cannot end first.
            state.recording_starts.insert(udid.to_owned(), (token, starting.clone()));
            starting
        };
        starting.await
    }

    pub async fn stop_recording(&self, udid: &str) -> DeviceResult<DeviceStopRecordingResult> {
        let this = self.this.upgrade().ok_or_else(Self::disposed_error)?;
        let (stopping, starting) = {
            let state = self.state.lock().unwrap();
            (
                state.recording_stops.get(udid).map(|(_, stopping)| stopping.clone()),
                state.recording_starts.get(udid).map(|(_, starting)| starting.clone()),
            )
        };
        if let Some(stopping) = stopping {
            return stopping.await;
        }
        if let Some(starting) = starting {
            let _ = starting.await;
        }
        let stopping = {
            let mut state = self.state.lock().unwrap();
            match state.recording_stops.get(udid).map(|(_, stopping)| stopping.clone()) {
                Some(stopping) => stopping,
                None => {
                    let recording = state
                        .recordings
                        .get(udid)
                        .cloned()
                        .ok_or_else(|| DeviceBackendError::new(format!("Device {udid} is not recording")))?;
                    state.recording_tasks += 1;
                    let token = state.recording_tasks;
                    let owned = udid.to_owned();
                    // As for a start: the stop finishes, and forgets itself, whoever still waits.
                    let task = spawn_inheriting(async move {
                        let result = this.clone().finish_recording(&owned, recording).await;
                        let mut state = this.state.lock().unwrap();
                        if state.recording_stops.get(&owned).is_some_and(|(current, _)| *current == token) {
                            state.recording_stops.remove(&owned);
                        }
                        result
                    });
                    let stopping: SharedStop = task.map(joined).boxed().shared();
                    state.recording_stops.insert(udid.to_owned(), (token, stopping.clone()));
                    stopping
                }
            }
        };
        stopping.await
    }

    // ── Helper-backed capabilities ─────────────────────────────────────
    //
    // Each operation asserts only the capability it needs, so a symbol Apple moved in one area
    // cannot disable the others. Screenshots and recordings run on public `simctl io` and
    // survive even a completely broken framebuffer path.

    /// Sends one HID injection, rebinding the helper's input client when the first attempt was
    /// refused before anything reached the guest. The client is bound to one boot of one
    /// simulator; when it goes stale the helper reports it, and a forced re-attach rebuilds it.
    async fn inject_input(
        &self,
        udid: &str,
        method: &str,
        params: impl Fn(&HelperClient) -> Result<Value, DeviceHelperError>,
    ) -> DeviceResult<Value> {
        self.assert_capability(DeviceCapabilityId::Hid).await?;
        let helper = self.attached_helper(udid, false).await?;
        let first = match params(&helper) {
            Ok(params) => self.helper_request(method, params).await,
            Err(error) => Err(helper_error(&error)),
        };
        match first {
            Ok(answer) => return Ok(answer),
            Err(error) => {
                if !is_input_not_delivered(&error.message)
                    // A budget refusal does not mean the now-ready transport is stale.
                    || regex_matches(r"(?i)input deadline", &error.message)
                    // Replaying keystrokes after a partial delivery types them twice; only a
                    // refusal that sent nothing is safe to repeat.
                    || !regex_matches(r"(?i)(?:^|: )nothing was sent:", &error.message)
                {
                    return Err(error);
                }
                // dtuhidd still coming up after a boot: the attachment is fine and keeps warming,
                // while a re-attach would restart the wait.
                if regex_matches(r"(?i)still starting", &error.message) {
                    let params = params(&helper).map_err(|error| helper_error(&error))?;
                    return self.helper_request(method, params).await;
                }
            }
        }
        let rebound = self.attached_helper(udid, true).await?;
        let params = params(&rebound).map_err(|error| helper_error(&error))?;
        self.helper_request(method, params).await
    }

    pub async fn tap(&self, udid: &str, x: f64, y: f64, hold_ms: Option<u32>) -> DeviceResult<()> {
        self.inject_input(udid, methods::TAP, |helper| {
            let (x, y) = helper.normalize(x, y)?;
            let mut params = json!({ "x": x, "y": y });
            if let Some(hold_ms) = hold_ms {
                params["holdMs"] = json!(hold_ms);
            }
            Ok(params)
        })
        .await
        .map(drop)
    }

    /// One step of a live touch: the helper's `touch`, which holds the finger down from `down`
    /// until `up`, each `move` moving it.
    pub async fn touch(&self, udid: &str, phase: DeviceTouchPhase, x: f64, y: f64) -> DeviceResult<()> {
        self.inject_input(udid, methods::TOUCH, |helper| {
            let (x, y) = helper.normalize(x, y)?;
            Ok(json!({ "phase": phase.as_str(), "x": x, "y": y }))
        })
        .await
        .map(drop)
    }

    pub async fn swipe(&self, udid: &str, gesture: DeviceSwipeGesture) -> DeviceResult<()> {
        self.inject_input(udid, methods::SWIPE, |helper| {
            let (start_x, start_y) = helper.normalize(gesture.from_x, gesture.from_y)?;
            let (end_x, end_y) = helper.normalize(gesture.to_x, gesture.to_y)?;
            let mut params = json!({
                "startX": start_x,
                "startY": start_y,
                "endX": end_x,
                "endY": end_y,
                "durationMs": gesture.duration_ms,
            });
            if let Some(edge) = gesture.edge {
                params["edge"] = json!(edge.as_str());
            }
            Ok(params)
        })
        .await
        .map(drop)
    }

    /// Types `text` in chunks that each fit one RPC deadline. Dropping the future stops it before
    /// the next chunk.
    pub async fn type_text(&self, udid: &str, text: &str) -> DeviceResult<DeviceTypeTextOutcome> {
        let characters: Vec<char> = text.chars().collect();
        let mut skipped = 0;
        for chunk in characters.chunks(TEXT_CHUNK_LENGTH) {
            let chunk: String = chunk.iter().collect();
            let result = self.inject_input(udid, methods::TEXT, |_| Ok(json!({ "text": chunk }))).await?;
            if let Some(count) = result.get("skipped").and_then(Value::as_f64) {
                skipped += count as u64;
            }
        }
        Ok(DeviceTypeTextOutcome { skipped })
    }

    pub async fn set_focused_value(&self, udid: &str, value: &str) -> DeviceResult<()> {
        self.assert_capability(DeviceCapabilityId::Accessibility).await?;
        self.attached_helper(udid, false).await?;
        self.helper_request(methods::SET_FOCUSED_VALUE, json!({ "value": value })).await.map(drop)
    }

    /// HID keystrokes go through the guest's hardware keyboard layout: on an Italian simulator
    /// the key that is "-" on a US keyboard types "'". Only a device whose first keyboard (or,
    /// with none set, whose locale) is US English gets keystrokes.
    pub async fn uses_us_keyboard_layout(&self, udid: &str) -> bool {
        if let Some(cached) = self.state.lock().unwrap().keyboard_layouts.get(udid) {
            return *cached;
        }
        let answer = async {
            let keyboards = self.simctl(&["spawn", udid, "defaults", "read", "-g", "AppleKeyboards"], SIMCTL_TIMEOUT, &[]).await?;
            let first = Regex::new(r#""?([A-Za-z]{2}[_-][A-Za-z]{2}[^",\s)]*)"#)
                .expect("valid pattern")
                .captures(if keyboards.succeeded() { &keyboards.stdout } else { "" })
                .map(|captures| captures[1].to_owned());
            let us = Regex::new(r"(?i)^en[_-]US\b").expect("valid pattern");
            if let Some(first) = first {
                return Ok::<bool, DeviceBackendError>(us.is_match(&first));
            }
            let locale = self.simctl(&["spawn", udid, "defaults", "read", "-g", "AppleLocale"], SIMCTL_TIMEOUT, &[]).await?;
            Ok(locale.succeeded() && us.is_match(locale.stdout.trim()))
        }
        .await
        .unwrap_or(false);
        self.state.lock().unwrap().keyboard_layouts.insert(udid.to_owned(), answer);
        answer
    }

    // ── Environment and diagnostics ────────────────────────────────────

    pub async fn configure(&self, udid: &str, configuration: &DeviceConfiguration) -> DeviceResult<()> {
        let args: Vec<String> = match configuration {
            DeviceConfiguration::Appearance(appearance) => {
                let appearance = match appearance {
                    super::backend::DeviceAppearance::Light => "light",
                    super::backend::DeviceAppearance::Dark => "dark",
                };
                vec!["ui".into(), udid.into(), "appearance".into(), appearance.into()]
            }
            DeviceConfiguration::ContentSize { category } => {
                vec!["ui".into(), udid.into(), "content_size".into(), category.clone()]
            }
            DeviceConfiguration::Location { latitude, longitude } => {
                vec!["location".into(), udid.into(), "set".into(), format!("{latitude},{longitude}")]
            }
            DeviceConfiguration::LocationClear => vec!["location".into(), udid.into(), "clear".into()],
            DeviceConfiguration::Privacy { action, service, bundle_id } => {
                let action = match action {
                    DevicePrivacyAction::Grant => "grant",
                    DevicePrivacyAction::Revoke => "revoke",
                    DevicePrivacyAction::Reset => "reset",
                };
                let mut args = vec!["privacy".into(), udid.into(), action.into(), service.clone()];
                args.extend(bundle_id.iter().cloned());
                args
            }
        };
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        let result = self.simctl(&borrowed, SIMCTL_TIMEOUT, &[]).await?;
        if !result.succeeded() {
            return Err(simctl_error(&args[0], &result));
        }
        Ok(())
    }

    pub async fn read_logs(&self, udid: &str, query: &DeviceLogQuery) -> DeviceResult<DeviceLogResult> {
        let executable = self.executable_for(udid, &query.bundle_id).await?;
        let since_ms = (self.now() - (query.since_seconds as i64) * 1000) as f64;
        let mut args = vec!["spawn".to_owned(), udid.to_owned(), "log".to_owned()];
        args.extend(unified_log_arguments(&executable, query));
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        let unified = async {
            let result = self.simctl(&borrowed, Duration::from_secs(60), &[]).await?;
            if !result.succeeded() {
                return Err(simctl_error("log show", &result));
            }
            // `log show` prints a column header before the first entry.
            let entry = Regex::new(r"^\d{4}-\d{2}-\d{2} ").expect("valid pattern");
            Ok(result.stdout.split('\n').filter(|line| entry.is_match(line)).map(str::to_owned).collect::<Vec<_>>())
        };
        let directory = self.options.diagnostic_reports.clone();
        let (crash_executable, crash_udid) = (executable.clone(), udid.to_owned());
        let crashes = tokio::task::spawn_blocking(move || read_crash_reports(&directory, &crash_executable, &crash_udid, since_ms))
            .unwrap_or_else(|_| Vec::new());
        let (unified, crashes) = tokio::join!(unified, crashes);
        let unified = unified?;
        let contains = query.contains.as_deref().map(str::to_lowercase);
        let filter = |lines: Vec<String>| -> Vec<String> {
            match &contains {
                None => lines,
                Some(needle) => lines.into_iter().filter(|line| line.to_lowercase().contains(needle)).collect(),
            }
        };
        let (log, log_omitted) = tail_lines(&filter(unified), query.limit);
        let (console, console_omitted) = tail_lines(&filter(Vec::new()), query.limit);
        Ok(DeviceLogResult {
            bundle_id: query.bundle_id.clone(),
            process: Some(executable),
            log,
            console,
            console_unavailable_reason: Some(
                "Direct stdout/stderr capture is unavailable; use Logger, NSLog or os_log for simulator output.".into(),
            ),
            crashes,
            omitted: log_omitted + console_omitted,
        })
    }

    /// `CFBundleExecutable` of an installed app, for log predicates and crash reports. A failure
    /// is not remembered: the app may be installed a moment later.
    async fn executable_for(&self, udid: &str, bundle_id: &str) -> DeviceResult<String> {
        let key = format!("{udid}:{bundle_id}");
        if let Some(executable) = self.state.lock().unwrap().executables.get(&key) {
            return Ok(executable.clone());
        }
        let result = self.simctl(&["appinfo", udid, bundle_id], SIMCTL_TIMEOUT, &[]).await?;
        let found = Regex::new(r#"CFBundleExecutable\s*=\s*"?([^";\n]+)"?;"#)
            .expect("valid pattern")
            .captures(&result.stdout)
            .map(|captures| captures[1].trim().to_owned());
        if !result.succeeded() && is_device_not_booted_detail(&result.stderr) {
            return Err(simctl_error("appinfo", &result));
        }
        let executable = found.filter(|_| result.succeeded()).ok_or_else(|| {
            DeviceBackendError::new(format!("App {bundle_id} is not installed on this simulator, so it has no logs to read."))
        })?;
        self.state.lock().unwrap().executables.insert(key, executable.clone());
        Ok(executable)
    }

    /// One USB HID usage per call, with held modifiers tracked by the helper, so a chord is sent
    /// as its modifier keys and then the main key.
    pub async fn key_event(&self, udid: &str, event: &DeviceKeyEvent) -> DeviceResult<()> {
        for modifier in &event.modifiers {
            let Some(usage) = hid_modifier_usage(*modifier) else { continue };
            self.inject_input(udid, methods::KEY, |_| Ok(json!({ "usage": usage, "phase": event.direction.as_str() })))
                .await?;
        }
        self.inject_input(udid, methods::KEY, |_| Ok(json!({ "usage": event.key_code, "phase": event.direction.as_str() })))
            .await
            .map(drop)
    }

    pub async fn press_button(&self, udid: &str, button: DeviceHardwareButton) -> DeviceResult<()> {
        if button == DeviceHardwareButton::Rotate {
            // Rotation is a Simulator.app window command, not a HID button, and the port it posts
            // through is not wired on a headless boot: refused rather than a silent no-op.
            return Err(DeviceBackendError::new(
                "Rotating a headless simulator is not supported; rotate the device from inside the app or use Simulator.app.",
            ));
        }
        self.assert_capability(DeviceCapabilityId::Hid).await?;
        self.inject_input(udid, methods::BUTTON, |_| Ok(json!({ "name": button.as_str() }))).await.map(drop)
    }

    pub async fn describe_ui(&self, udid: &str) -> DeviceResult<DeviceDescribeUiResult> {
        self.assert_capability(DeviceCapabilityId::Accessibility).await?;
        self.attached_helper(udid, false).await?;
        let result = self.helper_request(methods::DESCRIBE_UI, json!({})).await?;
        let tree = result.get("tree").filter(|tree| tree.is_object() || tree.is_array());
        let Some(tree) = tree else {
            return Err(DeviceBackendError::new("Device helper returned no accessibility tree"));
        };
        Ok(DeviceDescribeUiResult {
            udid: udid.to_owned(),
            captured_at: iso_from_millis(super::now_millis()),
            root: normalize_ui_node(tree),
        })
    }

    pub fn geometry(&self, udid: &str) -> Option<DeviceGeometry> {
        self.state.lock().unwrap().device_geometry.get(udid).copied()
    }

    /// Streams the device's screen to `subscribe_frames`. Needs both halves of the pipeline: the
    /// framebuffer to read and the encoder to compress it.
    pub async fn attach_stream(&self, udid: &str) -> DeviceResult<()> {
        self.assert_capability(DeviceCapabilityId::Framebuffer).await?;
        self.assert_capability(DeviceCapabilityId::Encoder).await?;
        let helper = self.attached_helper(udid, false).await?;
        if let Err(error) = helper.start_stream(udid).await {
            // After a reboot outside Cascade the cached attachment still looks valid, and the
            // stream fails with "no framebuffer surface" on every retry; a fresh attach fixes it.
            if !is_stale_descriptor_error(&error.message) {
                return Err(helper_error(&error));
            }
            self.attached_helper(udid, true).await?;
            helper.start_stream(udid).await.map_err(|error| helper_error(&error))?;
        }
        self.state.lock().unwrap().streaming_udid = Some(udid.to_owned());
        Ok(())
    }

    pub async fn detach_stream(&self, udid: &str) {
        let helper = {
            let mut state = self.state.lock().unwrap();
            if state.streaming_udid.as_deref() == Some(udid) {
                state.streaming_udid = None;
            }
            state.helper.as_ref().map(|(_, helper)| helper.clone())
        };
        // The helper holds one attachment, so its stream is this device's stream.
        let Some(helper) = helper.filter(|helper| helper.attached_device().is_some_and(|attachment| attachment.udid == udid))
        else {
            return;
        };
        helper.stop_stream().await;
    }

    pub fn subscribe_frames(&self) -> broadcast::Receiver<DeviceFrameRecord> {
        self.frames.subscribe()
    }

    pub fn subscribe_interruptions(&self) -> broadcast::Receiver<DeviceStreamInterruption> {
        self.interruptions.subscribe()
    }

    /// The helper exited. A running stream died with it, which nothing else reports: frames just
    /// stop. The next request starts a new helper; listeners decide whether to stream again.
    fn helper_exited(&self, number: u64, reason: String) {
        let udid = {
            let mut state = self.state.lock().unwrap();
            if state.disposed || state.helper.as_ref().map(|(current, _)| *current) != Some(number) {
                return;
            }
            state.streaming_udid.take()
        };
        if let Some(udid) = udid {
            let _ = self.interruptions.send(DeviceStreamInterruption { udid, reason });
        }
    }

    pub async fn dispose(&self) {
        let (active, starts) = {
            let mut state = self.state.lock().unwrap();
            if state.disposed {
                return;
            }
            state.disposed = true;
            (
                state.recordings.values().cloned().collect::<Vec<_>>(),
                state.recording_starts.values().map(|(_, starting)| starting.clone()).collect::<Vec<_>>(),
            )
        };
        futures_util::future::join_all(active.iter().map(|recording| interrupt_recording(recording))).await;
        futures_util::future::join_all(starts).await;
        let helper = {
            let mut state = self.state.lock().unwrap();
            state.recordings.clear();
            state.reserved_capture_paths.clear();
            state.helper.take()
        };
        if let Some((_, helper)) = helper {
            helper.dispose().await;
        }
    }

    // ── Recording ──────────────────────────────────────────────────────

    async fn start_recording_process(self: Arc<Self>, udid: &str) -> DeviceResult<DeviceStartRecordingResult> {
        if !self.darwin() {
            return Err(DeviceBackendError::new("iOS simulators are only available on macOS"));
        }
        let name = self.device_name(udid).await;
        let requested_at = self.now();
        let output = self.next_capture_path(&name, &iso_from_millis(requested_at), "mp4")?;
        if self.state.lock().unwrap().disposed {
            self.state.lock().unwrap().reserved_capture_paths.remove(&output);
            return Err(Self::disposed_error());
        }
        let args: Vec<String> = ["simctl", "io", udid, "recordVideo", "--codec=h264"]
            .iter()
            .map(|arg| arg.to_string())
            .chain([output.to_string_lossy().into_owned()])
            .collect();
        let child = match self.options.recording_spawner.spawn(&args) {
            Ok(child) => child,
            Err(error) => {
                self.state.lock().unwrap().reserved_capture_paths.remove(&output);
                return Err(DeviceBackendError::new(format!("Could not start simulator recording: {error}")));
            }
        };
        let (progress, receiver) = watch::channel(RecordingProgress::default());
        let progress = Arc::new(progress);
        let recording = Arc::new(ActiveRecording {
            path: output.clone(),
            started_at_ms: Mutex::new(requested_at),
            progress: receiver,
            interrupt: child.interrupt,
            kill: child.kill,
        });
        self.state.lock().unwrap().recordings.insert(udid.to_owned(), recording.clone());

        let mut stderr = child.stderr;
        let stderr_progress = progress.clone();
        let stderr_reader = tokio::spawn(async move {
            let mut buffer = vec![0u8; 8 * 1024];
            loop {
                let read = match stderr.read(&mut buffer).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => read,
                };
                let chunk = String::from_utf8_lossy(&buffer[..read]).into_owned();
                stderr_progress.send_modify(|state| {
                    state.stderr.push_str(&chunk);
                    let count = state.stderr.chars().count();
                    if count > MAX_RECORDING_STDERR_LENGTH {
                        let cut = state.stderr.char_indices().nth(count - MAX_RECORDING_STDERR_LENGTH).map_or(0, |(at, _)| at);
                        state.stderr.drain(..cut);
                    }
                });
            }
        });
        let backend = Arc::downgrade(&self);
        let finished = Arc::downgrade(&recording);
        let owned = udid.to_owned();
        let exited = child.exited;
        tokio::spawn(async move {
            exited.await;
            // What it printed before it ended is read first, as Node reads a stream to its end
            // before `close`; bounded, since a process it left behind could hold the pipe open.
            let _ = tokio::time::timeout(Duration::from_secs(1), stderr_reader).await;
            progress.send_modify(|state| state.exited = true);
            let (Some(backend), Some(recording)) = (backend.upgrade(), finished.upgrade()) else { return };
            let mut state = backend.state.lock().unwrap();
            if state.recordings.get(&owned).is_some_and(|current| Arc::ptr_eq(current, &recording)) {
                state.recordings.remove(&owned);
            }
            state.reserved_capture_paths.remove(&recording.path);
        });

        let started = match wait_for_recording_start(&recording).await {
            Ok(()) if recording.exited() => Err(DeviceBackendError::new("simctl recordVideo exited as recording began")),
            other => other,
        };
        match started {
            Ok(()) => {
                let started_at = self.now();
                *recording.started_at_ms.lock().unwrap() = started_at;
                Ok(DeviceStartRecordingResult {
                    udid: udid.to_owned(),
                    path: output.to_string_lossy().into_owned(),
                    started_at: iso_from_millis(started_at),
                })
            }
            Err(error) => {
                interrupt_recording(&recording).await;
                {
                    let mut state = self.state.lock().unwrap();
                    if state.recordings.get(udid).is_some_and(|current| Arc::ptr_eq(current, &recording)) {
                        state.recordings.remove(udid);
                    }
                    state.reserved_capture_paths.remove(&output);
                }
                let _ = std::fs::remove_file(&output);
                Err(error)
            }
        }
    }

    async fn finish_recording(self: Arc<Self>, udid: &str, recording: Arc<ActiveRecording>) -> DeviceResult<DeviceStopRecordingResult> {
        interrupt_recording(&recording).await;
        {
            let mut state = self.state.lock().unwrap();
            if state.recordings.get(udid).is_some_and(|current| Arc::ptr_eq(current, &recording)) {
                state.recordings.remove(udid);
            }
            state.reserved_capture_paths.remove(&recording.path);
        }
        let info = std::fs::metadata(&recording.path).map_err(|_| {
            DeviceBackendError::new(format!(
                "Simulator recording finished without a readable file at {}",
                recording.path.display()
            ))
        })?;
        let stopped_at = self.now();
        let started_at = *recording.started_at_ms.lock().unwrap();
        Ok(DeviceStopRecordingResult {
            udid: udid.to_owned(),
            path: recording.path.to_string_lossy().into_owned(),
            size_bytes: info.len(),
            duration_ms: (stopped_at - started_at).max(0) as u64,
            stopped_at: iso_from_millis(stopped_at),
        })
    }

    async fn stop_recording_for_lifecycle(&self, udid: &str) {
        let starting = self.state.lock().unwrap().recording_starts.get(udid).map(|(_, starting)| starting.clone());
        if let Some(starting) = starting {
            let _ = starting.await;
        }
        if !self.state.lock().unwrap().recordings.contains_key(udid) {
            return;
        }
        let _ = self.stop_recording(udid).await;
    }

    /// A unique path for a capture, shared by recordings (mp4) and screenshots (png).
    fn next_capture_path(&self, device_name: &str, started_at: &str, extension: &str) -> DeviceResult<PathBuf> {
        let directory = self.recording_directory();
        let timestamp = started_at.replace([':', '.'], "-");
        let base = format!("simulator-{}-{timestamp}", slug_device_name(device_name));
        let mut state = self.state.lock().unwrap();
        for suffix in 1u64.. {
            let name = if suffix == 1 { format!("{base}.{extension}") } else { format!("{base}-{suffix}.{extension}") };
            let candidate = directory.join(name);
            if state.reserved_capture_paths.contains(&candidate) {
                continue;
            }
            match std::fs::symlink_metadata(&candidate) {
                Ok(_) => continue,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(DeviceBackendError::new(format!(
                        "Could not inspect capture path {}: {error}",
                        candidate.display()
                    )))
                }
            }
            state.reserved_capture_paths.insert(candidate.clone());
            return Ok(candidate);
        }
        Err(DeviceBackendError::new(format!("Could not choose a unique capture path in {}", directory.display())))
    }

    fn recording_directory(&self) -> PathBuf {
        if let Some(directory) = &self.options.recording_directory {
            return std::path::absolute(directory).unwrap_or_else(|_| directory.clone());
        }
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        select_recording_directory(&[home.join("Desktop"), home.join("Downloads")], &std::env::temp_dir())
    }

    // ── simctl plumbing ────────────────────────────────────────────────

    async fn simctl(&self, args: &[&str], timeout: Duration, env: &[(String, String)]) -> DeviceResult<RunResult> {
        if !self.darwin() {
            return Err(DeviceBackendError::new("iOS simulators are only available on macOS"));
        }
        // Anything but a read can change what `list devices` reports; the listing cache is
        // dropped before the command runs so the next listing sees the change.
        if !READ_ONLY_SIMCTL_COMMANDS.contains(&args.first().copied().unwrap_or_default()) {
            let mut state = self.state.lock().unwrap();
            state.list_generation += 1;
            state.list_cache = None;
        }
        let mut environment = self.toolchain_env().await;
        environment.extend(env.iter().cloned());
        let mut command = vec!["simctl".to_owned()];
        command.extend(args.iter().map(|arg| arg.to_string()));
        process::run("xcrun", &command, timeout, &environment).await.map_err(DeviceBackendError::new)
    }

    /// One `simctl list` serves every caller within a short window: a manager snapshot lists
    /// twice, and agent tool calls arrive seconds apart. Any simctl change issued through this
    /// backend drops it at once.
    async fn list_devices_unchecked(&self) -> Vec<DeviceDescriptor> {
        if !self.darwin() {
            return Vec::new();
        }
        let _listing = self.list_lock.lock().await;
        let generation = {
            let state = self.state.lock().unwrap();
            if let Some(cache) = &state.list_cache {
                if cache.generation == state.list_generation && cache.listed_at.elapsed() < DEVICE_LIST_CACHE {
                    return cache.devices.clone();
                }
            }
            state.list_generation
        };
        let listed_at = Instant::now();
        let catalogue = self.device_type_catalogue().await;
        let devices = match self.simctl(&["list", "devices", "--json"], SIMCTL_TIMEOUT, &[]).await {
            Ok(result) if result.succeeded() => parse_simctl_devices(&result.stdout, catalogue).unwrap_or_default(),
            _ => Vec::new(),
        };
        let mut state = self.state.lock().unwrap();
        if state.list_generation == generation {
            state.list_cache = Some(ListCache { listed_at, generation, devices: devices.clone() });
        }
        devices
    }

    async fn device_type_catalogue(&self) -> &DeviceTypeCatalogue {
        // A failed read means no pre-boot geometry, not a broken pane, so it is kept empty.
        self.device_types
            .get_or_init(|| async {
                if !self.darwin() {
                    return DeviceTypeCatalogue::new();
                }
                let env = self.toolchain_env().await;
                read_device_type_catalogue(&env).await
            })
            .await
    }

    /// `DEVELOPER_DIR` wins over the machine-wide selection: that is how a beta Xcode is targeted
    /// without moving every other build on the machine onto it.
    fn developer_dir_override(&self) -> Option<String> {
        self.options.developer_dir_override.as_deref().map(str::trim).filter(|dir| !dir.is_empty()).map(str::to_owned)
    }

    /// The environment for `simctl`, `xcodebuild`, the helper build and the helper, pinning them
    /// all to one toolchain.
    async fn toolchain_env(&self) -> Vec<(String, String)> {
        match self.xcode_select_path().await {
            Some(dir) => vec![("DEVELOPER_DIR".to_owned(), dir)],
            None => Vec::new(),
        }
    }

    async fn xcode_select_path(&self) -> Option<String> {
        if let Some(dir) = self.developer_dir_override() {
            return Some(dir);
        }
        if let Some((at, dir)) = &self.state.lock().unwrap().xcode_select {
            if at.elapsed() < XCODE_SELECT_CACHE {
                return dir.clone();
            }
        }
        let resolved = self.resolve_xcode_select_path().await;
        self.state.lock().unwrap().xcode_select = Some((Instant::now(), resolved.clone()));
        resolved
    }

    /// The machine-wide selection, re-read on a short interval so `sudo xcode-select -s` from the
    /// checklist takes effect without a restart. A CommandLineTools selection is passed over for
    /// a full Xcode under /Applications: beta-only machines often never ran `xcode-select -s`.
    async fn resolve_xcode_select_path(&self) -> Option<String> {
        let result = process::run("xcode-select", &["-p".to_owned()], Duration::from_secs(10), &[]).await.ok();
        let selected = result
            .filter(RunResult::succeeded)
            .map(|result| result.stdout.trim().to_owned())
            .filter(|selected| !selected.is_empty());
        if let Some(selected) = selected.as_ref().filter(|selected| !selected.contains("CommandLineTools")) {
            return Some(selected.clone());
        }
        self.discover_xcode_developer_dir().or(selected)
    }

    /// A full Xcode under /Applications, found without `xcode-select`; scanned once per backend.
    fn discover_xcode_developer_dir(&self) -> Option<String> {
        if let Some(found) = &self.state.lock().unwrap().xcode_discovery {
            return found.clone();
        }
        let found = order_xcode_app_candidates(&(self.options.list_applications)())
            .into_iter()
            .map(|name| Path::new("/Applications").join(name).join("Contents/Developer"))
            .find(|dir| (self.options.xcode_bundle_usable)(dir))
            .map(|dir| dir.to_string_lossy().into_owned());
        self.state.lock().unwrap().xcode_discovery = Some(found.clone());
        found
    }

    async fn xcode_license_accepted(&self) -> bool {
        let env = self.toolchain_env().await;
        process::run("xcodebuild", &["-version".to_owned()], Duration::from_secs(20), &env)
            .await
            .is_ok_and(|result| result.succeeded())
    }

    // ── Helper lifecycle ───────────────────────────────────────────────

    fn current_helper(&self) -> Option<HelperClient> {
        self.state.lock().unwrap().helper.as_ref().map(|(_, helper)| helper.clone())
    }

    async fn helper_request(&self, method: &str, params: Value) -> DeviceResult<Value> {
        let helper = self.require_helper().await?;
        helper.request(method, params).await.map_err(|error| helper_error(&error))
    }

    /// The helper bound to `udid`. Every input and read acts on the helper's one attachment, so
    /// each call asserts it; `attach` is a no-op when the device is already the attached one.
    async fn attached_helper(&self, udid: &str, force: bool) -> DeviceResult<HelperClient> {
        let helper = self.require_helper().await?;
        let attachment = match helper.attach(udid, force).await {
            Ok(attachment) => attachment,
            // A device can be rebooted outside Cascade, which no hook here observes; a
            // dead-descriptor failure is retried once with a forced re-attach.
            Err(error) if is_stale_descriptor_error(&error.message) => {
                helper.attach(udid, true).await.map_err(|error| helper_error(&error))?
            }
            Err(error) => return Err(helper_error(&error)),
        };
        self.state.lock().unwrap().device_geometry.insert(
            udid.to_owned(),
            DeviceGeometry { point_width: attachment.point_width, point_height: attachment.point_height, scale: attachment.scale },
        );
        Ok(helper)
    }

    async fn require_helper(&self) -> DeviceResult<HelperClient> {
        if let Some(helper) = self.current_helper().filter(HelperClient::running) {
            return Ok(helper);
        }
        // Starting takes several awaits; without sharing it two callers arriving together would
        // each spawn a helper, and the first would never be disposed.
        let _starting = self.helper_start.lock().await;
        if let Some(helper) = self.current_helper().filter(HelperClient::running) {
            return Ok(helper);
        }
        self.start_helper().await
    }

    async fn start_helper(&self) -> DeviceResult<HelperClient> {
        let retired = self.state.lock().unwrap().helper.take();
        if let Some((_, retired)) = retired {
            retired.dispose().await;
        }
        let binary = self.compile_helper_if_needed().await?;
        // The helper resolves CoreSimulator out of DEVELOPER_DIR at runtime, so it inherits the
        // toolchain the binary was built against.
        let env = self.toolchain_env().await;
        let sandbox = self.sandbox_for(&binary, &[]).await;
        let number = {
            let mut state = self.state.lock().unwrap();
            if state.disposed {
                return Err(Self::disposed_error());
            }
            state.helpers_started += 1;
            state.helpers_started
        };
        let backend = self.this.clone();
        let helper = HelperClient::new(HelperClientOptions {
            spawner: self.options.spawner.clone(),
            launch: HelperLaunch { command: sandbox.command, args: sandbox.args, env, profile_path: sandbox.profile_path },
            request_timeout: self.options.request_timeout,
            frames: self.frames.clone(),
            on_exit: Some(Arc::new(move |reason| {
                if let Some(backend) = backend.upgrade() {
                    backend.helper_exited(number, reason);
                }
            })),
        });
        helper.start().map_err(|error| helper_error(&error))?;
        self.state.lock().unwrap().helper = Some((number, helper.clone()));
        Ok(helper)
    }

    /// Builds the helper against the current Xcode, or reuses the cached binary. Keyed by the
    /// Xcode build because the helper links private frameworks whose symbols move between
    /// releases: a binary from another Xcode would crash rather than fail to compile.
    pub async fn compile_helper_if_needed(&self) -> DeviceResult<PathBuf> {
        if let Some(cached) = self.cached_helper_path().await {
            return Ok(cached);
        }
        let _building = self.helper_build.lock().await;
        if let Some(cached) = self.cached_helper_path().await {
            return Ok(cached);
        }
        self.compile_helper().await
    }

    async fn compile_helper(&self) -> DeviceResult<PathBuf> {
        let key = self.xcode_build_key().await.map_err(|error| self.record_helper_failure(&error.message))?;
        let output = key_directory(&self.options.helper_cache_root, &key);
        let source = materialize_sources_blocking(output.join(DEVICE_HELPER_SOURCE_FOLDER))
            .await
            .map_err(|error| self.record_helper_failure(&format!("Could not write the device helper sources: {error}")))?;
        let env = self.toolchain_env().await;
        let args = [source.join("build.sh").to_string_lossy().into_owned(), output.to_string_lossy().into_owned()];
        let result = process::run("/bin/sh", &args, BUILD_TIMEOUT, &env)
            .await
            .map_err(|error| self.record_helper_failure(&error))?;
        if !result.succeeded() {
            let detail = match result.stderr.trim() {
                "" => result.stdout.trim(),
                stderr => stderr,
            };
            let detail = if detail.is_empty() { String::new() } else { format!(": {detail}") };
            return Err(self.record_helper_failure(&format!(
                "Device helper build failed{detail}. Verify Xcode is installed and its license accepted."
            )));
        }
        let binary = output.join(DEVICE_HELPER_BINARY_NAME);
        if !binary.exists() {
            return Err(self.record_helper_failure("Device helper build produced no binary"));
        }
        self.state.lock().unwrap().helper_build_failure = None;
        Ok(binary)
    }

    /// Remembered so `availability()` reports `helper-unavailable` instead of the pane retrying a
    /// build that will keep failing the same way.
    fn record_helper_failure(&self, message: &str) -> DeviceBackendError {
        self.state.lock().unwrap().helper_build_failure = Some(fit_device_message(message));
        DeviceBackendError::new(message)
    }

    async fn cached_helper_path(&self) -> Option<PathBuf> {
        if !self.darwin() {
            return None;
        }
        let key = self.xcode_build_key().await.ok()?;
        let binary = key_directory(&self.options.helper_cache_root, &key).join(DEVICE_HELPER_BINARY_NAME);
        binary.exists().then_some(binary)
    }

    /// The Seatbelt-wrapped command for a helper run, or the plain one; shared by the long-lived
    /// helper and the one-shot `--probe`. Logs once when confinement is skipped.
    async fn sandbox_for(&self, binary: &Path, args: &[String]) -> HelperSandboxCommand {
        let developer_dir = self.xcode_select_path().await;
        let folder = binary.parent().unwrap_or(Path::new("/")).join(DEVICE_HELPER_SOURCE_FOLDER);
        // Written again if anything removed them: the profile is read from here at every spawn.
        let source = materialize_sources_blocking(folder.clone()).await.unwrap_or(folder);
        let mut argv = vec![binary.to_string_lossy().into_owned()];
        argv.extend(args.iter().cloned());
        let launch = sandboxed_helper_command(
            &argv,
            &HelperSandboxContext {
                binary_path: binary,
                helper_source_dir: &source,
                developer_dir: developer_dir.as_deref(),
                opt_out: self.options.sandbox_opt_out.as_deref(),
            },
        );
        if launch.profile_path.is_none() && cfg!(target_os = "macos") {
            let mut state = self.state.lock().unwrap();
            if !state.warned_unsandboxed {
                state.warned_unsandboxed = true;
                tracing::warn!(
                    "device: the iOS Simulator helper is running WITHOUT its Seatbelt sandbox. It can read your files \
                     and open network sockets. Unset {SANDBOX_OPT_OUT_ENV} to restore confinement."
                );
            }
        }
        launch
    }

    /// The cache key: the Xcode version and build, and the digest of the vendored sources, so a
    /// helper fix invalidates the cache the way an Xcode upgrade does. Not recorded as a helper
    /// failure here: this runs on every cache lookup, and one slow call would otherwise leave the
    /// pane on "helper unavailable" until restart.
    async fn xcode_build_key(&self) -> DeviceResult<String> {
        let env = self.toolchain_env().await;
        let result = process::run("xcodebuild", &["-version".to_owned()], Duration::from_secs(20), &env).await.ok();
        result
            .filter(RunResult::succeeded)
            .and_then(|result| device_helper_cache_key(&result.stdout, Some(&vendored_source_revision())))
            .ok_or_else(|| {
                DeviceBackendError::new(
                    "Could not determine the Xcode version. Install Xcode and run: sudo xcode-select -s \
                     /Applications/Xcode.app/Contents/Developer",
                )
            })
    }
}

/// Runs a program to its end through the spawner, answering with its stdout; on a timeout the
/// process is ended and what it printed so far is not kept.
async fn run_once(spawner: &dyn Spawner, spec: &SpawnSpec, timeout: Duration) -> io::Result<String> {
    let child = spawner.spawn(spec)?;
    let mut terminate = child.terminate;
    drop(child.stdin);
    if let Some(mut stderr) = child.stderr {
        tokio::spawn(async move {
            let mut sink = Vec::new();
            let _ = stderr.read_to_end(&mut sink).await;
        });
    }
    let mut stdout = child.stdout;
    let exited = child.exited;
    let finished = async move {
        let mut output = Vec::new();
        let _ = stdout.read_to_end(&mut output).await;
        exited.await;
        output
    };
    match tokio::time::timeout(timeout, finished).await {
        Ok(output) => Ok(String::from_utf8_lossy(&output).into_owned()),
        Err(_) => {
            terminate();
            Ok(String::new())
        }
    }
}

/// Runs file work on the blocking pool rather than a runtime worker.
async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(work).await.expect("file work does not panic")
}

/// Spawns `future` with the command runner a test installed for this task, if any.
fn spawn_inheriting<F>(future: F) -> tokio::task::JoinHandle<F::Output>
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    match crate::cli::inherited() {
        Some(runner) => tokio::spawn(crate::cli::scoped(runner, future)),
        None => tokio::spawn(future),
    }
}

/// A recording task's answer, or why it gave none.
fn joined<T>(result: Result<DeviceResult<T>, tokio::task::JoinError>) -> DeviceResult<T> {
    result.unwrap_or_else(|error| Err(DeviceBackendError::new(format!("The recording task failed: {error}"))))
}

async fn wait_for_recording_start(recording: &ActiveRecording) -> DeviceResult<()> {
    let started = Regex::new(r"(?i)Recording started").expect("valid pattern");
    let mut progress = recording.progress.clone();
    let state = tokio::time::timeout(
        RECORDING_START_TIMEOUT,
        progress.wait_for(|state| started.is_match(&state.stderr) || state.exited),
    )
    .await;
    match state {
        Err(_) => Err(DeviceBackendError::retryable(format!(
            "simctl recordVideo did not start within {}ms",
            RECORDING_START_TIMEOUT.as_millis()
        ))),
        Ok(Ok(state)) if started.is_match(&state.stderr) => Ok(()),
        Ok(_) => {
            let detail = recording.progress.borrow().stderr.trim().to_owned();
            Err(DeviceBackendError::new(if detail.is_empty() {
                "simctl recordVideo exited before recording started".to_owned()
            } else {
                format!("simctl recordVideo exited before recording started: {detail}")
            }))
        }
    }
}

async fn wait_for_exit(recording: &ActiveRecording, timeout: Duration) -> bool {
    let mut progress = recording.progress.clone();
    let exited = tokio::time::timeout(timeout, progress.wait_for(|state| state.exited)).await.is_ok_and(|state| state.is_ok());
    exited
}

/// SIGINT, which makes simctl finish the file, then SIGKILL for one that does not exit in time.
async fn interrupt_recording(recording: &ActiveRecording) {
    if recording.exited() {
        return;
    }
    (recording.interrupt)();
    if wait_for_exit(recording, RECORDING_STOP_GRACE).await {
        return;
    }
    (recording.kill)();
    wait_for_exit(recording, RECORDING_KILL_GRACE).await;
}

/// The first of `candidates` that is a folder this process may write to, else `fallback`.
pub fn select_recording_directory(candidates: &[PathBuf], fallback: &Path) -> PathBuf {
    candidates
        .iter()
        .find(|directory| directory.is_dir() && writable(directory))
        .cloned()
        .unwrap_or_else(|| fallback.to_path_buf())
}

fn writable(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else { return false };
    // SAFETY: a valid C string, checked for write permission only.
    unsafe { libc::access(path.as_ptr(), libc::W_OK) == 0 }
}

/// A temporary folder, removed when dropped.
struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new(prefix: &str) -> io::Result<Self> {
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        let path = std::env::temp_dir().join(format!("{prefix}{}", &suffix[..12]));
        std::fs::create_dir(&path)?;
        Ok(Self(path))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Downscales a captured PNG with `sips` until it fits `max_bytes`, stepping the longest edge
/// down; a still-oversized result fails loudly rather than breaking the agent's transport.
async fn resample_screenshot_png(source: &Path, directory: &Path, max_bytes: usize) -> DeviceResult<Vec<u8>> {
    let mut smallest: Option<Vec<u8>> = None;
    for max_dimension in [1170, 840, 600] {
        let target = directory.join(format!("screenshot-{max_dimension}.png"));
        let args = [
            "-Z".to_owned(),
            max_dimension.to_string(),
            source.to_string_lossy().into_owned(),
            "--out".to_owned(),
            target.to_string_lossy().into_owned(),
        ];
        match process::run("/usr/bin/sips", &args, Duration::from_secs(30), &[]).await {
            Ok(result) if result.succeeded() => {}
            _ => continue,
        }
        let Some(bytes) = blocking(move || std::fs::read(&target).ok()).await else { continue };
        if bytes.len() <= max_bytes {
            return Ok(bytes);
        }
        if smallest.as_ref().is_none_or(|smallest| bytes.len() < smallest.len()) {
            smallest = Some(bytes);
        }
    }
    smallest
        .filter(|smallest| smallest.len() <= max_bytes)
        .ok_or_else(|| DeviceBackendError::new("Screenshot exceeded the maximum supported size"))
}

async fn read_bundle_identifier(app_path: &str) -> DeviceResult<String> {
    let plist = Path::new(app_path).join("Info.plist");
    let args = ["-c".to_owned(), "Print :CFBundleIdentifier".to_owned(), plist.to_string_lossy().into_owned()];
    let bundle_id = process::run("/usr/libexec/PlistBuddy", &args, Duration::from_secs(10), &[])
        .await
        .ok()
        .filter(RunResult::succeeded)
        .map(|result| result.stdout.trim().to_owned())
        .unwrap_or_default();
    if bundle_id.is_empty() {
        return Err(DeviceBackendError::new(format!("Could not read CFBundleIdentifier from {}", plist.display())));
    }
    Ok(bundle_id)
}

fn regex_matches(pattern: &str, text: &str) -> bool {
    Regex::new(pattern).expect("valid pattern").is_match(text)
}

fn helper_error(error: &DeviceHelperError) -> DeviceBackendError {
    // A timeout may still be progressing on the device; a refusal will not.
    DeviceBackendError { message: error.message.clone(), retryable: error.code == "helper_timeout" }
}

fn simctl_error(action: &str, result: &RunResult) -> DeviceBackendError {
    let detail = match result.stderr.trim() {
        "" => result.stdout.trim(),
        stderr => stderr,
    };
    // CoreSimulator answers a command for a shut-down device with SimError 405, which an agent
    // reads as a broken app rather than the one step it skipped.
    if is_device_not_booted_detail(detail) {
        return DeviceBackendError::new(format!(
            "simctl {action} failed because the simulator is not booted. Boot it with device_boot, then retry."
        ));
    }
    let message = if detail.is_empty() { format!("simctl {action} failed") } else { format!("simctl {action} failed: {detail}") };
    DeviceBackendError { message, retryable: result.timed_out }
}

/// SimError 405: the command needs a booted device and this one is not.
pub fn is_device_not_booted_detail(detail: &str) -> bool {
    regex_matches(r"(?i)current state: (?:Shutdown|Shutting Down)|code=405", detail)
}

/// The helper accepted an injection it could not deliver: the attachment answers, but its HID
/// client is bound to a boot that is gone.
pub fn is_input_not_delivered(message: &str) -> bool {
    regex_matches(r"(?i)not delivered to the simulator", message)
}

/// The helper holds a display descriptor from a previous boot: valid from its side, with nothing
/// behind it.
pub fn is_stale_descriptor_error(message: &str) -> bool {
    regex_matches(r"(?i)framebuffer surface|display has no|not attached", message)
}

/// USB HID keyboard usage codes for the modifiers the contract exposes.
fn hid_modifier_usage(modifier: DeviceKeyModifier) -> Option<u16> {
    match modifier {
        DeviceKeyModifier::Control => Some(0xe0),
        DeviceKeyModifier::Shift => Some(0xe1),
        DeviceKeyModifier::Option => Some(0xe2),
        DeviceKeyModifier::Command => Some(0xe3),
        DeviceKeyModifier::Function => None,
    }
}

fn slug_device_name(name: &str) -> String {
    let lower = name.to_lowercase();
    let slug = Regex::new(r"[^a-z0-9]+").expect("valid pattern").replace_all(&lower, "-");
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        "device".into()
    } else {
        slug.to_owned()
    }
}

fn map_simctl_state(raw: Option<&Value>) -> DeviceRuntimeState {
    match raw.and_then(Value::as_str) {
        Some("Booted") => DeviceRuntimeState::Booted,
        Some("Booting") => DeviceRuntimeState::Booting,
        Some("Shutting Down") => DeviceRuntimeState::ShuttingDown,
        _ => DeviceRuntimeState::Shutdown,
    }
}

/// `com.apple.CoreSimulator.SimRuntime.iOS-26-0` -> `iOS 26.0`.
pub fn format_runtime_identifier(identifier: &str) -> String {
    let tail = identifier.rsplit('.').next().unwrap_or(identifier);
    match Regex::new(r"^([A-Za-z]+)-(.+)$").expect("valid pattern").captures(tail) {
        Some(captures) => format!("{} {}", &captures[1], captures[2].replace('-', ".")),
        None => tail.to_owned(),
    }
}

/// `simctl list devices --json`. Unavailable devices (runtime deleted, profile missing) are
/// dropped: showing them only produces boots that fail.
pub fn parse_simctl_devices(json: &str, catalogue: &DeviceTypeCatalogue) -> DeviceResult<Vec<DeviceDescriptor>> {
    let parsed: Value =
        serde_json::from_str(json).map_err(|_| DeviceBackendError::new("Could not parse simctl device list"))?;
    let Some(by_runtime) = parsed.get("devices").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    let mut devices = Vec::new();
    for (runtime_identifier, list) in by_runtime {
        let Some(list) = list.as_array() else { continue };
        let runtime = format_runtime_identifier(runtime_identifier);
        for raw in list {
            if raw.get("isAvailable") == Some(&Value::Bool(false)) {
                continue;
            }
            let (Some(udid), Some(name)) = (
                raw.get("udid").and_then(Value::as_str).filter(|udid| !udid.is_empty()),
                raw.get("name").and_then(Value::as_str).filter(|name| !name.is_empty()),
            ) else {
                continue;
            };
            let device_type = raw.get("deviceTypeIdentifier").and_then(Value::as_str).and_then(|id| catalogue.get(id));
            devices.push(DeviceDescriptor {
                platform: DevicePlatform::IosSimulator,
                udid: udid.to_owned(),
                name: name.to_owned(),
                runtime: runtime.clone(),
                state: map_simctl_state(raw.get("state")),
                // Discovery cannot attribute a boot; the manager overrides the ones it booted.
                boot_source: DeviceBootSource::User,
                family: device_type.map(|profile| profile.family),
                geometry: device_type.map(|profile| profile.geometry),
            });
        }
    }
    Ok(devices)
}

pub fn has_bootable_ios_runtime(devices: &[DeviceDescriptor]) -> bool {
    !devices.is_empty()
}

/// `/Applications` entries as Xcode bundle candidates, stable `Xcode.app` first: a beta or
/// versioned install is picked only when it is the sole full Xcode.
pub fn order_xcode_app_candidates(entries: &[String]) -> Vec<String> {
    let mut candidates: Vec<String> =
        entries.iter().filter(|name| name.starts_with("Xcode") && name.ends_with(".app")).cloned().collect();
    candidates.sort_by(|a, b| match (a.as_str(), b.as_str()) {
        ("Xcode.app", "Xcode.app") => std::cmp::Ordering::Equal,
        ("Xcode.app", _) => std::cmp::Ordering::Less,
        (_, "Xcode.app") => std::cmp::Ordering::Greater,
        _ => a.to_lowercase().cmp(&b.to_lowercase()).then_with(|| a.cmp(b)),
    });
    candidates
}

fn clamp_text(value: Option<String>, max_length: usize) -> Option<String> {
    value.map(|value| {
        if value.chars().count() <= max_length {
            value
        } else {
            let mut clamped: String = value.chars().take(max_length - 1).collect();
            clamped.push('…');
            clamped
        }
    })
}

/// The helper's tree in the contract's shape. The helper omits absent attributes rather than
/// sending nulls; every one is filled in so the pane and the agent see one predictable node.
pub fn normalize_ui_node(raw: &Value) -> DeviceUiNode {
    let empty = serde_json::Map::new();
    let node = raw.as_object().unwrap_or(&empty);
    let frame = node.get("frame").and_then(Value::as_object).unwrap_or(&empty);
    let frame_value = |key: &str| frame.get(key).and_then(Value::as_f64).filter(|value| value.is_finite()).unwrap_or(0.0);
    let text = |key: &str| node.get(key).and_then(Value::as_str).filter(|value| !value.is_empty()).map(str::to_owned);
    // Only a complete pair of finite coordinates is worth surfacing: half a point would aim taps
    // at (0, y) instead of the control.
    let activation_point = node.get("activationPoint").and_then(Value::as_object).and_then(|point| {
        let x = point.get("x").and_then(Value::as_f64).filter(|x| x.is_finite())?;
        let y = point.get("y").and_then(Value::as_f64).filter(|y| y.is_finite())?;
        Some(DeviceUiPoint { x, y })
    });
    // JavaScript's `typeof null` is "object", so only a missing or non-object frame (not a null
    // one) marks the node unframed, as Synara reads it.
    let frame_missing = !matches!(node.get("frame"), Some(Value::Object(_)) | Some(Value::Null) | Some(Value::Array(_)));
    DeviceUiNode {
        role: node
            .get("role")
            .and_then(Value::as_str)
            .map(|role| role.chars().take(128).collect())
            .unwrap_or_else(|| "Unknown".into()),
        subrole: clamp_text(text("subrole"), 128),
        label: clamp_text(text("label"), UI_TEXT_MAX_LENGTH),
        value: clamp_text(text("value"), UI_TEXT_MAX_LENGTH),
        frame: DeviceUiFrame {
            x: frame_value("x"),
            y: frame_value("y"),
            width: frame_value("width").max(0.0),
            height: frame_value("height").max(0.0),
        },
        activation_point,
        identifier: clamp_text(text("identifier"), 512),
        enabled: Some(node.get("enabled") != Some(&Value::Bool(false))),
        focused: (node.get("focused") == Some(&Value::Bool(true))).then_some(true),
        selected: (node.get("selected") == Some(&Value::Bool(true))).then_some(true),
        placeholder: clamp_text(text("placeholder"), UI_TEXT_MAX_LENGTH),
        unframed: (node.get("unframed") == Some(&Value::Bool(true)) || frame_missing).then_some(true),
        children: node
            .get("children")
            .and_then(Value::as_array)
            .map(|children| children.iter().map(normalize_ui_node).collect())
            .unwrap_or_default(),
    }
}

const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// Width and height from the IHDR chunk, at a fixed offset; no decoder needed.
pub fn read_png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() < 24 || bytes[..8] != PNG_SIGNATURE {
        return None;
    }
    let width = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    (width > 0 && height > 0).then_some((width, height))
}

impl DeviceBackend for IosSimulatorBackend {
    fn platform(&self) -> DevicePlatform {
        DevicePlatform::IosSimulator
    }

    fn availability(&self) -> BoxFuture<'_, DeviceAvailability> {
        Box::pin(IosSimulatorBackend::availability(self))
    }

    fn list_devices(&self, options: DeviceListOptions) -> BoxFuture<'_, DeviceResult<Vec<DeviceDescriptor>>> {
        Box::pin(async move { Ok(IosSimulatorBackend::list_devices(self, options).await) })
    }

    fn boot<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceDescriptor>> {
        Box::pin(IosSimulatorBackend::boot(self, udid))
    }

    fn shutdown<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::shutdown(self, udid))
    }

    fn install<'a>(&'a self, udid: &'a str, app_path: &'a str) -> BoxFuture<'a, DeviceResult<DeviceInstallAppResult>> {
        Box::pin(IosSimulatorBackend::install(self, udid, app_path))
    }

    fn launch<'a>(
        &'a self,
        udid: &'a str,
        bundle_id: &'a str,
        arguments: &'a [String],
        options: &'a DeviceLaunchOptions,
    ) -> BoxFuture<'a, DeviceResult<DeviceLaunchAppResult>> {
        Box::pin(IosSimulatorBackend::launch(self, udid, bundle_id, arguments, options))
    }

    fn open_url<'a>(&'a self, udid: &'a str, url: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::open_url(self, udid, url))
    }

    fn tap<'a>(&'a self, udid: &'a str, x: f64, y: f64, hold_ms: Option<u32>) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::tap(self, udid, x, y, hold_ms))
    }

    fn swipe<'a>(&'a self, udid: &'a str, gesture: DeviceSwipeGesture) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::swipe(self, udid, gesture))
    }

    fn touch<'a>(&'a self, udid: &'a str, phase: DeviceTouchPhase, x: f64, y: f64) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::touch(self, udid, phase, x, y))
    }

    fn type_text<'a>(&'a self, udid: &'a str, text: &'a str) -> BoxFuture<'a, DeviceResult<DeviceTypeTextOutcome>> {
        Box::pin(IosSimulatorBackend::type_text(self, udid, text))
    }

    fn set_focused_value<'a>(&'a self, udid: &'a str, value: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::set_focused_value(self, udid, value))
    }

    fn uses_us_keyboard_layout<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, bool> {
        Box::pin(IosSimulatorBackend::uses_us_keyboard_layout(self, udid))
    }

    fn key_event<'a>(&'a self, udid: &'a str, event: &'a DeviceKeyEvent) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::key_event(self, udid, event))
    }

    fn press_button<'a>(&'a self, udid: &'a str, button: DeviceHardwareButton) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::press_button(self, udid, button))
    }

    fn screenshot<'a>(&'a self, udid: &'a str, options: DeviceScreenshotOptions) -> BoxFuture<'a, DeviceResult<DeviceScreenshotCapture>> {
        Box::pin(IosSimulatorBackend::screenshot(self, udid, options))
    }

    fn start_recording<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceStartRecordingResult>> {
        Box::pin(IosSimulatorBackend::start_recording(self, udid))
    }

    fn stop_recording<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceStopRecordingResult>> {
        Box::pin(IosSimulatorBackend::stop_recording(self, udid))
    }

    fn describe_ui<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceDescribeUiResult>> {
        Box::pin(IosSimulatorBackend::describe_ui(self, udid))
    }

    fn configure<'a>(&'a self, udid: &'a str, configuration: &'a DeviceConfiguration) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::configure(self, udid, configuration))
    }

    fn read_logs<'a>(&'a self, udid: &'a str, query: &'a DeviceLogQuery) -> BoxFuture<'a, DeviceResult<DeviceLogResult>> {
        Box::pin(IosSimulatorBackend::read_logs(self, udid, query))
    }

    fn geometry(&self, udid: &str) -> Option<DeviceGeometry> {
        IosSimulatorBackend::geometry(self, udid)
    }

    fn attach_stream<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(IosSimulatorBackend::attach_stream(self, udid))
    }

    fn detach_stream<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, ()> {
        Box::pin(IosSimulatorBackend::detach_stream(self, udid))
    }

    fn subscribe_frames(&self) -> broadcast::Receiver<DeviceFrameRecord> {
        IosSimulatorBackend::subscribe_frames(self)
    }

    fn subscribe_interruptions(&self) -> broadcast::Receiver<DeviceStreamInterruption> {
        IosSimulatorBackend::subscribe_interruptions(self)
    }

    fn dispose(&self) -> BoxFuture<'_, ()> {
        Box::pin(IosSimulatorBackend::dispose(self))
    }
}
