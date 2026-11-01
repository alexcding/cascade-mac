//! DeviceBackend - the platform abstraction behind the device pane and the agent tools.
//!
//! Port of Synara's `apps/server/src/device/DeviceBackend.ts`. One trait, one implementation per
//! device platform; the iOS simulator (`ios_simulator.rs`) is the only one today. Backends are
//! thin adapters over subprocesses and sockets, so the trait is plain futures, which keeps a fake
//! backend (and therefore every manager test) trivial to drive.
//!
//! Two deliberate differences from Synara: a stream is not handed to one `onFrame` callback but
//! broadcast (`subscribe_frames`), since the pane and the backend both read it; and an in-flight
//! `type_text` is cancelled by dropping its future rather than through an `AbortSignal`.

use std::{collections::BTreeMap, future::Future, pin::Pin, sync::Arc};

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use super::contracts::{
    DeviceAvailability, DeviceDescribeUiResult, DeviceDescriptor, DeviceGeometry, DeviceHardwareButton,
    DeviceInstallAppResult, DeviceKeyModifier, DeviceLaunchAppResult, DeviceScreenshotResult,
    DeviceStartRecordingResult, DeviceStopRecordingResult, DEVICE_MESSAGE_MAX_LENGTH,
};

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;
pub type DeviceResult<T> = Result<T, DeviceBackendError>;

/// One encoded video frame as the backend produces it. `sequence` is the helper's, per device and
/// monotonic, so a reader detects gaps without re-deriving them; `codec_config` marks parameter
/// sets a late subscriber must receive before any keyframe decodes.
#[derive(Clone, Debug, PartialEq)]
pub struct DeviceStreamFrame {
    pub sequence: u32,
    pub timestamp_ms: f64,
    pub keyframe: bool,
    pub codec_config: bool,
    /// The access unit with its envelope stripped.
    pub data: Arc<[u8]>,
}

/// A frame and the device it belongs to, as the frame broadcast carries it.
#[derive(Clone, Debug, PartialEq)]
pub struct DeviceFrameRecord {
    pub udid: Arc<str>,
    pub frame: DeviceStreamFrame,
}

/// A running stream ended without being detached (the helper process died).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceStreamInterruption {
    pub udid: String,
    pub reason: String,
}

/// Shortens a message to what the device contract accepts, keeping the start (what failed) and
/// the end (the last diagnostics and the suggested fix).
pub fn fit_device_message(message: &str) -> String {
    let chars: Vec<char> = message.chars().collect();
    if chars.len() <= DEVICE_MESSAGE_MAX_LENGTH {
        return message.to_owned();
    }
    let separator = "\n…\n";
    let keep = DEVICE_MESSAGE_MAX_LENGTH - separator.chars().count();
    let head = keep.div_ceil(2);
    let tail = keep - head;
    let mut fitted: String = chars[..head].iter().collect();
    fitted.push_str(separator);
    fitted.extend(&chars[chars.len() - tail..]);
    fitted
}

/// A device failure. `retryable` separates transient trouble (device still booting, a timeout
/// that may still be progressing) from a permanent refusal (no such device).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceBackendError {
    pub message: String,
    pub retryable: bool,
}

impl DeviceBackendError {
    pub fn new(message: impl Into<String>) -> Self {
        Self { message: message.into(), retryable: false }
    }

    pub fn retryable(message: impl Into<String>) -> Self {
        Self { message: message.into(), retryable: true }
    }
}

impl std::fmt::Display for DeviceBackendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for DeviceBackendError {}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeviceListOptions {
    pub include_shutdown: bool,
}

/// The screen edge a gesture starts on; iOS reads it as the OS edge gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceTouchEdge {
    Top,
    Left,
    Bottom,
    Right,
}

impl DeviceTouchEdge {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Top => "top",
            Self::Left => "left",
            Self::Bottom => "bottom",
            Self::Right => "right",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeviceSwipeGesture {
    pub from_x: f64,
    pub from_y: f64,
    pub to_x: f64,
    pub to_y: f64,
    pub duration_ms: u32,
    /// Set for a swipe that starts on an edge: back, notification shade, home, Control Center.
    pub edge: Option<DeviceTouchEdge>,
}

/// One step of a touch the user is making by hand, sent as it happens so the screen follows the
/// pointer. Cascade's own: Synara's pane sends a drag as one swipe on release.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceTouchPhase {
    Down,
    Move,
    Up,
}

