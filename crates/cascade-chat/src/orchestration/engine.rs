//! The chat engine: one task that owns every thread, every provider session and the database,
//! and the [`ChatEngine`] handle the backend holds. Ported from Synara's orchestration engine and
//! `ProviderService.ts`, reduced to what a single-user app needs; the per-event reactions of
//! `ProviderCommandReactor.ts` and `CheckpointReactor.ts` are in [`super::reactor`].
//!
//! Every command, a client's or the server's own, goes through one pipeline: the decider turns it
//! into events, each is numbered with the thread's next `sequence` and projected, ingestion hears
//! the ones it listens to (and its commands go through the pipeline first), the reactor reacts,
//! and the thread is saved and the events published. A provider call never blocks the task: it
//! runs in a task of its own and its answer comes back as a message.
//!
//! Synara keeps an event store and replays it; here the read model is what is stored (see
//! SYNARA.md), and each thread's last sequence with it. Streaming assistant text is saved at most
//! every [`STREAMING_SAVE_INTERVAL`] per thread and published at once; everything else is saved
//! before it is published.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use serde::Serialize;
use tokio::{
    sync::{mpsc, oneshot},
    time::Instant,
};

use crate::{
    checkpointing::{
        diff_query::{get_full_thread_diff, get_turn_diff, CheckpointDiffError},
        CheckpointStore, GitRunner, ProcessGit,
    },
    contracts::{
        base::{now_iso, CheckpointRef, MessageId, ThreadId, TurnId},
        orchestration::*,
        provider::{ProviderTurnStartResult, ProviderSendTurnInput},
        provider_runtime::ProviderRuntimeEvent,
    },
    persistence::store::{ChatStore, ProviderSessionRecord},
    provider::{
        adapter::{
            ProviderAdapter, ProviderAdapterCapabilities, ProviderModel, ProviderSessionHandle,
            PROVIDER_ADAPTER_RUNTIME_EVENT_BUFFER_CAPACITY,
        },
        attachment_projection::{
            attachment_relative_path, resolve_attachment_path_by_id, resolve_attachment_relative_path, StoredAttachment,
        },
        claude::ClaudeAdapter,
        codex::CodexAdapter,
        process::Spawner,
    },
};

use super::{
    decider::{command_thread_id, decide, decide_fork_create, DecideError},
    fork_thread_title::ForkLineageThread,
    ingestion::{IngestionEnvironment, ProviderRuntimeIngestion},
    projector::project,
};

/// How often a thread's streaming assistant text is saved while it streams.
pub const STREAMING_SAVE_INTERVAL: Duration = Duration::from_millis(250);
/// How many threads the engine keeps in memory beyond those with work in flight; the least
/// recently used idle one is let go past it, and read again from `chat.db` when next needed.
pub const MAX_IDLE_THREADS_IN_MEMORY: usize = 32;

/// What the engine needs from its host.
pub struct ChatEngineConfig {
    /// Where `chat.db` and `attachments/` live.
    pub data_dir: PathBuf,
    /// How provider CLIs are started.
    pub spawner: Arc<dyn Spawner>,
    /// The providers; `None` is Claude and Codex, reading attachments from `data_dir/attachments`.
    pub adapters: Option<Vec<Arc<dyn ProviderAdapter>>>,
    /// Hears every [`ChatEngineEvent`], on the engine's task: it must not block.
    pub publish: Arc<dyn Fn(ChatEngineEvent) + Send + Sync>,
    /// How checkpoints run git; `None` is the `git` on `PATH`.
    pub git: Option<Arc<dyn GitRunner>>,
}

impl ChatEngineConfig {
    /// The production configuration: real processes, Claude and Codex, the `git` on `PATH`.
    pub fn new(data_dir: impl Into<PathBuf>, publish: Arc<dyn Fn(ChatEngineEvent) + Send + Sync>) -> Self {
        Self {
            data_dir: data_dir.into(),
            spawner: Arc::new(crate::provider::process::ProcessSpawner),
            adapters: None,
            publish,
            git: None,
        }
    }
}

/// What the engine tells its host.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ChatEngineEvent {
    /// Events a thread took, in order, each with its `sequence`. A client that sees a gap in the
    /// sequence reads the thread again.
    #[serde(rename_all = "camelCase")]
    Thread { thread_id: ThreadId, events: Vec<OrchestrationEvent> },
    /// A thread's list-level fields changed.
    #[serde(rename_all = "camelCase")]
    Shell { shell: OrchestrationThreadShell },
    /// A thread was deleted.
    #[serde(rename_all = "camelCase")]
    Removed { thread_id: ThreadId },
}

/// What a dispatched command did.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchResult {
    /// The thread's last event sequence once the command and what it set off were applied.
    pub sequence: u64,
}

/// Why a command was not applied.
#[derive(Debug)]
pub enum ChatError {
    /// The command breaks an invariant; the text is the decider's.
    Invalid(String),
    /// The engine could not do it.
    Internal(anyhow::Error),
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(detail) => f.write_str(detail),
            Self::Internal(error) => write!(f, "{error:#}"),
        }
    }
}

impl std::error::Error for ChatError {}

/// A provider the engine can run.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    pub provider: ProviderKind,
    pub capabilities: ProviderAdapterCapabilities,
    pub models: Vec<ProviderModel>,
}

enum Request {
    Dispatch { command: ClientThreadCommand, reply: oneshot::Sender<Result<DispatchResult, ChatError>> },
    Thread { thread_id: ThreadId, reply: oneshot::Sender<Result<Option<OrchestrationThread>>> },
    ThreadDetail { thread_id: ThreadId, reply: oneshot::Sender<Result<Option<(OrchestrationThread, u64)>>> },
    Shells { project: Option<String>, reply: oneshot::Sender<Result<Vec<OrchestrationThreadShell>>> },
    ShellSnapshot { reply: oneshot::Sender<Result<OrchestrationShellSnapshot>> },
    Shutdown { reply: oneshot::Sender<()> },
}

