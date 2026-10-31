//! The device manager as the backend holds it: `AppState.device`, started once with the backend
//! (Synara's `DeviceServiceLive`), and stopped when the backend stops, which shuts down every
//! simulator Cascade booted and stops the helper.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
};

use cascade_chat::{
    contracts::{base::ThreadId, orchestration::OrchestrationEventBody},
    ChatEngineEvent,
};

use super::{
    backend::DeviceBackend,
    boot_ownership::{process_is_alive, BootOwnershipStore},
    frames::FrameSockets,
    ios_simulator::{IosSimulatorBackend, IosSimulatorOptions},
    manager::{AgentTurn, DeviceEvent, DeviceManager, DeviceManagerOptions},
    tools::{chat_holder, terminal_holder},
};
use crate::{
    chat::Chat,
    event::Event,
    gateway::Caller,
    AppState, Database,
};

/// `AppState.device`.
#[derive(Default)]
pub struct Devices {
    manager: OnceLock<DeviceManager>,
    sockets: FrameSockets,
    /// Where `device_screenshot` saves proof images: `<data>/device/proof`.
    proofs: OnceLock<PathBuf>,
    /// The owner each chat's tool calls acted for, by thread id, so a deleted chat's owner can be
    /// released when the thread itself can no longer be read.
    chat_owners: Mutex<HashMap<String, String>>,
    /// The turn each terminal agent is in, by run id, from its turn hooks: present from a
    /// `UserPromptSubmit` to the `Stop` after it. A run whose agent reports no turns has none.
    terminal_turns: Mutex<HashMap<String, String>>,
    next_terminal_turn: AtomicU64,
}

impl Devices {
    pub fn manager(&self) -> Option<&DeviceManager> {
        self.manager.get()
    }

    /// The manager, when this platform can run simulators: the agent tools are offered only then.
    pub fn supported(&self) -> Option<&DeviceManager> {
        self.manager.get().filter(|manager| manager.supported())
    }

    pub fn sockets(&self) -> &FrameSockets {
        &self.sockets
    }

    pub fn proofs_dir(&self) -> PathBuf {
        self.proofs.get().cloned().unwrap_or_else(|| std::env::temp_dir().join("cascade-device-proof"))
    }

    /// Installs the manager and relays its events to the app. Once; a second is ignored.
    pub fn install(&self, state: &AppState, manager: DeviceManager) {
        let mut events = manager.subscribe();
        if self.manager.set(manager).is_err() {
            return;
        }
        let app = state.clone();
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(event) => app.publish(Event::from(event)),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                }
            }
        });
    }

    /// Remembers whose pane a chat's device calls act for.
    pub fn remember_chat_owner(&self, thread_id: &str, owner: &str) {
        self.chat_owners.lock().unwrap().insert(thread_id.to_owned(), owner.to_owned());
    }

    pub fn set_proofs_dir(&self, dir: PathBuf) {
        let _ = self.proofs.set(dir);
    }

    /// Forgets a terminal's turn without telling the manager: a test's stand-in for a turn whose
    /// end came before its device call was counted.
    #[cfg(test)]
    pub(crate) fn forget_terminal_turn(&self, run_id: &str) {
        self.terminal_turns.lock().unwrap().remove(run_id);
    }

    /// The turn a terminal's agent is in, when its hooks reported one starting. Without them the
    /// backend never hears a terminal turn end, so its device calls lease nothing and the device
    /// idles from the last one (Synara's call with no `callerTurnId`).
    pub fn terminal_turn(&self, run_id: &str) -> Option<AgentTurn> {
        let id = self.terminal_turns.lock().unwrap().get(run_id).cloned()?;
        Some(AgentTurn { holder: terminal_holder(run_id), id })
    }
}

