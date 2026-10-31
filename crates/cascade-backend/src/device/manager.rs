//! The device manager: which simulator each owner watches, which ones Cascade booted, the one
//! video stream the helper can run, and the observe-and-settle loop the agent tools act through.
//!
//! Port of Synara's `apps/server/src/device/DeviceManager.ts`, behaviour for behaviour. Two
//! differences in shape:
//!
//! - **Owner, not thread.** Synara keys a device attachment by chat thread. Cascade keys it by the
//!   owner's working folder (a session's worktree, or a standalone chat's folder), so every chat
//!   and terminal agent working in one session shares the state that session's Simulator pane
//!   shows. An owner is an opaque string to the manager.
//! - **One task owns the state** (AGENTS.md, "the sync engine is one task"): [`DeviceManager`] is a
//!   handle, and every read or change of the state is a message to that task, run as one
//!   synchronous step, as each stretch between two `await`s is in Synara. The idle-shutdown timers
//!   are the task's own deadlines. What the manager does to devices runs on the caller's task and
//!   goes through `DeviceBackend`, so the whole state machine runs against a fake backend.
//!
//! The helper's single stream is serialized by `stream_lock`, Synara's `streamTransition` chain.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Weak,
    },
    time::Duration,
};

use regex::Regex;
use serde::Serialize;
use tokio::{
    sync::{broadcast, mpsc, oneshot, watch},
    time::Instant,
};

use super::{
    backend::{
        fit_device_message, DeviceBackend, DeviceBackendError, DeviceConfiguration, DeviceKeyDirection, DeviceKeyEvent,
        DeviceLaunchOptions, DeviceListOptions, DeviceLogQuery, DeviceLogResult, DeviceResult, DeviceScreenshotCapture,
        DeviceScreenshotOptions, DeviceSwipeGesture, DeviceTypeTextOutcome,
    },
    boot_ownership::{orphaned_boot_udids, BootOwnershipStore},
    contracts::{
        DeviceAttachPhase, DeviceAvailability, DeviceBootSource, DeviceDescribeUiResult, DeviceDescriptor,
        DeviceHardwareButton, DeviceInstallAppResult, DeviceKeyModifier, DeviceLaunchAppResult, DeviceRuntimeState,
        DeviceStartRecordingResult, DeviceStopRecordingResult, DeviceUiNode, DeviceUiPoint, DEVICE_BOOT_LIMIT,
        DEVICE_THREAD_STATE_MAX_DEVICES,
    },
    transport::FrameTransport,
    ui_snapshot::{effective_value, find_focused_node, is_secure_field, ui_fingerprint},
    ui_targeting::{
        describe_target, find_target, plan_scroll_step, target_phrase, visible_labels, DeviceUiTarget, DeviceUiTargetError,
        SCROLL_SWIPE_DURATION_MS,
    },
};

/// How long an unused Cascade-booted device stays up after work or viewing ends.
pub const DEVICE_IDLE_SHUTDOWN: Duration = Duration::from_secs(10 * 60);
/// How long to keep retrying a stream attach that keeps failing transiently. A simulator reports
/// itself booted before CoreSimulator publishes its display; on a cold machine with a new runtime
/// that window has been seen past twenty seconds.
pub const DEVICE_ATTACH_DEADLINE: Duration = Duration::from_secs(60);
/// Gap between attach retries.
pub const DEVICE_ATTACH_RETRY: Duration = Duration::from_millis(750);
/// Enough to cross a long Settings list; short enough to fail fast on a typo.
pub const DEVICE_DEFAULT_MAX_SCROLLS: u32 = 8;
/// Upper bound for an explicit wait, so a typo cannot hang a turn.
pub const DEVICE_WAIT_MAX: Duration = Duration::from_millis(30_000);

/// Synara `DEVICE_SETTLE_DEFAULTS`: the screen counts as settled once its accessibility
/// fingerprint holds for `quiet`, and the wait gives up at `timeout`.
pub const SETTLE_QUIET: Duration = Duration::from_millis(300);
pub const SETTLE_TIMEOUT: Duration = Duration::from_millis(2_500);
const SETTLE_POLL: Duration = Duration::from_millis(100);
const SETTLE_START_DELAY: Duration = Duration::from_millis(120);
/// How long an action's effect may take to start before an unchanged screen counts as unchanged.
const SETTLE_CHANGE_GRACE: Duration = Duration::from_millis(1_000);
/// How long a launch may take to bring its app to the front.
const APP_CHANGE_TIMEOUT: Duration = Duration::from_millis(10_000);
const WAIT_POLL: Duration = Duration::from_millis(200);

/// USB HID keyboard usages used for editing chords.
const HID_A: u16 = 0x04;
const HID_RETURN: u16 = 0x28;
const HID_DELETE: u16 = 0x2a;

/// What to tell the user when the display never appeared: the one action that fixes it.
pub const DISPLAY_TIMEOUT_MESSAGE: &str = "The simulator booted but never published a screen to capture. Shut it down and \
     start it again; if that keeps happening, the runtime may need reinstalling from Xcode's Platforms settings.";

/// Failures worth waiting out rather than latching: the display is not published yet, the device
/// is mid-boot, or the helper's descriptor belongs to a boot being replaced.
pub fn is_transient_attach_failure(error: &DeviceBackendError) -> bool {
    error.retryable || transient_pattern().is_match(&error.message)
}

fn transient_pattern() -> &'static Regex {
    static PATTERN: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r"(?i)framebuffer surface|display has no|is not booted|not attached|no display").expect("valid pattern")
    })
}

fn not_booted_pattern() -> &'static Regex {
    static PATTERN: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r"(?i)is not booted").expect("valid pattern"))
}

fn chrome_pattern() -> &'static Regex {
    static PATTERN: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r"(?i)^(?:AX)?(?:NavigationBar|TabBar)$").expect("valid pattern"))
}

// ── Contract shapes ────────────────────────────────────────────────────

/// Why the pane is asked to open (Synara `DeviceOpenPaneReason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum OpenPaneReason {
    AgentInstall,
    AgentLaunch,
    AgentTool,
}

/// What an owner's Simulator pane shows (Synara `ThreadDeviceState`, keyed by owner).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerDeviceState {
    pub owner: String,
    /// Monotonic per owner; lets the pane drop out-of-order pushes.
    pub version: u64,
    pub attached_device_udid: Option<String>,
    /// Set while the attachment is still coming up, null once it streams or has failed.
    pub attach_phase: Option<DeviceAttachPhase>,
    pub devices: Vec<DeviceDescriptor>,
    /// True while an agent tool is driving the device, for the pane's badge.
    pub agent_active: bool,
    pub availability: DeviceAvailability,
    pub last_error: Option<String>,
}

/// Synara `DeviceListResult`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DeviceListResult {
    pub devices: Vec<DeviceDescriptor>,
    pub availability: DeviceAvailability,
}

/// Synara `DeviceBootResult`: past the cap the caller is handed the shutdown candidates.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum DeviceBootResult {
    Booted {
        device: DeviceDescriptor,
    },
    #[serde(rename_all = "camelCase")]
    BootLimitReached {
        limit: usize,
        cascade_booted: Vec<DeviceDescriptor>,
    },
}

/// What the manager tells the app (Synara `DeviceEvent`).
#[derive(Clone, Debug, PartialEq)]
pub enum DeviceEvent {
    State { owner: String, state: OwnerDeviceState },
    OpenPane { owner: String, udid: String, reason: OpenPaneReason },
}

/// A manager failure: the backend's, or a target that did not resolve.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceError {
    Backend(DeviceBackendError),
    Target(DeviceUiTargetError),
}

impl DeviceError {
    pub fn message(&self) -> &str {
        match self {
            Self::Backend(error) => &error.message,
            Self::Target(error) => &error.message,
        }
    }
}

impl std::fmt::Display for DeviceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for DeviceError {}

impl From<DeviceBackendError> for DeviceError {
    fn from(error: DeviceBackendError) -> Self {
        Self::Backend(error)
    }
}

impl From<DeviceUiTargetError> for DeviceError {
    fn from(error: DeviceUiTargetError) -> Self {
        Self::Target(error)
    }
}

/// A resolved target, owned so it outlives the tree it was found in.
#[derive(Clone, Debug, PartialEq)]
pub struct TargetMatch {
    pub point: DeviceUiPoint,
    pub node: DeviceUiNode,
    pub on_screen: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SettleOutcome {
    /// False when the screen was still changing at the deadline.
    pub settled: bool,
    pub waited: Duration,
    /// The last tree read, or none when accessibility never answered.
    pub root: Option<DeviceUiNode>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    pub settled: bool,
    pub waited: Duration,
    pub root: Option<DeviceUiNode>,
    /// Whether the screen differs from just before the action; none if unknown.
    pub changed: Option<bool>,
}

/// Wait for an app to come to the front before settling: one other than the app in front before,
/// or any when relaunching the app already in front.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AwaitApp {
    Different,
    Any,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ObserveOptions {
    pub quiet: Option<Duration>,
    pub timeout: Option<Duration>,
    pub await_app: Option<AwaitApp>,
    pub await_change: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TextMethod {
    #[default]
    Auto,
    Keys,
    Value,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TextEntryOptions {
    pub method: TextMethod,
    pub clear: bool,
    pub submit: bool,
}

/// How the text went in: keystrokes, or the field's value set directly.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EnteredBy {
    Keys,
    Value,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextEntryOutcome {
    pub method: EnteredBy,
    pub submitted: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum WaitStatus {
    Ready,
    Timeout,
    Ambiguous,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WaitOutcome {
    pub status: WaitStatus,
    pub waited: Duration,
    pub root: Option<DeviceUiNode>,
    pub found: Option<TargetMatch>,
}

/// Synara `releaseDevice`'s reason: a switch frees a Cascade-booted device at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Release {
    Detached,
    Switched,
}

/// The provider turn an agent's device use belongs to: who called (`chat:<thread>`, `run:<run>`)
/// and which of its turns. A device an agent used stays leased to its turn until that turn settles
/// (Synara `agentDevicesByTurn`), so a simulator the agent booted is not shut down between two of
/// its tool calls, and is released once the turn is over.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct AgentTurn {
    pub holder: String,
    pub id: String,
}

/// The device an agent tool acts on, and the turn it acts in, when it has one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceUse {
    pub udid: String,
    pub turn: Option<AgentTurn>,
    /// The turn's lease lapses after the idle grace with no device call of that turn: for a caller
    /// whose turn end may never be heard (a terminal agent interrupted, or gone, with no `Stop`).
    pub lapses: bool,
}

/// Who pointed an owner at its device: a user's attachment keeps the device up, an agent's is
/// metadata and keeps it only through the turn that made it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum AttachmentSource {
    #[default]
    User,
    Agent,
}

/// How many settled turns are remembered, to refuse a tool completion arriving after its turn.
const ENDED_TURNS_KEPT: usize = 256;

fn disposed_error() -> DeviceBackendError {
    DeviceBackendError::new("Device manager is disposed.")
}

// ── Options ────────────────────────────────────────────────────────────

pub struct DeviceManagerOptions {
    pub backend: Arc<dyn DeviceBackend>,
    /// Whether this platform can run simulators at all; the agent tools are offered only then.
    pub supported: bool,
    /// Remembers Cascade's boots across a crash.
    pub boot_ownership: BootOwnershipStore,
    pub idle_shutdown: Duration,
    pub boot_limit: usize,
    pub attach_deadline: Duration,
    pub attach_retry: Duration,
}

impl DeviceManagerOptions {
    pub fn new(backend: Arc<dyn DeviceBackend>) -> Self {
        Self {
            backend,
            supported: true,
            boot_ownership: BootOwnershipStore::null(),
            idle_shutdown: DEVICE_IDLE_SHUTDOWN,
            boot_limit: DEVICE_BOOT_LIMIT,
            attach_deadline: DEVICE_ATTACH_DEADLINE,
            attach_retry: DEVICE_ATTACH_RETRY,
        }
    }
}

// ── State, owned by the manager's task ─────────────────────────────────

#[derive(Default)]
struct Attachment {
    /// Which incarnation of this owner's state: one removed and made again is another.
    epoch: u64,
    version: u64,
    attached: Option<String>,
    source: AttachmentSource,
    agent_active: u32,
    /// Devices each agent turn used; they stay leased until that exact turn settles.
    agent_turns: HashMap<AgentTurn, HashSet<String>>,
    last_error: Option<String>,
    /// Some while the attachment is still coming up.
    phase: Option<DeviceAttachPhase>,
    /// The attach attempt in flight; a retry loop that finds another has been superseded.
    token: u64,
    /// The device this owner's pane was already asked to open for.
    pane_surfaced: Option<String>,
}

#[derive(Default)]
struct State {
    owners: HashMap<String, Attachment>,
    /// Availability and device list from the most recent discovery; see `snapshot`.
    last_discovery: Option<(DeviceAvailability, Vec<DeviceDescriptor>)>,
    /// Devices this manager booted, in boot order, and therefore may shut down again.
    booted: Vec<String>,
    /// Boots still running: a device being booted can still list as shut down meanwhile.
    boots_in_flight: HashSet<String>,
    /// When each idle Cascade-booted device is shut down.
    idle: HashMap<String, Instant>,
    active_stream: Option<String>,
    desired_stream: Option<String>,
    recording: HashSet<String>,
    /// Idle poweroffs already handed to simctl, and boots restoring one, by device: what a new
    /// consumer of the device waits out before it acts (Synara `idleShutdowns`).
    idle_shutdowns: HashMap<String, (u64, watch::Receiver<bool>)>,
    /// Device calls running now, pane or agent, by device.
    active_actions: HashMap<String, u32>,
    /// Turns that settled, oldest first, so a late call of one leases nothing.
    ended_turns: VecDeque<AgentTurn>,
    /// When each lapsing turn's lease lapses: the idle grace after its last device call ended.
    lapses: HashMap<AgentTurn, Instant>,
    /// When each held turn first leased a device, on the `next_id` clock: a settle check releases
    /// only turns leased before it began (`end_agent_turns_except`).
    lease_marks: HashMap<AgentTurn, u64>,
    next_id: u64,
    disposed: bool,
}

impl State {
    fn owner(&mut self, owner: &str) -> &mut Attachment {
        if !self.owners.contains_key(owner) {
            self.next_id += 1;
            let epoch = self.next_id;
            self.owners.insert(owner.to_owned(), Attachment { epoch, ..Attachment::default() });
        }
        self.owners.get_mut(owner).expect("just inserted")
    }

