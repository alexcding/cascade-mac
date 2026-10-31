//! The device manager against the fake backend. Ported from Synara's `DeviceManager.test.ts`,
//! `DeviceManager.streamOwnership.test.ts`, `DeviceManager.coldBoot.test.ts`, the logic half of
//! `DeviceManager.contractLimits.test.ts`, and `DeviceManager.observation.test.ts`. Every test runs
//! on paused Tokio time, which advances exactly as far as the manager waits, so settle deadlines
//! are exact and nothing sleeps for real.

use std::{
    sync::{
        atomic::{AtomicI32, AtomicU32, Ordering},
        Arc,
    },
    time::Duration,
};

use tokio::sync::{broadcast, Notify};

use super::fake::{frame, node, FakeCall, FakeDeviceBackend, Seed, DEVICE_A, DEVICE_B, DEVICE_C, DEVICE_D, FAKE_GEOMETRY};
use crate::device::{
    backend::{DeviceBackend, DeviceBackendError, DeviceKeyDirection},
    boot_ownership::BootOwnershipStore,
    contracts::{
        DeviceAttachPhase, DeviceAvailability, DeviceBootSource, DeviceRuntimeState, DeviceKeyModifier, DeviceSetupStep, DeviceSetupStepId,
        DEVICE_MESSAGE_MAX_LENGTH, DEVICE_THREAD_STATE_MAX_DEVICES,
    },
    manager::{
        AgentTurn, AwaitApp, DeviceBootResult, DeviceUse, DeviceError, DeviceEvent, DeviceManager, DeviceManagerOptions, EnteredBy, ObserveOptions,
        OpenPaneReason, OwnerDeviceState, TextEntryOptions, TextMethod, WaitStatus, DEVICE_IDLE_SHUTDOWN,
    },
    ui_targeting::DeviceUiTarget,
};

const OWNER_A: &str = "/work/a";
const OWNER_B: &str = "/work/b";
/// The cold-boot failure: booted, but no display published yet.
const NO_DISPLAY: &str = "display has no framebuffer surface yet";

/// A manager whose first attach failure is final unless a test asks for retries.
fn manager_with(backend: &Arc<FakeDeviceBackend>, configure: impl FnOnce(&mut DeviceManagerOptions)) -> DeviceManager {
    let mut options = DeviceManagerOptions::new(backend.clone());
    options.attach_deadline = Duration::ZERO;
    options.attach_retry = Duration::from_millis(1);
    configure(&mut options);
    DeviceManager::new(options)
}

fn setup() -> (Arc<FakeDeviceBackend>, DeviceManager) {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |_| {});
    (backend, manager)
}

/// A manager on a booted device A, for the observation tests.
async fn booted() -> (Arc<FakeDeviceBackend>, DeviceManager) {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    (backend, manager)
}

async fn until(what: &str, mut check: impl FnMut() -> bool) {
    for _ in 0..2_000 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    panic!("never observed: {what}");
}

async fn until_state(manager: &DeviceManager, owner: &str, check: impl Fn(&OwnerDeviceState) -> bool) -> OwnerDeviceState {
    for _ in 0..2_000 {
        let state = manager.owner_state(owner).await;
        if check(&state) {
            return state;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    panic!("{owner} never reached the expected device state");
}

/// Lets whatever the background attach and stream tasks are doing finish.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(20)).await;
}

fn drain(events: &mut broadcast::Receiver<DeviceEvent>) -> Vec<DeviceEvent> {
    let mut drained = Vec::new();
    while let Ok(event) = events.try_recv() {
        drained.push(event);
    }
    drained
}

fn open_pane_udids(events: &[DeviceEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|event| match event {
            DeviceEvent::OpenPane { udid, .. } => Some(udid.clone()),
            DeviceEvent::State { .. } => None,
        })
        .collect()
}

fn label(text: &str) -> DeviceUiTarget {
    DeviceUiTarget { label: Some(text.into()), ..DeviceUiTarget::default() }
}

fn identifier(text: &str) -> DeviceUiTarget {
    DeviceUiTarget { identifier: Some(text.into()), ..DeviceUiTarget::default() }
}

fn ownership_store() -> (tempfile::TempDir, BootOwnershipStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = BootOwnershipStore::new(dir.path().join("boot-ownership.json"), 4_242);
    (dir, store)
}

// ── Attachment ─────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn attaches_an_owner_to_one_device_and_streams_it() {
    let (backend, manager) = setup();
    let mut events = manager.subscribe();
    backend.boot(DEVICE_A).await.unwrap();

    let state = manager.attach(OWNER_A, DEVICE_A).await;

    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_A));
    assert_eq!(state.owner, OWNER_A);
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    assert!(matches!(drain(&mut events).last(), Some(DeviceEvent::State { .. })));
}

#[tokio::test(start_paused = true)]
async fn versions_owner_states_monotonically_so_panes_can_drop_stale_pushes() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();

    let first = manager.attach(OWNER_A, DEVICE_A).await;
    let second = manager.detach(OWNER_A).await;
    let third = manager.attach(OWNER_A, DEVICE_A).await;

    assert!(second.version > first.version);
    assert!(third.version > second.version);
}

#[tokio::test(start_paused = true)]
async fn replaces_the_previous_device_when_an_owner_attaches_to_another() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    backend.boot(DEVICE_B).await.unwrap();

    manager.attach(OWNER_A, DEVICE_A).await;
    until("A streaming", || backend.has_stream(DEVICE_A)).await;
    let state = manager.attach(OWNER_A, DEVICE_B).await;

    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_B));
    until("B replacing A", || backend.has_stream(DEVICE_B) && !backend.has_stream(DEVICE_A)).await;
}

#[tokio::test(start_paused = true)]
async fn keeps_the_stream_alive_while_another_owner_is_still_attached() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();

    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    manager.attach(OWNER_B, DEVICE_A).await;
    manager.detach(OWNER_A).await;
    settle().await;

    assert!(backend.has_stream(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn keeps_the_attachment_when_the_stream_fails_to_start_and_records_the_error() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    backend.fail_next("attachStream", DeviceBackendError::new("helper is not built"));

    let state = manager.attach(OWNER_A, DEVICE_A).await;
    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_A));

    // A permanent refusal is reported without waiting out the retry deadline.
    let settled = until_state(&manager, OWNER_A, |state| state.last_error.is_some()).await;
    assert_eq!(settled.last_error.as_deref(), Some("helper is not built"));
    assert_eq!(settled.attached_device_udid.as_deref(), Some(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn detaches_and_forgets_an_owner_that_is_removed() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;

    manager.handle_owner_removed(OWNER_A).await;

    assert_eq!(manager.owner_state(OWNER_A).await.attached_device_udid, None);
    until("the stream to stop", || !backend.has_stream(DEVICE_A)).await;
}

// ── Discovery before the helper exists ─────────────────────────────────

fn setup_required() -> DeviceAvailability {
    DeviceAvailability::SetupRequired {
        steps: vec![
            DeviceSetupStep { id: DeviceSetupStepId::InstallXcode, label: "Install Xcode".into(), done: true, detail: None },
            DeviceSetupStep {
                id: DeviceSetupStepId::BuildDeviceHelper,
                label: "Build the Cascade device helper".into(),
                done: false,
                detail: None,
            },
        ],
    }
}

#[tokio::test(start_paused = true)]
async fn lists_devices_while_the_helper_build_is_still_outstanding() {
    let backend = FakeDeviceBackend::with_availability(setup_required());
    let manager = manager_with(&backend, |_| {});

    let result = manager.list(true).await;

    // The helper is built on first attach, and attaching needs a udid from this list.
    assert!(result.devices.iter().any(|device| device.udid == DEVICE_A));
    assert_eq!(result.availability, setup_required());
}

#[tokio::test(start_paused = true)]
async fn reports_no_devices_off_a_supported_platform() {
    let unsupported = DeviceAvailability::UnsupportedPlatform { platform: "linux".into() };
    let backend = FakeDeviceBackend::with_availability(unsupported.clone());
    let manager = manager_with(&backend, |_| {});

    let result = manager.list(true).await;
    assert!(result.devices.is_empty());
    assert_eq!(result.availability, unsupported);
    assert!(manager.owner_state(OWNER_A).await.devices.is_empty());
}

#[tokio::test(start_paused = true)]
async fn degrades_to_an_empty_list_when_discovery_itself_fails() {
    let backend = FakeDeviceBackend::with_availability(setup_required());
    backend.set_fail_listing(true);
    let manager = manager_with(&backend, |_| {});

    let result = manager.list(false).await;

    assert!(result.devices.is_empty());
    assert_eq!(result.availability, setup_required());
}

// ── Keyframe resync ────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn rebuilds_the_capture_session_so_the_encoder_emits_new_parameter_sets() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    let _viewer = manager.subscribe_frames(DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;

    manager.request_keyframe(DEVICE_A).await.unwrap();

    assert_eq!(backend.count("detachStream"), 1);
    assert_eq!(backend.count("attachStream"), 2);
    assert!(backend.has_stream(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn does_not_restart_the_stream_on_a_plain_reattach() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;

    manager.attach(OWNER_A, DEVICE_A).await;
    settle().await;

    assert_eq!(backend.count("attachStream"), 1);
}

#[tokio::test(start_paused = true)]
async fn drops_cached_frames_so_a_late_viewer_cannot_get_a_stale_keyframe() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    backend.emit_frame(DEVICE_A, true, false).unwrap();
    until("the keyframe cached", || manager.transport().has_keyframe(DEVICE_A)).await;
    let _first = manager.subscribe_frames(DEVICE_A).await;
    settle().await;

    manager.request_keyframe(DEVICE_A).await.unwrap();
    let _late = manager.subscribe_frames(DEVICE_A).await;

    assert!(!manager.transport().has_keyframe(DEVICE_A));
    assert!(manager.transport().stats_for(DEVICE_A).iter().all(|viewer| viewer.queued == 0));
}

#[tokio::test(start_paused = true)]
async fn requesting_a_keyframe_is_a_no_op_for_a_device_that_is_not_streaming() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();

    manager.request_keyframe(DEVICE_A).await.unwrap();

    assert_eq!(backend.count("attachStream"), 0);
}