/// The handle to the engine. Cloning it is cheap; the engine runs until [`ChatEngine::shutdown`]
/// or until every handle is dropped.
#[derive(Clone)]
pub struct ChatEngine {
    requests: mpsc::UnboundedSender<Request>,
    checkpoints: Arc<CheckpointStore>,
    adapters: Arc<Vec<Arc<dyn ProviderAdapter>>>,
    attachments_dir: PathBuf,
}

impl ChatEngine {
    /// Opens `data_dir/chat.db`, settles the sessions a previous run left running (no CLI
    /// outlives the engine) and starts the engine's task.
    pub async fn start(config: ChatEngineConfig) -> Result<ChatEngine> {
        let attachments_dir = config.data_dir.join("attachments");
        let store = ChatStore::open(&config.data_dir.join("chat.db"))?;
        let adapters: Vec<Arc<dyn ProviderAdapter>> = config.adapters.unwrap_or_else(|| {
            vec![
                Arc::new(ClaudeAdapter::new(attachments_dir.clone())) as Arc<dyn ProviderAdapter>,
                Arc::new(CodexAdapter::with_attachments_dir(attachments_dir.clone())),
            ]
        });
        let live_diff: HashSet<String> = adapters
            .iter()
            .filter(|a| a.capabilities().supports_live_turn_diff_patch)
            .map(|a| a.provider().as_str().to_owned())
            .collect();
        let ingestion = ProviderRuntimeIngestion::with_environment(IngestionEnvironment {
            is_git_repo: Box::new(|thread| resolve_cwd(thread).ok().is_some_and(|cwd| is_inside_git_work_tree(Path::new(&cwd)))),
            supports_live_turn_diff_patch: Box::new(move |provider| live_diff.contains(provider.as_str())),
        });
        let checkpoints = Arc::new(CheckpointStore::new(config.git.unwrap_or_else(|| Arc::new(ProcessGit))));
        let (sink, runtime) = mpsc::channel(PROVIDER_ADAPTER_RUNTIME_EVENT_BUFFER_CAPACITY);
        let (internal, internal_inbox) = mpsc::unbounded_channel();
        let (requests, inbox) = mpsc::unbounded_channel();
        let mut actor = Actor {
            store,
            publish: config.publish,
            spawner: config.spawner,
            adapters: adapters.iter().map(|a| (a.provider(), a.clone())).collect(),
            checkpoints: checkpoints.clone(),
            ingestion,
            sink,
            internal,
            entries: HashMap::new(),
            sessions: HashMap::new(),
            generations: HashMap::new(),
        };
        actor.settle_after_restart().await.context("settle the sessions of the last run")?;
        tokio::spawn(actor.run(inbox, internal_inbox, runtime));
        Ok(ChatEngine { requests, checkpoints, adapters: Arc::new(adapters), attachments_dir })
    }

    async fn ask<T>(&self, request: impl FnOnce(oneshot::Sender<T>) -> Request) -> Result<T> {
        let (reply, answer) = oneshot::channel();
        self.requests.send(request(reply)).map_err(|_| anyhow!("the chat engine has stopped"))?;
        answer.await.map_err(|_| anyhow!("the chat engine stopped before it answered"))
    }

    /// Applies a client's command and everything it sets off that can be done at once; provider
    /// calls carry on in the background and report through [`ChatEngineEvent`]s.
    pub async fn dispatch(&self, command: ClientThreadCommand) -> Result<DispatchResult, ChatError> {
        self.ask(|reply| Request::Dispatch { command, reply }).await.map_err(ChatError::Internal)?
    }

    /// The whole thread, or `None` for one never made or deleted.
    pub async fn thread(&self, thread_id: ThreadId) -> Result<Option<OrchestrationThread>> {
        self.ask(|reply| Request::Thread { thread_id, reply }).await?
    }

    /// The whole thread with the sequence of the last event it includes, or `None` for one never
    /// made or deleted: what a client applies before the events that follow it.
    pub async fn thread_detail(&self, thread_id: ThreadId) -> Result<Option<(OrchestrationThread, u64)>> {
        self.ask(|reply| Request::ThreadDetail { thread_id, reply }).await?
    }

    /// Threads not deleted, newest first; `project` as [`ChatStore::list_shells`] takes it.
    pub async fn shells(&self, project: Option<String>) -> Result<Vec<OrchestrationThreadShell>> {
        self.ask(|reply| Request::Shells { project, reply }).await?
    }

    /// The providers this engine runs, with what they can do and the models they offer.
    pub async fn providers(&self) -> Vec<ProviderInfo> {
        self.adapters
            .iter()
            .map(|adapter| ProviderInfo {
                provider: adapter.provider(),
                capabilities: adapter.capabilities(),
                models: adapter.models(),
            })
            .collect()
    }