/// A terminal agent's turn started (its `UserPromptSubmit` hook). A turn still held is one whose
/// `Stop` never came, and settles now.
pub fn terminal_turn_started(state: &AppState, run_id: &str) {
    let id = state.device.next_terminal_turn.fetch_add(1, Ordering::Relaxed).to_string();
    let previous = state.device.terminal_turns.lock().unwrap().insert(run_id.to_owned(), id);
    if let (Some(previous), Some(manager)) = (previous, state.device.manager().cloned()) {
        let turn = AgentTurn { holder: terminal_holder(run_id), id: previous };
        tokio::spawn(async move { manager.end_agent_turn(turn).await });
    }
}

/// A terminal agent's turn ended (its `Stop` hook): the devices it used are released to their
/// idle grace (Synara's turn settling in `ProviderRuntimeIngestion`).
pub fn terminal_turn_ended(state: &AppState, run_id: &str) {
    let Some(id) = state.device.terminal_turns.lock().unwrap().remove(run_id) else { return };
    let Some(manager) = state.device.manager().cloned() else { return };
    let turn = AgentTurn { holder: terminal_holder(run_id), id };
    tokio::spawn(async move { manager.end_agent_turn(turn).await });
}

/// A terminal agent's conversation changed under its run (`SessionStart`: a `/clear`, a
/// `/resume`, a relaunch): whatever turn the run still held is over, its `Stop` lost to an
/// interrupt.
pub fn terminal_session_changed(state: &AppState, run_id: &str) {
    terminal_turn_ended(state, run_id);
}

/// Ends a device call's turn if it is no longer running once the call is over, however it ends:
/// awaited by `finish`, or spawned from `Drop` for a call a Stop dropped.
pub struct SettleCheck {
    state: AppState,
    caller: Caller,
    manager: super::manager::DeviceManager,
    turn: Option<AgentTurn>,
}

impl SettleCheck {
    pub fn new(state: &AppState, caller: &Caller, manager: &super::manager::DeviceManager, turn: Option<AgentTurn>) -> Self {
        Self { state: state.clone(), caller: caller.clone(), manager: manager.clone(), turn }
    }

    pub async fn finish(mut self) {
        if let Some(turn) = self.turn.take() {
            settle(&self.state, &self.caller, &self.manager, turn).await;
        }
    }
}

impl Drop for SettleCheck {
    fn drop(&mut self) {
        let Some(turn) = self.turn.take() else { return };
        let (state, caller, manager) = (self.state.clone(), self.caller.clone(), self.manager.clone());
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move { settle(&state, &caller, &manager, turn).await });
        }
    }
}

async fn settle(state: &AppState, caller: &Caller, manager: &super::manager::DeviceManager, turn: AgentTurn) {
    if !turn_still_running(state, caller, &turn).await {
        manager.end_agent_turn(turn).await;
    }
}

/// Whether the turn a device call was leased to is still its caller's running turn.
pub async fn turn_still_running(state: &AppState, caller: &Caller, turn: &AgentTurn) -> bool {
    match caller {
        Caller::Chat { thread_id } => match state.chat.engine() {
            Some(engine) => match engine.running_turn(ThreadId::new(thread_id.clone())).await {
                Ok(running) => running.is_some_and(|running| running.as_str() == turn.id),
                // Unknown is not "settled": the thread's next session change releases it.
                Err(_) => true,
            },
            None => false,
        },
        Caller::Terminal { run_id, .. } => state.device.terminal_turn(run_id).as_ref() == Some(turn),
    }
}

impl From<DeviceEvent> for Event {
    fn from(event: DeviceEvent) -> Self {
        match event {
            DeviceEvent::State { owner, state } => {
                Event::Device { owner, state: serde_json::to_value(state).expect("a device state serializes") }
            }
            DeviceEvent::OpenPane { owner, udid, reason } => Event::DeviceOpenPane { owner, udid, reason },
        }
    }
}