// ── Stream transition ordering ─────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn stops_a_stream_whose_last_viewer_leaves_while_startup_is_pending() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    let (started, release) = backend.hold_attach(DEVICE_A);

    let viewer = manager.subscribe_frames(DEVICE_A).await;
    started.notified().await;
    drop(viewer);
    release.notify_one();

    until("the detach", || backend.count("detachStream") >= 1).await;
    assert!(!backend.has_stream(DEVICE_A));
    assert_eq!(backend.count("attachStream"), 1);
    assert_eq!(backend.count("detachStream"), 1);
}

#[tokio::test(start_paused = true)]
async fn lets_the_latest_device_win_when_stream_starts_overlap() {
    let (backend, manager) = setup();
    backend.boot(DEVICE_A).await.unwrap();
    backend.boot(DEVICE_B).await.unwrap();
    let (started, release) = backend.hold_attach(DEVICE_A);

    let _a = manager.subscribe_frames(DEVICE_A).await;
    started.notified().await;
    let _b = manager.subscribe_frames(DEVICE_B).await;
    release.notify_one();

    until("B streaming", || backend.has_stream(DEVICE_B)).await;
    assert!(!backend.has_stream(DEVICE_A));
    assert!(backend.udids_of("detachStream").contains(&DEVICE_A.to_owned()));
}

// ── Boot ownership ─────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn marks_devices_it_booted_as_cascades_and_leaves_discovered_ones_alone() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_B);

    let booted = manager.boot(DEVICE_A).await.unwrap();
    let listed = manager.list(false).await;

    assert!(matches!(booted, DeviceBootResult::Booted { .. }));
    let source = |udid: &str| listed.devices.iter().find(|device| device.udid == udid).map(|device| device.boot_source);
    assert_eq!(source(DEVICE_A), Some(DeviceBootSource::Cascade));
    assert_eq!(source(DEVICE_B), Some(DeviceBootSource::User));
}

#[tokio::test(start_paused = true)]
async fn refuses_to_boot_past_the_cap_and_hands_back_the_shutdown_candidates() {
    let (_backend, manager) = setup();
    for udid in [DEVICE_A, DEVICE_B, DEVICE_C] {
        manager.boot(udid).await.unwrap();
    }

    let result = manager.boot(DEVICE_D).await.unwrap();

    let DeviceBootResult::BootLimitReached { limit, cascade_booted } = result else { panic!("expected the cap") };
    assert_eq!(limit, 3);
    assert_eq!(cascade_booted.iter().map(|device| device.udid.as_str()).collect::<Vec<_>>(), [DEVICE_A, DEVICE_B, DEVICE_C]);
}

#[tokio::test(start_paused = true)]
async fn stops_counting_devices_that_were_shut_down_behind_its_back() {
    let (backend, manager) = setup();
    for udid in [DEVICE_A, DEVICE_B, DEVICE_C] {
        manager.boot(udid).await.unwrap();
        backend.shutdown_externally(udid);
    }

    assert!(matches!(manager.boot(DEVICE_D).await.unwrap(), DeviceBootResult::Booted { .. }));
}

#[tokio::test(start_paused = true)]
async fn only_offers_shutdown_candidates_that_are_actually_running() {
    let (backend, manager) = setup();
    for udid in [DEVICE_A, DEVICE_B, DEVICE_C] {
        manager.boot(udid).await.unwrap();
    }
    backend.shutdown_externally(DEVICE_B);

    let candidates: Vec<String> = manager.cascade_booted_devices().await.into_iter().map(|device| device.udid).collect();
    assert_eq!(candidates, [DEVICE_A, DEVICE_C]);
}

#[tokio::test(start_paused = true)]
async fn does_not_count_an_already_booted_device_against_the_cap() {
    let (backend, manager) = setup();
    for udid in [DEVICE_A, DEVICE_B, DEVICE_C] {
        manager.boot(udid).await.unwrap();
    }
    backend.boot_externally(DEVICE_D);

    let result = manager.boot(DEVICE_D).await.unwrap();

    assert!(matches!(result, DeviceBootResult::Booted { .. }));
    assert!(!backend.udids_of("boot").contains(&DEVICE_D.to_owned()));
}

#[tokio::test(start_paused = true)]
async fn frees_a_cap_slot_when_a_cascade_booted_device_is_shut_down() {
    let (_backend, manager) = setup();
    for udid in [DEVICE_A, DEVICE_B, DEVICE_C] {
        manager.boot(udid).await.unwrap();
    }

    manager.shutdown(DEVICE_A).await.unwrap();

    assert!(matches!(manager.boot(DEVICE_D).await.unwrap(), DeviceBootResult::Booted { .. }));
}

#[tokio::test(start_paused = true)]
async fn drops_the_attachment_of_every_owner_watching_a_device_that_shuts_down() {
    let (_backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.attach(OWNER_B, DEVICE_A).await;

    manager.shutdown(DEVICE_A).await.unwrap();

    assert_eq!(manager.owner_state(OWNER_A).await.attached_device_udid, None);
    assert_eq!(manager.owner_state(OWNER_B).await.attached_device_udid, None);
}

// ── Idle shutdown ──────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn shuts_down_a_cascade_booted_device_after_the_idle_timeout_following_detach() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.detach(OWNER_A).await;

    tokio::time::sleep(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;

    until("the idle shutdown", || backend.udids_of("shutdown") == [DEVICE_A]).await;
}

#[tokio::test(start_paused = true)]
async fn never_auto_shuts_down_a_device_the_user_booted() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.detach(OWNER_A).await;

    tokio::time::sleep(DEVICE_IDLE_SHUTDOWN * 4).await;
    settle().await;

    assert_eq!(backend.count("shutdown"), 0);
}

#[tokio::test(start_paused = true)]
async fn cancels_the_countdown_when_an_owner_reattaches_in_time() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.detach(OWNER_A).await;

    tokio::time::sleep(DEVICE_IDLE_SHUTDOWN / 2).await;
    manager.attach(OWNER_B, DEVICE_A).await;
    tokio::time::sleep(DEVICE_IDLE_SHUTDOWN * 2).await;
    settle().await;

    assert_eq!(backend.count("shutdown"), 0);
}

#[tokio::test(start_paused = true)]
async fn does_not_fire_for_a_device_that_is_still_attached_elsewhere() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.attach(OWNER_B, DEVICE_A).await;

    manager.detach(OWNER_A).await;
    tokio::time::sleep(DEVICE_IDLE_SHUTDOWN * 2).await;
    settle().await;

    assert_eq!(backend.count("shutdown"), 0);
}

// ── Agent-owned idle lifetime ──────────────────────────────────────────
// Synara `DeviceManager.test.ts` "DeviceManager agent-owned idle lifetime" (d419d5d40). Synara's
// thread is the turn's holder here; the owner is the folder whose pane shows the device.

fn turn(holder: &str, id: &str) -> AgentTurn {
    AgentTurn { holder: holder.into(), id: id.into() }
}

fn used_in(udid: &str, holder: &str, id: &str) -> Option<DeviceUse> {
    Some(DeviceUse { udid: udid.into(), turn: Some(turn(holder, id)), lapses: false })
}

/// An agent tool call that claims the device, as `device_boot` does.
async fn use_device(manager: &DeviceManager, owner: &str, udid: &str, id: &str) {
    manager.with_agent_activity(owner, used_in(udid, owner, id), manager.ensure_attached(owner, udid)).await.unwrap();
}

/// Waits for a held backend call to start; a regression that never makes it fails, not hangs.
async fn reached(what: &str, notify: &Notify) {
    tokio::time::timeout(Duration::from_secs(60), notify.notified()).await.unwrap_or_else(|_| panic!("never reached: {what}"));
}

/// Moves paused time on by `by`, letting what wakes run.
async fn advance(by: Duration) {
    tokio::time::sleep(by).await;
    tokio::task::yield_now().await;
}

#[tokio::test(start_paused = true)]
async fn waits_for_every_exact_turn_user_including_a_device_other_than_the_attached_one() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.boot(DEVICE_B).await.unwrap();
    use_device(&manager, OWNER_A, DEVICE_A, "old").await;
    use_device(&manager, OWNER_A, DEVICE_A, "new").await;
    use_device(&manager, OWNER_B, DEVICE_A, "other-thread").await;
    use_device(&manager, OWNER_A, DEVICE_B, "new").await;

    manager.end_agent_turn(turn(OWNER_A, "old")).await;
    manager.end_agent_turn(turn(OWNER_A, "old")).await;
    advance(DEVICE_IDLE_SHUTDOWN * 2).await;
    settle().await;
    assert_eq!(backend.count("shutdown"), 0);

    manager.end_agent_turn(turn(OWNER_A, "new")).await;
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("device B's idle shutdown", || backend.udids_of("shutdown") == [DEVICE_B]).await;

    manager.end_agent_turn(turn(OWNER_B, "other-thread")).await;
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("device A's idle shutdown", || backend.udids_of("shutdown") == [DEVICE_B, DEVICE_A]).await;
}

#[derive(Clone, Copy, Debug)]
enum Consumer {
    UserAttachment,
    Viewer,
    Recording,
    UserBoot,
}