    /// Keeps an upload as `attachments/<id><ext>`, where the adapters look for it, and returns the
    /// attachment a `thread.turn.start` names it by.
    pub async fn save_attachment(
        &self,
        thread: ThreadId,
        name: String,
        mime_type: String,
        bytes: Vec<u8>,
    ) -> Result<ChatAttachment> {
        let size_bytes = bytes.len() as u64;
        let is_image = mime_type.to_ascii_lowercase().starts_with("image/");
        let limit = if is_image { PROVIDER_SEND_TURN_MAX_IMAGE_BYTES } else { PROVIDER_SEND_TURN_MAX_FILE_BYTES };
        if size_bytes > limit {
            anyhow::bail!("'{name}' is larger than the {limit} bytes an attachment may be.");
        }
        let safe_thread = to_safe_thread_attachment_segment(thread.as_str())
            .with_context(|| format!("thread '{thread}' cannot name an attachment"))?;
        let id = format!("{safe_thread}-{}", uuid::Uuid::new_v4());
        let attachment = if is_image {
            ChatAttachment::Image(ChatImageAttachment { id, name, mime_type, size_bytes })
        } else {
            ChatAttachment::File(ChatFileAttachment { id, name, mime_type, size_bytes })
        };
        let stored = match &attachment {
            ChatAttachment::Image(image) => StoredAttachment::Image(image),
            ChatAttachment::File(file) => StoredAttachment::File(file),
            ChatAttachment::AssistantSelection(_) => unreachable!("made above"),
        };
        let path = resolve_attachment_relative_path(&self.attachments_dir, &attachment_relative_path(stored))
            .context("the attachment's path leaves the attachments folder")?;
        tokio::task::spawn_blocking(move || -> Result<()> {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, bytes).with_context(|| format!("write {}", path.display()))
        })
        .await??;
        Ok(attachment)
    }

    /// Synara `attachments` HTTP read, as a call: the file a saved attachment's id names, and its
    /// bytes. `None` for an id that is not an attachment id
    /// ([`crate::provider::attachment_projection::is_attachment_id`]), for no such file, or for
    /// one larger than an attachment may be.
    pub async fn read_attachment(&self, id: String) -> Result<Option<(PathBuf, Vec<u8>)>> {
        let dir = self.attachments_dir.clone();
        tokio::task::spawn_blocking(move || -> Result<Option<(PathBuf, Vec<u8>)>> {
            let Some(path) = resolve_attachment_path_by_id(&dir, &id) else { return Ok(None) };
            let size = std::fs::metadata(&path)?.len();
            if size > PROVIDER_SEND_TURN_MAX_FILE_BYTES.max(PROVIDER_SEND_TURN_MAX_IMAGE_BYTES) {
                return Ok(None);
            }
            let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
            Ok(Some((path, bytes)))
        })
        .await?
    }

    /// Synara `orchestration.getTurnDiff` (`CheckpointDiffQuery.getTurnDiff`).
    pub async fn turn_diff(&self, input: OrchestrationGetTurnDiffInput) -> Result<ThreadTurnDiff, CheckpointDiffError> {
        let thread = self.thread(input.thread_id.clone()).await.map_err(|e| CheckpointDiffError::Failed(format!("{e:#}")))?;
        get_turn_diff(&self.checkpoints, thread.as_ref(), &input).await
    }

    /// Synara `orchestration.getFullThreadDiff` (`CheckpointDiffQuery.getFullThreadDiff`).
    pub async fn full_thread_diff(
        &self,
        input: OrchestrationGetFullThreadDiffInput,
    ) -> Result<ThreadTurnDiff, CheckpointDiffError> {
        let thread = self.thread(input.thread_id.clone()).await.map_err(|e| CheckpointDiffError::Failed(format!("{e:#}")))?;
        get_full_thread_diff(&self.checkpoints, thread.as_ref(), &input).await
    }

    /// Synara `orchestration.getShellSnapshot`: every thread's shell (archived ones included,
    /// newest first). Sequences are per thread here, so `snapshotSequence` is their sum, which
    /// grows whenever any thread takes an event.
    pub async fn shell_snapshot(&self) -> Result<OrchestrationShellSnapshot> {
        self.ask(|reply| Request::ShellSnapshot { reply }).await?
    }

    /// Stops every provider session and saves what is unsaved; the engine then stops.
    pub async fn shutdown(&self) {
        let _ = self.ask(|reply| Request::Shutdown { reply }).await;
    }
}

/// What a provider call or a git operation running beside the engine reports back.
pub(super) enum Internal {
    TurnSent {
        thread_id: ThreadId,
        generation: String,
        payload: ThreadTurnStartRequestedPayload,
        native_steer: bool,
        retried: bool,
        result: Result<ProviderTurnStartResult, String>,
    },
    Interrupted { thread_id: ThreadId, turn_id: Option<TurnId>, outcome: CallOutcome },
    Responded { thread_id: ThreadId, approval: bool, request_id: String, command_id: Option<String>, error: String },
    StopFailed { thread_id: ThreadId, detail: String },
    CheckpointCaptured(CapturedCheckpoint),
    Reverted { thread_id: ThreadId, turn_count: u64, result: Result<RevertOutcome, String> },
    /// A files-scope undo finished; on success, the checkpoint whose changes were taken back.
    FilesUndone { thread_id: ThreadId, turn_count: u64, result: Result<OrchestrationCheckpointSummary, String> },
    /// The edit's restore checkpoint was looked for in git before anything was reset.
    EditChecked { thread_id: ThreadId, restore: EditRestore, result: Result<(), String> },
    EditRestored { thread_id: ThreadId, edit: PendingEdit, result: Result<(), String> },
}

/// How a bounded provider call ended (Synara `runBoundedProviderCall`).
pub(super) enum CallOutcome {
    Ok,
    TimedOut,
    Failed(String),
}

pub(super) struct CapturedCheckpoint {
    pub thread_id: ThreadId,
    pub turn_id: TurnId,
    pub turn_count: u64,
    pub checkpoint_ref: CheckpointRef,
    pub status: OrchestrationCheckpointStatus,
    pub files: Vec<OrchestrationCheckpointFile>,
    pub failure: Option<String>,
    pub completed_at: crate::contracts::base::IsoDateTime,
}

pub(super) struct RevertOutcome {
    pub rolled_back_turns: u64,
    pub cwd: PathBuf,
    pub obsolete_refs: Vec<CheckpointRef>,
}

/// An edit-and-resend waiting for its workspace restore.
pub(super) struct PendingEdit {
    pub payload: ThreadMessageEditResendRequestedPayload,
    pub original: OrchestrationMessage,
}

