//! A deterministic in-memory `DeviceBackend` for the manager, tool and route tests. Port of
//! Synara's `apps/server/src/device/FakeDeviceBackend.ts`: every call is recorded, any call can be
//! made to fail once, and the screen is a small fixed app with a virtualized list below the fold.
//! Where Synara's tests replace a method on the instance, this fake takes a hook instead
//! (`transform_tree`, `fail_listing`, `hold_attach`, `hold_boot`, `hold_shutdown`,
//! `hold_detach`).

use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};

use tokio::sync::{broadcast, Notify};

use crate::device::{
    backend::{
        BoxFuture, DeviceBackend, DeviceBackendError, DeviceConfiguration, DeviceFrameRecord, DeviceKeyEvent,
        DeviceLaunchOptions, DeviceListOptions, DeviceLogQuery, DeviceLogResult, DeviceResult, DeviceScreenshotCapture,
        DeviceScreenshotOptions, DeviceStreamFrame, DeviceStreamInterruption, DeviceSwipeGesture, DeviceTouchPhase, DeviceTypeTextOutcome,
    },
    contracts::{
        DeviceAvailability, DeviceBootSource, DeviceDescribeUiResult, DeviceDescriptor, DeviceGeometry, DeviceHardwareButton,
        DeviceInstallAppResult, DeviceLaunchAppResult, DevicePlatform, DeviceRuntimeState, DeviceScreenshotResult,
        DeviceStartRecordingResult, DeviceStopRecordingResult, DeviceUiFrame, DeviceUiNode, DeviceUiPoint,
    },
};

pub const DEVICE_A: &str = "FAKE-0001";
pub const DEVICE_B: &str = "FAKE-0002";
pub const DEVICE_C: &str = "FAKE-0003";
pub const DEVICE_D: &str = "FAKE-0004";

/// iPhone 17 Pro geometry.
pub const FAKE_GEOMETRY: DeviceGeometry = DeviceGeometry { point_width: 402.0, point_height: 874.0, scale: 3.0 };

/// A 1x1 transparent PNG.
pub const PNG_BASE64: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// Far enough below the 852pt screen to need several swipes to reach.
const FAKE_DEEP_ROW_START_Y: f64 = 2_400.0;
/// The list's end: past this the deep row stops moving.
const FAKE_MAX_SCROLL_OFFSET: f64 = 2_000.0;
/// Rows further down than this are not rendered yet, as UIKit virtualizes them.
const FAKE_VIRTUALIZATION_HORIZON: f64 = 1_600.0;

#[derive(Clone, Debug, PartialEq)]
pub enum FakeCall {
    Boot(String),
    Shutdown(String),
    Install { udid: String, app_path: String },
    Launch { udid: String, bundle_id: String, options: DeviceLaunchOptions },
    OpenUrl { udid: String, url: String },
    Tap { udid: String, x: f64, y: f64, hold_ms: Option<u32> },
    Swipe { udid: String, gesture: DeviceSwipeGesture },
    Touch { udid: String, phase: DeviceTouchPhase, x: f64, y: f64 },
    TypeText { udid: String, text: String },
    SetFocusedValue { udid: String, value: String },
    Configure { udid: String, configuration: DeviceConfiguration },
    ReadLogs(String),
    KeyEvent { udid: String, event: DeviceKeyEvent },
    PressButton { udid: String, button: DeviceHardwareButton },
    Screenshot(String),
    StartRecording(String),
    StopRecording(String),
    DescribeUi(String),
    AttachStream(String),
    DetachStream(String),
}