#[tokio::test(start_paused = true)]
async fn preserves_each_consumer_and_starts_a_new_grace_period_only_after_its_release() {
    for consumer in [Consumer::UserAttachment, Consumer::Viewer, Consumer::Recording, Consumer::UserBoot] {
        let (backend, manager) = setup();
        if matches!(consumer, Consumer::UserBoot) {
            backend.boot_externally(DEVICE_A);
        } else {
            manager.boot(DEVICE_A).await.unwrap();
        }
        use_device(&manager, OWNER_A, DEVICE_A, "agent-turn").await;
        manager.end_agent_turn(turn(OWNER_A, "agent-turn")).await;
        advance(DEVICE_IDLE_SHUTDOWN / 2).await;

        let mut viewer = None;
        match consumer {
            Consumer::UserAttachment => {
                manager.attach(OWNER_A, DEVICE_A).await;
            }
            Consumer::Viewer => viewer = Some(manager.subscribe_frames(DEVICE_A).await),
            Consumer::Recording => {
                manager.start_recording(DEVICE_A).await.unwrap();
            }
            Consumer::UserBoot => {}
        }
        advance(DEVICE_IDLE_SHUTDOWN * 2).await;
        settle().await;
        assert_eq!(backend.count("shutdown"), 0, "{consumer:?} kept the device up");

        match consumer {
            Consumer::UserAttachment => {
                manager.detach(OWNER_A).await;
            }
            Consumer::Viewer => drop(viewer.take()),
            Consumer::Recording => {
                manager.stop_recording(DEVICE_A).await.unwrap();
            }
            Consumer::UserBoot => {}
        }
        tokio::task::yield_now().await;
        advance(DEVICE_IDLE_SHUTDOWN - Duration::from_millis(50)).await;
        assert_eq!(backend.count("shutdown"), 0, "{consumer:?}: a fresh grace period follows the release");
        advance(Duration::from_millis(100)).await;
        settle().await;
        let expected = if matches!(consumer, Consumer::UserBoot) { 0 } else { 1 };
        assert_eq!(backend.count("shutdown"), expected, "{consumer:?}");
        manager.dispose().await;
    }
}

#[tokio::test(start_paused = true)]
async fn lets_an_in_flight_tool_finish_after_its_turn_ends_without_leaking_the_settled_turn() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    let finish = Arc::new(Notify::new());
    let action = {
        let (manager, finish) = (manager.clone(), finish.clone());
        tokio::spawn(async move {
            manager.with_agent_activity(OWNER_A, used_in(DEVICE_A, OWNER_A, "ending-turn"), finish.notified()).await.unwrap()
        })
    };
    settle().await;
    manager.end_agent_turn(turn(OWNER_A, "ending-turn")).await;
    advance(DEVICE_IDLE_SHUTDOWN * 2).await;
    settle().await;
    assert_eq!(backend.count("shutdown"), 0);

    finish.notify_one();
    action.await.unwrap();
    // A late call cannot bring back a lease its turn's own end already released.
    manager.with_agent_activity(OWNER_A, used_in(DEVICE_A, OWNER_A, "ending-turn"), async {}).await.unwrap();
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the idle shutdown", || backend.count("shutdown") == 1).await;
}

#[tokio::test(start_paused = true)]
async fn rechecks_ownership_after_the_stream_teardown_before_shutting_down() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    use_device(&manager, OWNER_A, DEVICE_A, "ending-turn").await;
    until("the agent's stream", || backend.has_stream(DEVICE_A)).await;
    let (detaching, finish) = backend.hold_detach(DEVICE_A);

    manager.end_agent_turn(turn(OWNER_A, "ending-turn")).await;
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    reached("the stream teardown", &detaching).await;
    let attach = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.attach(OWNER_B, DEVICE_A).await })
    };
    let viewer = manager.subscribe_frames(DEVICE_A).await;
    settle().await;
    finish.notify_one();
    attach.await.unwrap();
    settle().await;

    assert_eq!(backend.count("shutdown"), 0);
    until("the viewer's stream", || backend.has_stream(DEVICE_A)).await;
    drop(viewer);
    assert_eq!(manager.owner_state(OWNER_B).await.attached_device_udid.as_deref(), Some(DEVICE_A));
}

/// Device A booted by Cascade, used by a turn that ended, and its idle poweroff handed to the
/// backend and held there; returns the notify that lets the poweroff finish.
async fn poweroff_under_way(backend: &Arc<FakeDeviceBackend>, manager: &DeviceManager) -> Arc<Notify> {
    manager.boot(DEVICE_A).await.unwrap();
    use_device(manager, OWNER_A, DEVICE_A, "ending-turn").await;
    let (started, finish) = backend.hold_shutdown(DEVICE_A);
    manager.end_agent_turn(turn(OWNER_A, "ending-turn")).await;
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    reached("the idle poweroff", &started).await;
    finish
}

fn lifecycle(backend: &FakeDeviceBackend) -> Vec<&'static str> {
    backend.calls().iter().map(FakeCall::kind).filter(|kind| matches!(*kind, "shutdown" | "boot" | "tap")).collect()
}

#[tokio::test(start_paused = true)]
async fn waits_out_an_idle_poweroff_and_restores_the_owned_boot_before_new_agent_input() {
    let (backend, manager) = setup();
    let finish = poweroff_under_way(&backend, &manager).await;

    let input = {
        let manager = manager.clone();
        tokio::spawn(async move {
            manager.with_agent_activity(OWNER_A, used_in(DEVICE_A, OWNER_A, "new-turn"), manager.tap(DEVICE_A, 1.0, 1.0, None)).await
        })
    };
    let attach = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.attach(OWNER_B, DEVICE_A).await })
    };
    let recording = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.start_recording(DEVICE_A).await })
    };
    let viewer = manager.subscribe_frames(DEVICE_A).await;
    settle().await;
    assert_eq!(backend.count("tap"), 0);
    assert_eq!(backend.count("startRecording"), 0);

    finish.notify_one();
    input.await.unwrap().unwrap().unwrap();
    attach.await.unwrap();
    recording.await.unwrap().unwrap();

    assert_eq!(backend.count("boot"), 2);
    assert_eq!(lifecycle(&backend).split_off(lifecycle(&backend).len() - 3), ["shutdown", "boot", "tap"]);
    assert_eq!(manager.owner_state(OWNER_B).await.attached_device_udid.as_deref(), Some(DEVICE_A));
    drop(viewer);
    let listed = manager.list(true).await;
    assert_eq!(listed.devices.iter().find(|device| device.udid == DEVICE_A).unwrap().state, DeviceRuntimeState::Booted);
}

#[tokio::test(start_paused = true)]
async fn protects_direct_pane_input_while_an_idle_poweroff_is_pending() {
    let (backend, manager) = setup();
    let finish = poweroff_under_way(&backend, &manager).await;

    let input = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.tap(DEVICE_A, 1.0, 1.0, None).await })
    };
    settle().await;
    assert_eq!(backend.count("tap"), 0);
    finish.notify_one();
    input.await.unwrap().unwrap();

    assert_eq!(lifecycle(&backend).split_off(lifecycle(&backend).len() - 3), ["shutdown", "boot", "tap"]);
}

#[tokio::test(start_paused = true)]
async fn does_not_start_recording_if_disposal_begins_while_its_owned_boot_is_restored() {
    let (backend, manager) = setup();
    let finish_shutdown = poweroff_under_way(&backend, &manager).await;
    let (boot_started, finish_boot) = backend.hold_boot_reporting(DEVICE_A);

    let recording = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.start_recording(DEVICE_A).await })
    };
    settle().await;
    finish_shutdown.notify_one();
    reached("the restoring boot", &boot_started).await;
    let dispose = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.dispose().await })
    };
    settle().await;
    finish_boot.notify_one();

    let refused = recording.await.unwrap().unwrap_err();
    assert!(refused.message.contains("disposed"), "{}", refused.message);
    dispose.await.unwrap();
    assert_eq!(backend.count("startRecording"), 0);
}

#[tokio::test(start_paused = true)]
async fn does_not_recreate_a_removed_attachment_or_arm_new_timers_after_disposal() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    use_device(&manager, OWNER_A, DEVICE_A, "ending-turn").await;
    let finish = Arc::new(Notify::new());
    let action = {
        let (manager, finish) = (manager.clone(), finish.clone());
        tokio::spawn(async move {
            manager.with_agent_activity(OWNER_A, used_in(DEVICE_A, OWNER_A, "ending-turn"), finish.notified()).await
        })
    };
    settle().await;

    manager.handle_owner_removed(OWNER_A).await;
    manager.dispose().await;
    finish.notify_one();
    action.await.unwrap().unwrap();
    manager.end_agent_turn(turn(OWNER_A, "ending-turn")).await;
    advance(DEVICE_IDLE_SHUTDOWN * 2).await;
    settle().await;

    assert_eq!(backend.count("shutdown"), 1);
}

// Review fixes on top of the d419d5d40 port.

#[tokio::test(start_paused = true)]
async fn a_lapsing_lease_lapses_after_the_grace_with_no_call_of_its_turn() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    let lapsing = Some(DeviceUse { udid: DEVICE_A.into(), turn: Some(turn("run:pty1", "1")), lapses: true });
    manager.with_agent_activity(OWNER_A, lapsing.clone(), manager.ensure_attached(OWNER_A, DEVICE_A)).await.unwrap();

    // A call of the turn inside the grace keeps the lease.
    advance(DEVICE_IDLE_SHUTDOWN - Duration::from_secs(1)).await;
    manager.with_agent_activity(OWNER_A, lapsing, async {}).await.unwrap();
    advance(DEVICE_IDLE_SHUTDOWN - Duration::from_secs(1)).await;
    settle().await;
    assert_eq!(backend.count("shutdown"), 0);

    // No Stop ever comes: the lease lapses a grace after the last call, then the device idles off.
    advance(Duration::from_secs(2)).await;
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the idle shutdown after the lapse", || backend.count("shutdown") == 1).await;
}