/// Where an edit-and-resend puts the workspace back to, once its checkpoint is known to exist.
pub(super) struct EditRestore {
    pub edit: PendingEdit,
    pub cwd: PathBuf,
    pub target: CheckpointRef,
    pub target_count: u64,
}

/// A queued turn that has been handed to the provider and not yet finished (Synara's pending
/// queued dispatch reservation): the next one waits for it.
pub(super) struct Reservation {
    pub message_id: MessageId,
    pub turn_id: Option<TurnId>,
}

/// One thread as the engine holds it.
pub(super) struct Entry {
    /// The thread as it is now (`None` before `thread.created`).
    pub thread: Option<OrchestrationThread>,
    /// The thread as last saved.
    pub saved: Option<OrchestrationThread>,
    pub sequence: u64,
    pub runtime_sequence: u64,
    /// Projected since the last save.
    pub dirty: bool,
    /// When the unsaved streaming text must be saved.
    pub flush_at: Option<Instant>,
    /// The shell last published.
    pub shell: Option<OrchestrationThreadShell>,
    /// What resumes the provider's conversation.
    pub record: Option<ProviderSessionRecord>,
    /// A fork whose own first session has bound (`fork_bindings`): its conversation is its own
    /// for good, even once `record` is cleared, and its source's is never forked again.
    pub fork_bound: bool,
    /// Synara's queued turn promotions, in order.
    pub queue: VecDeque<ThreadTurnQueuedPayload>,
    pub reservation: Option<Reservation>,
    /// Terminal turn ids seen while the reservation was not yet bound to its turn.
    pub terminal_before_bind: HashSet<TurnId>,
    /// Serializes a thread's turn starts and checkpoint captures (Synara's thread lease).
    pub lease: Arc<tokio::sync::Mutex<()>>,
    /// When the thread was last loaded or used, for letting idle ones go.
    pub last_used: Instant,
    /// An edit-and-resend is checking or restoring the workspace: turn starts wait for it.
    pub edit_in_flight: bool,
    /// Turn starts that arrived while an edit was in flight, started when it ends.
    pub deferred_turn_starts: Vec<(OrchestrationEvent, ThreadTurnStartRequestedPayload)>,
}

/// A provider session the engine started.
pub(super) struct LiveSession {
    pub handle: ProviderSessionHandle,
    pub generation: String,
    pub provider: ProviderKind,
    pub cwd: String,
    pub runtime_mode: RuntimeMode,
    pub model_selection: ModelSelection,
    pub provider_options: Option<ProviderStartOptions>,
}

/// What one unit of work did to one thread, to save and publish when it ends.
pub(super) struct Ctx {
    pub thread_id: ThreadId,
    pub events: Vec<OrchestrationEvent>,
    pub record: Option<Option<ProviderSessionRecord>>,
}

impl Ctx {
    pub fn new(thread_id: ThreadId) -> Self {
        Self { thread_id, events: Vec::new(), record: None }
    }
}

pub(super) struct Actor {
    pub store: ChatStore,
    pub publish: Arc<dyn Fn(ChatEngineEvent) + Send + Sync>,
    pub spawner: Arc<dyn Spawner>,
    pub adapters: HashMap<ProviderKind, Arc<dyn ProviderAdapter>>,
    pub checkpoints: Arc<CheckpointStore>,
    pub ingestion: ProviderRuntimeIngestion,
    pub sink: mpsc::Sender<ProviderRuntimeEvent>,
    pub internal: mpsc::UnboundedSender<Internal>,
    pub entries: HashMap<ThreadId, Entry>,
    pub sessions: HashMap<ThreadId, LiveSession>,
    /// The lifecycle generation of the session each thread last started: events of an older
    /// one are dropped (Synara's lifecycle-generation guard).
    pub generations: HashMap<ThreadId, String>,
}