/// Starts the device manager on the real backend, and reclaims simulators a crashed run left
/// booted. Off macOS the manager still exists, reporting `unsupported-platform`.
pub fn start(state: &AppState, data_dir: &Path) {
    let options = IosSimulatorOptions::production();
    let darwin = options.platform == "darwin";
    let backend: Arc<dyn DeviceBackend> = IosSimulatorBackend::new(options);
    let mut manager_options = DeviceManagerOptions::new(backend);
    manager_options.supported = darwin;
    // Only a Mac can boot anything, so only a Mac needs to remember doing so.
    manager_options.boot_ownership =
        if darwin { BootOwnershipStore::in_data_dir(data_dir) } else { BootOwnershipStore::null() };
    let manager = DeviceManager::new(manager_options);
    state.device.set_proofs_dir(data_dir.join("device").join("proof"));
    state.device.install(state, manager.clone());
    if darwin {
        // Off the startup path: listing simulators runs `simctl`, which can take seconds.
        tokio::spawn(async move {
            let reclaimed = manager.reclaim_orphaned_boots(process_is_alive).await;
            if !reclaimed.is_empty() {
                tracing::info!(
                    count = reclaimed.len(),
                    udids = %reclaimed.join(", "),
                    "device: shut down simulators a previous Cascade run left booted"
                );
            }
        });
    }
}

/// App quit: shuts down every simulator Cascade booted, leaves the user's own running, and stops
/// the helper and the frame sockets. The quit waits for it no longer than `STOP_GRACE`: what is
/// still booted then stays in the boot record, and the next start shuts it down
/// (`reclaim_orphaned_boots`).
pub async fn stop(state: &AppState) {
    state.device.sockets.close();
    if let Some(manager) = state.device.manager() {
        if tokio::time::timeout(STOP_GRACE, manager.dispose()).await.is_err() {
            tracing::warn!("device: simulators still shutting down at quit are left to the next start");
        }
    }
}

/// How long a quit waits on the simulators: each `simctl shutdown` may take many seconds.
const STOP_GRACE: std::time::Duration = std::time::Duration::from_secs(5);

/// A session's worktree was removed: its pane is gone, so whatever it watched is released as a
/// detach would (Synara `handleThreadRemoved`).
pub async fn owner_removed(state: &AppState, folder: &str) {
    if let Some(manager) = state.device.manager() {
        manager.handle_owner_removed(&normalize_owner(folder)).await;
    }
}

/// The chat engine's `publish`, with a deleted chat's device owner released behind it (Synara's
/// `handleThreadRemoved` on thread deletion). Off the engine's task, which must not block.
pub fn releasing_devices(
    state: &AppState,
    publish: Arc<dyn Fn(ChatEngineEvent) + Send + Sync>,
) -> Arc<dyn Fn(ChatEngineEvent) + Send + Sync> {
    // Weak: the engine's own publish must not keep the chats alive.
    let (devices, chat, db) = (state.device.clone(), Arc::downgrade(&state.chat), state.db.clone());
    Arc::new(move |event| {
        match &event {
            ChatEngineEvent::Removed { thread_id } => {
                let (devices, chat, db, thread_id) = (devices.clone(), chat.clone(), db.clone(), thread_id.as_str().to_owned());
                tokio::spawn(async move { chat_removed(&devices, &chat, &db, &thread_id).await });
            }
            ChatEngineEvent::Thread { thread_id, events } if events.iter().any(|event| settles_turn(&event.body)) => {
                let (devices, chat, thread_id) = (devices.clone(), chat.clone(), thread_id.clone());
                tokio::spawn(async move { chat_turns_settled(&devices, &chat, thread_id).await });
            }
            _ => {}
        }
        publish(event)
    })
}

/// Events after which a chat's running turn may have changed: its session moved (a turn started,
/// completed, was interrupted, or the session stopped), or a turn's checkpoint closed it.
fn settles_turn(body: &OrchestrationEventBody) -> bool {
    matches!(
        body,
        OrchestrationEventBody::ThreadSessionSet(_)
            | OrchestrationEventBody::ThreadTurnDiffCompleted(_)
            | OrchestrationEventBody::ThreadDeleted(_)
    )
}