#[tokio::test(start_paused = true)]
async fn a_check_ends_only_turns_leased_before_it_began() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    use_device(&manager, OWNER_A, DEVICE_A, "t1").await;
    let mark = manager.lease_mark().await;
    // T2 leases while the check is asking which turn runs; the stale answer is "none".
    use_device(&manager, OWNER_A, DEVICE_A, "t2").await;
    manager.end_agent_turns_except(OWNER_A, None, Some(mark)).await;

    advance(DEVICE_IDLE_SHUTDOWN * 2).await;
    settle().await;
    assert_eq!(backend.count("shutdown"), 0, "T2 still holds the device");
    // T2 was not counted settled either: its next call still leases.
    manager.end_agent_turn(turn(OWNER_A, "t2")).await;
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the idle shutdown", || backend.count("shutdown") == 1).await;
}

#[tokio::test(start_paused = true)]
async fn a_user_detach_idles_a_device_only_a_settled_agent_attachment_still_shows() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    use_device(&manager, OWNER_B, DEVICE_A, "done").await;
    manager.end_agent_turn(turn(OWNER_B, "done")).await;
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.detach(OWNER_A).await;

    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the idle shutdown", || backend.count("shutdown") == 1).await;
}

#[tokio::test(start_paused = true)]
async fn a_restore_finishes_when_the_call_that_started_it_is_dropped() {
    let (backend, manager) = setup();
    let finish_shutdown = poweroff_under_way(&backend, &manager).await;
    let (boot_started, finish_boot) = backend.hold_boot_reporting(DEVICE_A);
    let tap = |manager: &DeviceManager| {
        let manager = manager.clone();
        tokio::spawn(async move { manager.tap(DEVICE_A, 1.0, 1.0, None).await })
    };
    // The first call starts the restoration; the second waits on it.
    let restorer = tap(&manager);
    settle().await;
    let waiter = tap(&manager);
    settle().await;
    finish_shutdown.notify_one();
    reached("the restoring boot", &boot_started).await;
    restorer.abort();
    let _ = restorer.await;
    finish_boot.notify_one();

    // The restoration finished without its caller, and the waiter acted on the booted device.
    waiter.await.unwrap().unwrap();
    assert_eq!(backend.count("boot"), 2);
    assert_eq!(lifecycle(&backend).split_off(lifecycle(&backend).len() - 3), ["shutdown", "boot", "tap"]);
    // Once nothing uses it, it idles off again.
    advance(DEVICE_IDLE_SHUTDOWN + Duration::from_millis(1)).await;
    until("the second idle shutdown", || backend.count("shutdown") == 2).await;
}

#[tokio::test(start_paused = true)]
async fn a_dropped_boot_gives_its_slot_back() {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |options| options.boot_limit = 1);
    let (started, _never) = backend.hold_boot_reporting(DEVICE_B);
    let boot = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.boot(DEVICE_B).await })
    };
    reached("the boot", &started).await;
    boot.abort();
    let _ = boot.await;
    settle().await;

    assert!(matches!(manager.boot(DEVICE_A).await.unwrap(), DeviceBootResult::Booted { .. }));
}

// ── Device switching ───────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn frees_the_old_slot_immediately_when_an_owner_switches_devices() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.boot(DEVICE_B).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;

    manager.attach(OWNER_A, DEVICE_B).await;

    assert_eq!(backend.udids_of("shutdown"), [DEVICE_A]);
}

#[tokio::test(start_paused = true)]
async fn leaves_a_user_booted_device_running_when_an_owner_switches_away() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.boot(DEVICE_B).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;

    manager.attach(OWNER_A, DEVICE_B).await;

    assert_eq!(backend.count("shutdown"), 0);
}

#[tokio::test(start_paused = true)]
async fn keeps_a_device_another_owner_is_still_watching_booted() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.boot(DEVICE_B).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.attach(OWNER_B, DEVICE_A).await;

    manager.attach(OWNER_A, DEVICE_B).await;

    // The helper holds one stream, so B's replaces A's either way.
    assert_eq!(backend.count("shutdown"), 0);
    until("B streaming", || backend.has_stream(DEVICE_B)).await;
    until("A stopped", || !backend.has_stream(DEVICE_A)).await;
}

#[tokio::test(start_paused = true)]
async fn frees_the_slot_for_the_next_boot_rather_than_refusing_it() {
    let (backend, manager) = setup();
    for udid in [DEVICE_A, DEVICE_B, DEVICE_C] {
        manager.boot(udid).await.unwrap();
        manager.attach(OWNER_A, udid).await;
    }

    let fourth = manager.boot(DEVICE_D).await.unwrap();

    assert!(matches!(fourth, DeviceBootResult::Booted { .. }));
    assert_eq!(backend.udids_of("shutdown"), [DEVICE_A, DEVICE_B]);
}

// ── Surviving a crash ──────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn writes_down_every_device_it_boots_so_a_crash_leaves_a_trail() {
    let backend = FakeDeviceBackend::new();
    let (_dir, store) = ownership_store();
    let manager = manager_with(&backend, |options| options.boot_ownership = store.clone());

    manager.boot(DEVICE_A).await.unwrap();
    manager.boot(DEVICE_B).await.unwrap();

    assert_eq!(store.read().unwrap().udids, [DEVICE_A, DEVICE_B]);
}

#[tokio::test(start_paused = true)]
async fn forgets_a_device_as_soon_as_it_is_shut_down() {
    let backend = FakeDeviceBackend::new();
    let (_dir, store) = ownership_store();
    let manager = manager_with(&backend, |options| options.boot_ownership = store.clone());
    manager.boot(DEVICE_A).await.unwrap();
    manager.boot(DEVICE_B).await.unwrap();

    manager.shutdown(DEVICE_A).await.unwrap();

    assert_eq!(store.read().unwrap().udids, [DEVICE_B]);
}

#[tokio::test(start_paused = true)]
async fn leaves_an_empty_record_after_a_clean_quit() {
    let backend = FakeDeviceBackend::new();
    let (_dir, store) = ownership_store();
    let manager = manager_with(&backend, |options| options.boot_ownership = store.clone());
    manager.boot(DEVICE_A).await.unwrap();

    manager.dispose().await;

    assert!(store.read().unwrap().udids.is_empty());
}

#[tokio::test(start_paused = true)]
async fn shuts_down_simulators_a_crashed_run_left_behind() {
    let backend = FakeDeviceBackend::new();
    let (_dir, store) = ownership_store();
    let manager = manager_with(&backend, |options| options.boot_ownership = store.clone());
    store.write(&[DEVICE_A.to_owned()]);
    backend.boot_externally(DEVICE_A);

    let reclaimed = manager.reclaim_orphaned_boots(|_| false).await;

    assert_eq!(reclaimed, [DEVICE_A]);
    assert_eq!(backend.udids_of("shutdown"), [DEVICE_A]);
}

#[tokio::test(start_paused = true)]
async fn leaves_the_devices_of_a_backend_that_is_still_running() {
    let backend = FakeDeviceBackend::new();
    let (_dir, store) = ownership_store();
    let manager = manager_with(&backend, |options| options.boot_ownership = store.clone());
    store.write(&[DEVICE_A.to_owned()]);
    backend.boot_externally(DEVICE_A);

    let reclaimed = manager.reclaim_orphaned_boots(|_| true).await;

    assert!(reclaimed.is_empty());
    assert_eq!(backend.count("shutdown"), 0);
}

// ── Lifecycle and agent activity ───────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn shuts_down_only_cascade_booted_devices_on_dispose() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    backend.boot_externally(DEVICE_B);
    manager.attach(OWNER_A, DEVICE_B).await;

    manager.dispose().await;

    assert_eq!(backend.udids_of("shutdown"), [DEVICE_A]);
    assert!(backend.disposed());
}

#[tokio::test(start_paused = true)]
async fn publishes_agent_activity_without_running_device_discovery_again() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    until_state(&manager, OWNER_A, |state| state.attach_phase.is_none()).await;
    settle().await;
    let mut events = manager.subscribe();
    let before = backend.discovery_calls();

    manager.with_agent_activity(OWNER_A, None, async {}).await.unwrap();
    manager.record_owner_error(OWNER_A, "tap failed").await;

    // Only the badge and the error changed; the device list was reused.
    assert_eq!(backend.discovery_calls(), before);
    let states: Vec<OwnerDeviceState> = drain(&mut events)
        .into_iter()
        .filter_map(|event| match event {
            DeviceEvent::State { state, .. } => Some(state),
            DeviceEvent::OpenPane { .. } => None,
        })
        .collect();
    assert_eq!(states.iter().map(|state| state.agent_active).collect::<Vec<_>>(), [true, false, false]);
    assert_eq!(states.last().unwrap().last_error.as_deref(), Some("tap failed"));
    assert!(states.iter().all(|state| state.devices.iter().any(|device| device.udid == DEVICE_A)));

    // An explicit read still discovers fresh state.
    manager.owner_state(OWNER_A).await;
    assert_eq!(backend.discovery_calls().0, before.0 + 1);
}