impl Actor {
    async fn run(
        mut self,
        mut requests: mpsc::UnboundedReceiver<Request>,
        mut internal: mpsc::UnboundedReceiver<Internal>,
        mut runtime: mpsc::Receiver<ProviderRuntimeEvent>,
    ) {
        let shutdown_reply = loop {
            let deadline = self.entries.values().filter_map(|e| e.flush_at).min();
            let flush = async move {
                match deadline {
                    Some(deadline) => tokio::time::sleep_until(deadline).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                request = requests.recv() => match request {
                    None => break None,
                    Some(Request::Shutdown { reply }) => break Some(reply),
                    Some(request) => self.on_request(request).await,
                },
                Some(message) = internal.recv() => self.on_internal(message).await,
                Some(event) = runtime.recv() => self.on_runtime(event).await,
                _ = flush => self.flush_due().await,
            }
            self.evict_idle();
        };
        self.stop_all_sessions().await;
        self.flush_all().await;
        if let Some(reply) = shutdown_reply {
            let _ = reply.send(());
        }
    }

    async fn on_request(&mut self, request: Request) {
        match request {
            Request::Dispatch { command, reply } => {
                let _ = reply.send(self.dispatch(command).await);
            }
            Request::Thread { thread_id, reply } => {
                let answer = match self.entries.get(&thread_id) {
                    Some(entry) => Ok(entry.thread.clone().filter(|t| t.deleted_at.is_none())),
                    None => self.store.load_thread(thread_id).await,
                };
                let _ = reply.send(answer);
            }
            Request::ThreadDetail { thread_id, reply } => {
                let answer = match self.entries.get(&thread_id) {
                    Some(entry) => Ok(entry.thread.clone().filter(|t| t.deleted_at.is_none()).map(|t| (t, entry.sequence))),
                    None => self.load_detail(thread_id).await,
                };
                let _ = reply.send(answer);
            }
            Request::Shells { project, reply } => {
                self.flush_all().await;
                let _ = reply.send(self.store.list_shells(project).await);
            }
            Request::ShellSnapshot { reply } => {
                self.flush_all().await;
                let snapshot = async {
                    let threads = self.store.list_shells(None).await?;
                    // One read for every thread's sequence, not one per thread on the actor.
                    let stored = self.store.thread_sequences().await?;
                    let snapshot_sequence = threads
                        .iter()
                        .map(|thread| match self.entries.get(&thread.id) {
                            Some(entry) => entry.sequence,
                            None => stored.get(&thread.id).copied().unwrap_or(0),
                        })
                        .sum();
                    Ok(OrchestrationShellSnapshot {
                        snapshot_sequence,
                        spaces: Vec::new(),
                        projects: Vec::new(),
                        threads,
                        updated_at: now_iso(),
                    })
                }
                .await;
                let _ = reply.send(snapshot);
            }
            Request::Shutdown { .. } => unreachable!("handled by the loop"),
        }
    }

    async fn dispatch(&mut self, command: ClientThreadCommand) -> Result<DispatchResult, ChatError> {
        let command = OrchestrationCommand::Client(command);
        let thread_id = command_thread_id(&command).clone();
        self.load(&thread_id).await.map_err(ChatError::Internal)?;
        let mut ctx = Ctx::new(thread_id.clone());
        let outcome = match &command {
            OrchestrationCommand::Client(ClientThreadCommand::ForkCreate(fork)) => {
                self.run_fork_create(&mut ctx, fork).await.map_err(ChatError::Internal)?
            }
            _ => self.run_command(&mut ctx, command),
        };
        let sequence = self.entries.get(&thread_id).map_or(0, |e| e.sequence);
        self.commit(ctx).await;
        self.forget_if_absent(&thread_id);
        match outcome {
            Ok(()) => Ok(DispatchResult { sequence }),
            Err(error) => Err(ChatError::Invalid(error.to_string())),
        }
    }

    /// A thread not in memory as stored, with its sequence.
    async fn load_detail(&self, thread_id: ThreadId) -> Result<Option<(OrchestrationThread, u64)>> {
        let Some(thread) = self.store.load_thread(thread_id.clone()).await? else {
            return Ok(None);
        };
        Ok(Some((thread, self.store.thread_sequence(thread_id).await?)))
    }

    /// Synara decides `thread.fork.create` against the whole read model: here the source thread
    /// and its project's threads (for the fork's title) are read first, then the fork is decided
    /// and its events go the way every command's do.
    async fn run_fork_create(&mut self, ctx: &mut Ctx, fork: &ThreadForkCreateCommand) -> Result<Result<(), DecideError>> {
        self.load(&fork.source_thread_id).await?;
        let source = self.thread(&fork.source_thread_id).cloned();
        self.forget_if_absent(&fork.source_thread_id);
        self.flush_all().await;
        let project_threads: Vec<ForkLineageThread> = self
            .store
            .list_shells(Some(fork.project_id.to_string()))
            .await?
            .into_iter()
            .map(|shell| ForkLineageThread {
                id: shell.id.to_string(),
                project_id: shell.project_id.to_string(),
                title: shell.title,
                fork_source_thread_id: shell.fork_source_thread_id.map(|id| id.to_string()),
            })
            .collect();
        let thread = self.entries.get(&ctx.thread_id).and_then(|e| e.thread.as_ref());
        match decide_fork_create(fork, thread, source.as_ref(), &project_threads) {
            Ok(events) => {
                self.apply_events(ctx, events);
                Ok(Ok(()))
            }
            Err(error) => Ok(Err(error)),
        }
    }

    /// Brings a thread into memory, with its sequence and its provider session record; for a fork
    /// that has no conversation of its own yet (no session of its own has ever bound), its source
    /// too, whose conversation the fork's first session forks (`ensure_session`).
    pub(super) async fn load(&mut self, thread_id: &ThreadId) -> Result<()> {
        self.load_one(thread_id).await?;
        let source = self
            .entries
            .get(thread_id)
            .filter(|entry| entry.record.is_none() && !entry.fork_bound)
            .and_then(|entry| entry.thread.as_ref())
            .and_then(|thread| thread.fork_source_thread_id.clone())
            .filter(|source| source != thread_id);
        if let Some(source) = source {
            match self.load_one(&source).await {
                Ok(()) => self.forget_if_absent(&source),
                Err(error) => tracing::warn!(thread = %source, "chat: a fork's source could not be read: {error:#}"),
            }
        }
        Ok(())
    }

    async fn load_one(&mut self, thread_id: &ThreadId) -> Result<()> {
        if let Some(entry) = self.entries.get_mut(thread_id) {
            entry.last_used = Instant::now();
            return Ok(());
        }
        let thread = self.store.load_thread(thread_id.clone()).await?;
        let sequence = self.store.thread_sequence(thread_id.clone()).await?;
        let record = self.store.provider_session(thread_id.clone()).await?;
        let fork_bound = match thread.as_ref().is_some_and(|t| t.fork_source_thread_id.is_some()) {
            true => self.store.fork_bound(thread_id.clone()).await?,
            false => false,
        };
        let shell = thread.as_ref().map(shell_of);
        self.entries.insert(
            thread_id.clone(),
            Entry {
                saved: thread.clone(),
                thread,
                sequence,
                runtime_sequence: sequence,
                dirty: false,
                flush_at: None,
                shell,
                record,
                fork_bound,
                queue: VecDeque::new(),
                reservation: None,
                terminal_before_bind: HashSet::new(),
                lease: Arc::new(tokio::sync::Mutex::new(())),
                last_used: Instant::now(),
                edit_in_flight: false,
                deferred_turn_starts: Vec::new(),
            },
        );
        Ok(())
    }

    /// Decides `command` against its thread, numbers and projects the events, lets ingestion and
    /// the reactor hear each, in order. The thread must be loaded.
    pub(super) fn run_command(&mut self, ctx: &mut Ctx, command: OrchestrationCommand) -> Result<(), DecideError> {
        if command_thread_id(&command) != &ctx.thread_id {
            tracing::warn!(thread = %ctx.thread_id, "chat: a command for another thread was dropped");
            return Ok(());
        }
        let Some(entry) = self.entries.get_mut(&ctx.thread_id) else {
            tracing::error!(thread = %ctx.thread_id, "chat: a command ran before its thread was loaded");
            return Ok(());
        };
        let events = decide(&command, entry.thread.as_ref(), &now_iso())?;
        self.apply_events(ctx, events);
        Ok(())
    }

    /// Numbers and projects decided events, then lets ingestion and the reactor hear each.
    fn apply_events(&mut self, ctx: &mut Ctx, events: Vec<OrchestrationEvent>) {
        let Some(entry) = self.entries.get_mut(&ctx.thread_id) else { return };
        let mut numbered = Vec::with_capacity(events.len());
        for mut event in events {
            entry.sequence += 1;
            event.sequence = entry.sequence;
            entry.thread = project(entry.thread.take(), &event);
            entry.dirty = true;
            numbered.push(event);
        }
        ctx.events.extend(numbered.iter().cloned());
        for event in &numbered {
            if matches!(
                event.body,
                OrchestrationEventBody::ThreadTurnStartRequested(_)
                    | OrchestrationEventBody::ThreadReverted(_)
                    | OrchestrationEventBody::ThreadConversationRolledBack(_)
            ) {
                let thread = self.entries.get(&ctx.thread_id).and_then(|e| e.thread.as_ref());
                for follow_up in self.ingestion.ingest_domain_event(thread, event) {
                    self.run_logged(ctx, follow_up);
                }
            }
            self.react(ctx, event);
        }
    }

    /// [`Self::run_command`] for the server's own commands: a refusal is logged, as Synara does.
    pub(super) fn run_logged(&mut self, ctx: &mut Ctx, command: impl Into<OrchestrationCommand>) {
        let command = command.into();
        let kind = super::decider::command_type(&command);
        if let Err(error) = self.run_command(ctx, command) {
            tracing::debug!(thread = %ctx.thread_id, command = kind, %error, "chat: an internal command was refused");
        }
    }

    /// Saves (or schedules the save of) what a unit of work did, then publishes it.
    pub(super) async fn commit(&mut self, ctx: Ctx) {
        let Ctx { thread_id, events, record } = ctx;
        let Some(entry) = self.entries.get_mut(&thread_id) else { return };
        if let Some(record) = &record {
            entry.record = record.clone();
        }
        // A fork's first session of its own has bound: never fork its source again.
        let fork_binds = matches!(record, Some(Some(_)))
            && !entry.fork_bound
            && entry.thread.as_ref().is_some_and(|t| t.fork_source_thread_id.is_some());
        if fork_binds {
            entry.fork_bound = true;
        }
        if events.is_empty() && record.is_none() {
            return;
        }
        let streaming_only = record.is_none() && events.iter().all(is_streaming_delta);
        if streaming_only {
            entry.flush_at.get_or_insert_with(|| Instant::now() + STREAMING_SAVE_INTERVAL);
        } else {
            self.save(&thread_id).await;
            if let Some(record) = record {
                let outcome = match record {
                    Some(record) => self.store.set_provider_session(record).await,
                    None => self.store.clear_provider_session(thread_id.clone()).await,
                };
                if let Err(error) = outcome {
                    tracing::warn!(thread = %thread_id, "chat: could not save the provider session: {error:#}");
                }
            }
            if fork_binds {
                if let Err(error) = self.store.set_fork_bound(thread_id.clone()).await {
                    tracing::warn!(thread = %thread_id, "chat: could not save the fork's binding: {error:#}");
                }
            }
        }
        if !events.is_empty() {
            (self.publish)(ChatEngineEvent::Thread { thread_id: thread_id.clone(), events });
        }
        let Some(entry) = self.entries.get_mut(&thread_id) else { return };
        match &entry.thread {
            Some(thread) if thread.deleted_at.is_some() => {
                self.entries.remove(&thread_id);
                (self.publish)(ChatEngineEvent::Removed { thread_id });
            }
            Some(thread) => {
                let shell = shell_of(thread);
                if entry.shell.as_ref() != Some(&shell) {
                    entry.shell = Some(shell.clone());
                    (self.publish)(ChatEngineEvent::Shell { shell });
                }
            }
            None => {}
        }
    }

    async fn save(&mut self, thread_id: &ThreadId) {
        let Some(entry) = self.entries.get_mut(thread_id) else { return };
        entry.flush_at = None;
        let Some(thread) = entry.thread.clone() else { return };
        if !entry.dirty {
            return;
        }
        match self.store.save_thread_at(entry.saved.clone(), thread.clone(), entry.sequence).await {
            Ok(()) => {
                entry.saved = Some(thread);
                entry.dirty = false;
            }
            Err(error) => tracing::error!(thread = %thread_id, "chat: could not save the thread: {error:#}"),
        }
    }

    async fn flush_due(&mut self) {
        let now = Instant::now();
        let due: Vec<ThreadId> =
            self.entries.iter().filter(|(_, e)| e.flush_at.is_some_and(|at| at <= now)).map(|(id, _)| id.clone()).collect();
        for thread_id in due {
            self.save(&thread_id).await;
        }
    }

    async fn flush_all(&mut self) {
        let dirty: Vec<ThreadId> = self.entries.iter().filter(|(_, e)| e.dirty).map(|(id, _)| id.clone()).collect();
        for thread_id in dirty {
            self.save(&thread_id).await;
        }
    }

    async fn stop_all_sessions(&mut self) {
        let stops: Vec<_> = self
            .sessions
            .drain()
            .map(|(_, live)| {
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(5), live.handle.stop()).await;
                })
            })
            .collect();
        for stop in stops {
            let _ = stop.await;
        }
    }

    async fn on_runtime(&mut self, event: ProviderRuntimeEvent) {
        let thread_id = event.thread_id.clone();
        if let (Some(generation), Some(current)) = (&event.lifecycle_generation, self.generations.get(&thread_id)) {
            if generation != current {
                return;
            }
        }
        if let Err(error) = self.load(&thread_id).await {
            tracing::warn!(thread = %thread_id, "chat: could not load a thread for a provider event: {error:#}");
            return;
        }
        if self.entries.get(&thread_id).and_then(|e| e.thread.as_ref()).is_none_or(|t| t.deleted_at.is_some()) {
            self.forget_if_absent(&thread_id);
            return;
        }
        let mut ctx = Ctx::new(thread_id);
        self.ingest_runtime(&mut ctx, &event);
        self.commit(ctx).await;
    }

    async fn on_internal(&mut self, message: Internal) {
        let thread_id = match &message {
            Internal::TurnSent { thread_id, .. }
            | Internal::Interrupted { thread_id, .. }
            | Internal::Responded { thread_id, .. }
            | Internal::StopFailed { thread_id, .. }
            | Internal::Reverted { thread_id, .. }
            | Internal::FilesUndone { thread_id, .. }
            | Internal::EditChecked { thread_id, .. }
            | Internal::EditRestored { thread_id, .. } => thread_id.clone(),
            Internal::CheckpointCaptured(captured) => captured.thread_id.clone(),
        };
        if self.load(&thread_id).await.is_err()
            || self.entries.get(&thread_id).and_then(|e| e.thread.as_ref()).is_none_or(|t| t.deleted_at.is_some())
        {
            self.forget_if_absent(&thread_id);
            return;
        }
        let mut ctx = Ctx::new(thread_id);
        self.handle_internal(&mut ctx, message);
        self.commit(ctx).await;
    }

    /// No CLI outlives the engine: a thread whose session was starting or running when the last
    /// run ended is settled as Synara settles a `session.exited` (stopped, its turn interrupted,
    /// its streaming text completed).
    async fn settle_after_restart(&mut self) -> Result<()> {
        for shell in self.store.list_shells(None).await? {
            let live = shell.session.as_ref().is_some_and(|s| {
                matches!(s.status, OrchestrationSessionStatus::Starting | OrchestrationSessionStatus::Running)
            });
            if !live {
                continue;
            }
            if let Err(error) = self.load(&shell.id).await {
                tracing::warn!(thread = %shell.id, "chat: a thread could not be read to settle it and is skipped: {error:#}");
                continue;
            }
            let mut ctx = Ctx::new(shell.id.clone());
            let Some(thread) = self.entries.get(&shell.id).and_then(|e| e.thread.clone()) else { continue };
            let now = now_iso();
            for message in thread.messages.iter().filter(|m| m.streaming && m.role == OrchestrationMessageRole::Assistant) {
                self.run_logged(
                    &mut ctx,
                    InternalThreadCommand::MessageAssistantComplete(ThreadMessageAssistantCompleteCommand {
                        async_questions: None,
                        command_id: server_command_id("assistant-complete-restart"),
                        thread_id: thread.id.clone(),
                        message_id: message.id.clone(),
                        turn_id: message.turn_id.clone(),
                        created_at: now.clone(),
                    }),
                );
            }
            if let Some(session) = thread.session.clone() {
                self.run_logged(
                    &mut ctx,
                    InternalThreadCommand::SessionSet(ThreadSessionSetCommand {
                        command_id: server_command_id("session-settle-restart"),
                        thread_id: thread.id.clone(),
                        session: OrchestrationSession {
                            status: OrchestrationSessionStatus::Stopped,
                            active_turn_id: None,
                            updated_at: now.clone(),
                            ..session
                        },
                        expected_session_status: None,
                        expected_session_updated_at: None,
                        created_at: now.clone(),
                    }),
                );
            }
            self.commit(ctx).await;
        }
        Ok(())
    }

    /// Lets go of the entry `load` made for a thread that does not exist (and that the command
    /// did not create), so an unknown id leaves nothing behind.
    fn forget_if_absent(&mut self, thread_id: &ThreadId) {
        if self.entries.get(thread_id).is_some_and(|e| e.thread.is_none() && !e.dirty) {
            self.entries.remove(thread_id);
        }
    }

    /// Lets the least recently used idle threads go once more than [`MAX_IDLE_THREADS_IN_MEMORY`]
    /// are held. Idle: no live session, nothing queued or reserved, nothing unsaved, and no task
    /// beside the engine holding its lease.
    fn evict_idle(&mut self) {
        if self.entries.len() <= MAX_IDLE_THREADS_IN_MEMORY {
            return;
        }
        let mut idle: Vec<(Instant, ThreadId)> = self
            .entries
            .iter()
            .filter(|(id, e)| {
                !self.sessions.contains_key(*id)
                    && e.queue.is_empty()
                    && e.reservation.is_none()
                    && !e.edit_in_flight
                    && !e.dirty
                    && e.flush_at.is_none()
                    && Arc::strong_count(&e.lease) == 1
            })
            .map(|(id, e)| (e.last_used, id.clone()))
            .collect();
        let excess = self.entries.len() - MAX_IDLE_THREADS_IN_MEMORY;
        idle.sort_by_key(|(last_used, _)| *last_used);
        for (_, thread_id) in idle.into_iter().take(excess) {
            self.entries.remove(&thread_id);
        }
    }

    pub(super) fn thread(&self, thread_id: &ThreadId) -> Option<&OrchestrationThread> {
        self.entries.get(thread_id).and_then(|e| e.thread.as_ref())
    }

    pub(super) fn entry_mut(&mut self, thread_id: &ThreadId) -> Option<&mut Entry> {
        self.entries.get_mut(thread_id)
    }

    /// The live session of a thread, if its CLI is still there.
    pub(super) fn live_session(&self, thread_id: &ThreadId) -> Option<&LiveSession> {
        self.sessions.get(thread_id).filter(|live| live.handle.is_alive())
    }
}