    fn is_current(&self, owner: &str, epoch: u64) -> bool {
        !self.disposed && self.owners.get(owner).is_some_and(|attachment| attachment.epoch == epoch)
    }

    /// Something still needs this device up: a boot, a recording, a call, a viewer, a user's
    /// attachment, or an agent turn that used it and has not settled. An agent's attachment alone
    /// does not keep a simulator alive after the work ends.
    fn is_busy(&self, transport: &FrameTransport, udid: &str) -> bool {
        self.boots_in_flight.contains(udid)
            || self.recording.contains(udid)
            || self.active_actions.contains_key(udid)
            || transport.subscriber_count(udid) > 0
            || self.owners.values().any(|attachment| {
                (attachment.attached.as_deref() == Some(udid) && attachment.source == AttachmentSource::User)
                    || attachment.agent_turns.values().any(|devices| devices.contains(udid))
            })
    }

    /// Starts the idle grace when the last consumer of a Cascade-booted device goes away, and
    /// cancels it while one remains (Synara `updateIdleTimer`). A grace already running keeps its
    /// deadline.
    fn update_idle(&mut self, transport: &FrameTransport, udid: &str, after: Duration) {
        if self.disposed || !self.owns(udid) {
            return;
        }
        if self.is_busy(transport, udid) {
            self.idle.remove(udid);
            return;
        }
        self.idle.entry(udid.to_owned()).or_insert_with(|| Instant::now() + after);
    }

    fn begin_action(&mut self, udid: &str) {
        self.idle.remove(udid);
        *self.active_actions.entry(udid.to_owned()).or_insert(0) += 1;
    }

    fn end_action(&mut self, udid: &str) {
        if let Some(count) = self.active_actions.get_mut(udid) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.active_actions.remove(udid);
            }
        }
    }

    fn remember_ended(&mut self, turn: AgentTurn) {
        if !self.ended_turns.contains(&turn) {
            self.ended_turns.push_back(turn);
        }
        while self.ended_turns.len() > ENDED_TURNS_KEPT {
            self.ended_turns.pop_front();
        }
    }

    /// Releases the leases of every turn `settled` names, wherever it worked, and starts the grace
    /// of each device that leaves unused. `exact` is remembered as settled even when it held
    /// nothing, so a call of it still in flight leases nothing when it lands.
    fn end_turns(
        &mut self,
        transport: &FrameTransport,
        after: Duration,
        settled: impl Fn(&AgentTurn) -> bool,
        exact: Option<AgentTurn>,
    ) {
        if self.disposed {
            return;
        }
        let mut devices = HashSet::new();
        let mut ended = Vec::new();
        for attachment in self.owners.values_mut() {
            attachment.agent_turns.retain(|turn, used| {
                if !settled(turn) {
                    return true;
                }
                devices.extend(used.iter().cloned());
                ended.push(turn.clone());
                false
            });
        }
        for turn in ended.into_iter().chain(exact) {
            self.lapses.remove(&turn);
            self.lease_marks.remove(&turn);
            self.remember_ended(turn);
        }
        for udid in devices {
            self.update_idle(transport, &udid, after);
        }
    }

    fn holds_turn(&self, turn: &AgentTurn) -> bool {
        self.owners.values().any(|attachment| attachment.agent_turns.contains_key(turn))
    }

    /// Drops the leases of turns whose lapse came, without counting them settled: a later call of
    /// the same turn leases its device again.
    fn lapse_turns(&mut self, transport: &FrameTransport, after: Duration, due: &[AgentTurn]) {
        let mut devices = HashSet::new();
        for turn in due {
            self.lapses.remove(turn);
            self.lease_marks.remove(turn);
            for attachment in self.owners.values_mut() {
                if let Some(used) = attachment.agent_turns.remove(turn) {
                    devices.extend(used);
                }
            }
        }
        for udid in devices {
            self.update_idle(transport, &udid, after);
        }
    }

    fn is_attached_anywhere(&self, udid: &str) -> bool {
        self.owners.values().any(|attachment| attachment.attached.as_deref() == Some(udid))
    }

    fn own(&mut self, udid: &str) {
        if !self.booted.iter().any(|booted| booted == udid) {
            self.booted.push(udid.to_owned());
        }
    }

    fn disown(&mut self, udid: &str) {
        self.booted.retain(|booted| booted != udid);
    }

    fn owns(&self, udid: &str) -> bool {
        self.booted.iter().any(|booted| booted == udid)
    }
}

type Op = Box<dyn FnOnce(&mut State) + Send>;

struct Shared {
    backend: Arc<dyn DeviceBackend>,
    supported: bool,
    boot_ownership: BootOwnershipStore,
    idle_shutdown: Duration,
    boot_limit: usize,
    attach_deadline: Duration,
    attach_retry: Duration,
    ops: mpsc::UnboundedSender<Op>,
    transport: FrameTransport,
    /// Serializes the helper's single stream (Synara's `streamTransition` chain).
    stream_lock: tokio::sync::Mutex<()>,
    events: broadcast::Sender<DeviceEvent>,
    /// Set at the end of `dispose`: nothing is told after.
    silenced: AtomicBool,
}

/// The device manager's handle; clones share one manager.
#[derive(Clone)]
pub struct DeviceManager {
    shared: Arc<Shared>,
}

/// A viewer of a device's frames. Dropping it unsubscribes, and the last viewer leaving stops the
/// encode.
pub struct FrameSubscription {
    manager: DeviceManager,
    udid: String,
    id: u64,
}

impl FrameSubscription {
    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn udid(&self) -> &str {
        &self.udid
    }
}

impl Drop for FrameSubscription {
    fn drop(&mut self) {
        self.manager.shared.transport.unsubscribe(self.id);
        // The last viewer leaving starts the device's idle grace, in order with what follows.
        let udid = self.udid.clone();
        self.manager.step_now(move |state, shared| state.update_idle(&shared.transport, &udid, shared.idle_shutdown));
        // Capture stops as soon as the last viewer goes, whether or not an owner is still
        // attached: the attachment is metadata and survives, only the encode stops.
        if self.manager.shared.transport.subscriber_count(&self.udid) == 0 {
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                let manager = self.manager.clone();
                let udid = self.udid.clone();
                runtime.spawn(async move {
                    let _ = manager.stop_stream_if_unwatched(&udid).await;
                });
            }
        }
    }
}

/// Clears the agent-activity count if the action it wraps is dropped before it finishes: a Stop
/// that cancels a tool call still waiting out an idle poweroff ends it there.
struct ActivityGuard {
    manager: Option<DeviceManager>,
    owner: String,
    epoch: u64,
    device_use: Option<DeviceUse>,
}

impl Drop for ActivityGuard {
    fn drop(&mut self) {
        let Some(manager) = self.manager.take() else { return };
        let (owner, epoch, device_use) = (std::mem::take(&mut self.owner), self.epoch, self.device_use.take());
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move { manager.end_activity(&owner, epoch, device_use).await });
        }
    }
}

/// Undoes a boot's reservation if the boot is dropped before it returns, so a cancelled boot
/// neither keeps its slot in the cap nor counts as a boot in flight for good.
struct BootGuard {
    manager: Option<DeviceManager>,
    udid: String,
}

impl Drop for BootGuard {
    fn drop(&mut self) {
        let Some(manager) = self.manager.take() else { return };
        let udid = std::mem::take(&mut self.udid);
        manager.step_now(move |state, shared| {
            state.boots_in_flight.remove(&udid);
            state.disown(&udid);
            state.update_idle(&shared.transport, &udid, shared.idle_shutdown);
        });
    }
}

/// Ends a device call however it ends, completed or dropped, in order with what follows.
struct ActionGuard {
    manager: DeviceManager,
    udid: String,
}

impl Drop for ActionGuard {
    fn drop(&mut self) {
        let udid = std::mem::take(&mut self.udid);
        self.manager.step_now(move |state, shared| {
            state.end_action(&udid);
            state.update_idle(&shared.transport, &udid, shared.idle_shutdown);
        });
    }
}

const EVENTS_CAPACITY: usize = 1024;