#[tokio::test(start_paused = true)]
async fn publishes_the_badge_until_the_last_overlapping_agent_action_finishes() {
    let (_backend, manager) = setup();
    let mut events = manager.subscribe();
    let entered = [Arc::new(Notify::new()), Arc::new(Notify::new())];
    let finish = [Arc::new(Notify::new()), Arc::new(Notify::new())];
    let actions: Vec<_> = (0..2)
        .map(|index| {
            let (manager, started, finish) = (manager.clone(), entered[index].clone(), finish[index].clone());
            tokio::spawn(async move {
                let device = DeviceUse {
                    udid: DEVICE_A.into(),
                    turn: Some(turn(OWNER_A, &format!("overlapping-{index}"))),
                    lapses: false,
                };
                manager
                    .with_agent_activity(OWNER_A, Some(device), async {
                        started.notify_one();
                        finish.notified().await;
                    })
                    .await
                    .unwrap();
            })
        })
        .collect();
    let mut badges = Vec::new();
    let mut read_badges = |events: &mut broadcast::Receiver<DeviceEvent>| {
        for event in drain(events) {
            if let DeviceEvent::State { state, .. } = event {
                badges.push(state.agent_active);
            }
        }
        badges.clone()
    };

    entered[0].notified().await;
    entered[1].notified().await;
    assert_eq!(read_badges(&mut events), [true]);
    finish[0].notify_one();
    let mut actions = actions.into_iter();
    actions.next().unwrap().await.unwrap();
    assert_eq!(read_badges(&mut events), [true]);
    finish[1].notify_one();
    actions.next().unwrap().await.unwrap();
    assert_eq!(read_badges(&mut events), [true, false]);
}

#[tokio::test(start_paused = true)]
async fn clears_the_badge_when_the_agent_action_is_dropped() {
    let (_backend, manager) = setup();
    let running = manager.with_agent_activity(OWNER_A, None, std::future::pending::<()>());
    let _ = tokio::time::timeout(Duration::from_millis(5), running).await;

    until_state(&manager, OWNER_A, |state| !state.agent_active).await;
}

// ── Screen recording ───────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn returns_the_same_output_path_when_a_recording_is_started_and_stopped() {
    let (backend, manager) = booted().await;

    let started = manager.start_recording(DEVICE_A).await.unwrap();
    let stopped = manager.stop_recording(DEVICE_A).await.unwrap();

    assert_eq!(stopped.path, started.path);
    assert_eq!(stopped.udid, DEVICE_A);
    assert_eq!(backend.count("startRecording"), 1);
    assert_eq!(backend.count("stopRecording"), 1);
}

#[tokio::test(start_paused = true)]
async fn refuses_to_start_a_second_recording_for_the_same_device() {
    let (backend, manager) = booted().await;
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.start_recording(DEVICE_A).await.unwrap();

    let second = manager.start_recording(DEVICE_A).await.unwrap_err();
    assert!(second.message.to_lowercase().contains("already recording"));
    manager.detach(OWNER_A).await;

    assert_eq!(backend.count("startRecording"), 2);
    assert_eq!(backend.count("stopRecording"), 1);
}

#[tokio::test(start_paused = true)]
async fn stops_a_recording_when_the_last_owner_detaches_from_its_device() {
    let (backend, manager) = booted().await;
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.start_recording(DEVICE_A).await.unwrap();

    manager.detach(OWNER_A).await;

    assert_eq!(backend.udids_of("stopRecording"), [DEVICE_A]);
}

#[tokio::test(start_paused = true)]
async fn stops_a_recording_on_detach_while_another_owner_keeps_the_stream() {
    let (backend, manager) = booted().await;
    manager.attach(OWNER_A, DEVICE_A).await;
    manager.attach(OWNER_B, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    manager.start_recording(DEVICE_A).await.unwrap();

    manager.detach(OWNER_A).await;

    assert_eq!(backend.udids_of("stopRecording"), [DEVICE_A]);
    assert!(backend.has_stream(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn stops_a_recording_before_shutting_down_its_device() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    manager.start_recording(DEVICE_A).await.unwrap();

    manager.shutdown(DEVICE_A).await.unwrap();

    let calls = backend.calls();
    let kinds: Vec<&str> = calls[calls.len() - 2..].iter().map(FakeCall::kind).collect();
    assert_eq!(kinds, ["stopRecording", "shutdown"]);
}

#[tokio::test(start_paused = true)]
async fn stops_recordings_on_user_owned_devices_when_the_manager_disposes() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.start_recording(DEVICE_A).await.unwrap();

    manager.dispose().await;

    assert_eq!(backend.udids_of("stopRecording"), [DEVICE_A]);
    assert_eq!(backend.count("shutdown"), 0);
}

// ── Agent auto-attach ──────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn attaches_an_unattached_owner_to_the_device_the_agent_is_using() {
    let (backend, manager) = booted().await;

    manager.ensure_attached(OWNER_A, DEVICE_A).await;

    assert_eq!(manager.owner_state(OWNER_A).await.attached_device_udid.as_deref(), Some(DEVICE_A));
    until("the stream", || backend.has_stream(DEVICE_A)).await;
}

#[tokio::test(start_paused = true)]
async fn never_steals_an_owner_already_attached_to_a_different_device() {
    let (backend, manager) = booted().await;
    backend.boot(DEVICE_B).await.unwrap();
    manager.attach(OWNER_A, DEVICE_B).await;

    manager.ensure_attached(OWNER_A, DEVICE_A).await;
    settle().await;

    assert_eq!(manager.owner_state(OWNER_A).await.attached_device_udid.as_deref(), Some(DEVICE_B));
    assert!(!backend.has_stream(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn auto_attach_is_idempotent_when_the_owner_already_watches_that_device() {
    let (backend, manager) = booted().await;
    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;
    let before = manager.owner_state(OWNER_A).await.version;

    manager.ensure_attached(OWNER_A, DEVICE_A).await;
    manager.ensure_attached(OWNER_A, DEVICE_A).await;

    assert_eq!(manager.owner_state(OWNER_A).await.version, before);
    assert_eq!(backend.count("attachStream"), 1);
}

#[tokio::test(start_paused = true)]
async fn attaches_and_requests_the_pane_in_one_step_when_an_agent_drives_a_device() {
    let (_backend, manager) = booted().await;
    let mut events = manager.subscribe();

    manager.surface_device_for_agent(OWNER_A, DEVICE_A, OpenPaneReason::AgentTool).await;

    assert_eq!(manager.owner_state(OWNER_A).await.attached_device_udid.as_deref(), Some(DEVICE_A));
    assert!(drain(&mut events).contains(&DeviceEvent::OpenPane {
        owner: OWNER_A.into(),
        udid: DEVICE_A.into(),
        reason: OpenPaneReason::AgentTool,
    }));
}

#[tokio::test(start_paused = true)]
async fn requests_the_pane_once_no_matter_how_often_the_agent_surfaces() {
    let (backend, manager) = booted().await;
    let mut events = manager.subscribe();

    for _ in 0..5 {
        manager.surface_device_for_agent(OWNER_A, DEVICE_A, OpenPaneReason::AgentTool).await;
    }
    settle().await;

    assert_eq!(open_pane_udids(&drain(&mut events)).len(), 1);
    assert_eq!(backend.count("attachStream"), 1);
}

#[tokio::test(start_paused = true)]
async fn surfaces_again_when_the_agent_moves_to_another_device() {
    let (backend, manager) = booted().await;
    backend.boot(DEVICE_B).await.unwrap();
    let mut events = manager.subscribe();

    manager.surface_device_for_agent(OWNER_A, DEVICE_A, OpenPaneReason::AgentTool).await;
    manager.surface_device_for_agent(OWNER_A, DEVICE_B, OpenPaneReason::AgentTool).await;

    assert_eq!(open_pane_udids(&drain(&mut events)), [DEVICE_A, DEVICE_B]);
}

// ── Geometry ───────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn reports_geometry_once_the_device_has_been_attached() {
    let (backend, manager) = booted().await;
    let geometry = |result: &crate::device::manager::DeviceListResult| {
        result.devices.iter().find(|device| device.udid == DEVICE_A).and_then(|device| device.geometry)
    };

    let before = manager.list(true).await;
    manager.attach(OWNER_A, DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    let after = manager.list(true).await;

    assert_eq!(geometry(&before), None);
    assert_eq!(geometry(&after), Some(FAKE_GEOMETRY));
}

#[tokio::test(start_paused = true)]
async fn leaves_never_attached_devices_without_geometry() {
    let (_backend, manager) = setup();
    assert!(manager.list(true).await.devices.iter().all(|device| device.geometry.is_none()));
}

// ── Element targeting ──────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn taps_a_switch_at_its_own_point_rather_than_its_row_centre() {
    let (backend, manager) = booted().await;

    let found = manager.tap_element(DEVICE_A, &label("Fake Toggle"), None, None).await.unwrap();

    assert_eq!((found.point.x, found.point.y), (340.0, 222.0));
    assert_eq!(backend.last_call(), Some(FakeCall::Tap { udid: DEVICE_A.into(), x: 340.0, y: 222.0, hold_ms: None }));
}

#[tokio::test(start_paused = true)]
async fn reads_the_tree_fresh_for_every_element_tap() {
    let (backend, manager) = booted().await;

    manager.tap_element(DEVICE_A, &label("Fake Toggle"), None, None).await.unwrap();

    let calls = backend.calls();
    let kinds: Vec<&str> = calls[calls.len() - 2..].iter().map(FakeCall::kind).collect();
    assert_eq!(kinds, ["describeUi", "tap"]);
}

#[tokio::test(start_paused = true)]
async fn refuses_an_unknown_label_without_tapping_anything() {
    let (backend, manager) = booted().await;

    let error = manager.tap_element(DEVICE_A, &label("Nonexistent"), None, None).await.unwrap_err();

    assert!(error.message().contains("No element labelled"), "{error}");
    assert_eq!(backend.count("tap"), 0);
}

// ── Scrolling to an element ────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn swipes_until_the_target_lands_in_the_tappable_band_then_stops() {
    let (backend, manager) = booted().await;

    let found = manager.scroll_to_element(DEVICE_A, &label("Deep Row"), None).await.unwrap();

    let centre = found.node.frame.y + found.node.frame.height / 2.0;
    assert!(centre > 852.0 * 0.12 && centre < 852.0 * 0.88, "{centre}");
    let swipes = backend.count("swipe");
    assert!(swipes > 1);
    assert_eq!(backend.count("describeUi"), swipes + 1);
}

#[tokio::test(start_paused = true)]
async fn costs_no_swipes_when_the_target_is_already_visible() {
    let (backend, manager) = booted().await;

    let found = manager.scroll_to_element(DEVICE_A, &label("Fake Toggle"), None).await.unwrap();

    assert_eq!(found.node.label.as_deref(), Some("Fake Toggle"));
    assert_eq!(backend.count("swipe"), 0);
}

#[tokio::test(start_paused = true)]
async fn gives_up_within_the_swipe_budget_rather_than_scrolling_forever() {
    let (backend, manager) = booted().await;

    let error = manager.scroll_to_element(DEVICE_A, &label("Deep Row"), Some(1)).await.unwrap_err();

    assert!(error.message().contains("within 1 swipes"), "{error}");
    assert_eq!(backend.count("swipe"), 1);
}

#[tokio::test(start_paused = true)]
async fn stops_when_the_list_stops_moving_instead_of_burning_the_budget() {
    let (backend, manager) = booted().await;
    // A screen that ignores scrolling: the target stays put however often it is swiped.
    backend.transform_tree(|mut tree| {
        tree.root.label = Some("Stuck".into());
        tree.root.children = vec![node("Button", Some("Unreachable"), frame(24.0, 2_000.0, 345.0, 44.0))];
        tree
    });

    let error = manager.scroll_to_element(DEVICE_A, &label("Unreachable"), None).await.unwrap_err();

    assert!(error.message().contains("appears to be at its end"), "{error}");
    // One swipe that could have moved it, one that proves it did not.
    assert_eq!(backend.count("swipe"), 2);
}

#[tokio::test(start_paused = true)]
async fn taps_a_below_the_fold_element_in_one_call_scrolling_on_the_way() {
    let (backend, manager) = booted().await;

    let found = manager.tap_element(DEVICE_A, &label("Deep Row"), None, None).await.unwrap();

    assert_eq!(
        backend.last_call(),
        Some(FakeCall::Tap { udid: DEVICE_A.into(), x: found.point.x, y: found.point.y, hold_ms: None })
    );
    assert!(backend.count("swipe") > 0);
}

#[tokio::test(start_paused = true)]
async fn reports_a_label_that_never_appears_naming_what_it_did_find() {
    let (_backend, manager) = booted().await;

    let error = manager.scroll_to_element(DEVICE_A, &label("Nonexistent Row"), None).await.unwrap_err();

    assert!(error.message().contains("No element labelled"), "{error}");
    assert!(["Fake Toggle", "Continue", "Deep Row"].iter().any(|seen| error.message().contains(seen)), "{error}");
}

// ── Stream ownership (Synara #1905) ────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_viewerless_attach_leaves_another_owners_watched_stream_alone() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    backend.boot_externally(DEVICE_B);
    manager.attach(OWNER_A, DEVICE_A).await;
    let _viewer_a = manager.subscribe_frames(DEVICE_A).await;
    until("A streaming", || backend.has_stream(DEVICE_A)).await;

    // An agent in another session drives device B with no pane open.
    manager.attach(OWNER_B, DEVICE_B).await;
    settle().await;

    assert!(backend.has_stream(DEVICE_A));
    assert!(!backend.has_stream(DEVICE_B));
    assert_eq!(manager.owner_state(OWNER_B).await.attach_phase, None);

    // Opening a pane on device B is a viewer asking for it: now it switches.
    let _viewer_b = manager.subscribe_frames(DEVICE_B).await;
    until("B streaming", || backend.has_stream(DEVICE_B)).await;
}

#[tokio::test(start_paused = true)]
async fn brings_the_stream_back_for_viewers_when_the_helper_dies() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.attach(OWNER_A, DEVICE_A).await;
    let _viewer = manager.subscribe_frames(DEVICE_A).await;
    until("the first stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;
    let before = backend.count("attachStream");

    backend.interrupt_stream(DEVICE_A, "device helper exited (code=null, signal=SIGKILL)");

    until("the replacement stream", || backend.has_stream(DEVICE_A) && backend.count("attachStream") > before).await;
}

#[tokio::test(start_paused = true)]
async fn tells_the_watching_owner_when_the_stream_cannot_come_back() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.attach(OWNER_A, DEVICE_A).await;
    let _viewer = manager.subscribe_frames(DEVICE_A).await;
    until("the first stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;

    backend.fail_every_stream("device helper build failed");
    backend.interrupt_stream(DEVICE_A, "device helper exited (code=null, signal=SIGSEGV)");

    let state = until_state(&manager, OWNER_A, |state| state.last_error.is_some()).await;
    let pattern = regex::Regex::new(r"helper stopped \(device helper exited.*SIGSEGV\).*could not be restarted").unwrap();
    assert!(pattern.is_match(state.last_error.as_deref().unwrap()), "{:?}", state.last_error);
}

#[tokio::test(start_paused = true)]
async fn does_nothing_when_nobody_needs_the_stream_any_more() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.attach(OWNER_A, DEVICE_A).await;
    let viewer = manager.subscribe_frames(DEVICE_A).await;
    until("the first stream", || backend.has_stream(DEVICE_A)).await;
    manager.detach(OWNER_A).await;
    drop(viewer);
    settle().await;
    let before = backend.count("attachStream");

    backend.interrupt_stream(DEVICE_A, "device helper exited");
    settle().await;

    assert_eq!(backend.count("attachStream"), before);
}