impl FakeCall {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Boot(_) => "boot",
            Self::Shutdown(_) => "shutdown",
            Self::Install { .. } => "install",
            Self::Launch { .. } => "launch",
            Self::OpenUrl { .. } => "openUrl",
            Self::Tap { .. } => "tap",
            Self::Swipe { .. } => "swipe",
            Self::Touch { .. } => "touch",
            Self::TypeText { .. } => "typeText",
            Self::SetFocusedValue { .. } => "setFocusedValue",
            Self::Configure { .. } => "configure",
            Self::ReadLogs(_) => "readLogs",
            Self::KeyEvent { .. } => "keyEvent",
            Self::PressButton { .. } => "pressButton",
            Self::Screenshot(_) => "screenshot",
            Self::StartRecording(_) => "startRecording",
            Self::StopRecording(_) => "stopRecording",
            Self::DescribeUi(_) => "describeUi",
            Self::AttachStream(_) => "attachStream",
            Self::DetachStream(_) => "detachStream",
        }
    }

    pub fn udid(&self) -> &str {
        match self {
            Self::Boot(udid)
            | Self::Shutdown(udid)
            | Self::ReadLogs(udid)
            | Self::Screenshot(udid)
            | Self::StartRecording(udid)
            | Self::StopRecording(udid)
            | Self::DescribeUi(udid)
            | Self::AttachStream(udid)
            | Self::DetachStream(udid) => udid,
            Self::Install { udid, .. }
            | Self::Launch { udid, .. }
            | Self::OpenUrl { udid, .. }
            | Self::Tap { udid, .. }
            | Self::Swipe { udid, .. }
            | Self::Touch { udid, .. }
            | Self::TypeText { udid, .. }
            | Self::SetFocusedValue { udid, .. }
            | Self::Configure { udid, .. }
            | Self::KeyEvent { udid, .. }
            | Self::PressButton { udid, .. } => udid,
        }
    }
}

pub type TreeTransform = Arc<dyn Fn(DeviceDescribeUiResult) -> DeviceDescribeUiResult + Send + Sync>;

struct Fake {
    availability: DeviceAvailability,
    /// In seed order.
    devices: Vec<DeviceDescriptor>,
    calls: Vec<FakeCall>,
    failures: HashMap<&'static str, DeviceBackendError>,
    scroll_offset: f64,
    streams: HashSet<String>,
    next_stream_failure: Option<String>,
    persistent_stream_failure: Option<String>,
    sequences: HashMap<String, u32>,
    attached_geometry: HashSet<String>,
    animating_reads: u32,
    field_value: String,
    us_keyboard_layout: bool,
    recordings: HashMap<String, (String, String)>,
    disposed: bool,
    fail_listing: bool,
    availability_calls: usize,
    list_calls: usize,
    transform: Option<TreeTransform>,
    attach_holds: HashMap<String, (Arc<Notify>, Arc<Notify>)>,
    boot_holds: HashMap<String, (Arc<Notify>, Arc<Notify>)>,
    shutdown_holds: HashMap<String, (Arc<Notify>, Arc<Notify>)>,
    detach_holds: HashMap<String, (Arc<Notify>, Arc<Notify>)>,
}

pub struct FakeDeviceBackend {
    state: Mutex<Fake>,
    frames: broadcast::Sender<DeviceFrameRecord>,
    interruptions: broadcast::Sender<DeviceStreamInterruption>,
}

pub struct Seed<'a> {
    pub udid: &'a str,
    pub name: &'a str,
    pub runtime: &'a str,
}

const DEFAULT_SEEDS: [Seed<'static>; 4] = [
    Seed { udid: DEVICE_A, name: "iPhone 17 Pro", runtime: "iOS 26.0" },
    Seed { udid: DEVICE_B, name: "iPhone 17", runtime: "iOS 26.0" },
    Seed { udid: DEVICE_C, name: "iPad Pro 13-inch", runtime: "iOS 26.0" },
    Seed { udid: DEVICE_D, name: "iPhone Air", runtime: "iOS 26.0" },
];

fn now_iso() -> String {
    crate::device::iso_from_millis(crate::device::now_millis())
}

impl FakeDeviceBackend {
    pub fn new() -> Arc<Self> {
        Self::with_devices(&DEFAULT_SEEDS, DeviceAvailability::available())
    }