impl DeviceManager {
    /// Starts the manager's task. Must run on a Tokio runtime.
    pub fn new(options: DeviceManagerOptions) -> Self {
        let (ops, receiver) = mpsc::unbounded_channel();
        let (events, _) = broadcast::channel(EVENTS_CAPACITY);
        let shared = Arc::new(Shared {
            backend: options.backend,
            supported: options.supported,
            boot_ownership: options.boot_ownership,
            idle_shutdown: options.idle_shutdown,
            boot_limit: options.boot_limit,
            attach_deadline: options.attach_deadline,
            attach_retry: options.attach_retry,
            ops,
            transport: FrameTransport::default(),
            stream_lock: tokio::sync::Mutex::new(()),
            events,
            silenced: AtomicBool::new(false),
        });
        tokio::spawn(run_state(receiver, Arc::downgrade(&shared)));
        let mut frames = shared.backend.subscribe_frames();
        let weak = Arc::downgrade(&shared);
        tokio::spawn(async move {
            loop {
                let record = match frames.recv().await {
                    Ok(record) => record,
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        let Some(shared) = weak.upgrade() else { return };
                        // Off this loop, so the frames that follow keep being read.
                        tokio::spawn(async move { DeviceManager { shared }.resync_after_lag().await });
                        continue;
                    }
                    Err(broadcast::error::RecvError::Closed) => return,
                };
                let Some(shared) = weak.upgrade() else { return };
                DeviceManager { shared }.forward_frame(&record.udid, &record.frame).await;
            }
        });
        let mut interruptions = shared.backend.subscribe_interruptions();
        let weak = Arc::downgrade(&shared);
        tokio::spawn(async move {
            loop {
                let interruption = match interruptions.recv().await {
                    Ok(interruption) => interruption,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return,
                };
                let Some(shared) = weak.upgrade() else { return };
                DeviceManager { shared }.handle_stream_interrupted(interruption.udid, interruption.reason);
            }
        });
        Self { shared }
    }

    pub fn supported(&self) -> bool {
        self.shared.supported
    }

    pub fn backend(&self) -> &Arc<dyn DeviceBackend> {
        &self.shared.backend
    }

    pub fn transport(&self) -> &FrameTransport {
        &self.shared.transport
    }

    /// Every event from now on.
    pub fn subscribe(&self) -> broadcast::Receiver<DeviceEvent> {
        self.shared.events.subscribe()
    }

    /// Runs one step on the state, on the manager's task.
    async fn with<R: Send + 'static>(&self, step: impl FnOnce(&mut State) -> R + Send + 'static) -> R {
        let (reply, answer) = oneshot::channel();
        let op: Op = Box::new(move |state| {
            let _ = reply.send(step(state));
        });
        if self.shared.ops.send(op).is_err() {
            panic!("the device manager's task ended while its handle was alive");
        }
        answer.await.expect("the device manager's task answers every step")
    }

    /// Sends a step without waiting for it: for a `Drop`, which cannot await. Steps run in the
    /// order they are sent, so it still lands before anything its caller does next.
    fn step_now(&self, step: impl FnOnce(&mut State, &Shared) + Send + 'static) {
        let shared = Arc::downgrade(&self.shared);
        let op: Op = Box::new(move |state| {
            if let Some(shared) = shared.upgrade() {
                step(state, &shared);
            }
        });
        let _ = self.shared.ops.send(op);
    }

    /// Fails once the manager is disposed (Synara `assertNotDisposed`).
    async fn ensure_live(&self) -> DeviceResult<()> {
        if self.with(|state| state.disposed).await {
            return Err(disposed_error());
        }
        Ok(())
    }

    /// Recomputes a device's idle grace from what still uses it.
    async fn update_idle_timer(&self, udid: &str) {
        let (target, shared) = (udid.to_owned(), self.shared.clone());
        self.with(move |state| state.update_idle(&shared.transport, &target, shared.idle_shutdown)).await;
    }

    /// Waits out an idle poweroff already handed to simctl, which cannot be cancelled, and boots
    /// the device again if a consumer still needs it once it is down: concurrent viewers and tools
    /// share one restoration, boot cap and all (Synara `waitForIdleShutdown`).
    async fn wait_for_idle_shutdown(&self, udid: &str) -> DeviceResult<()> {
        let target = udid.to_owned();
        let Some((id, mut done)) = self.with(move |state| state.idle_shutdowns.get(&target).cloned()).await else {
            return Ok(());
        };
        let _ = done.wait_for(|done| *done).await;
        self.ensure_live().await?;
        enum Next {
            Done,
            Wait(watch::Receiver<bool>),
            Restore(u64, watch::Sender<bool>),
        }
        let (target, shared) = (udid.to_owned(), self.shared.clone());
        let next = self
            .with(move |state| {
                if let Some((other, resuming)) = state.idle_shutdowns.get(&target) {
                    if *other != id {
                        return Next::Wait(resuming.clone());
                    }
                }
                if !state.owns(&target) && state.is_busy(&shared.transport, &target) {
                    state.next_id += 1;
                    let (sender, receiver) = watch::channel(false);
                    state.idle_shutdowns.insert(target, (state.next_id, receiver));
                    return Next::Restore(state.next_id, sender);
                }
                Next::Done
            })
            .await;
        match next {
            Next::Done => Ok(()),
            Next::Wait(mut resuming) => {
                let _ = resuming.wait_for(|done| *done).await;
                self.ensure_live().await
            }
            Next::Restore(id, sender) => {
                // On a task of its own, which the waiters (this one too) only await: a caller
                // dropped mid-boot must not leave the restoration half done for the others.
                let (manager, target) = (self.clone(), udid.to_owned());
                let restoring = tokio::spawn(async move {
                    let restored = manager.boot_now(&target).await;
                    manager
                        .with(move |state| {
                            if state.idle_shutdowns.get(&target).is_some_and(|(held, _)| *held == id) {
                                state.idle_shutdowns.remove(&target);
                            }
                        })
                        .await;
                    let _ = sender.send(true);
                    restored
                });
                let restored = restoring
                    .await
                    .unwrap_or_else(|_| Err(DeviceBackendError::new("The simulator could not be resumed.")));
                match restored? {
                    DeviceBootResult::Booted { .. } => {}
                    DeviceBootResult::BootLimitReached { .. } => {
                        return Err(DeviceBackendError::new(
                            "The simulator boot limit was reached while resuming device use.",
                        ))
                    }
                }
                self.ensure_live().await
            }
        }
    }

    /// Guards one call across the native boundary, a pane's or an agent's: the device counts as in
    /// use while it runs, and it waits out an idle poweroff before it starts.
    async fn with_device_action<T>(
        &self,
        udid: &str,
        action: impl std::future::Future<Output = DeviceResult<T>>,
    ) -> DeviceResult<T> {
        let target = udid.to_owned();
        let admitted = self
            .with(move |state| {
                if state.disposed {
                    return false;
                }
                state.begin_action(&target);
                true
            })
            .await;
        if !admitted {
            return Err(disposed_error());
        }
        let _guard = ActionGuard { manager: self.clone(), udid: udid.to_owned() };
        self.wait_for_idle_shutdown(udid).await?;
        self.ensure_live().await?;
        action.await
    }

    fn emit(&self, event: DeviceEvent) {
        if !self.shared.silenced.load(Ordering::SeqCst) {
            let _ = self.shared.events.send(event);
        }
    }

    // ── Startup ────────────────────────────────────────────────────────

    /// Shuts down simulators a previous run booted and never cleaned up, returning their udids.
    /// Called once at startup; a clean quit left an empty record, so this is normally a no-op.
    pub async fn reclaim_orphaned_boots(&self, is_process_alive: impl Fn(u32) -> bool) -> Vec<String> {
        let Some(recorded) = self.shared.boot_ownership.read() else { return Vec::new() };
        if recorded.udids.is_empty() {
            return Vec::new();
        }
        let devices = self
            .shared
            .backend
            .list_devices(DeviceListOptions { include_shutdown: false })
            .await
            .unwrap_or_default();
        let booted: Vec<String> = devices.into_iter().map(|device| device.udid).collect();
        let orphans = orphaned_boot_udids(Some(&recorded), &booted, &is_process_alive);
        for udid in &orphans {
            let _ = self.shared.backend.shutdown(udid).await;
        }
        // Cleared even when nothing was shut down: the record described a dead process.
        if !is_process_alive(recorded.pid) {
            self.shared.boot_ownership.clear();
        }
        orphans
    }

    async fn record_boot_ownership(&self) {
        let booted = self.with(|state| state.booted.clone()).await;
        self.shared.boot_ownership.write(&booted);
    }

    // ── Queries ────────────────────────────────────────────────────────

    pub async fn availability(&self) -> DeviceAvailability {
        self.shared.backend.availability().await
    }

    pub async fn list(&self, include_shutdown: bool) -> DeviceListResult {
        let availability = self.shared.backend.availability().await;
        let devices = self.discover(&availability, include_shutdown).await;
        DeviceListResult { devices, availability }
    }

    /// Devices to show beside an availability state. Discovery is gated only on the platform:
    /// listing runs on `simctl`, long before the helper exists, and the helper is built on first
    /// attach, which needs a udid from this list.
    async fn discover(&self, availability: &DeviceAvailability, include_shutdown: bool) -> Vec<DeviceDescriptor> {
        if matches!(availability, DeviceAvailability::UnsupportedPlatform { .. }) {
            return Vec::new();
        }
        let devices = self.shared.backend.list_devices(DeviceListOptions { include_shutdown }).await.unwrap_or_default();
        self.describe_all(devices).await
    }

    /// Fills in what discovery cannot know: who booted the device, and its geometry.
    async fn describe_all(&self, devices: Vec<DeviceDescriptor>) -> Vec<DeviceDescriptor> {
        let booted = self.with(|state| state.booted.clone()).await;
        devices.into_iter().map(|device| self.describe(device, &booted)).collect()
    }

    fn describe(&self, mut device: DeviceDescriptor, booted: &[String]) -> DeviceDescriptor {
        if booted.iter().any(|udid| *udid == device.udid) {
            device.boot_source = DeviceBootSource::Cascade;
        }
        if let Some(geometry) = self.shared.backend.geometry(&device.udid) {
            device.geometry = Some(geometry);
        }
        device
    }

    /// An owner's state, discovered fresh.
    pub async fn owner_state(&self, owner: &str) -> OwnerDeviceState {
        self.snapshot(owner, false).await
    }

    /// Devices the pane may offer as shutdown candidates when the cap is hit.
    pub async fn cascade_booted_devices(&self) -> Vec<DeviceDescriptor> {
        let listed = self.shared.backend.list_devices(DeviceListOptions { include_shutdown: true }).await.ok();
        // A failed listing says nothing about what is running; reconciling against it would drop
        // every device Cascade booted.
        if let Some(listed) = &listed {
            self.reconcile_booted(listed).await;
        }
        let booted = self.with(|state| state.booted.clone()).await;
        listed
            .unwrap_or_default()
            .into_iter()
            .filter(|device| booted.contains(&device.udid))
            .map(|device| self.describe(device, &booted))
            .collect()
    }

    /// Forgets devices that are no longer running: `simctl shutdown all`, Simulator.app quitting
    /// or a crashed runtime all stop a device without telling Cascade, and each left a phantom
    /// holding a slot in the cap.
    async fn reconcile_booted(&self, devices: &[DeviceDescriptor]) {
        let running: HashSet<String> = devices
            .iter()
            .filter(|device| matches!(device.state, DeviceRuntimeState::Booted | DeviceRuntimeState::Booting))
            .map(|device| device.udid.clone())
            .collect();
        self.with(move |state| {
            let gone: Vec<String> = state
                .booted
                .iter()
                .filter(|udid| !running.contains(*udid) && !state.boots_in_flight.contains(*udid))
                .cloned()
                .collect();
            for udid in gone {
                state.disown(&udid);
                state.idle.remove(&udid);
            }
        })
        .await;
    }

    // ── Boot / shutdown ────────────────────────────────────────────────

    pub async fn boot(&self, udid: &str) -> DeviceResult<DeviceBootResult> {
        self.ensure_live().await?;
        self.wait_for_idle_shutdown(udid).await?;
        self.ensure_live().await?;
        self.boot_now(udid).await
    }

    /// `boot` without waiting out an idle poweroff: the boot that restores one.
    async fn boot_now(&self, udid: &str) -> DeviceResult<DeviceBootResult> {
        let listed = self.shared.backend.list_devices(DeviceListOptions { include_shutdown: true }).await.ok();
        if let Some(listed) = &listed {
            self.reconcile_booted(listed).await;
        }
        let known = listed.unwrap_or_default().into_iter().find(|device| device.udid == udid);
        // Viewing an already-booted device is uncapped: the cap stops Cascade accumulating
        // simulators, not what the user watches.
        if let Some(known) = known.filter(|device| device.state == DeviceRuntimeState::Booted) {
            let booted = self.with(|state| state.booted.clone()).await;
            return Ok(DeviceBootResult::Booted { device: self.describe(known, &booted) });
        }
        let limit = self.shared.boot_limit;
        let target = udid.to_owned();
        // The slot is taken before the boot runs, not after: a boot takes the better part of a
        // minute, and two asks inside that window would otherwise both pass the cap.
        let reserved = self
            .with(move |state| {
                if state.booted.len() >= limit {
                    return false;
                }
                state.own(&target);
                state.boots_in_flight.insert(target);
                true
            })
            .await;
        if !reserved {
            return Ok(DeviceBootResult::BootLimitReached { limit, cascade_booted: self.cascade_booted_devices().await });
        }
        let mut guard = BootGuard { manager: Some(self.clone()), udid: udid.to_owned() };
        let outcome = self.shared.backend.boot(udid).await;
        guard.manager = None;
        let target = udid.to_owned();
        let failed = outcome.is_err();
        self.with(move |state| {
            state.boots_in_flight.remove(&target);
            // A reservation only stands for a boot that happened.
            if failed {
                state.disown(&target);
            }
        })
        .await;
        let mut device = outcome?;
        // Persisted before the caller is told, so a crash in the next instant still leaves a
        // record to reclaim from.
        self.record_boot_ownership().await;
        // A device booted for a new purpose is no longer idle-condemned.
        self.clear_idle_timer(udid).await;
        self.publish_all().await;
        device.boot_source = DeviceBootSource::Cascade;
        Ok(DeviceBootResult::Booted { device })
    }

    pub async fn shutdown(&self, udid: &str) -> DeviceResult<()> {
        self.shutdown_inner(udid, false).await
    }

    /// `only_if_idle` is the idle poweroff: it re-checks after the stream teardown, which yields,
    /// since a tool, a user's attachment or a viewer may have arrived meanwhile, and leaves alone
    /// an owner that attached during the shutdown itself.
    async fn shutdown_inner(&self, udid: &str, only_if_idle: bool) -> DeviceResult<()> {
        let _ = self.stop_recording_if_active(udid).await;
        self.stop_stream(udid).await?;
        let tokens = if only_if_idle {
            let (target, shared) = (udid.to_owned(), self.shared.clone());
            let tokens = self
                .with(move |state| {
                    if state.disposed || state.is_busy(&shared.transport, &target) {
                        return None;
                    }
                    Some(state.owners.iter().map(|(owner, attachment)| (owner.clone(), attachment.token)).collect::<HashMap<_, _>>())
                })
                .await;
            let Some(tokens) = tokens else { return Ok(()) };
            Some(tokens)
        } else {
            None
        };
        self.shared.backend.shutdown(udid).await?;
        let target = udid.to_owned();
        // Every owner watching this device loses its attachment rather than pointing at a
        // shut-down simulator, and a retry loop waiting on its display stops.
        let detached = self
            .with(move |state| {
                state.disown(&target);
                state.idle.remove(&target);
                let mut detached = Vec::new();
                for (owner, attachment) in &mut state.owners {
                    if attachment.attached.as_deref() != Some(target.as_str()) {
                        continue;
                    }
                    if tokens.as_ref().is_some_and(|tokens| tokens.get(owner) != Some(&attachment.token)) {
                        continue;
                    }
                    attachment.attached = None;
                    attachment.phase = None;
                    attachment.token += 1;
                    detached.push(owner.clone());
                }
                detached
            })
            .await;
        self.record_boot_ownership().await;
        for owner in detached {
            self.publish(&owner, false).await;
        }
        self.publish_all().await;
        Ok(())
    }

    // ── Attachment ─────────────────────────────────────────────────────

    /// Points an owner at a device and brings its stream up. Returns as soon as the attachment is
    /// recorded, not when the picture arrives; the stream comes up behind it, a phase at a time.
    pub async fn attach(&self, owner: &str, udid: &str) -> OwnerDeviceState {
        self.attach_as(owner, udid, AttachmentSource::User).await
    }

    async fn attach_as(&self, owner: &str, udid: &str, source: AttachmentSource) -> OwnerDeviceState {
        let (key, target) = (owner.to_owned(), udid.to_owned());
        let (previous, token) = self
            .with(move |state| {
                let attachment = state.owner(&key);
                // Set before releasing: `release_device` asks whether anyone still holds the
                // previous device, and this owner must no longer count.
                let previous = attachment.attached.replace(target);
                attachment.source = source;
                attachment.last_error = None;
                attachment.phase = Some(DeviceAttachPhase::Connecting);
                attachment.token += 1;
                (previous, attachment.token)
            })
            .await;
        if let Some(previous) = previous.filter(|previous| previous != udid) {
            self.release_device(&previous, Release::Switched).await;
        }
        self.clear_idle_timer(udid).await;
        let waited = self.wait_for_idle_shutdown(udid).await;
        let key = owner.to_owned();
        let (disposed, current) = self
            .with(move |state| (state.disposed, state.owners.get(&key).is_some_and(|attachment| attachment.token == token)))
            .await;
        if disposed || !current {
            return self.snapshot(owner, false).await;
        }
        if let Err(error) = waited {
            let key = owner.to_owned();
            self.with(move |state| {
                let attachment = state.owner(&key);
                attachment.phase = None;
                attachment.last_error = Some(error.message);
            })
            .await;
            return self.publish(owner, false).await;
        }

        // Already streaming (another owner watches the same device): nothing to wait for.
        let (key, target) = (owner.to_owned(), udid.to_owned());
        let streaming = self
            .with(move |state| {
                let streaming = state.active_stream.as_deref() == Some(target.as_str())
                    || state.desired_stream.as_deref() == Some(target.as_str());
                if streaming {
                    state.owner(&key).phase = None;
                }
                streaming
            })
            .await;
        if streaming {
            return self.publish(owner, false).await;
        }
        let published = self.publish(owner, false).await;
        let manager = self.clone();
        let (owner, udid) = (owner.to_owned(), udid.to_owned());
        tokio::spawn(async move { manager.bring_stream_up(owner, udid, token).await });
        published
    }

    /// Opens the stream, waiting out the failures that only mean "not ready yet", until the
    /// attach deadline; a device that never comes up ends in a message naming what to do.
    async fn bring_stream_up(&self, owner: String, udid: String, token: u64) {
        let deadline = Instant::now() + self.shared.attach_deadline;
        let mut saw_transient_failure = false;
        loop {
            let (key, wanted) = (owner.clone(), udid.clone());
            let current = self
                .with(move |state| {
                    !state.disposed
                        && state
                            .owners
                            .get(&key)
                            .is_some_and(|attachment| attachment.token == token && attachment.attached.as_deref() == Some(wanted.as_str()))
                })
                .await;
            // Superseded, detached or disposed: another attach owns this owner's state now.
            if !current {
                if self.with(|state| state.disposed).await {
                    break;
                }
                return;
            }

            if self.would_steal_stream(&udid).await {
                // Nobody watches this device yet, while another owner's viewers watch a different
                // one on the helper's single stream: the stream starts when this one gets a viewer.
                let key = owner.clone();
                let cleared = self
                    .with(move |state| match state.owners.get_mut(&key) {
                        Some(attachment) if attachment.token == token && attachment.phase.is_some() => {
                            attachment.phase = None;
                            true
                        }
                        _ => false,
                    })
                    .await;
                if cleared {
                    self.publish(&owner, false).await;
                }
                return;
            }

            match self.start_stream(&udid).await {
                Ok(started) => {
                    if !started {
                        return;
                    }
                    let key = owner.clone();
                    let changed = self
                        .with(move |state| match state.owners.get_mut(&key) {
                            Some(attachment)
                                if attachment.token == token
                                    && (attachment.phase.is_some() || attachment.last_error.is_some()) =>
                            {
                                attachment.phase = None;
                                attachment.last_error = None;
                                true
                            }
                            _ => false,
                        })
                        .await;
                    if changed {
                        self.publish(&owner, false).await;
                    }
                    return;
                }
                Err(error) => {
                    let key = owner.clone();
                    if !is_transient_attach_failure(&error) {
                        let message = error.message.clone();
                        let current = self
                            .with(move |state| match state.owners.get_mut(&key) {
                                Some(attachment) if attachment.token == token => {
                                    attachment.phase = None;
                                    attachment.last_error = Some(message);
                                    true
                                }
                                _ => false,
                            })
                            .await;
                        if current {
                            self.publish(&owner, false).await;
                        }
                        return;
                    }
                    // A device that is up but has no screen yet is a different wait from booting.
                    let phase = if not_booted_pattern().is_match(&error.message) {
                        DeviceAttachPhase::Booting
                    } else {
                        DeviceAttachPhase::WaitingForDisplay
                    };
                    let changed = self
                        .with(move |state| match state.owners.get_mut(&key) {
                            Some(attachment) if attachment.token == token && attachment.phase != Some(phase) => {
                                attachment.phase = Some(phase);
                                true
                            }
                            _ => false,
                        })
                        .await;
                    if changed {
                        self.publish(&owner, false).await;
                    }
                    saw_transient_failure = true;
                }
            }

            if Instant::now() >= deadline {
                break;
            }
            tokio::time::sleep(self.shared.attach_retry).await;
        }

        let key = owner.clone();
        let current = self
            .with(move |state| {
                let disposed = state.disposed;
                match state.owners.get_mut(&key) {
                    Some(attachment) if attachment.token == token => {
                        attachment.phase = None;
                        // Only the display-wait deadline gets the tailored message; a disposal
                        // mid-wait is not the user's problem to act on.
                        if saw_transient_failure && !disposed {
                            attachment.last_error = Some(DISPLAY_TIMEOUT_MESSAGE.to_owned());
                        }
                        true
                    }
                    _ => false,
                }
            })
            .await;
        if current {
            self.publish(&owner, false).await;
        }
    }

    /// Points an owner at the device its agent drives, unless it already watches one: an existing
    /// attachment is the user's choice and is never stolen.
    pub async fn ensure_attached(&self, owner: &str, udid: &str) {
        let key = owner.to_owned();
        let attached = self.with(move |state| state.owner(&key).attached.clone()).await;
        if attached.is_some() {
            return;
        }
        self.attach_as(owner, udid, AttachmentSource::Agent).await;
        self.update_idle_timer(udid).await;
    }

    pub async fn detach(&self, owner: &str) -> OwnerDeviceState {
        let key = owner.to_owned();
        let udid = self
            .with(move |state| {
                let attachment = state.owner(&key);
                attachment.phase = None;
                // Abandons any attach still retrying in the background.
                attachment.token += 1;
                attachment.attached.take()
            })
            .await;
        if let Some(udid) = udid {
            self.release_device(&udid, Release::Detached).await;
        }
        self.publish(owner, false).await
    }

    /// The owner is gone (its session was removed): treat it as a detach, then forget it.
    pub async fn handle_owner_removed(&self, owner: &str) {
        let key = owner.to_owned();
        if !self.with(move |state| state.owners.contains_key(&key)).await {
            return;
        }
        self.detach(owner).await;
        let key = owner.to_owned();
        let shared = self.shared.clone();
        self.with(move |state| {
            let Some(attachment) = state.owners.remove(&key) else { return };
            let devices: HashSet<String> = attachment.agent_turns.into_values().flatten().collect();
            for udid in devices {
                state.update_idle(&shared.transport, &udid, shared.idle_shutdown);
            }
        })
        .await;
    }

    // ── Streaming ──────────────────────────────────────────────────────

    /// Registers a viewer of a device's video. The stream starts if it is not running, and stops
    /// when the last viewer's subscription is dropped.
    pub async fn subscribe_frames(&self, udid: &str) -> FrameSubscription {
        let id = self.shared.transport.subscribe(udid);
        let subscription = FrameSubscription { manager: self.clone(), udid: udid.to_owned(), id };
        let target = udid.to_owned();
        // A viewer is a consumer: no idle grace runs under it. One that arrives while an idle
        // poweroff is under way starts its stream once the device is back.
        let (disposed, pending) = self
            .with(move |state| {
                state.idle.remove(&target);
                (state.disposed, state.idle_shutdowns.contains_key(&target))
            })
            .await;
        if disposed {
            return subscription;
        }
        if pending {
            let manager = self.clone();
            let udid = udid.to_owned();
            tokio::spawn(async move {
                if manager.wait_for_idle_shutdown(&udid).await.is_err()
                    || manager.with(|state| state.disposed).await
                    || manager.shared.transport.subscriber_count(&udid) == 0
                {
                    return;
                }
                manager.start_for_viewer(&udid).await;
            });
            return subscription;
        }
        self.start_for_viewer(udid).await;
        subscription
    }

    /// An owner whose attach deferred its stream (see `would_steal_stream`) gets the attach's
    /// retry loop now that someone is watching: the device may still be publishing its display.
    async fn start_for_viewer(&self, udid: &str) {
        let target = udid.to_owned();
        let waiting = self
            .with(move |state| {
                let waiting = (state.active_stream.as_deref() != Some(target.as_str()))
                    .then(|| {
                        state
                            .owners
                            .iter()
                            .find(|(_, attachment)| attachment.attached.as_deref() == Some(target.as_str()))
                            .map(|(owner, attachment)| (owner.clone(), attachment.token))
                    })
                    .flatten();
                if waiting.is_none() && !state.disposed {
                    // Wanted from this moment, so a viewer leaving before the stream is up stops
                    // it rather than finding nothing to stop.
                    state.desired_stream = Some(target);
                }
                waiting
            })
            .await;
        let manager = self.clone();
        let udid = udid.to_owned();
        match waiting {
            Some((owner, token)) => {
                tokio::spawn(async move { manager.bring_stream_up(owner, udid, token).await });
            }
            None => {
                tokio::spawn(async move {
                    let _ = manager.start_stream(&udid).await;
                });
            }
        }
    }

    async fn forward_frame(&self, udid: &str, frame: &super::backend::DeviceStreamFrame) {
        let target = udid.to_owned();
        let wanted = self
            .with(move |state| {
                state.desired_stream.as_deref() == Some(target.as_str()) || state.active_stream.as_deref() == Some(target.as_str())
            })
            .await;
        if wanted {
            self.shared.transport.publish(udid, frame);
        }
    }

    /// Whether the helper is streaming `udid` now.
    pub async fn is_streaming(&self, udid: &str) -> bool {
        let target = udid.to_owned();
        self.with(move |state| state.active_stream.as_deref() == Some(target.as_str())).await
    }

    /// Starting `udid` would end a stream someone is watching, for no viewer of its own.
    async fn would_steal_stream(&self, udid: &str) -> bool {
        let Some(active) = self.with(|state| state.active_stream.clone()).await else { return false };
        active != udid
            && self.shared.transport.subscriber_count(udid) == 0
            && self.shared.transport.subscriber_count(&active) > 0
    }

    /// The helper died under a live stream. It is rebuilt on a fresh helper while anyone still
    /// needs it, and a failure is shown on every owner watching the device.
    fn handle_stream_interrupted(&self, udid: String, reason: String) {
        let manager = self.clone();
        tokio::spawn(async move {
            let _transition = manager.shared.stream_lock.lock().await;
            let target = udid.clone();
            let active = manager
                .with(move |state| {
                    if state.disposed || state.active_stream.as_deref() != Some(target.as_str()) {
                        return false;
                    }
                    state.active_stream = None;
                    true
                })
                .await;
            if !active {
                return;
            }
            manager.shared.transport.reset(&udid);
            let viewers = manager.shared.transport.subscriber_count(&udid) > 0;
            let target = udid.clone();
            let needed = manager
                .with(move |state| {
                    let desired = state.desired_stream.as_deref() == Some(target.as_str());
                    if desired && viewers {
                        return true;
                    }
                    if desired {
                        state.desired_stream = None;
                    }
                    false
                })
                .await;
            if !needed {
                return;
            }
            if let Err(error) = manager.reconcile_stream().await {
                let message =
                    format!("The simulator helper stopped ({reason}) and could not be restarted: {}", error.message);
                let target = udid.clone();
                let owners = manager
                    .with(move |state| {
                        let mut owners = Vec::new();
                        for (owner, attachment) in &mut state.owners {
                            if attachment.attached.as_deref() != Some(target.as_str()) {
                                continue;
                            }
                            attachment.phase = None;
                            attachment.last_error = Some(message.clone());
                            owners.push(owner.clone());
                        }
                        owners
                    })
                    .await;
                for owner in owners {
                    manager.publish(&owner, false).await;
                }
            }
        });
    }

    async fn start_stream(&self, udid: &str) -> DeviceResult<bool> {
        let target = udid.to_owned();
        let accepted = self
            .with(move |state| {
                if state.disposed {
                    return false;
                }
                state.desired_stream = Some(target);
                true
            })
            .await;
        if !accepted {
            return Ok(false);
        }
        self.queue_stream_reconciliation().await?;
        let target = udid.to_owned();
        Ok(self.with(move |state| state.active_stream.as_deref() == Some(target.as_str())).await)
    }

    /// Clears stale startup state from every owner now watching this device.
    async fn clear_stream_startup_state(&self, udid: &str) {
        let target = udid.to_owned();
        let cleared = self
            .with(move |state| {
                let mut cleared = Vec::new();
                for (owner, attachment) in &mut state.owners {
                    if attachment.attached.as_deref() != Some(target.as_str())
                        || (attachment.last_error.is_none() && attachment.phase.is_none())
                    {
                        continue;
                    }
                    attachment.last_error = None;
                    attachment.phase = None;
                    cleared.push(owner.clone());
                }
                cleared
            })
            .await;
        for owner in cleared {
            self.publish(&owner, false).await;
        }
    }

    /// Forces a fresh codec config and keyframe by rebuilding the stream: the helper has no
    /// "keyframe now" call, and a new compression session always starts with both. Cached frames
    /// are dropped first so a late viewer is not primed with the previous generation's keyframe.
    pub async fn request_keyframe(&self, udid: &str) -> DeviceResult<()> {
        let target = udid.to_owned();
        let streaming = self
            .with(move |state| {
                if state.disposed || state.active_stream.as_deref() != Some(target.as_str()) {
                    return false;
                }
                state.desired_stream = None;
                true
            })
            .await;
        if !streaming {
            return Ok(());
        }
        self.queue_stream_reconciliation().await?;
        let (disposed, desired) = self.with(|state| (state.disposed, state.desired_stream.is_some())).await;
        if disposed || desired || self.shared.transport.subscriber_count(udid) == 0 {
            return Ok(());
        }
        self.start_stream(udid).await.map(|_| ())
    }

    async fn stop_stream(&self, udid: &str) -> DeviceResult<()> {
        let target = udid.to_owned();
        let stop = self
            .with(move |state| {
                if state.desired_stream.as_deref() == Some(target.as_str()) {
                    state.desired_stream = None;
                    true
                } else {
                    state.desired_stream.is_none() && state.active_stream.as_deref() == Some(target.as_str())
                }
            })
            .await;
        if !stop {
            return Ok(());
        }
        self.queue_stream_reconciliation().await
    }

    /// `stop_stream` for a viewer that left: Synara clears the wanted stream inside its
    /// unsubscribe, in the same step. Here the stop runs later, so it re-checks, in the state's own
    /// step, that no viewer subscribed meanwhile; a pane that reconnects at once keeps its stream.
    async fn stop_stream_if_unwatched(&self, udid: &str) -> DeviceResult<()> {
        let target = udid.to_owned();
        let shared = self.shared.clone();
        let stop = self
            .with(move |state| {
                if shared.transport.subscriber_count(&target) > 0 {
                    return false;
                }
                if state.desired_stream.as_deref() == Some(target.as_str()) {
                    state.desired_stream = None;
                    true
                } else {
                    state.desired_stream.is_none() && state.active_stream.as_deref() == Some(target.as_str())
                }
            })
            .await;
        if !stop {
            return Ok(());
        }
        self.queue_stream_reconciliation().await
    }

    /// The frame forwarder fell behind the backend's broadcast, so the codec config or keyframe a
    /// viewer needs may be among the frames lost: drop what is cached and rebuild the stream.
    async fn resync_after_lag(&self) {
        let Some(active) = self.with(|state| state.active_stream.clone()).await else { return };
        self.shared.transport.reset(&active);
        let _ = self.request_keyframe(&active).await;
    }

    async fn queue_stream_reconciliation(&self) -> DeviceResult<()> {
        let _transition = self.shared.stream_lock.lock().await;
        self.reconcile_stream().await
    }

    /// The one stream state machine: tears the active stream down when it differs from the desired
    /// one, and attaches the desired one. The helper runs one stream at a time.
    async fn reconcile_stream(&self) -> DeviceResult<()> {
        loop {
            let (active, desired) = self
                .with(|state| (state.active_stream.clone(), if state.disposed { None } else { state.desired_stream.clone() }))
                .await;
            if active == desired {
                return Ok(());
            }
            if let Some(active) = active {
                self.with(|state| state.active_stream = None).await;
                self.shared.transport.reset(&active);
                self.shared.backend.detach_stream(&active).await;
                continue;
            }
            let Some(desired) = desired else { return Ok(()) };

            if let Err(error) = self.shared.backend.attach_stream(&desired).await {
                let target = desired.clone();
                let raise = self
                    .with(move |state| {
                        if !state.disposed && state.desired_stream.as_deref() == Some(target.as_str()) {
                            state.desired_stream = None;
                            true
                        } else {
                            false
                        }
                    })
                    .await;
                if raise {
                    return Err(error);
                }
                continue;
            }

            let target = desired.clone();
            let superseded = self
                .with(move |state| {
                    if state.disposed || state.desired_stream.as_deref() != Some(target.as_str()) {
                        return true;
                    }
                    state.active_stream = Some(target);
                    false
                })
                .await;
            if superseded {
                self.shared.transport.reset(&desired);
                self.shared.backend.detach_stream(&desired).await;
                continue;
            }
            self.clear_stream_startup_state(&desired).await;
        }
    }

    /// Nobody watches this device any more: stop its stream, and shut it down (on a switch) or
    /// start the idle countdown (on a detach) if Cascade booted it. A user's device is never
    /// touched.
    async fn release_device(&self, udid: &str, reason: Release) {
        let _ = self.stop_recording_if_active(udid).await;
        let (target, shared) = (udid.to_owned(), self.shared.clone());
        let (busy, attached) = self
            .with(move |state| (state.is_busy(&shared.transport, &target), state.is_attached_anywhere(&target)))
            .await;
        if busy {
            return;
        }
        if attached {
            // Only another owner's agent attachment is left, which keeps nothing up: the device
            // keeps its stream for that pane, and idles off after the grace.
            self.update_idle_timer(udid).await;
            return;
        }
        if self.shared.transport.subscriber_count(udid) == 0 {
            let _ = self.stop_stream(udid).await;
        }
        let target = udid.to_owned();
        if !self.with(move |state| state.owns(&target)).await {
            return;
        }
        if reason == Release::Switched {
            self.clear_idle_timer(udid).await;
            // The cap is three, and each costs gigabytes: a switch frees the slot at once.
            let _ = self.shutdown(udid).await;
            return;
        }
        self.update_idle_timer(udid).await;
    }

    async fn shutdown_if_still_idle(&self, udid: &str) {
        let (target, shared) = (udid.to_owned(), self.shared.clone());
        // Re-checked at fire time: a consumer may have arrived during the wait.
        let idle = self
            .with(move |state| !state.disposed && !state.is_busy(&shared.transport, &target) && state.owns(&target))
            .await;
        if idle {
            let _ = self.shutdown_inner(udid, true).await;
        }
    }

    async fn clear_idle_timer(&self, udid: &str) {
        let target = udid.to_owned();
        self.with(move |state| {
            state.idle.remove(&target);
        })
        .await;
    }

    async fn stop_recording_if_active(&self, udid: &str) -> DeviceResult<()> {
        let target = udid.to_owned();
        if !self.with(move |state| state.recording.contains(&target)).await {
            return Ok(());
        }
        self.stop_recording(udid).await.map(|_| ())
    }

    // ── Control plane ──────────────────────────────────────────────────

    pub async fn tap(&self, udid: &str, x: f64, y: f64, hold_ms: Option<u32>) -> DeviceResult<()> {
        self.with_device_action(udid, self.shared.backend.tap(udid, x, y, hold_ms)).await
    }

    pub async fn swipe(&self, udid: &str, gesture: DeviceSwipeGesture) -> DeviceResult<()> {
        self.with_device_action(udid, self.shared.backend.swipe(udid, gesture)).await
    }

    pub async fn type_text(&self, udid: &str, text: &str) -> DeviceResult<DeviceTypeTextOutcome> {
        self.with_device_action(udid, self.shared.backend.type_text(udid, text)).await
    }

    pub async fn key_event(&self, udid: &str, event: &DeviceKeyEvent) -> DeviceResult<()> {
        self.with_device_action(udid, self.shared.backend.key_event(udid, event)).await
    }

    pub async fn press_button(&self, udid: &str, button: DeviceHardwareButton) -> DeviceResult<()> {
        self.with_device_action(udid, self.shared.backend.press_button(udid, button)).await
    }

    pub async fn install(&self, udid: &str, app_path: &str) -> DeviceResult<DeviceInstallAppResult> {
        self.with_device_action(udid, self.shared.backend.install(udid, app_path)).await
    }

    pub async fn launch(
        &self,
        udid: &str,
        bundle_id: &str,
        arguments: &[String],
        options: &DeviceLaunchOptions,
    ) -> DeviceResult<DeviceLaunchAppResult> {
        self.with_device_action(udid, self.shared.backend.launch(udid, bundle_id, arguments, options)).await
    }

    pub async fn configure(&self, udid: &str, configuration: &DeviceConfiguration) -> DeviceResult<()> {
        self.with_device_action(udid, self.shared.backend.configure(udid, configuration)).await
    }

    pub async fn read_logs(&self, udid: &str, query: &DeviceLogQuery) -> DeviceResult<DeviceLogResult> {
        self.with_device_action(udid, self.shared.backend.read_logs(udid, query)).await
    }

    pub async fn open_url(&self, udid: &str, url: &str) -> DeviceResult<()> {
        self.with_device_action(udid, self.shared.backend.open_url(udid, url)).await
    }

    pub async fn screenshot(&self, udid: &str, options: DeviceScreenshotOptions) -> DeviceResult<DeviceScreenshotCapture> {
        self.with_device_action(udid, self.shared.backend.screenshot(udid, options)).await
    }

    pub async fn describe_ui(&self, udid: &str) -> DeviceResult<DeviceDescribeUiResult> {
        self.with_device_action(udid, self.shared.backend.describe_ui(udid)).await
    }

    pub async fn start_recording(&self, udid: &str) -> DeviceResult<DeviceStartRecordingResult> {
        self.ensure_live().await?;
        let target = udid.to_owned();
        let already = self
            .with(move |state| {
                state.idle.remove(&target);
                !state.recording.insert(target)
            })
            .await;
        let started = self.with_device_action(udid, self.shared.backend.start_recording(udid)).await;
        if started.is_err() {
            let (target, shared) = (udid.to_owned(), self.shared.clone());
            self.with(move |state| {
                if !already {
                    state.recording.remove(&target);
                }
                state.update_idle(&shared.transport, &target, shared.idle_shutdown);
            })
            .await;
        }
        started
    }

    pub async fn stop_recording(&self, udid: &str) -> DeviceResult<DeviceStopRecordingResult> {
        let result = self.shared.backend.stop_recording(udid).await?;
        let (target, shared) = (udid.to_owned(), self.shared.clone());
        self.with(move |state| {
            state.recording.remove(&target);
            state.update_idle(&shared.transport, &target, shared.idle_shutdown);
        })
        .await;
        Ok(result)
    }

    /// The screen in points: the helper's geometry when attached, else the tree's root.
    pub async fn point_size(&self, udid: &str) -> Option<(f64, f64)> {
        if let Some(geometry) = self.shared.backend.geometry(udid) {
            return Some((geometry.point_width, geometry.point_height));
        }
        let tree = self.describe_ui(udid).await.ok()?;
        (tree.root.frame.width > 0.0 && tree.root.frame.height > 0.0).then_some((tree.root.frame.width, tree.root.frame.height))
    }

    // ── Targeting ──────────────────────────────────────────────────────

    /// Taps the element a target names, scrolling it into view first. The tree is read fresh: a
    /// stale frame is how a tap lands on whatever scrolled into that position instead.
    pub async fn tap_element(
        &self,
        udid: &str,
        target: &DeviceUiTarget,
        max_scrolls: Option<u32>,
        hold_ms: Option<u32>,
    ) -> Result<TargetMatch, DeviceError> {
        let found = self.scroll_to_element(udid, target, max_scrolls).await?;
        self.with_device_action(udid, self.shared.backend.tap(udid, found.point.x, found.point.y, hold_ms)).await?;
        Ok(found)
    }

    /// Brings the element a target names into the tappable band and returns it. A target missing
    /// from the tree is "not reached yet" (long lists are virtualized), so the loop pages down
    /// while it is absent and only reports it missing once the list stops moving.
    pub async fn scroll_to_element(
        &self,
        udid: &str,
        target: &DeviceUiTarget,
        max_scrolls: Option<u32>,
    ) -> Result<TargetMatch, DeviceError> {
        let max_scrolls = max_scrolls.unwrap_or(DEVICE_DEFAULT_MAX_SCROLLS);
        let mut tree = self.describe_ui(udid).await?;
        let mut found = locate(&tree.root, target)?.map(|(found, _)| found);
        let mut previous_position: Option<String> = None;

        for scrolls in 0..max_scrolls {
            // Nothing to aim at yet: page down a screenful to materialize more of the list.
            let step = match &found {
                None => Some(page_down_step(&tree.root)),
                Some(found) => plan_scroll_step(&found.node, &tree.root)?.map(|step| DeviceSwipeGesture {
                    from_x: step.from_x,
                    from_y: step.from_y,
                    to_x: step.to_x,
                    to_y: step.to_y,
                    duration_ms: step.duration_ms,
                    edge: None,
                }),
            };
            let Some(step) = step else {
                return Ok(found.expect("a step is only skipped for a match"));
            };

            let position_before = found.as_ref().map(|found| found.node.frame.y);
            self.with_device_action(udid, self.shared.backend.swipe(udid, step)).await?;
            tree = self.describe_ui(udid).await?;
            let located = locate(&tree.root, target)?;
            // Fixed chrome (a navigation bar's back button, a tab bar) sits outside the band by
            // design and does not scroll: tapped in place once a swipe shows it does not move.
            if let Some((candidate, fixed_chrome)) = &located {
                if candidate.on_screen && Some(candidate.node.frame.y) == position_before && *fixed_chrome {
                    return Ok(candidate.clone());
                }
            }
            found = located.map(|(found, _)| found);

            // A list at its end keeps rendering the same thing; compared across the visible labels
            // as well as the target's own position, since an absent target has none.
            let position = match &found {
                None => visible_labels(&tree.root).join("|"),
                Some(found) => format!("y:{}", found.node.frame.y),
            };
            if previous_position.as_ref() == Some(&position) {
                let message = match &found {
                    None => format!("No element {} appeared after scrolling to the end of the screen.", target_phrase(target)),
                    Some(_) => format!(
                        "Scrolling stopped moving {} after {} swipe{}; the list appears to be at its end and the element is \
                         still out of reach.",
                        describe_target(target),
                        scrolls + 1,
                        if scrolls == 0 { "" } else { "s" }
                    ),
                };
                let candidates = if found.is_none() { visible_labels(&tree.root) } else { Vec::new() };
                return Err(DeviceUiTargetError::new(message, candidates, found.is_none()).into());
            }
            previous_position = Some(position);
        }

        if let Some(found) = &found {
            if plan_scroll_step(&found.node, &tree.root)?.is_none() {
                return Ok(found.clone());
            }
        }
        let candidates = if found.is_none() { visible_labels(&tree.root) } else { Vec::new() };
        Err(DeviceUiTargetError::new(
            format!(
                "Could not bring {} into view within {max_scrolls} swipes. Raise maxSwipes, or scroll manually with \
                 device_swipe if it sits in a nested scroll area.",
                describe_target(target)
            ),
            candidates,
            found.is_none(),
        )
        .into())
    }

    // ── Text ───────────────────────────────────────────────────────────

    /// Puts text into the focused field exactly: keystrokes for ASCII on a US layout, otherwise
    /// the field's value through accessibility, which carries any Unicode. Trailing newlines
    /// become a Return press either way.
    pub async fn enter_text(&self, udid: &str, text: &str, options: TextEntryOptions) -> Result<TextEntryOutcome, DeviceError> {
        let body = text.trim_end_matches('\n');
        let submit = options.submit || body.len() != text.len();
        let printable_ascii = body.chars().all(|c| matches!(c, '\x20'..='\x7e' | '\t' | '\n'));
        let method = match options.method {
            TextMethod::Keys => {
                if !printable_ascii {
                    return Err(DeviceBackendError::new(
                        "method \"keys\" types printable ASCII only; use method \"value\" (or \"auto\") for this text.",
                    )
                    .into());
                }
                EnteredBy::Keys
            }
            TextMethod::Value => EnteredBy::Value,
            TextMethod::Auto => {
                if printable_ascii
                    && self
                        .with_device_action(udid, async { Ok(self.shared.backend.uses_us_keyboard_layout(udid).await) })
                        .await
                        .unwrap_or(false)
                {
                    EnteredBy::Keys
                } else {
                    EnteredBy::Value
                }
            }
        };

        if method == EnteredBy::Value && !body.is_empty() {
            let tree = self.describe_ui(udid).await?;
            let Some(focused) = find_focused_node(&tree.root) else {
                return Err(DeviceUiTargetError::new(
                    "No element has keyboard focus, so there is nowhere to put the text. Tap the field first, then retry.",
                    Vec::new(),
                    false,
                )
                .into());
            };
            if is_secure_field(focused) && !options.clear {
                return Err(DeviceBackendError::new(
                    "Secure fields cannot be appended to through accessibility; pass clear: true to replace the whole value.",
                )
                .into());
            }
            let current = if options.clear { "" } else { effective_value(focused).unwrap_or("") };
            let value = format!("{current}{body}");
            self.with_device_action(udid, self.shared.backend.set_focused_value(udid, &value)).await?;
        }
        if method == EnteredBy::Keys {
            if options.clear {
                self.press_key(udid, HID_A, vec![DeviceKeyModifier::Command]).await?;
                self.press_key(udid, HID_DELETE, Vec::new()).await?;
            }
            if !body.is_empty() {
                let outcome = self.with_device_action(udid, self.shared.backend.type_text(udid, body)).await?;
                if outcome.skipped > 0 {
                    return Err(DeviceBackendError::new(format!(
                        "{} character(s) have no key and were not typed; retry with method \"value\".",
                        outcome.skipped
                    ))
                    .into());
                }
            }
        } else if body.is_empty() && options.clear {
            self.with_device_action(udid, self.shared.backend.set_focused_value(udid, "")).await?;
        }
        if submit {
            self.press_key(udid, HID_RETURN, Vec::new()).await?;
        }
        Ok(TextEntryOutcome { method, submitted: submit })
    }

    async fn press_key(&self, udid: &str, key_code: u16, modifiers: Vec<DeviceKeyModifier>) -> DeviceResult<()> {
        let down = DeviceKeyEvent { key_code, modifiers: modifiers.clone(), direction: DeviceKeyDirection::Down };
        self.with_device_action(udid, self.shared.backend.key_event(udid, &down)).await?;
        let up = DeviceKeyEvent { key_code, modifiers, direction: DeviceKeyDirection::Up };
        self.with_device_action(udid, self.shared.backend.key_event(udid, &up)).await
    }

    // ── Observation ────────────────────────────────────────────────────

    /// Waits until the screen stops changing, or the deadline passes. A read failing
    /// mid-transition counts as change rather than as an error.
    pub async fn wait_for_settle(&self, udid: &str, quiet: Option<Duration>, timeout: Option<Duration>) -> SettleOutcome {
        let quiet = quiet.unwrap_or(SETTLE_QUIET);
        let timeout = timeout.unwrap_or(SETTLE_TIMEOUT);
        let started = Instant::now();
        tokio::time::sleep(SETTLE_START_DELAY.min(timeout)).await;
        let mut root: Option<DeviceUiNode> = None;
        let mut fingerprint: Option<String> = None;
        let mut stable_since = Instant::now();
        loop {
            let read = self.describe_ui(udid).await.ok();
            let next = read.as_ref().map(|read| ui_fingerprint(&read.root));
            if let Some(read) = read {
                root = Some(read.root);
            }
            if next.is_none() || next != fingerprint {
                fingerprint = next;
                stable_since = Instant::now();
            } else if stable_since.elapsed() >= quiet {
                return SettleOutcome { settled: true, waited: started.elapsed(), root };
            }
            if started.elapsed() >= timeout {
                return SettleOutcome { settled: false, waited: started.elapsed(), root };
            }
            tokio::time::sleep(SETTLE_POLL).await;
        }
    }

    /// Runs an action and reports what it did to the screen: the settled tree and whether it
    /// differs from just before. An unchanged screen after a tap is the clearest sign it missed.
    pub async fn observe<T, F>(&self, udid: &str, action: F, options: ObserveOptions) -> Result<(T, Observation), DeviceError>
    where
        F: std::future::Future<Output = Result<T, DeviceError>>,
    {
        let before_tree = self.describe_ui(udid).await.ok();
        let before = before_tree.as_ref().map(|tree| ui_fingerprint(&tree.root));
        let value = action.await?;
        let acted = Instant::now();
        if let Some(mode) = options.await_app {
            let previous = before_tree.as_ref().and_then(|tree| tree.root.label.clone());
            let transitioned = self.wait_for_app(udid, previous.as_deref(), before.as_deref(), mode).await;
            if !transitioned {
                let root = self.describe_ui(udid).await.ok().map(|tree| tree.root);
                return Ok((value, Observation { settled: false, waited: acted.elapsed(), root, changed: None }));
            }
        } else if let Some(before) = &before {
            let grace = if options.await_change { options.timeout.unwrap_or(SETTLE_CHANGE_GRACE) } else { SETTLE_CHANGE_GRACE };
            let changed = self.wait_for_change(udid, before, grace).await;
            if options.await_change && !changed {
                let root = self.describe_ui(udid).await.ok().map(|tree| tree.root);
                return Ok((value, Observation { settled: false, waited: acted.elapsed(), root, changed: Some(false) }));
            }
        }
        let settled = self.wait_for_settle(udid, options.quiet, options.timeout).await;
        let after = settled.root.as_ref().map(ui_fingerprint);
        let changed = before.zip(after).map(|(before, after)| before != after);
        // From the end of the action, so a slow-starting transition counts.
        Ok((value, Observation { settled: settled.settled, waited: acted.elapsed(), root: settled.root, changed }))
    }

    /// Polls until the screen differs from `baseline`, for at most `timeout`.
    async fn wait_for_change(&self, udid: &str, baseline: &str, timeout: Duration) -> bool {
        let started = Instant::now();
        while started.elapsed() < timeout {
            if let Ok(tree) = self.describe_ui(udid).await {
                if ui_fingerprint(&tree.root) != baseline {
                    return true;
                }
            }
            tokio::time::sleep(SETTLE_POLL).await;
        }
        false
    }

    /// Polls until an app is in front (the root carries a name; SpringBoard and the launch
    /// transition do not) and, in `Different` mode, it is not the one in front before.
    async fn wait_for_app(&self, udid: &str, previous: Option<&str>, baseline: Option<&str>, mode: AwaitApp) -> bool {
        let started = Instant::now();
        let mut transitioned = baseline.is_none();
        let previous = previous.map(str::trim);
        while started.elapsed() < APP_CHANGE_TIMEOUT {
            let tree = self.describe_ui(udid).await.ok();
            let label = tree
                .as_ref()
                .and_then(|tree| tree.root.label.as_deref())
                .map(str::trim)
                .filter(|label| !label.is_empty())
                .map(str::to_owned);
            if tree.is_none()
                || label.is_none()
                || baseline.is_some_and(|baseline| tree.as_ref().is_some_and(|tree| ui_fingerprint(&tree.root) != baseline))
            {
                transitioned = true;
            }
            if let Some(label) = &label {
                let arrived = match mode {
                    AwaitApp::Different => Some(label.as_str()) != previous,
                    AwaitApp::Any => transitioned,
                };
                if arrived {
                    return true;
                }
            }
            tokio::time::sleep(SETTLE_POLL).await;
        }
        false
    }

    /// Waits for an element to appear (or, with `gone`, to disappear) without sending input.
    /// Ambiguity proves presence, so it ends a presence wait.
    pub async fn wait_for(&self, udid: &str, target: &DeviceUiTarget, gone: bool, timeout: Duration) -> WaitOutcome {
        let started = Instant::now();
        let timeout = timeout.min(DEVICE_WAIT_MAX);
        let mut root: Option<DeviceUiNode> = None;
        loop {
            if let Ok(read) = self.describe_ui(udid).await {
                let mut found: Option<TargetMatch> = None;
                let mut ambiguous = false;
                match find_target(&read.root, target) {
                    Ok(candidate) => {
                        found = candidate.on_screen.then(|| TargetMatch {
                            point: candidate.point,
                            node: candidate.node.clone(),
                            on_screen: candidate.on_screen,
                        })
                    }
                    Err(error) => ambiguous = !error.not_found,
                }
                root = Some(read.root);
                let present = found.is_some() || ambiguous;
                if if gone { !present } else { present } {
                    let status = if ambiguous && !gone { WaitStatus::Ambiguous } else { WaitStatus::Ready };
                    return WaitOutcome { status, waited: started.elapsed(), root, found };
                }
            }
            if started.elapsed() >= timeout {
                return WaitOutcome { status: WaitStatus::Timeout, waited: started.elapsed(), root, found: None };
            }
            tokio::time::sleep(WAIT_POLL).await;
        }
    }

    // ── Agent integration ──────────────────────────────────────────────

    /// Wraps one agent-driven action so the pane shows its "agent is using this device" badge for
    /// exactly as long as it runs. Nested calls are counted. With a device, the call also counts as
    /// that device's use, waits out an idle poweroff before it acts, and leases the device to the
    /// caller's turn until `end_agent_turn` says it settled. Fails only when the manager is
    /// disposed, or a device's restoration after a poweroff fails.
    pub async fn with_agent_activity<T>(
        &self,
        owner: &str,
        device_use: Option<DeviceUse>,
        action: impl std::future::Future<Output = T>,
    ) -> DeviceResult<T> {
        let key = owner.to_owned();
        let leased = device_use.clone();
        let admitted = self
            .with(move |state| {
                if state.disposed {
                    return None;
                }
                if let Some(DeviceUse { udid, turn, .. }) = leased {
                    state.begin_action(&udid);
                    // A call landing after its turn settled leases nothing: its terminal event
                    // already released the turn, and a newer turn holds its own lease.
                    if let Some(turn) = turn.filter(|turn| !state.ended_turns.contains(turn)) {
                        // A call of the turn is running: its lease does not lapse under it.
                        state.lapses.remove(&turn);
                        if !state.lease_marks.contains_key(&turn) {
                            state.next_id += 1;
                            let mark = state.next_id;
                            state.lease_marks.insert(turn.clone(), mark);
                        }
                        state.owner(&key).agent_turns.entry(turn).or_default().insert(udid);
                    }
                }
                let attachment = state.owner(&key);
                let became_active = attachment.agent_active == 0;
                attachment.agent_active += 1;
                Some((attachment.epoch, became_active))
            })
            .await;
        let Some((epoch, became_active)) = admitted else { return Err(disposed_error()) };
        let udid = device_use.as_ref().map(|device_use| device_use.udid.clone());
        let mut guard = ActivityGuard { manager: Some(self.clone()), owner: owner.to_owned(), epoch, device_use: device_use.clone() };
        let outcome = async {
            if let Some(udid) = &udid {
                self.wait_for_idle_shutdown(udid).await?;
            }
            // The 0→1 edge was taken before the wait: overlapping calls may already be counted.
            // Only the badge changes here; the device list the pane shows does not.
            let key = owner.to_owned();
            if became_active && self.with(move |state| state.is_current(&key, epoch)).await {
                self.publish(owner, true).await;
            }
            self.ensure_live().await?;
            Ok(action.await)
        }
        .await;
        guard.manager = None;
        self.end_activity(owner, epoch, device_use).await;
        outcome
    }

    async fn end_activity(&self, owner: &str, epoch: u64, device_use: Option<DeviceUse>) {
        let (key, shared) = (owner.to_owned(), self.shared.clone());
        let publish = self
            .with(move |state| {
                if let Some(DeviceUse { udid, turn, lapses }) = &device_use {
                    state.end_action(udid);
                    if let Some(turn) = turn.as_ref().filter(|turn| *lapses && state.holds_turn(turn)) {
                        state.lapses.insert(turn.clone(), Instant::now() + shared.idle_shutdown);
                    }
                    state.update_idle(&shared.transport, udid, shared.idle_shutdown);
                }
                // A removed owner, or a disposed manager, is not recreated to clear a badge.
                let current = state.is_current(&key, epoch);
                match state.owners.get_mut(&key) {
                    Some(attachment) if attachment.epoch == epoch => {
                        attachment.agent_active = attachment.agent_active.saturating_sub(1);
                        current && attachment.agent_active == 0
                    }
                    _ => false,
                }
            })
            .await;
        if publish {
            self.publish(owner, true).await;
        }
    }

    /// The turn settled: the devices it used are released, and each one nothing else uses starts
    /// its idle grace. Only that exact turn: a delayed end cannot evict a newer turn's lease.
    pub async fn end_agent_turn(&self, turn: AgentTurn) {
        let shared = self.shared.clone();
        self.with(move |state| {
            let settled = turn.clone();
            state.end_turns(&shared.transport, shared.idle_shutdown, move |held| *held == settled, Some(turn));
        })
        .await;
    }

    /// A point on the lease clock: a check that takes one before asking which turn runs releases
    /// only turns leased before it, never one leased while it asked.
    pub async fn lease_mark(&self) -> u64 {
        self.with(|state| {
            state.next_id += 1;
            state.next_id
        })
        .await
    }

    /// Every turn of `holder` but `running` that leased a device before `before` (a `lease_mark`;
    /// none for every turn) settled: the ones it still holds are released. For a caller whose end
    /// is learned as "this is the turn running now", such as a chat.
    pub async fn end_agent_turns_except(&self, holder: &str, running: Option<&str>, before: Option<u64>) {
        let (holder, running, shared) = (holder.to_owned(), running.map(str::to_owned), self.shared.clone());
        self.with(move |state| {
            let marks = state.lease_marks.clone();
            state.end_turns(
                &shared.transport,
                shared.idle_shutdown,
                move |held| {
                    held.holder == holder
                        && running.as_deref() != Some(held.id.as_str())
                        && before.is_none_or(|before| marks.get(held).is_none_or(|mark| *mark < before))
                },
                None,
            );
        })
        .await;
    }

    /// Whether any turn of `holder` still holds a device.
    pub async fn holds_agent_turns(&self, holder: &str) -> bool {
        let holder = holder.to_owned();
        self.with(move |state| {
            state.owners.values().any(|attachment| attachment.agent_turns.keys().any(|turn| turn.holder == holder))
        })
        .await
    }

    /// Asks the pane to open on a device.
    pub async fn request_open_pane(&self, owner: &str, udid: &str, reason: OpenPaneReason) {
        let (key, target) = (owner.to_owned(), udid.to_owned());
        self.with(move |state| state.owner(&key).pane_surfaced = Some(target)).await;
        self.emit(DeviceEvent::OpenPane { owner: owner.to_owned(), udid: udid.to_owned(), reason });
    }

    /// Puts the agent's device in front of the user: attaches the owner to it so the pane has
    /// something to stream, then asks the pane to open. Once per owner and device: agents call a
    /// tool every few seconds, and a request per call could yank a user who navigated away.
    pub async fn surface_device_for_agent(&self, owner: &str, udid: &str, reason: OpenPaneReason) {
        let (key, target) = (owner.to_owned(), udid.to_owned());
        if self.with(move |state| state.owner(&key).pane_surfaced.as_deref() == Some(target.as_str())).await {
            return;
        }
        self.ensure_attached(owner, udid).await;
        self.request_open_pane(owner, udid, reason).await;
    }

    pub async fn record_owner_error(&self, owner: &str, message: &str) {
        let (key, message) = (owner.to_owned(), message.to_owned());
        self.with(move |state| state.owner(&key).last_error = Some(message)).await;
        self.publish(owner, true).await;
    }

    // ── Lifecycle ──────────────────────────────────────────────────────

    /// App quit: shut down everything Cascade booted, leave the user's devices alone, and release
    /// the backend.
    pub async fn dispose(&self) {
        let pending = self
            .with(|state| {
                if state.disposed {
                    return None;
                }
                state.disposed = true;
                state.idle.clear();
                Some(state.idle_shutdowns.values().map(|(_, done)| done.clone()).collect::<Vec<_>>())
            })
            .await;
        let Some(pending) = pending else { return };
        // A poweroff or a restoring boot already under way finishes first, so what it booted is
        // among what is shut down below.
        for mut done in pending {
            let _ = done.wait_for(|done| *done).await;
        }
        // Snapshotted: both loops below change the sets they walk.
        let (recording, booted) = self
            .with(|state| {
                state.desired_stream = None;
                (state.recording.iter().cloned().collect::<Vec<_>>(), state.booted.clone())
            })
            .await;
        let _ = self.queue_stream_reconciliation().await;
        for udid in recording {
            let _ = self.stop_recording_if_active(&udid).await;
        }
        for udid in booted {
            let _ = self.shared.backend.shutdown(&udid).await;
            self.with(move |state| state.disown(&udid)).await;
        }
        // Nothing is ours any more, so a later start must not adopt these.
        self.shared.boot_ownership.clear();
        self.shared.silenced.store(true, Ordering::SeqCst);
        self.shared.transport.close();
        self.shared.backend.dispose().await;
    }

    // ── Publishing ─────────────────────────────────────────────────────

    /// Builds an owner's state. `reuse_discovery` serves the last availability and device list
    /// instead of spawning discovery again; only publishes that change nothing about the list
    /// (the badge, a recorded error) use it.
    async fn snapshot(&self, owner: &str, reuse_discovery: bool) -> OwnerDeviceState {
        let reused = if reuse_discovery { self.with(|state| state.last_discovery.clone()).await } else { None };
        let (availability, devices) = match reused {
            Some(discovery) => discovery,
            None => {
                let availability = self.shared.backend.availability().await;
                let devices = self.discover(&availability, true).await;
                let discovery = (availability, devices);
                let stored = discovery.clone();
                self.with(move |state| state.last_discovery = Some(stored)).await;
                discovery
            }
        };
        let key = owner.to_owned();
        self.with(move |state| {
            let attachment = state.owner(&key);
            OwnerDeviceState {
                owner: key.clone(),
                version: attachment.version,
                attached_device_udid: attachment.attached.clone(),
                attach_phase: attachment.phase,
                devices: fit_device_list(devices, attachment.attached.as_deref()),
                agent_active: attachment.agent_active > 0,
                availability,
                last_error: attachment.last_error.as_deref().map(fit_device_message),
            }
        })
        .await
    }

    async fn publish(&self, owner: &str, reuse_discovery: bool) -> OwnerDeviceState {
        let key = owner.to_owned();
        self.with(move |state| state.owner(&key).version += 1).await;
        let state = self.snapshot(owner, reuse_discovery).await;
        self.emit(DeviceEvent::State { owner: owner.to_owned(), state: state.clone() });
        state
    }

    /// A boot or shutdown changes the device list every open pane shows.
    async fn publish_all(&self) {
        let owners: Vec<String> = self.with(|state| state.owners.keys().cloned().collect()).await;
        for owner in owners {
            self.publish(&owner, false).await;
        }
    }
}