/// A chat's session changed: every turn of it that is not the one running now has settled, and
/// the devices it used go to their idle grace (Synara ends the exact turn its ingestion saw
/// complete; here the engine is asked which turn runs, so a late check never ends a newer turn).
pub async fn chat_turns_settled(devices: &Devices, chat: &Weak<Chat>, thread_id: ThreadId) {
    let Some(manager) = devices.manager() else { return };
    let holder = chat_holder(thread_id.as_str());
    if !manager.holds_agent_turns(&holder).await {
        return;
    }
    let Some(engine) = chat.upgrade().and_then(|chat| chat.engine().cloned()) else { return };
    // Taken before asking: a turn that leases a device while the engine answers is newer than the
    // answer, and is not this check's to end.
    let mark = manager.lease_mark().await;
    let Ok(running) = engine.running_turn(thread_id).await else { return };
    manager.end_agent_turns_except(&holder, running.as_ref().map(|turn| turn.as_str()), Some(mark)).await;
}

/// A chat was deleted. A `chat:<id>` owner was the chat's alone and is released; a folder owner
/// only when no other chat and no session works in that folder, since its pane is theirs too.
pub async fn chat_removed(devices: &Devices, chat: &Weak<Chat>, db: &Database, thread_id: &str) {
    let Some(manager) = devices.manager() else { return };
    // Whatever its turns still held is released, whether or not its owner goes too.
    manager.end_agent_turns_except(&chat_holder(thread_id), None, None).await;
    let owner = devices.chat_owners.lock().unwrap().remove(thread_id).unwrap_or_else(|| format!("chat:{thread_id}"));
    if !owner.starts_with("chat:") {
        if devices.chat_owners.lock().unwrap().values().any(|other| *other == owner) {
            return;
        }
        let engine = chat.upgrade().and_then(|chat| chat.engine().cloned());
        if let Some(engine) = engine {
            match engine.shells(None).await {
                Ok(shells) => {
                    let shared = shells.iter().any(|shell| {
                        shell.id.as_str() != thread_id
                            && [&shell.worktree_path, &shell.working_directory]
                                .into_iter()
                                .flatten()
                                .any(|folder| normalize_owner(folder) == owner)
                    });
                    if shared {
                        return;
                    }
                }
                // Unknown is not "unused": keep the attachment rather than cut another's pane.
                Err(_) => return,
            }
        }
        match db.tasks().await {
            Ok(sessions) if sessions.iter().any(|session| normalize_owner(&session.worktree) == owner) => return,
            Err(_) => return,
            Ok(_) => {}
        }
    }
    manager.handle_owner_removed(&owner).await;
}

/// The owner a folder names: trimmed, without a trailing slash, so `/w/` and `/w` are one owner,
/// and with its symlinks resolved when the folder exists. A terminal reports its folder as
/// `pwd -P` does (`/private/var/…`, a symlinked checkout resolved) while a session knows its
/// worktree by the path it was stored under: both must name one owner.
pub fn normalize_owner(owner: &str) -> String {
    let trimmed = owner.trim();
    let stripped = trimmed.trim_end_matches('/');
    let plain = if stripped.is_empty() && trimmed.starts_with('/') { "/" } else { stripped };
    if plain.starts_with('/') {
        if let Ok(real) = std::fs::canonicalize(plain) {
            if let Some(real) = real.to_str() {
                return real.to_owned();
            }
        }
    }
    plain.to_owned()
}

#[cfg(test)]
mod owner_tests {
    use super::normalize_owner;

    /// A terminal's `pwd -P` and a session's stored path name the same owner.
    #[test]
    fn a_symlinked_folder_and_its_target_are_one_owner() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let resolved = std::fs::canonicalize(&real).unwrap().to_string_lossy().into_owned();
        assert_eq!(normalize_owner(&format!(" {}/ ", link.display())), resolved);
        assert_eq!(normalize_owner(&real.to_string_lossy()), resolved);
        // A folder that is not there is only trimmed.
        assert_eq!(normalize_owner("/nowhere/at/all/"), "/nowhere/at/all");
        assert_eq!(normalize_owner("run:1"), "run:1");
    }
}