impl DeviceTouchPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Move => "move",
            Self::Up => "up",
        }
    }
}

/// A screenshot, plus the full-resolution bytes when a proof copy was asked for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceScreenshotCapture {
    pub result: DeviceScreenshotResult,
    pub proof_bytes_base64: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DeviceScreenshotResolution {
    #[default]
    Pixels,
    /// Scaled to the screen's size in points, so an image coordinate is the point a tap takes.
    Points,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeviceScreenshotOptions {
    /// Write the PNG beside recordings and report its path.
    pub save: bool,
    pub max_inline_bytes: Option<usize>,
    pub resolution: DeviceScreenshotResolution,
    pub proof: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeviceTypeTextOutcome {
    /// Characters with no key on the keyboard, which were not typed.
    pub skipped: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeviceLaunchOptions {
    /// Kill a running copy first, so the launch starts from a cold process.
    pub terminate_existing: bool,
    /// Environment for the app process (passed as `SIMCTL_CHILD_*`).
    pub environment: BTreeMap<String, String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceAppearance {
    Light,
    Dark,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DevicePrivacyAction {
    Grant,
    Revoke,
    Reset,
}

/// One environment change; see `DeviceBackend::configure`.
#[derive(Clone, Debug, PartialEq)]
pub enum DeviceConfiguration {
    Appearance(DeviceAppearance),
    ContentSize { category: String },
    Location { latitude: f64, longitude: f64 },
    LocationClear,
    Privacy { action: DevicePrivacyAction, service: String, bundle_id: Option<String> },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceLogLevel {
    Error,
    Default,
    Info,
    Debug,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceLogQuery {
    pub bundle_id: String,
    /// How far back to read, in seconds.
    pub since_seconds: u64,
    /// Lowest unified-log level to include.
    pub level: DeviceLogLevel,
    /// Case-insensitive substring every returned line must contain.
    pub contains: Option<String>,
    /// Newest lines kept when there are more.
    pub limit: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCrashReport {
    pub path: String,
    pub captured_at: String,
    /// e.g. `EXC_BAD_ACCESS (SIGSEGV)` or `EXC_CRASH (SIGABRT)`, when parseable.
    pub exception: Option<String>,
    /// Abort/assertion text or termination reason, when the report carries one.
    pub reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceLogResult {
    pub bundle_id: String,
    pub process: Option<String>,
    /// Unified log (os_log, Logger, NSLog) for the app's process.
    pub log: Vec<String>,
    /// stdout/stderr (`print`) of the app, when captured; it never is today.
    pub console: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub console_unavailable_reason: Option<String>,
    pub crashes: Vec<DeviceCrashReport>,
    /// Lines dropped by `limit`, across both streams.
    pub omitted: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceKeyDirection {
    Down,
    Up,
}

impl DeviceKeyDirection {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Up => "up",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceKeyEvent {
    /// A USB HID usage code.
    pub key_code: u16,
    pub modifiers: Vec<DeviceKeyModifier>,
    pub direction: DeviceKeyDirection,
}

/// What every device platform offers.
pub trait DeviceBackend: Send + Sync {
    /// The platform, as `DeviceDescriptor.platform` names it.
    fn platform(&self) -> super::contracts::DevicePlatform;

    /// Whether the pane can run at all, and which setup steps remain. Cheap enough to call on
    /// every list; backends cache their own probes.
    fn availability(&self) -> BoxFuture<'_, DeviceAvailability>;

    /// Discovered devices. `boot_source` is always `User` here: the backend cannot know who asked
    /// for a boot, so the manager overrides it for devices it booted itself.
    fn list_devices(&self, options: DeviceListOptions) -> BoxFuture<'_, DeviceResult<Vec<DeviceDescriptor>>>;

    fn boot<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceDescriptor>>;
    fn shutdown<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<()>>;

    fn install<'a>(&'a self, udid: &'a str, app_path: &'a str) -> BoxFuture<'a, DeviceResult<DeviceInstallAppResult>>;
    fn launch<'a>(
        &'a self,
        udid: &'a str,
        bundle_id: &'a str,
        arguments: &'a [String],
        options: &'a DeviceLaunchOptions,
    ) -> BoxFuture<'a, DeviceResult<DeviceLaunchAppResult>>;
    fn open_url<'a>(&'a self, udid: &'a str, url: &'a str) -> BoxFuture<'a, DeviceResult<()>>;

    /// `hold_ms` above ~500 is a long press.
    fn tap<'a>(&'a self, udid: &'a str, x: f64, y: f64, hold_ms: Option<u32>) -> BoxFuture<'a, DeviceResult<()>>;
    fn swipe<'a>(&'a self, udid: &'a str, gesture: DeviceSwipeGesture) -> BoxFuture<'a, DeviceResult<()>>;
    /// One step of a live touch, in device points.
    fn touch<'a>(&'a self, udid: &'a str, phase: DeviceTouchPhase, x: f64, y: f64) -> BoxFuture<'a, DeviceResult<()>>;
    /// Keystrokes through HID. Only printable ASCII has a key, and the guest resolves keys through
    /// its own hardware keyboard layout, so a caller that needs exact text checks
    /// `uses_us_keyboard_layout` or uses `set_focused_value`.
    fn type_text<'a>(&'a self, udid: &'a str, text: &'a str) -> BoxFuture<'a, DeviceResult<DeviceTypeTextOutcome>>;
    /// Replace the focused element's value through accessibility: any Unicode, independent of
    /// keyboard layout, one change event instead of keystrokes.
    fn set_focused_value<'a>(&'a self, udid: &'a str, value: &'a str) -> BoxFuture<'a, DeviceResult<()>>;
    /// Whether HID keystrokes produce the characters their US key caps show.
    fn uses_us_keyboard_layout<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, bool>;
    fn key_event<'a>(&'a self, udid: &'a str, event: &'a DeviceKeyEvent) -> BoxFuture<'a, DeviceResult<()>>;
    fn press_button<'a>(&'a self, udid: &'a str, button: DeviceHardwareButton) -> BoxFuture<'a, DeviceResult<()>>;

    fn screenshot<'a>(
        &'a self,
        udid: &'a str,
        options: DeviceScreenshotOptions,
    ) -> BoxFuture<'a, DeviceResult<DeviceScreenshotCapture>>;
    fn start_recording<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceStartRecordingResult>>;
    fn stop_recording<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceStopRecordingResult>>;
    fn describe_ui<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<DeviceDescribeUiResult>>;

    /// Change one piece of simulator state an E2E test needs to control.
    fn configure<'a>(&'a self, udid: &'a str, configuration: &'a DeviceConfiguration) -> BoxFuture<'a, DeviceResult<()>>;
    /// Recent logs and crash reports for one app.
    fn read_logs<'a>(&'a self, udid: &'a str, query: &'a DeviceLogQuery) -> BoxFuture<'a, DeviceResult<DeviceLogResult>>;

    /// Screen geometry, when the backend knows it: none until something has attached to the
    /// device, since the values come from the native helper rather than from discovery.
    fn geometry(&self, udid: &str) -> Option<DeviceGeometry>;

    /// Begin the encoded video stream for a device. Its frames reach every `subscribe_frames`
    /// receiver; the backend streams one device at a time.
    fn attach_stream<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, DeviceResult<()>>;
    fn detach_stream<'a>(&'a self, udid: &'a str) -> BoxFuture<'a, ()>;
    /// Every frame of every stream from now on. A receiver that lags loses frames and should wait
    /// for the next keyframe.
    fn subscribe_frames(&self) -> broadcast::Receiver<DeviceFrameRecord>;
    /// Running streams that ended without being detached (the helper process died).
    fn subscribe_interruptions(&self) -> broadcast::Receiver<DeviceStreamInterruption>;

    /// Release every process, socket and timer the backend owns.
    fn dispose(&self) -> BoxFuture<'_, ()>;
}