#[tokio::test(start_paused = true)]
async fn boot_ownership_survives_a_listing_that_fails() {
    let (backend, manager) = setup();
    manager.boot(DEVICE_A).await.unwrap();
    backend.set_fail_listing(true);

    manager.cascade_booted_devices().await;
    backend.set_fail_listing(false);

    // Still Cascade's: quitting shuts it down.
    manager.dispose().await;
    assert!(backend.udids_of("shutdown").contains(&DEVICE_A.to_owned()));
}

#[tokio::test(start_paused = true)]
async fn keeps_both_of_two_boots_that_run_at_the_same_time() {
    let (backend, manager) = setup();
    // Device A stays mid-boot (still listed as shut down) while B boots and reconciles against a
    // listing that does not show A running yet.
    let release = backend.hold_boot(DEVICE_A);
    let booting_a = tokio::spawn({
        let manager = manager.clone();
        async move { manager.boot(DEVICE_A).await }
    });
    tokio::time::sleep(Duration::from_millis(5)).await;
    manager.boot(DEVICE_B).await.unwrap();
    release.notify_one();
    booting_a.await.unwrap().unwrap();

    let mut owned: Vec<String> = manager.cascade_booted_devices().await.into_iter().map(|device| device.udid).collect();
    owned.sort();
    assert_eq!(owned, [DEVICE_A, DEVICE_B]);
}

#[tokio::test(start_paused = true)]
async fn does_not_undo_the_last_viewers_stop_while_its_owner_stays_attached() {
    let (backend, manager) = setup();
    backend.boot_externally(DEVICE_A);
    manager.attach(OWNER_A, DEVICE_A).await;
    let viewer = manager.subscribe_frames(DEVICE_A).await;
    until("the first stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;
    let before = backend.count("attachStream");

    backend.interrupt_stream(DEVICE_A, "device helper exited");
    drop(viewer);
    settle().await;

    assert_eq!(backend.count("attachStream"), before);
    assert!(!backend.has_stream(DEVICE_A));
    manager.dispose().await;
}

// ── Cold-boot attach ───────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn waits_out_a_display_that_has_not_been_published_yet() {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |options| options.attach_deadline = Duration::from_secs(5));
    backend.boot(DEVICE_A).await.unwrap();
    backend.fail_next_stream(NO_DISPLAY);

    let attached = manager.attach(OWNER_A, DEVICE_A).await;
    assert_eq!(attached.attached_device_udid.as_deref(), Some(DEVICE_A));

    until("the retried attach", || backend.has_stream(DEVICE_A)).await;
    // The retry worked, so nothing about the transient failure survives it.
    let settled = until_state(&manager, OWNER_A, |state| state.attach_phase.is_none() && state.last_error.is_none()).await;
    assert_eq!(settled.attached_device_udid.as_deref(), Some(DEVICE_A));
    assert!(backend.count("attachStream") > 1);
}

#[tokio::test(start_paused = true)]
async fn tells_the_pane_it_is_waiting_on_the_display_rather_than_spinning_silently() {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |options| {
        options.attach_deadline = Duration::from_secs(5);
        options.attach_retry = Duration::from_millis(50);
    });
    backend.boot(DEVICE_A).await.unwrap();
    backend.fail_every_stream(NO_DISPLAY);

    manager.attach(OWNER_A, DEVICE_A).await;

    until_state(&manager, OWNER_A, |state| state.attach_phase == Some(DeviceAttachPhase::WaitingForDisplay)).await;
}

#[tokio::test(start_paused = true)]
async fn gives_up_with_an_actionable_message_when_the_display_never_appears() {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |_| {});
    backend.boot(DEVICE_A).await.unwrap();
    backend.fail_every_stream(NO_DISPLAY);

    manager.attach(OWNER_A, DEVICE_A).await;

    let state = until_state(&manager, OWNER_A, |state| state.last_error.is_some()).await;
    assert!(state.last_error.as_deref().unwrap().contains("never published a screen"));
    assert_eq!(state.attach_phase, None);
    // The attachment survives: input and the agent's tools still work.
    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn reports_a_permanent_refusal_immediately_instead_of_retrying_it() {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |options| options.attach_deadline = Duration::from_secs(60));
    backend.boot(DEVICE_A).await.unwrap();
    backend.fail_every_stream("the device helper could not be built");

    manager.attach(OWNER_A, DEVICE_A).await;

    let state = until_state(&manager, OWNER_A, |state| state.last_error.is_some()).await;
    assert!(state.last_error.as_deref().unwrap().contains("could not be built"));
    assert_eq!(backend.count("attachStream"), 1);
}