/// The state task: runs each step it is sent, and shuts down idle devices when their time comes.
async fn run_state(mut ops: mpsc::UnboundedReceiver<Op>, shared: Weak<Shared>) {
    let mut state = State::default();
    loop {
        let next = state.idle.values().chain(state.lapses.values()).min().copied();
        let idle = async move {
            match next {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            op = ops.recv() => match op {
                Some(op) => op(&mut state),
                None => return,
            },
            () = idle => {
                let now = Instant::now();
                let due: Vec<String> = state.idle.iter().filter(|(_, at)| **at <= now).map(|(udid, _)| udid.clone()).collect();
                for udid in &due {
                    state.idle.remove(udid);
                }
                let lapsed: Vec<AgentTurn> = state.lapses.iter().filter(|(_, at)| **at <= now).map(|(turn, _)| turn.clone()).collect();
                let Some(shared) = shared.upgrade() else {
                    for turn in &lapsed {
                        state.lapses.remove(turn);
                    }
                    continue;
                };
                if !lapsed.is_empty() {
                    state.lapse_turns(&shared.transport, shared.idle_shutdown, &lapsed);
                }
                for udid in due {
                    // Registered in this step, so a consumer arriving from now on waits it out.
                    state.next_id += 1;
                    let id = state.next_id;
                    let (done, receiver) = watch::channel(false);
                    state.idle_shutdowns.insert(udid.clone(), (id, receiver));
                    let manager = DeviceManager { shared: shared.clone() };
                    tokio::spawn(async move {
                        manager.shutdown_if_still_idle(&udid).await;
                        let target = udid.clone();
                        manager
                            .with(move |state| {
                                if state.idle_shutdowns.get(&target).is_some_and(|(held, _)| *held == id) {
                                    state.idle_shutdowns.remove(&target);
                                }
                            })
                            .await;
                        let _ = done.send(true);
                    });
                }
            }
        }
    }
}

/// The match, or none when the target has not been rendered into the tree yet; with whether it
/// sits in fixed chrome. Only absence means "keep scrolling": an ambiguity is an answer.
fn locate(root: &DeviceUiNode, target: &DeviceUiTarget) -> Result<Option<(TargetMatch, bool)>, DeviceUiTargetError> {
    match find_target(root, target) {
        Ok(found) => {
            let fixed_chrome = is_fixed_chrome(root, found.node, false);
            Ok(Some((TargetMatch { point: found.point, node: found.node.clone(), on_screen: found.on_screen }, fixed_chrome)))
        }
        Err(error) if error.not_found => Ok(None),
        Err(error) => Err(error),
    }
}

/// Whether `target` sits inside a navigation bar or tab bar.
fn is_fixed_chrome(node: &DeviceUiNode, target: &DeviceUiNode, chrome: bool) -> bool {
    let owns_chrome = chrome
        || chrome_pattern().is_match(&node.role)
        || chrome_pattern().is_match(node.subrole.as_deref().unwrap_or(""));
    if std::ptr::eq(node, target) {
        return owns_chrome;
    }
    node.children.iter().any(|child| is_fixed_chrome(child, target, owns_chrome))
}

/// A blind screenful downward, for when the target has not appeared yet.
fn page_down_step(root: &DeviceUiNode) -> DeviceSwipeGesture {
    let mid_x = root.frame.x + root.frame.width / 2.0;
    let centre = root.frame.y + root.frame.height / 2.0;
    let distance = root.frame.height * 0.6;
    DeviceSwipeGesture {
        from_x: mid_x,
        from_y: centre + distance / 2.0,
        to_x: mid_x,
        to_y: centre - distance / 2.0,
        duration_ms: SCROLL_SWIPE_DURATION_MS,
        edge: None,
    }
}

/// Keeps an owner's device list within the contract's cap: the attached device first, then booted
/// ones, then the rest.
fn fit_device_list(devices: Vec<DeviceDescriptor>, attached: Option<&str>) -> Vec<DeviceDescriptor> {
    if devices.len() <= DEVICE_THREAD_STATE_MAX_DEVICES {
        return devices;
    }
    let rank = |device: &DeviceDescriptor| {
        if Some(device.udid.as_str()) == attached {
            0
        } else if device.state == DeviceRuntimeState::Shutdown {
            2
        } else {
            1
        }
    };
    let mut devices = devices;
    devices.sort_by_key(rank);
    devices.truncate(DEVICE_THREAD_STATE_MAX_DEVICES);
    devices
}