/// A batch made only of streamed assistant text is saved on a timer rather than at once.
fn is_streaming_delta(event: &OrchestrationEvent) -> bool {
    matches!(
        &event.body,
        OrchestrationEventBody::ThreadMessageSent(payload)
            if payload.streaming && payload.role == OrchestrationMessageRole::Assistant
    )
}

/// Synara `serverCommandId`: `server:<tag>:<uuid>`.
pub(super) fn server_command_id(tag: &str) -> crate::contracts::base::CommandId {
    crate::contracts::base::CommandId::new(format!("server:{tag}:{}", uuid::Uuid::new_v4()))
}

/// The folder a thread's provider runs in: the working directory, else the worktree (Synara
/// `resolveThreadWorkspaceCwd`, with no project root to fall back to).
pub fn resolve_cwd(thread: &OrchestrationThread) -> Result<String, String> {
    let working_directory = thread.working_directory.as_deref().filter(|d| !d.trim().is_empty());
    let worktree = thread.worktree_path.as_deref().filter(|d| !d.trim().is_empty());
    match thread.env_mode {
        ThreadEnvironmentMode::Worktree => {
            let Some(worktree) = worktree else {
                return Err(format!("Thread '{}' targets a worktree that has not been created yet.", thread.id));
            };
            Ok(working_directory
                .filter(|d| !d.contains("..") && Path::new(d).starts_with(worktree))
                .unwrap_or(worktree)
                .to_owned())
        }
        ThreadEnvironmentMode::Local => working_directory
            .or(worktree)
            .or(thread.associated_worktree_path.as_deref())
            .map(str::to_owned)
            .ok_or_else(|| format!("Thread '{}' has no working directory to run its provider in.", thread.id)),
    }
}

