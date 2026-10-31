//! The device contract: the data the device layer hands its callers (the manager, the pane, the
//! agent tools), shaped as Synara's schema shapes it so the JSON reads the same.
//!
//! Port of Synara's `packages/contracts/src/device.ts` (types only: its schema checks become the
//! callers' validation, and its WebSocket method names have no counterpart here).

use serde::{Deserialize, Serialize};

/// Longest message a device error or setup hint may carry; see `backend::fit_device_message`.
pub const DEVICE_MESSAGE_MAX_LENGTH: usize = 2_048;
/// Devices Cascade itself booted are capped globally; viewing already-booted devices is not.
pub const DEVICE_BOOT_LIMIT: usize = 3;
/// Most devices one thread state can list; a machine can have more simulators than this.
pub const DEVICE_THREAD_STATE_MAX_DEVICES: usize = 64;
pub const DEVICE_SWIPE_DURATION_MIN_MS: u32 = 0;
pub const DEVICE_SWIPE_DURATION_MAX_MS: u32 = 10_000;
pub const DEVICE_SCROLL_MIN_SWIPES: u32 = 1;
pub const DEVICE_SCROLL_MAX_SWIPES: u32 = 32;
/// Device points, not pixels: the ceiling clears any current iPad in points while still rejecting
/// nonsense coordinates from a mis-scaled canvas.
pub const DEVICE_COORDINATE_MAX: f64 = 20_000.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DevicePlatform {
    #[serde(rename = "ios-simulator")]
    IosSimulator,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceRuntimeState {
    Shutdown,
    Booting,
    Booted,
    ShuttingDown,
}

/// Who owns the boot. Cascade only auto-shuts down devices it booted itself; anything the user
/// started (pane picker, Simulator.app) outlives the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceBootSource {
    Cascade,
    User,
}

/// Which chassis a device is drawn in, from the simulator device type's product family.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceFamily {
    Phone,
    Tablet,
}

/// Screen size in device points, and the pixel-per-point scale. Input is in points while video
/// frames are pixels; these are what let a caller convert.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceGeometry {
    pub point_width: f64,
    pub point_height: f64,
    pub scale: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceDescriptor {
    pub platform: DevicePlatform,
    pub udid: String,
    pub name: String,
    /// Human-readable runtime label, e.g. `iOS 18.2`.
    pub runtime: String,
    pub state: DeviceRuntimeState,
    pub boot_source: DeviceBootSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<DeviceFamily>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub geometry: Option<DeviceGeometry>,
}

// ── Availability / setup gating ──────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceSetupStepId {
    InstallXcode,
    AcceptXcodeLicense,
    SelectXcodeCommandLineTools,
    InstallIosRuntime,
    BuildDeviceHelper,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSetupStep {
    pub id: DeviceSetupStepId,
    pub label: String,
    pub done: bool,
    /// Optional one-line hint, e.g. the command that completes the step.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// The helper capabilities that can fail independently, each backed by one group of private
/// symbols the helper resolves at runtime (`Sources/SymbolManifest.swift`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceCapabilityId {
    /// Reading the device framebuffer — the live video stream.
    Framebuffer,
    /// Injecting touches, keys and hardware buttons.
    Hid,
    /// Reading the accessibility tree.
    Accessibility,
    /// Hardware H.264 encoding of captured frames.
    Encoder,
}

impl DeviceCapabilityId {
    /// Every capability, in the order the pane lists them.
    pub const ALL: [DeviceCapabilityId; 4] = [Self::Framebuffer, Self::Hid, Self::Accessibility, Self::Encoder];

    /// `DEVICE_CAPABILITY_LABELS`.
    pub fn label(self) -> &'static str {
        match self {
            Self::Framebuffer => "Screen capture",
            Self::Hid => "Touch and keyboard input",
            Self::Accessibility => "Accessibility inspection",
            Self::Encoder => "Video encoding",
        }
    }

    /// The key the helper's probe reports it under.
    pub fn key(self) -> &'static str {
        match self {
            Self::Framebuffer => "framebuffer",
            Self::Hid => "hid",
            Self::Accessibility => "accessibility",
            Self::Encoder => "encoder",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCapabilityStatus {
    pub id: DeviceCapabilityId,
    pub ok: bool,
    /// The private symbol that could not be resolved, when that is the cause.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub missing_symbol: Option<String>,
    /// A failure that is not a missing symbol (framework load, encoder refusal).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl DeviceCapabilityStatus {
    pub fn ok(id: DeviceCapabilityId) -> Self {
        Self { id, ok: true, missing_symbol: None, detail: None }
    }
}

/// The toolchain a capability report was measured against.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceToolchain {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xcode_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xcode_build: Option<String>,
    #[serde(default, rename = "macOS", skip_serializing_if = "Option::is_none")]
    pub mac_os: Option<String>,
}