#[tokio::test(start_paused = true)]
async fn stops_retrying_once_the_owner_moves_to_another_device() {
    let backend = FakeDeviceBackend::new();
    let manager = manager_with(&backend, |options| {
        options.attach_deadline = Duration::from_secs(5);
        options.attach_retry = Duration::from_millis(5);
    });
    backend.boot(DEVICE_A).await.unwrap();
    backend.boot(DEVICE_B).await.unwrap();
    backend.fail_every_stream(NO_DISPLAY);

    manager.attach(OWNER_A, DEVICE_A).await;
    backend.clear_stream_failures();
    manager.attach(OWNER_A, DEVICE_B).await;

    until("B streaming", || backend.has_stream(DEVICE_B)).await;
    // A superseded retry loop must not write a phase or an error onto the device switched to.
    let state = until_state(&manager, OWNER_A, |state| state.attach_phase.is_none()).await;
    assert_eq!(state.attached_device_udid.as_deref(), Some(DEVICE_B));
    assert_eq!(state.last_error, None);
}

// ── Contract limits ────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn keeps_an_owner_state_within_the_contract_on_a_machine_with_many_simulators() {
    let udids: Vec<String> = (0..70).map(|index| format!("FAKE-{index:04}")).collect();
    let names: Vec<String> = (0..70).map(|index| format!("iPhone {index}")).collect();
    let seeds: Vec<Seed<'_>> = (0..70).map(|index| Seed { udid: &udids[index], name: &names[index], runtime: "iOS 26.0" }).collect();
    let backend = FakeDeviceBackend::with_devices(&seeds, DeviceAvailability::available());
    backend.boot_externally("FAKE-0069");
    let manager = manager_with(&backend, |_| {});
    manager.attach(OWNER_A, "FAKE-0068").await;

    let state = manager.owner_state(OWNER_A).await;

    assert_eq!(state.devices.len(), DEVICE_THREAD_STATE_MAX_DEVICES);
    // The attached device first, then the booted one.
    assert_eq!(state.devices[0].udid, "FAKE-0068");
    assert_eq!(state.devices[1].udid, "FAKE-0069");
}

#[tokio::test(start_paused = true)]
async fn fits_a_long_error_into_the_contracts_message_limit() {
    let (_backend, manager) = setup();
    let long = format!("Device helper build failed: {}", "error: cannot find type 'SimDeviceIOClient' in scope\n".repeat(80));

    manager.record_owner_error(OWNER_A, &long).await;

    let state = manager.owner_state(OWNER_A).await;
    let error = state.last_error.unwrap();
    assert!(error.chars().count() <= DEVICE_MESSAGE_MAX_LENGTH);
    assert!(error.starts_with("Device helper build failed"));
}

// ── Observation ────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn settles_once_the_tree_holds_still_for_the_quiet_window() {
    let (_backend, manager) = booted().await;

    let outcome = manager.wait_for_settle(DEVICE_A, Some(Duration::from_millis(300)), Some(Duration::from_millis(2_500))).await;

    assert!(outcome.settled);
    assert!(outcome.waited >= Duration::from_millis(300) && outcome.waited < Duration::from_millis(1_000), "{:?}", outcome.waited);
    assert_eq!(outcome.root.unwrap().label.as_deref(), Some("Fake App"));
}

#[tokio::test(start_paused = true)]
async fn keeps_waiting_while_the_tree_changes_then_settles_after_it_stops() {
    let (backend, manager) = booted().await;
    backend.animate_for(6);

    let outcome = manager.wait_for_settle(DEVICE_A, Some(Duration::from_millis(300)), Some(Duration::from_millis(5_000))).await;

    assert!(outcome.settled);
    assert!(outcome.waited >= Duration::from_millis(700), "{:?}", outcome.waited);
    assert!(!serde_json::to_string(&outcome.root).unwrap().contains("Loading"));
}

#[tokio::test(start_paused = true)]
async fn reports_an_endless_animation_as_unsettled_at_the_deadline() {
    let (backend, manager) = booted().await;
    backend.animate_for(1_000);

    let outcome = manager.wait_for_settle(DEVICE_A, Some(Duration::from_millis(300)), Some(Duration::from_millis(1_000))).await;

    assert!(!outcome.settled);
    assert!(outcome.waited >= Duration::from_millis(1_000));
    assert!(outcome.root.is_some());
}

#[tokio::test(start_paused = true)]
async fn says_whether_an_action_changed_the_screen() {
    let (backend, manager) = booted().await;

    let ((), unchanged) = manager
        .observe(DEVICE_A, async { manager.tap(DEVICE_A, 1.0, 1.0, None).await.map_err(DeviceError::from) }, ObserveOptions::default())
        .await
        .unwrap();
    assert_eq!(unchanged.changed, Some(false));

    let ((), changed) = manager
        .observe(
            DEVICE_A,
            async {
                backend.set_focused_value(DEVICE_A, "typed").await?;
                backend.animate_for(2);
                Ok(())
            },
            ObserveOptions::default(),
        )
        .await
        .unwrap();
    // A field's new value is a lasting change; the transient spinner is not.
    assert!(changed.settled);
    assert_eq!(changed.changed, Some(true));
    assert!(!serde_json::to_string(&changed.root).unwrap().contains("Loading"));
}