/// Synara `toSafeThreadAttachmentSegment` (attachmentStore.ts:25): the thread's part of an
/// attachment id, lower case, runs of other characters made one `-`, at most 80 characters.
fn to_safe_thread_attachment_segment(thread_id: &str) -> Option<String> {
    let mut segment = String::new();
    for c in thread_id.trim().to_lowercase().chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            segment.push(c);
        } else if !segment.ends_with('-') {
            segment.push('-');
        }
    }
    let trimmed = segment.trim_matches(|c| c == '-' || c == '_');
    let truncated: String = trimmed.chars().take(80).collect();
    let segment = truncated.trim_end_matches(|c| c == '-' || c == '_').to_owned();
    (!segment.is_empty()).then_some(segment)
}

/// Whether `path` is inside a git work tree, by looking for `.git` up the tree: ingestion asks
/// synchronously, so it does not run git.
pub(super) fn is_inside_git_work_tree(path: &Path) -> bool {
    path.ancestors().any(|dir| dir.join(".git").exists())
}

/// A thread's list-level fields.
pub fn shell_of(thread: &OrchestrationThread) -> OrchestrationThreadShell {
    let t = thread.clone();
    OrchestrationThreadShell {
        is_project_import: t.is_project_import,
        id: t.id,
        project_id: t.project_id,
        title: t.title,
        model_selection: t.model_selection,
        runtime_mode: t.runtime_mode,
        interaction_mode: t.interaction_mode,
        env_mode: t.env_mode,
        branch: t.branch,
        worktree_path: t.worktree_path,
        working_directory: t.working_directory,
        associated_worktree_path: t.associated_worktree_path,
        associated_worktree_branch: t.associated_worktree_branch,
        associated_worktree_ref: t.associated_worktree_ref,
        create_branch_flow_completed: t.create_branch_flow_completed,
        is_pinned: t.is_pinned,
        parent_thread_id: t.parent_thread_id,
        creation_source: t.creation_source,
        source_thread_id: t.source_thread_id,
        source_turn_id: t.source_turn_id,
        gateway_operation_id: t.gateway_operation_id,
        gateway_operation_index: t.gateway_operation_index,
        subagent_agent_id: t.subagent_agent_id,
        subagent_nickname: t.subagent_nickname,
        subagent_role: t.subagent_role,
        fork_source_thread_id: t.fork_source_thread_id,
        latest_turn: t.latest_turn,
        latest_user_message_at: t.latest_user_message_at,
        latest_human_message_at: t.latest_human_message_at,
        has_pending_approvals: t.has_pending_approvals,
        has_pending_user_input: t.has_pending_user_input,
        has_actionable_proposed_plan: t.has_actionable_proposed_plan,
        created_at: t.created_at,
        updated_at: t.updated_at,
        archived_at: t.archived_at,
        settled_at: t.settled_at,
        snoozed_until: t.snoozed_until,
        snooze_reminder_at: t.snooze_reminder_at,
        session: t.session,
    }
}

/// The turn input for a user message.
pub(super) fn send_turn_input(
    thread_id: &ThreadId,
    message: &OrchestrationMessage,
    model_selection: &ModelSelection,
    interaction_mode: ProviderInteractionMode,
) -> ProviderSendTurnInput {
    let attachments = message.attachments.clone().filter(|a| !a.is_empty());
    ProviderSendTurnInput {
        thread_id: thread_id.clone(),
        input: Some(message.text.clone()).filter(|t| !t.trim().is_empty()),
        attachments,
        skills: message.skills.clone(),
        mentions: message.mentions.clone(),
        model_selection: Some(model_selection.clone()),
        interaction_mode: Some(interaction_mode),
    }
}