/// Why (or whether) the pane can run: the UI renders one of these instead of guessing from errors.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum DeviceAvailability {
    /// `capabilities` is absent when the helper reported no per-capability detail, which means
    /// "no detail", not "nothing works".
    #[serde(rename_all = "camelCase")]
    Available {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        capabilities: Option<Vec<DeviceCapabilityStatus>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        toolchain: Option<DeviceToolchain>,
    },
    UnsupportedPlatform { platform: String },
    SetupRequired { steps: Vec<DeviceSetupStep> },
    /// Setup is complete and the helper runs, but at least one capability failed its preflight —
    /// typically a private symbol Apple moved in a new Xcode. Nothing is left to install.
    Degraded {
        capabilities: Vec<DeviceCapabilityStatus>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        toolchain: Option<DeviceToolchain>,
    },
    /// The helper is compiled on demand against the user's Xcode; a compile or launch failure is
    /// a designed state, not a generic error.
    HelperUnavailable { message: String },
}

impl DeviceAvailability {
    /// `{ kind: "available" }` with no capability detail.
    pub fn available() -> Self {
        Self::Available { capabilities: None, toolchain: None }
    }
}

/// How far along a thread's attachment is; named for what the user is waiting on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceAttachPhase {
    /// The simulator is starting up.
    Booting,
    /// Booted, but it has not published a screen to capture yet.
    WaitingForDisplay,
    /// The display exists; the video stream is being opened.
    Connecting,
}

// ── Input ────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceKeyModifier {
    Command,
    Shift,
    Option,
    Control,
    Function,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceHardwareButton {
    Home,
    Lock,
    VolumeUp,
    VolumeDown,
    Rotate,
}

impl DeviceHardwareButton {
    /// The name the helper's `button` method takes.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Home => "home",
            Self::Lock => "lock",
            Self::VolumeUp => "volume-up",
            Self::VolumeDown => "volume-down",
            Self::Rotate => "rotate",
        }
    }
}

// ── App lifecycle ────────────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInstallAppResult {
    pub udid: String,
    pub bundle_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceLaunchAppResult {
    pub udid: String,
    pub bundle_id: String,
    pub pid: Option<u32>,
}

// ── Read tools ───────────────────────────────────────────────────────

/// A screenshot as it crosses JSON: the PNG travels base64-encoded.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceScreenshotResult {
    pub udid: String,
    pub name: String,
    pub mime_type: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: usize,
    pub bytes_base64: String,
    pub captured_at: String,
    /// Where the PNG was written, when the caller asked for it to be saved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceStartRecordingResult {
    pub udid: String,
    /// Absolute so the pane can reveal the eventual file without reconstructing server paths.
    pub path: String,
    pub started_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceStopRecordingResult {
    pub udid: String,
    pub path: String,
    pub size_bytes: u64,
    pub duration_ms: u64,
    pub stopped_at: String,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct DeviceUiFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct DeviceUiPoint {
    pub x: f64,
    pub y: f64,
}

/// One accessibility element, in device points.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceUiNode {
    pub role: String,
    /// Separates controls that share a role, e.g. `Switch` inside `CheckBox`.
    pub subrole: Option<String>,
    pub label: Option<String>,
    pub value: Option<String>,
    pub frame: DeviceUiFrame,
    /// The control's own hit point. UIKit merges a settings row and the control inside it into a
    /// single element whose frame spans the row, so tap this rather than the frame centre.
    pub activation_point: Option<DeviceUiPoint>,
    /// `accessibilityIdentifier`: the stable, locale-independent handle a test should target.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
    /// False for a disabled control; absent is treated as enabled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    /// Holds keyboard focus: where typed text lands.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focused: Option<bool>,
    /// A selected tab, segment, or row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<bool>,
    /// Placeholder text of an empty field, which iOS also reports as its value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    /// The element reported no usable frame (typical of off-screen SwiftUI content). Its `frame`
    /// is zeroed and it is never a tap target.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unframed: Option<bool>,
    pub children: Vec<DeviceUiNode>,
}

impl DeviceUiNode {
    pub fn is_focused(&self) -> bool {
        self.focused == Some(true)
    }

    pub fn is_selected(&self) -> bool {
        self.selected == Some(true)
    }

    pub fn is_unframed(&self) -> bool {
        self.unframed == Some(true)
    }

    pub fn is_disabled(&self) -> bool {
        self.enabled == Some(false)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceDescribeUiResult {
    pub udid: String,
    pub captured_at: String,
    pub root: DeviceUiNode,
}