#[tokio::test(start_paused = true)]
async fn returns_as_soon_as_the_element_is_on_screen() {
    let (_backend, manager) = booted().await;

    let outcome = manager.wait_for(DEVICE_A, &identifier("continue-button"), false, Duration::from_millis(5_000)).await;

    assert_eq!(outcome.status, WaitStatus::Ready);
    assert_eq!(outcome.found.unwrap().node.label.as_deref(), Some("Continue"));
    assert_eq!(outcome.waited, Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn waits_for_an_element_to_go_away() {
    let (backend, manager) = booted().await;
    backend.animate_for(3);

    let outcome = manager.wait_for(DEVICE_A, &label("Loading"), true, Duration::from_millis(5_000)).await;

    assert_eq!(outcome.status, WaitStatus::Ready);
    assert!(outcome.waited > Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn times_out_on_an_element_that_never_appears() {
    let (_backend, manager) = booted().await;

    let outcome = manager.wait_for(DEVICE_A, &label("Never"), false, Duration::from_millis(1_000)).await;

    assert_eq!(outcome.status, WaitStatus::Timeout);
    assert!(outcome.waited >= Duration::from_millis(1_000));
}

#[tokio::test(start_paused = true)]
async fn taps_by_accessibility_identifier() {
    let (backend, manager) = booted().await;

    let found = manager.tap_element(DEVICE_A, &identifier("continue-button"), None, None).await.unwrap();

    assert_eq!(found.node.label.as_deref(), Some("Continue"));
    assert_eq!(backend.last_call(), Some(FakeCall::Tap { udid: DEVICE_A.into(), x: 196.0, y: 725.0, hold_ms: None }));
}

#[tokio::test(start_paused = true)]
async fn names_the_identifiers_on_screen_when_one_does_not_exist() {
    let (_backend, manager) = booted().await;

    let error = manager.tap_element(DEVICE_A, &identifier("missing"), None, None).await.unwrap_err();

    assert!(error.message().contains("No element with identifier #missing appeared"), "{error}");
}

#[tokio::test(start_paused = true)]
async fn passes_a_long_press_through_to_the_backend() {
    let (backend, manager) = booted().await;

    manager.tap_element(DEVICE_A, &label("Continue"), None, Some(800)).await.unwrap();

    assert!(matches!(backend.last_call(), Some(FakeCall::Tap { hold_ms: Some(800), .. })));
}

// ── Text entry ─────────────────────────────────────────────────────────

fn typed(backend: &FakeDeviceBackend) -> Vec<String> {
    backend
        .calls_of("typeText")
        .into_iter()
        .filter_map(|call| match call {
            FakeCall::TypeText { text, .. } => Some(text),
            _ => None,
        })
        .collect()
}

fn last_value(backend: &FakeDeviceBackend) -> Option<String> {
    backend.calls_of("setFocusedValue").into_iter().rev().find_map(|call| match call {
        FakeCall::SetFocusedValue { value, .. } => Some(value),
        _ => None,
    })
}

#[tokio::test(start_paused = true)]
async fn types_ascii_as_keystrokes_on_a_us_keyboard_layout() {
    let (backend, manager) = booted().await;

    let outcome = manager.enter_text(DEVICE_A, "hello", TextEntryOptions::default()).await.unwrap();

    assert_eq!((outcome.method, outcome.submitted), (EnteredBy::Keys, false));
    assert_eq!(typed(&backend), ["hello"]);
}

#[tokio::test(start_paused = true)]
async fn sets_the_value_instead_of_typing_on_a_non_us_layout_appending_to_what_is_there() {
    let (backend, manager) = booted().await;
    backend.set_us_keyboard_layout(false);
    backend.set_focused_value(DEVICE_A, "Wi").await.unwrap();

    let outcome = manager.enter_text(DEVICE_A, "-Fi", TextEntryOptions::default()).await.unwrap();

    assert_eq!(outcome.method, EnteredBy::Value);
    assert_eq!(last_value(&backend).as_deref(), Some("Wi-Fi"));
    assert!(typed(&backend).is_empty());
}

#[tokio::test(start_paused = true)]
async fn sets_non_ascii_text_as_a_value_even_on_a_us_layout() {
    let (backend, manager) = booted().await;

    let outcome =
        manager.enter_text(DEVICE_A, "Città 🚀", TextEntryOptions { clear: true, ..TextEntryOptions::default() }).await.unwrap();

    assert_eq!(outcome.method, EnteredBy::Value);
    assert_eq!(last_value(&backend).as_deref(), Some("Città 🚀"));
}

#[tokio::test(start_paused = true)]
async fn treats_a_placeholder_reported_as_the_value_as_an_empty_field() {
    let (backend, manager) = booted().await;
    backend.set_us_keyboard_layout(false);

    manager.enter_text(DEVICE_A, "a@b.co", TextEntryOptions::default()).await.unwrap();

    assert_eq!(last_value(&backend).as_deref(), Some("a@b.co"));
}

#[tokio::test(start_paused = true)]
async fn refuses_keystrokes_for_text_that_has_no_keys() {
    let (_backend, manager) = booted().await;

    let error = manager
        .enter_text(DEVICE_A, "Città", TextEntryOptions { method: TextMethod::Keys, ..TextEntryOptions::default() })
        .await
        .unwrap_err();

    assert!(error.message().contains("printable ASCII only"), "{error}");
}

#[tokio::test(start_paused = true)]
async fn clears_with_select_all_and_delete_and_submits_with_return() {
    let (backend, manager) = booted().await;

    let outcome =
        manager.enter_text(DEVICE_A, "query\n", TextEntryOptions { clear: true, ..TextEntryOptions::default() }).await.unwrap();

    assert_eq!((outcome.method, outcome.submitted), (EnteredBy::Keys, true));
    let keys: Vec<(u16, Vec<DeviceKeyModifier>)> = backend
        .calls_of("keyEvent")
        .into_iter()
        .filter_map(|call| match call {
            FakeCall::KeyEvent { event, .. } if event.direction == DeviceKeyDirection::Down => Some((event.key_code, event.modifiers)),
            _ => None,
        })
        .collect();
    assert_eq!(keys, [(0x04, vec![DeviceKeyModifier::Command]), (0x2a, vec![]), (0x28, vec![])]);
    assert_eq!(typed(&backend).last().map(String::as_str), Some("query"));
}

// ── Observing launches and late transitions ────────────────────────────

#[tokio::test(start_paused = true)]
async fn does_not_settle_on_the_blank_screen_between_apps() {
    let (backend, manager) = booted().await;
    let blank_reads = Arc::new(AtomicU32::new(0));
    backend.transform_tree({
        let blank_reads = blank_reads.clone();
        move |mut tree| {
            if blank_reads.load(Ordering::SeqCst) > 0 {
                blank_reads.fetch_sub(1, Ordering::SeqCst);
                tree.root.label = Some(" ".into());
                tree.root.children.clear();
            }
            tree
        }
    });

    let ((), observation) = manager
        .observe(
            DEVICE_A,
            async {
                blank_reads.store(5, Ordering::SeqCst);
                Ok(())
            },
            ObserveOptions { await_app: Some(AwaitApp::Any), ..ObserveOptions::default() },
        )
        .await
        .unwrap();

    assert_eq!(observation.root.unwrap().label.as_deref(), Some("Fake App"));
}

#[tokio::test(start_paused = true)]
async fn waits_for_an_effect_that_starts_after_a_pause_instead_of_settling_on_the_old_screen() {
    let (backend, manager) = booted().await;
    let reads_until_change = Arc::new(AtomicI32::new(-1));
    backend.transform_tree({
        let reads_until_change = reads_until_change.clone();
        move |mut tree| {
            let left = reads_until_change.load(Ordering::SeqCst);
            if left < 0 {
                return tree;
            }
            if left > 0 {
                reads_until_change.fetch_sub(1, Ordering::SeqCst);
                return tree;
            }
            tree.root.label = Some("Home Screen".into());
            tree.root.children.clear();
            tree
        }
    });

    // The home press lands, but the screen only starts moving five reads later.
    let ((), observation) = manager
        .observe(
            DEVICE_A,
            async {
                reads_until_change.store(5, Ordering::SeqCst);
                Ok(())
            },
            ObserveOptions::default(),
        )
        .await
        .unwrap();

    assert_eq!(observation.changed, Some(true));
    assert_eq!(observation.root.unwrap().label.as_deref(), Some("Home Screen"));
}

#[tokio::test(start_paused = true)]
async fn reports_no_change_once_the_grace_passes_with_nothing_moving() {
    let (_backend, manager) = booted().await;

    let ((), observation) = manager.observe(DEVICE_A, async { Ok(()) }, ObserveOptions::default()).await.unwrap();

    assert_eq!(observation.changed, Some(false));
    assert!(observation.waited >= Duration::from_millis(300));
}

#[tokio::test(start_paused = true)]
async fn taps_a_navigation_bar_button_that_scrolling_cannot_move() {
    let (backend, manager) = booted().await;
    backend.transform_tree(|mut tree| {
        let back = crate::device::contracts::DeviceUiNode {
            identifier: Some("BackButton".into()),
            ..node("Button", Some("Settings"), frame(16.0, 62.0, 44.0, 44.0))
        };
        let bar = crate::device::contracts::DeviceUiNode {
            role: "NavigationBar".into(),
            label: None,
            children: vec![back],
            ..tree.root.clone()
        };
        tree.root.children.insert(0, bar);
        tree
    });

    let found = manager.tap_element(DEVICE_A, &identifier("BackButton"), None, None).await.unwrap();

    assert_eq!((found.point.x, found.point.y), (38.0, 84.0));
    // One probing swipe shows it does not scroll; then it is tapped in place.
    assert_eq!(backend.count("swipe"), 1);
    assert_eq!(backend.last_call(), Some(FakeCall::Tap { udid: DEVICE_A.into(), x: 38.0, y: 84.0, hold_ms: None }));
}

#[tokio::test(start_paused = true)]
async fn does_not_certify_an_unchanged_pre_restart_screen() {
    let (_backend, manager) = booted().await;

    let ((), outcome) = manager
        .observe(
            DEVICE_A,
            async { Ok(()) },
            ObserveOptions { await_app: Some(AwaitApp::Any), timeout: Some(Duration::from_millis(1_000)), ..ObserveOptions::default() },
        )
        .await
        .unwrap();

    assert!(!outcome.settled);
}

#[tokio::test(start_paused = true)]
async fn refuses_value_appends_to_secure_fields() {
    let (backend, manager) = booted().await;
    backend.set_us_keyboard_layout(false);
    backend.transform_tree(|mut tree| {
        tree.root.children = vec![crate::device::contracts::DeviceUiNode {
            subrole: Some("SecureTextField".into()),
            value: Some("••".into()),
            focused: Some(true),
            ..node("TextField", Some("Password"), frame(0.0, 100.0, 200.0, 40.0))
        }];
        tree
    });

    let error = manager
        .enter_text(DEVICE_A, "a-b", TextEntryOptions { method: TextMethod::Value, ..TextEntryOptions::default() })
        .await
        .unwrap_err();

    assert!(error.message().contains("clear: true"), "{error}");
    assert!(typed(&backend).is_empty());
}

#[tokio::test(start_paused = true)]
async fn does_not_tap_a_covered_field_merely_because_a_swipe_did_not_move_it() {
    let (backend, manager) = booted().await;
    backend.transform_tree(|mut tree| {
        tree.root.children = vec![node("Button", Some("Covered"), frame(0.0, 840.0, 200.0, 30.0))];
        tree
    });

    let error = manager.tap_element(DEVICE_A, &label("Covered"), None, None).await.unwrap_err();

    assert!(error.message().contains("out of reach"), "{error}");
    assert_eq!(backend.count("tap"), 0);
}

#[tokio::test(start_paused = true)]
async fn reports_a_deep_link_without_a_changed_screen_as_unsettled() {
    let (_backend, manager) = booted().await;

    let ((), result) = manager
        .observe(
            DEVICE_A,
            async { Ok(()) },
            ObserveOptions { await_change: true, timeout: Some(Duration::from_millis(1_000)), ..ObserveOptions::default() },
        )
        .await
        .unwrap();

    assert!(!result.settled);
    assert_eq!(result.changed, Some(false));
}

#[tokio::test(start_paused = true)]
async fn ends_an_explicit_wait_without_further_reads_once_it_is_dropped() {
    let (backend, manager) = booted().await;
    let never = label("Never");
    let waiting = manager.wait_for(DEVICE_A, &never, false, Duration::from_secs(30));
    let _ = tokio::time::timeout(Duration::from_millis(500), waiting).await;
    let reads = backend.count("describeUi");

    tokio::time::sleep(Duration::from_secs(5)).await;

    assert_eq!(backend.count("describeUi"), reads);
}

// ── Review fixes ───────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_viewer_reconnecting_at_once_keeps_the_stream_the_stale_stop_would_have_cut() {
    let (backend, manager) = booted().await;
    let first = manager.subscribe_frames(DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;

    // The pane reconnects: the old viewer's stop is queued, the new viewer subscribes before it runs.
    drop(first);
    let _second = manager.subscribe_frames(DEVICE_A).await;
    settle().await;

    assert!(backend.has_stream(DEVICE_A));
    assert_eq!(backend.count("detachStream"), 0, "the watched stream was torn down and rebuilt");
    assert_eq!(backend.count("attachStream"), 1);
}

#[tokio::test(start_paused = true)]
async fn rebuilds_the_stream_when_the_frame_forwarder_falls_behind() {
    let (backend, manager) = booted().await;
    let _viewer = manager.subscribe_frames(DEVICE_A).await;
    until("the stream", || backend.has_stream(DEVICE_A)).await;
    settle().await;
    let attaches = backend.count("attachStream");

    // More frames than the backend's broadcast holds, with no chance for the forwarder to read:
    // the codec config and keyframe may be among those lost.
    for _ in 0..300 {
        backend.emit_frame(DEVICE_A, false, false);
    }

    until("the rebuilt stream", || backend.count("attachStream") > attaches && backend.has_stream(DEVICE_A)).await;
}