    pub fn with_availability(availability: DeviceAvailability) -> Arc<Self> {
        Self::with_devices(&DEFAULT_SEEDS, availability)
    }

    pub fn with_devices(seeds: &[Seed<'_>], availability: DeviceAvailability) -> Arc<Self> {
        let devices = seeds
            .iter()
            .map(|seed| DeviceDescriptor {
                platform: DevicePlatform::IosSimulator,
                udid: seed.udid.to_owned(),
                name: seed.name.to_owned(),
                runtime: seed.runtime.to_owned(),
                state: DeviceRuntimeState::Shutdown,
                boot_source: DeviceBootSource::User,
                family: None,
                geometry: None,
            })
            .collect();
        let (frames, _) = broadcast::channel(256);
        let (interruptions, _) = broadcast::channel(16);
        Arc::new(Self {
            state: Mutex::new(Fake {
                availability,
                devices,
                calls: Vec::new(),
                failures: HashMap::new(),
                scroll_offset: 0.0,
                streams: HashSet::new(),
                next_stream_failure: None,
                persistent_stream_failure: None,
                sequences: HashMap::new(),
                attached_geometry: HashSet::new(),
                animating_reads: 0,
                field_value: String::new(),
                us_keyboard_layout: true,
                recordings: HashMap::new(),
                disposed: false,
                fail_listing: false,
                availability_calls: 0,
                list_calls: 0,
                transform: None,
                attach_holds: HashMap::new(),
                boot_holds: HashMap::new(),
                shutdown_holds: HashMap::new(),
                detach_holds: HashMap::new(),
            }),
            frames,
            interruptions,
        })
    }

    // ── Test controls ──────────────────────────────────────────────────

    pub fn calls(&self) -> Vec<FakeCall> {
        self.state.lock().unwrap().calls.clone()
    }

    pub fn calls_of(&self, kind: &str) -> Vec<FakeCall> {
        self.calls().into_iter().filter(|call| call.kind() == kind).collect()
    }

    pub fn udids_of(&self, kind: &str) -> Vec<String> {
        self.calls_of(kind).iter().map(|call| call.udid().to_owned()).collect()
    }

    pub fn count(&self, kind: &str) -> usize {
        self.calls_of(kind).len()
    }

    pub fn last_call(&self) -> Option<FakeCall> {
        self.state.lock().unwrap().calls.last().cloned()
    }

    pub fn fail_next(&self, kind: &'static str, error: DeviceBackendError) {
        self.state.lock().unwrap().failures.insert(kind, error);
    }

    pub fn fail_next_stream(&self, message: &str) {
        self.state.lock().unwrap().next_stream_failure = Some(message.to_owned());
    }

    pub fn fail_every_stream(&self, message: &str) {
        self.state.lock().unwrap().persistent_stream_failure = Some(message.to_owned());
    }

    pub fn clear_stream_failures(&self) {
        let mut state = self.state.lock().unwrap();
        state.next_stream_failure = None;
        state.persistent_stream_failure = None;
    }

    pub fn set_fail_listing(&self, fail: bool) {
        self.state.lock().unwrap().fail_listing = fail;
    }

    pub fn set_us_keyboard_layout(&self, us: bool) {
        self.state.lock().unwrap().us_keyboard_layout = us;
    }

    /// Make the next `reads` describes return a different tree each time.
    pub fn animate_for(&self, reads: u32) {
        self.state.lock().unwrap().animating_reads = reads;
    }

    /// Rewrites every tree `describe_ui` returns, as Synara's tests replace the method.
    pub fn transform_tree(&self, transform: impl Fn(DeviceDescribeUiResult) -> DeviceDescribeUiResult + Send + Sync + 'static) {
        self.state.lock().unwrap().transform = Some(Arc::new(transform));
    }

    pub fn discovery_calls(&self) -> (usize, usize) {
        let state = self.state.lock().unwrap();
        (state.availability_calls, state.list_calls)
    }

    pub fn disposed(&self) -> bool {
        self.state.lock().unwrap().disposed
    }

    /// Mark a device booted without going through Cascade, as Simulator.app would.
    pub fn boot_externally(&self, udid: &str) {
        let mut state = self.state.lock().unwrap();
        let device = state.devices.iter_mut().find(|device| device.udid == udid).expect("a seeded device");
        device.state = DeviceRuntimeState::Booted;
        device.boot_source = DeviceBootSource::User;
    }

    /// Stop a device behind Cascade's back, as `simctl shutdown` from a shell would.
    pub fn shutdown_externally(&self, udid: &str) {
        let mut state = self.state.lock().unwrap();
        let device = state.devices.iter_mut().find(|device| device.udid == udid).expect("a seeded device");
        device.state = DeviceRuntimeState::Shutdown;
        state.streams.remove(udid);
    }

    pub fn has_stream(&self, udid: &str) -> bool {
        self.state.lock().unwrap().streams.contains(udid)
    }

    /// Pushes one frame to the stream, if it runs.
    pub fn emit_frame(&self, udid: &str, keyframe: bool, codec_config: bool) -> Option<DeviceStreamFrame> {
        let frame = {
            let mut state = self.state.lock().unwrap();
            if !state.streams.contains(udid) {
                return None;
            }
            let sequence = state.sequences.get(udid).copied().unwrap_or(0) + 1;
            state.sequences.insert(udid.to_owned(), sequence);
            DeviceStreamFrame {
                sequence,
                timestamp_ms: 1_000.0,
                keyframe,
                codec_config,
                data: Arc::from(vec![(sequence & 0xff) as u8]),
            }
        };
        let _ = self.frames.send(DeviceFrameRecord { udid: Arc::from(udid), frame: frame.clone() });
        Some(frame)
    }

    /// End a stream as a helper crash does: no detach, frames just stop.
    pub fn interrupt_stream(&self, udid: &str, reason: &str) {
        self.state.lock().unwrap().streams.remove(udid);
        let _ = self.interruptions.send(DeviceStreamInterruption { udid: udid.to_owned(), reason: reason.to_owned() });
    }

    /// Holds the next `attach_stream` of `udid`: the first notify says it started, the second
    /// lets it go on.
    pub fn hold_attach(&self, udid: &str) -> (Arc<Notify>, Arc<Notify>) {
        let started = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        self.state.lock().unwrap().attach_holds.insert(udid.to_owned(), (started.clone(), release.clone()));
        (started, release)
    }

    /// Holds the next `boot` of `udid` until the notify.
    pub fn hold_boot(&self, udid: &str) -> Arc<Notify> {
        self.hold_boot_reporting(udid).1
    }

    /// Holds the next `boot` of `udid`: the first notify says it started, the second lets it go
    /// on. The call is recorded once it goes on.
    pub fn hold_boot_reporting(&self, udid: &str) -> (Arc<Notify>, Arc<Notify>) {
        let hold = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        self.state.lock().unwrap().boot_holds.insert(udid.to_owned(), hold.clone());
        hold
    }

    /// Holds the next `shutdown` of `udid`, as `hold_boot_reporting` holds a boot.
    pub fn hold_shutdown(&self, udid: &str) -> (Arc<Notify>, Arc<Notify>) {
        let hold = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        self.state.lock().unwrap().shutdown_holds.insert(udid.to_owned(), hold.clone());
        hold
    }

    /// Holds the next `detach_stream` of `udid`: the stream teardown that yields.
    pub fn hold_detach(&self, udid: &str) -> (Arc<Notify>, Arc<Notify>) {
        let hold = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        self.state.lock().unwrap().detach_holds.insert(udid.to_owned(), hold.clone());
        hold
    }

    // ── Internals ──────────────────────────────────────────────────────

    fn record(&self, call: FakeCall) -> DeviceResult<()> {
        let mut state = self.state.lock().unwrap();
        if let Some(failure) = state.failures.remove(call.kind()) {
            return Err(failure);
        }
        state.calls.push(call);
        Ok(())
    }

    fn require_device(&self, udid: &str) -> DeviceResult<DeviceDescriptor> {
        self.state
            .lock()
            .unwrap()
            .devices
            .iter()
            .find(|device| device.udid == udid)
            .cloned()
            .ok_or_else(|| DeviceBackendError::new(format!("Unknown device {udid}")))
    }

    fn require_booted(&self, udid: &str) -> DeviceResult<DeviceDescriptor> {
        let device = self.require_device(udid)?;
        if device.state != DeviceRuntimeState::Booted {
            return Err(DeviceBackendError::retryable(format!("Device {udid} is not booted")));
        }
        Ok(device)
    }

    fn set_state(&self, udid: &str, runtime: DeviceRuntimeState) -> DeviceDescriptor {
        let mut state = self.state.lock().unwrap();
        let device = state.devices.iter_mut().find(|device| device.udid == udid).expect("a known device");
        device.state = runtime;
        if runtime == DeviceRuntimeState::Shutdown {
            device.boot_source = DeviceBootSource::User;
        }
        device.clone()
    }

    fn tree(&self, udid: &str) -> DeviceDescribeUiResult {
        let mut state = self.state.lock().unwrap();
        let animation_frame = state.animating_reads;
        state.animating_reads = state.animating_reads.saturating_sub(1);
        let deep_row_y = FAKE_DEEP_ROW_START_Y - state.scroll_offset;
        let field = if state.field_value.is_empty() { "you@example.com".to_owned() } else { state.field_value.clone() };
        let transform = state.transform.clone();
        drop(state);
        let mut children = vec![
            DeviceUiNode {
                identifier: Some("continue-button".into()),
                enabled: Some(true),
                activation_point: Some(point(196.0, 725.0)),
                ..node("Button", Some("Continue"), frame(24.0, 700.0, 345.0, 50.0))
            },
            DeviceUiNode {
                value: Some(field),
                identifier: Some("email-field".into()),
                enabled: Some(true),
                focused: Some(true),
                placeholder: Some("you@example.com".into()),
                ..node("TextField", Some("Email"), frame(24.0, 300.0, 345.0, 44.0))
            },
        ];
        if animation_frame > 0 {
            children.push(node("StaticText", Some(&format!("Loading {animation_frame}")), frame(24.0, 400.0, 345.0, 20.0)));
        }
        // A switch row: its frame centre is dead space, so only the activation point toggles it.
        children.push(DeviceUiNode {
            subrole: Some("Switch".into()),
            value: Some("0".into()),
            activation_point: Some(point(340.0, 222.0)),
            ..node("CheckBox", Some("Fake Toggle"), frame(24.0, 200.0, 345.0, 44.0))
        });
        // Virtualized: absent until scrolling brings it near.
        if deep_row_y <= FAKE_VIRTUALIZATION_HORIZON {
            children.push(DeviceUiNode {
                activation_point: Some(point(196.0, deep_row_y + 22.0)),
                ..node("Button", Some("Deep Row"), frame(24.0, deep_row_y, 345.0, 44.0))
            });
        }
        let tree = DeviceDescribeUiResult {
            udid: udid.to_owned(),
            captured_at: now_iso(),
            root: DeviceUiNode { children, ..node("Application", Some("Fake App"), frame(0.0, 0.0, 393.0, 852.0)) },
        };
        match transform {
            Some(transform) => transform(tree),
            None => tree,
        }
    }
}

pub fn frame(x: f64, y: f64, width: f64, height: f64) -> DeviceUiFrame {
    DeviceUiFrame { x, y, width, height }
}

pub fn point(x: f64, y: f64) -> DeviceUiPoint {
    DeviceUiPoint { x, y }
}

pub fn node(role: &str, label: Option<&str>, frame: DeviceUiFrame) -> DeviceUiNode {
    DeviceUiNode {
        role: role.into(),
        subrole: None,
        label: label.map(str::to_owned),
        value: None,
        frame,
        activation_point: None,
        identifier: None,
        enabled: None,
        focused: None,
        selected: None,
        placeholder: None,
        unframed: None,
        children: Vec::new(),
    }
}

impl DeviceBackend for FakeDeviceBackend {
    fn platform(&self) -> DevicePlatform {
        DevicePlatform::IosSimulator
    }

    fn availability(&self) -> BoxFuture<'_, DeviceAvailability> {
        Box::pin(async move {
            let mut state = self.state.lock().unwrap();
            state.availability_calls += 1;
            state.availability.clone()
        })
    }

    fn list_devices(&self, options: DeviceListOptions) -> BoxFuture<'_, DeviceResult<Vec<DeviceDescriptor>>> {
        Box::pin(async move {
            let mut state = self.state.lock().unwrap();
            state.list_calls += 1;
            if state.fail_listing {
                return Err(DeviceBackendError::new("simctl list failed"));
            }
            Ok(state
                .devices
                .iter()
                .filter(|device| options.include_shutdown || device.state != DeviceRuntimeState::Shutdown)
                .cloned()
                .collect())
        })
    }

    fn boot<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceDescriptor>> {
        Box::pin(async move {
            let hold = self.state.lock().unwrap().boot_holds.remove(udid);
            if let Some((started, release)) = hold {
                started.notify_one();
                release.notified().await;
            }
            self.record(FakeCall::Boot(udid.to_owned()))?;
            self.require_device(udid)?;
            Ok(self.set_state(udid, DeviceRuntimeState::Booted))
        })
    }

    fn shutdown<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            let hold = self.state.lock().unwrap().shutdown_holds.remove(udid);
            if let Some((started, release)) = hold {
                started.notify_one();
                release.notified().await;
            }
            self.record(FakeCall::Shutdown(udid.to_owned()))?;
            self.require_device(udid)?;
            self.set_state(udid, DeviceRuntimeState::Shutdown);
            self.detach_stream(udid).await;
            Ok(())
        })
    }

    fn install<'a>(&'a self, udid: &'a str, app_path: &'a str) -> BoxFuture<'a, DeviceResult<DeviceInstallAppResult>> {
        Box::pin(async move {
            self.record(FakeCall::Install { udid: udid.to_owned(), app_path: app_path.to_owned() })?;
            self.require_booted(udid)?;
            let name = app_path.rsplit('/').next().unwrap_or("").trim_end_matches(".app");
            let name = if name.is_empty() { "app" } else { name };
            Ok(DeviceInstallAppResult { udid: udid.to_owned(), bundle_id: format!("com.example.{name}") })
        })
    }

    fn launch<'a>(
        &'a self,
        udid: &'a str,
        bundle_id: &'a str,
        _arguments: &'a [String],
        options: &'a DeviceLaunchOptions,
    ) -> BoxFuture<'a, DeviceResult<DeviceLaunchAppResult>> {
        Box::pin(async move {
            self.record(FakeCall::Launch { udid: udid.to_owned(), bundle_id: bundle_id.to_owned(), options: options.clone() })?;
            self.require_booted(udid)?;
            Ok(DeviceLaunchAppResult { udid: udid.to_owned(), bundle_id: bundle_id.to_owned(), pid: Some(4_242) })
        })
    }

    fn open_url<'a>(&'a self, udid: &'a str, url: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::OpenUrl { udid: udid.to_owned(), url: url.to_owned() })?;
            self.require_booted(udid).map(|_| ())
        })
    }

    fn tap<'a>(&'a self, udid: &'a str, x: f64, y: f64, hold_ms: Option<u32>) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::Tap { udid: udid.to_owned(), x, y, hold_ms })?;
            self.require_booted(udid).map(|_| ())
        })
    }

    fn touch<'a>(&'a self, udid: &'a str, phase: DeviceTouchPhase, x: f64, y: f64) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::Touch { udid: udid.to_owned(), phase, x, y })?;
            self.require_booted(udid).map(|_| ())
        })
    }

    fn swipe<'a>(&'a self, udid: &'a str, gesture: DeviceSwipeGesture) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::Swipe { udid: udid.to_owned(), gesture })?;
            self.require_booted(udid)?;
            // Content follows the finger, clamped at the list's end.
            let delta = gesture.to_y - gesture.from_y;
            let mut state = self.state.lock().unwrap();
            state.scroll_offset = (state.scroll_offset - delta).clamp(0.0, FAKE_MAX_SCROLL_OFFSET);
            Ok(())
        })
    }

    fn type_text<'a>(&'a self, udid: &'a str, text: &'a str) -> BoxFuture<'a, DeviceResult<DeviceTypeTextOutcome>> {
        Box::pin(async move {
            self.record(FakeCall::TypeText { udid: udid.to_owned(), text: text.to_owned() })?;
            self.require_booted(udid)?;
            let typed: String = text.chars().filter(|c| matches!(c, '\x20'..='\x7e' | '\n' | '\t')).collect();
            let skipped = (text.chars().count() - typed.chars().count()) as u64;
            self.state.lock().unwrap().field_value.push_str(&typed.replace('\n', ""));
            Ok(DeviceTypeTextOutcome { skipped })
        })
    }

    fn set_focused_value<'a>(&'a self, udid: &'a str, value: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::SetFocusedValue { udid: udid.to_owned(), value: value.to_owned() })?;
            self.require_booted(udid)?;
            self.state.lock().unwrap().field_value = value.to_owned();
            Ok(())
        })
    }

    fn uses_us_keyboard_layout<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, bool> {
        Box::pin(async move { self.require_booted(udid).is_ok() && self.state.lock().unwrap().us_keyboard_layout })
    }

    fn key_event<'a>(&'a self, udid: &'a str, event: &'a DeviceKeyEvent) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::KeyEvent { udid: udid.to_owned(), event: event.clone() })?;
            self.require_booted(udid).map(|_| ())
        })
    }

    fn press_button<'a>(&'a self, udid: &'a str, button: DeviceHardwareButton) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::PressButton { udid: udid.to_owned(), button })?;
            self.require_booted(udid).map(|_| ())
        })
    }

    fn screenshot<'a>(&'a self, udid: &'a str, options: DeviceScreenshotOptions) -> BoxFuture<'a, DeviceResult<DeviceScreenshotCapture>> {
        Box::pin(async move {
            self.record(FakeCall::Screenshot(udid.to_owned()))?;
            let device = self.require_booted(udid)?;
            Ok(DeviceScreenshotCapture {
                result: DeviceScreenshotResult {
                    udid: udid.to_owned(),
                    name: format!("{}.png", device.name),
                    mime_type: "image/png".into(),
                    width: 1,
                    height: 1,
                    size_bytes: 70,
                    bytes_base64: PNG_BASE64.into(),
                    captured_at: now_iso(),
                    path: options.save.then(|| std::env::temp_dir().join(format!("simulator-{udid}.png")).to_string_lossy().into_owned()),
                },
                proof_bytes_base64: options.proof.then(|| PNG_BASE64.to_owned()),
            })
        })
    }

    fn start_recording<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceStartRecordingResult>> {
        Box::pin(async move {
            self.record(FakeCall::StartRecording(udid.to_owned()))?;
            self.require_booted(udid)?;
            let mut state = self.state.lock().unwrap();
            if state.recordings.contains_key(udid) {
                return Err(DeviceBackendError::new(format!("Device {udid} is already recording")));
            }
            let started_at = now_iso();
            let path = std::env::temp_dir().join(format!("simulator-{udid}.mp4")).to_string_lossy().into_owned();
            state.recordings.insert(udid.to_owned(), (path.clone(), started_at.clone()));
            Ok(DeviceStartRecordingResult { udid: udid.to_owned(), path, started_at })
        })
    }

    fn stop_recording<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceStopRecordingResult>> {
        Box::pin(async move {
            self.record(FakeCall::StopRecording(udid.to_owned()))?;
            let (path, _) = self
                .state
                .lock()
                .unwrap()
                .recordings
                .remove(udid)
                .ok_or_else(|| DeviceBackendError::new(format!("Device {udid} is not recording")))?;
            Ok(DeviceStopRecordingResult { udid: udid.to_owned(), path, size_bytes: 1_024, duration_ms: 0, stopped_at: now_iso() })
        })
    }

    fn describe_ui<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceDescribeUiResult>> {
        Box::pin(async move {
            self.record(FakeCall::DescribeUi(udid.to_owned()))?;
            self.require_booted(udid)?;
            Ok(self.tree(udid))
        })
    }

    fn configure<'a>(&'a self, udid: &'a str, configuration: &'a DeviceConfiguration) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            self.record(FakeCall::Configure { udid: udid.to_owned(), configuration: configuration.clone() })?;
            self.require_booted(udid).map(|_| ())
        })
    }

    fn read_logs<'a>(&'a self, udid: &'a str, query: &'a DeviceLogQuery) -> BoxFuture<'a, DeviceResult<DeviceLogResult>> {
        Box::pin(async move {
            self.record(FakeCall::ReadLogs(udid.to_owned()))?;
            self.require_booted(udid)?;
            Ok(DeviceLogResult {
                bundle_id: query.bundle_id.clone(),
                process: Some("FakeApp".into()),
                log: vec!["2026-10-14 01:00:00.000 E  FakeApp[1:1] request failed".into()],
                console: vec!["hello from print".into()],
                console_unavailable_reason: None,
                crashes: Vec::new(),
                omitted: 0,
            })
        })
    }

    fn geometry(&self, udid: &str) -> Option<DeviceGeometry> {
        // Geometry only exists once something attached, as on the real backend.
        self.state.lock().unwrap().attached_geometry.contains(udid).then_some(FAKE_GEOMETRY)
    }

    fn attach_stream<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<()>> {
        Box::pin(async move {
            let hold = self.state.lock().unwrap().attach_holds.remove(udid);
            if let Some((started, release)) = hold {
                started.notify_one();
                release.notified().await;
            }
            self.record(FakeCall::AttachStream(udid.to_owned()))?;
            let failure = {
                let mut state = self.state.lock().unwrap();
                state.persistent_stream_failure.clone().or_else(|| state.next_stream_failure.take())
            };
            if let Some(failure) = failure {
                return Err(DeviceBackendError::new(failure));
            }
            self.require_booted(udid)?;
            let mut state = self.state.lock().unwrap();
            state.attached_geometry.insert(udid.to_owned());
            state.streams.insert(udid.to_owned());
            Ok(())
        })
    }

    fn detach_stream<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, ()> {
        Box::pin(async move {
            let hold = self.state.lock().unwrap().detach_holds.remove(udid);
            if let Some((started, release)) = hold {
                started.notify_one();
                release.notified().await;
            }
            let mut state = self.state.lock().unwrap();
            if state.streams.remove(udid) {
                state.calls.push(FakeCall::DetachStream(udid.to_owned()));
            }
        })
    }

    fn subscribe_frames(&self) -> broadcast::Receiver<DeviceFrameRecord> {
        self.frames.subscribe()
    }

    fn subscribe_interruptions(&self) -> broadcast::Receiver<DeviceStreamInterruption> {
        self.interruptions.subscribe()
    }

    fn dispose(&self) -> BoxFuture<'_, ()> {
        Box::pin(async move {
            let recording: Vec<String> = self.state.lock().unwrap().recordings.keys().cloned().collect();
            for udid in recording {
                let _ = self.stop_recording(&udid).await;
            }
            let mut state = self.state.lock().unwrap();
            state.disposed = true;
            state.streams.clear();
        })
    }
}
