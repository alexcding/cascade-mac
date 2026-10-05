//! What the engine does when a thread takes an event: ported from Synara
//! `apps/server/src/orchestration/Layers/ProviderCommandReactor.ts` (`processDomainEvent` and the
//! handlers it calls), the session decisions of `provider/Layers/ProviderService.ts`, and the
//! capture, diff and revert of `orchestration/Layers/CheckpointReactor.ts`.
//!
//! Synara's reactor is a subscriber with durable delivery, leases and an interaction-claim table;
//! here it runs inside the engine's one task, so those collapse into plain state on the thread's
//! [`Entry`]. Provider calls and git run in tasks of their own and answer through
//! [`Internal`] messages. Not ported: goals, sidechats, handoffs, the Claude cache, computer
//! control, messaging a running subagent (`steerSubagent`), model-generated titles (the first-message fallback title is), the
//! context-bootstrap recap after a lost history, worktree branch renames, background-task stop and
//! backgrounding (no adapter supports them yet), and one-turn file undo.

use std::{path::PathBuf, time::Duration};

use serde_json::{json, Value};

use crate::{
    checkpointing::store::{
        checkpoint_ref_for_message_start, checkpoint_ref_for_thread_turn, checkpoint_ref_for_thread_turn_in_managed_family,
        checkpoint_ref_for_turn_start, checkpoint_ref_for_turn_start_in_managed_family, is_managed_checkpoint_ref,
        is_managed_checkpoint_ref_for_thread, revert_rescue_checkpoint_ref,
    },
    contracts::{
        base::{now_iso, CommandId, EventId, IsoDateTime, ProviderDriverKind, ThreadId, TurnId},
        orchestration::*,
        provider::ProviderSessionStartInput,
        provider_runtime::{ProviderRuntimeEvent, ProviderRuntimeEventBody, RuntimeTurnState},
    },
    persistence::store::ProviderSessionRecord,
    provider::adapter::ProviderSessionHandle,
};

use super::{
    activity_projection::runtime_turn_state,
    ingestion::resolve_subagent_provider_thread_id,
    decider::{collect_tail_turn_ids, model_selection_provider, CHECKPOINT_REVERT_FAILED_ACTIVITY_KIND},
    engine::{
        is_inside_git_work_tree, resolve_cwd, send_turn_input, server_command_id, Actor, CallOutcome,
        CapturedCheckpoint, Ctx, EditRestore, Internal, LiveSession, PendingEdit, Reservation, RevertOutcome,
    },
    ingestion::parse_checkpoint_files_from_unified_diff,
};

/// Synara `PROVIDER_COMMAND_INTERRUPT_TIMEOUT`
const PROVIDER_COMMAND_INTERRUPT_TIMEOUT: Duration = Duration::from_secs(10);
/// Synara `PROVIDER_COMMAND_STOP_TIMEOUT`
const PROVIDER_COMMAND_STOP_TIMEOUT: Duration = Duration::from_secs(15);
/// Synara `GENERIC_CHAT_THREAD_TITLE` (chatThreads.ts:6)
const GENERIC_CHAT_THREAD_TITLE: &str = "New thread";
/// Synara `MAX_CHAT_THREAD_TITLE_WORDS` (chatThreads.ts:25)
const MAX_CHAT_THREAD_TITLE_WORDS: usize = 6;
/// Synara `MAX_CHAT_THREAD_TITLE_LENGTH` (chatThreads.ts:7)
const MAX_CHAT_THREAD_TITLE_LENGTH: usize = 60;

/// What a turn asks of the session it runs in (Synara `ensureSessionForThread` options).
#[derive(Default)]
struct EnsureOptions {
    model_selection: Option<ModelSelection>,
    provider_options: Option<ProviderStartOptions>,
    runtime_mode: Option<RuntimeMode>,
}

/// Why a session could not be had. `reconfigure` is Synara's `session/reconfigure` validation
/// error: the thread's session is not put in error for it.
struct EnsureError {
    detail: String,
    reconfigure: bool,
}

impl EnsureError {
    fn new(detail: impl Into<String>) -> Self {
        Self { detail: detail.into(), reconfigure: false }
    }
}

struct EnsuredSession {
    handle: ProviderSessionHandle,
    generation: String,
    cwd: String,
    model_selection: ModelSelection,
}

impl Actor {
    /// Synara `processDomainEvent` (PCR:6673): the reaction to one event of `ctx`'s thread.
    pub(super) fn react(&mut self, ctx: &mut Ctx, event: &OrchestrationEvent) {
        use OrchestrationEventBody as E;
        match &event.body {
            E::ThreadDeleted(_) => self.on_thread_deleted(ctx),
            E::ThreadArchived(payload) => {
                let at = payload.archived_at.clone().or_else(|| payload.updated_at.clone()).unwrap_or_else(|| event.occurred_at.clone());
                self.process_session_stop(ctx, &at);
            }
            E::ThreadMetaUpdated(payload) => {
                if let Some(selection) = &payload.model_selection {
                    self.reconcile_idle_session(ctx, EnsureOptions { model_selection: Some(selection.clone()), ..Default::default() });
                }
            }
            E::ThreadRuntimeModeSet(payload) => {
                let selection = self.thread(&ctx.thread_id).map(|t| t.model_selection.clone());
                self.reconcile_idle_session(
                    ctx,
                    EnsureOptions { model_selection: selection, runtime_mode: Some(payload.runtime_mode), ..Default::default() },
                );
            }
            E::ThreadTurnQueued(payload) => {
                if let Some(entry) = self.entry_mut(&ctx.thread_id) {
                    entry.queue.push_back(payload.clone());
                }
            }
            E::ThreadTurnStartRequested(payload) => self.on_turn_start_requested(ctx, event, payload),
            E::ThreadTurnInterruptRequested(payload) => {
                self.interrupt_provider_turn(ctx, payload.turn_id.clone(), &payload.created_at)
            }
            E::ThreadTaskStopRequested(_) => self.append_provider_failure(
                ctx,
                "provider.task.stop.failed",
                "Provider task stop failed",
                json!({ "detail": "Stopping a background task is not supported by this provider session." }),
                None,
            ),
            E::ThreadTaskBackgroundRequested(_) => self.append_provider_failure(
                ctx,
                "provider.task.background.failed",
                "Provider task background failed",
                json!({ "detail": "Moving a tool call to the background is not supported by this provider session." }),
                None,
            ),
            E::ThreadApprovalResponseRequested(payload) => self.respond_to_interaction(
                ctx,
                event,
                true,
                payload.request_id.as_str(),
                payload.lifecycle_generation.clone(),
                Some(payload.decision),
                None,
            ),
            E::ThreadUserInputResponseRequested(payload) => self.respond_to_interaction(
                ctx,
                event,
                false,
                payload.request_id.as_str(),
                payload.lifecycle_generation.clone(),
                None,
                Some(payload.answers.clone()),
            ),
            E::ThreadCheckpointRevertRequested(payload) => self.on_checkpoint_revert_requested(ctx, payload),
            E::ThreadConversationRollbackRequested(payload) => self.on_conversation_rollback_requested(ctx, payload),
            E::ThreadMessageEditResendRequested(payload) => self.on_message_edit_resend_requested(ctx, payload),
            E::ThreadSessionStopRequested(payload) => self.process_session_stop(ctx, &payload.created_at),
            _ => {}
        }
    }

    // --- dispatch helpers (PCR:1474-1664) ---

    /// Synara `appendProviderFailureActivity` (PCR:1474)
    fn append_provider_failure(&mut self, ctx: &mut Ctx, kind: &str, summary: &str, payload: Value, turn_id: Option<TurnId>) {
        self.append_activity(ctx, OrchestrationThreadActivityTone::Error, kind, summary, payload, turn_id);
    }

    fn append_activity(
        &mut self,
        ctx: &mut Ctx,
        tone: OrchestrationThreadActivityTone,
        kind: &str,
        summary: &str,
        payload: Value,
        turn_id: Option<TurnId>,
    ) {
        let now = now_iso();
        self.run_logged(
            ctx,
            InternalThreadCommand::ActivityAppend(ThreadActivityAppendCommand {
                require_unarchived: None,
                command_id: server_command_id(kind),
                thread_id: ctx.thread_id.clone(),
                activity: OrchestrationThreadActivity {
                    id: EventId::new(uuid::Uuid::new_v4().to_string()),
                    tone,
                    kind: kind.to_owned(),
                    summary: summary.to_owned(),
                    payload,
                    turn_id,
                    sequence: None,
                    created_at: now.clone(),
                },
                created_at: now,
            }),
        );
    }

    fn set_session(&mut self, ctx: &mut Ctx, session: OrchestrationSession, tag: &str) {
        let now = now_iso();
        self.run_logged(
            ctx,
            InternalThreadCommand::SessionSet(ThreadSessionSetCommand {
                command_id: server_command_id(tag),
                thread_id: ctx.thread_id.clone(),
                session,
                expected_session_status: None,
                expected_session_updated_at: None,
                created_at: now,
            }),
        );
    }

    /// The thread's session with `change` applied, or a new one for a thread that has none.
    fn session_with(&self, thread_id: &ThreadId, change: impl FnOnce(&mut OrchestrationSession)) -> Option<OrchestrationSession> {
        let thread = self.thread(thread_id)?;
        let mut session = thread.session.clone().unwrap_or_else(|| OrchestrationSession {
            thread_id: thread.id.clone(),
            status: OrchestrationSessionStatus::Idle,
            provider_name: Some(model_selection_provider(&thread.model_selection).as_str().to_owned()),
            provider_instance_id: None,
            runtime_mode: thread.runtime_mode,
            active_turn_id: None,
            last_error: None,
            last_activity_at: None,
            last_progress_at: None,
            updated_at: now_iso(),
        });
        change(&mut session);
        Some(session)
    }

    /// Synara `setThreadSessionError` (PCR:1549)
    fn set_session_error(&mut self, ctx: &mut Ctx, detail: &str, runtime_mode: Option<RuntimeMode>) {
        let now = now_iso();
        let Some(session) = self.session_with(&ctx.thread_id, |session| {
            session.status = OrchestrationSessionStatus::Error;
            session.active_turn_id = None;
            session.last_error = Some(detail.to_owned());
            if let Some(mode) = runtime_mode {
                session.runtime_mode = mode;
            }
            session.updated_at = now;
        }) else {
            return;
        };
        self.set_session(ctx, session, "thread-session-error");
    }

    /// Synara `settleInterruptedProviderTurn` (PCR:1636)
    fn settle_interrupted_turn(&mut self, ctx: &mut Ctx, at: &IsoDateTime) {
        let Some(thread) = self.thread(&ctx.thread_id) else { return };
        let Some(session) = thread.session.clone() else { return };
        let latest_running = thread.latest_turn.as_ref().is_some_and(|t| t.state == OrchestrationLatestTurnState::Running);
        if session.active_turn_id.is_none() && !latest_running {
            return;
        }
        let status = match session.status {
            OrchestrationSessionStatus::Stopped | OrchestrationSessionStatus::Error => session.status,
            _ => OrchestrationSessionStatus::Interrupted,
        };
        self.set_session(
            ctx,
            OrchestrationSession { status, active_turn_id: None, updated_at: at.clone(), ..session },
            "thread-session-interrupted",
        );
    }

    fn set_record(&mut self, ctx: &mut Ctx, provider: ProviderKind, cursor: Value) {
        ctx.record = Some(Some(ProviderSessionRecord {
            thread_id: ctx.thread_id.clone(),
            provider: provider.as_str().to_owned(),
            resume_cursor: Some(cursor),
        }));
    }

    /// The resume cursor as this unit of work leaves it.
    fn current_record(&self, ctx: &Ctx) -> Option<ProviderSessionRecord> {
        match &ctx.record {
            Some(record) => record.clone(),
            None => self.entries.get(&ctx.thread_id).and_then(|e| e.record.clone()),
        }
    }

    fn stop_in_background(&self, thread_id: &ThreadId, handle: ProviderSessionHandle, report: bool) {
        let internal = self.internal.clone();
        let thread_id = thread_id.clone();
        tokio::spawn(async move {
            let detail = match tokio::time::timeout(PROVIDER_COMMAND_STOP_TIMEOUT, handle.stop()).await {
                Ok(Ok(())) => return,
                Ok(Err(error)) => format!("{error:#}"),
                Err(_) => format!(
                    "The provider session did not stop within {}ms.",
                    PROVIDER_COMMAND_STOP_TIMEOUT.as_millis()
                ),
            };
            if report {
                let _ = internal.send(Internal::StopFailed { thread_id, detail });
            }
        });
    }

    /// Synara `clearSessionResumeCursor` (PS:4560): stop the CLI and forget its conversation, so
    /// the next turn starts a fresh one. Also how a rollback reaches a provider here: Claude's
    /// rollback is this in Synara, and the session handle has no native Codex rollback.
    fn reset_provider_conversation(&mut self, ctx: &mut Ctx) {
        if let Some(handle) = self.take_provider_conversation(ctx) {
            self.stop_in_background(&ctx.thread_id, handle, false);
        }
    }

    /// [`Self::reset_provider_conversation`] that hands the caller the session to stop, so it can
    /// wait for the CLI to be gone before it touches the workspace.
    fn take_provider_conversation(&mut self, ctx: &mut Ctx) -> Option<ProviderSessionHandle> {
        let handle = self.sessions.remove(&ctx.thread_id).map(|live| live.handle);
        if self.current_record(ctx).is_some() {
            ctx.record = Some(None);
        }
        handle
    }

    // --- sessions (PCR:1934-2581, PS:2766-3258) ---

    /// Synara `ensureSessionForThread`: the live session when it still fits the turn, else a new
    /// one (resuming the stored conversation when only the workspace changed or nothing did).
    fn ensure_session(&mut self, ctx: &mut Ctx, options: EnsureOptions) -> Result<EnsuredSession, EnsureError> {
        let thread_id = ctx.thread_id.clone();
        let Some(thread) = self.thread(&thread_id).cloned() else {
            return Err(EnsureError::new(format!("Thread '{thread_id}' was not found in projection state.")));
        };
        let desired_runtime_mode = options.runtime_mode.unwrap_or(thread.runtime_mode);
        let live = self.live_session(&thread_id).filter(|_| {
            thread.session.as_ref().is_some_and(|s| s.status != OrchestrationSessionStatus::Stopped)
        });
        let bound_provider = live.map(|l| l.provider).or_else(|| {
            let established = thread.latest_turn.is_some()
                || thread.session.as_ref().is_some_and(|s| s.status == OrchestrationSessionStatus::Ready);
            established.then(|| model_selection_provider(&thread.model_selection))
        });
        let desired_selection = options.model_selection.unwrap_or_else(|| thread.model_selection.clone());
        let desired_provider = model_selection_provider(&desired_selection);
        if let Some(bound) = bound_provider.filter(|bound| *bound != desired_provider) {
            return Err(EnsureError::new(format!(
                "Thread '{thread_id}' is bound to provider '{}' and cannot switch to '{}'.",
                bound.as_str(),
                desired_provider.as_str()
            )));
        }
        let Some(adapter) = self.adapters.get(&desired_provider).cloned() else {
            return Err(EnsureError::new(format!("Unknown provider instance '{}'.", desired_provider.as_str())));
        };
        let cwd = resolve_cwd(&thread).map_err(EnsureError::new)?;
        let provider_options = options.provider_options.or_else(|| live.and_then(|l| l.provider_options.clone()));

        // Synara forks only a thread with no provider binding of its own (PS:3316): here, no
        // resume cursor yet (Codex has one once `thread/fork` answers, Claude once a turn is sent),
        // and none ever: a fork whose record a revert, an edit, a rollback or a stale resume
        // cleared starts a conversation of its own, not the source's again.
        let has_own_conversation = self.current_record(ctx).is_some()
            || self.entries.get(&thread_id).is_some_and(|entry| entry.fork_bound);
        let mut resume_cursor = self
            .current_record(ctx)
            .filter(|record| record.provider == desired_provider.as_str())
            .and_then(|record| record.resume_cursor);
        if let Some(live) = live {
            let runtime_changed = live.runtime_mode != desired_runtime_mode;
            let provider_changed = live.provider != desired_provider;
            let workspace_changed = live.cwd != cwd;
            let options_changed = live.provider_options != provider_options;
            let profile_changed = claude_selection_requires_restart(&live.model_selection, &desired_selection);
            if !(runtime_changed || provider_changed || workspace_changed || options_changed || profile_changed) {
                // Both providers switch models in session: the next turn carries the model.
                let live = self.sessions.get_mut(&thread_id).expect("checked live");
                live.model_selection = desired_selection.clone();
                return Ok(EnsuredSession {
                    handle: live.handle.clone(),
                    generation: live.generation.clone(),
                    cwd: live.cwd.clone(),
                    model_selection: desired_selection,
                });
            }
            if live.provider == ProviderKind::ClaudeAgent && thread.session.as_ref().is_some_and(|s| s.active_turn_id.is_some()) {
                return Err(EnsureError {
                    detail: "Wait for Claude's active turn to finish before changing session settings.".into(),
                    reconfigure: true,
                });
            }
            if runtime_changed || provider_changed || options_changed || profile_changed {
                resume_cursor = None;
            }
            let old = self.sessions.remove(&thread_id).expect("checked live");
            self.stop_in_background(&thread_id, old.handle, false);
        }

        // A session the thread no longer shows as running (stopped, or its CLI gone) is ended
        // before its replacement starts.
        if let Some(old) = self.sessions.remove(&thread_id) {
            self.stop_in_background(&thread_id, old.handle, false);
        }
        let fork_source_resume_cursor = match has_own_conversation {
            false => self.fork_source_resume_cursor(&thread, desired_provider),
            true => None,
        };
        let generation = uuid::Uuid::new_v4().to_string();
        let input = ProviderSessionStartInput {
            thread_id: thread_id.clone(),
            provider: Some(ProviderDriverKind::from(desired_provider)),
            lifecycle_generation: Some(generation.clone()),
            provider_instance_id: None,
            cwd: Some(cwd.clone()),
            model_selection: Some(desired_selection.clone()),
            resume_cursor,
            fork_source_resume_cursor,
            approval_policy: None,
            sandbox_mode: None,
            provider_options: provider_options.clone(),
            auto_approve_synara_tools: None,
            runtime_mode: desired_runtime_mode,
        };
        let handle = adapter.start_session(input, self.sink.clone(), self.spawner.clone());
        self.generations.insert(thread_id.clone(), generation.clone());
        self.sessions.insert(
            thread_id.clone(),
            LiveSession {
                handle: handle.clone(),
                generation: generation.clone(),
                provider: desired_provider,
                cwd: cwd.clone(),
                runtime_mode: desired_runtime_mode,
                model_selection: desired_selection.clone(),
                provider_options,
            },
        );
        // Synara `bindSessionToThread`: a session that is connecting shows as starting.
        let current = thread.session.as_ref().map(|s| s.status);
        if current != Some(OrchestrationSessionStatus::Starting) {
            let now = now_iso();
            if let Some(session) = self.session_with(&thread_id, |session| {
                session.status = OrchestrationSessionStatus::Starting;
                session.provider_name = Some(desired_provider.as_str().to_owned());
                session.runtime_mode = desired_runtime_mode;
                session.active_turn_id = None;
                session.last_error = None;
                session.updated_at = now;
            }) {
                self.set_session(ctx, session, "thread-session-bind");
            }
        }
        Ok(EnsuredSession { handle, generation, cwd, model_selection: desired_selection })
    }

    /// Synara `ProviderService.forkThread` (PS:3309) and the fork branch of
    /// `ensureSessionForThread` (PCR:2425): the source's conversation to fork the thread's first
    /// session from, when the source has one with the same provider. Claude does not fork a source
    /// whose turn is in flight (ClaudeAdapter.ts:7287); like any thread with no native fork, the
    /// fork then starts a conversation of its own. The engine loads a fork's source with it.
    fn fork_source_resume_cursor(&self, thread: &OrchestrationThread, provider: ProviderKind) -> Option<Value> {
        let source_id = thread.fork_source_thread_id.as_ref()?;
        let source = self.entries.get(source_id)?;
        let cursor = source.record.as_ref().filter(|r| r.provider == provider.as_str())?.resume_cursor.clone()?;
        if provider == ProviderKind::ClaudeAgent {
            let busy = self.live_session(source_id).is_some()
                && source.thread.as_ref().and_then(|t| t.session.as_ref()).is_some_and(|s| s.active_turn_id.is_some());
            if busy {
                tracing::info!(thread = %thread.id, source = %source_id, "chat: the fork's source has a turn in flight; not forked natively");
                return None;
            }
        }
        Some(cursor)
    }

    /// `thread.meta-updated` with a model and `thread.runtime-mode-set` (PCR:6744, 6809): only an
    /// idle live session is reconciled now; a busy or absent one is at the next turn.
    fn reconcile_idle_session(&mut self, ctx: &mut Ctx, options: EnsureOptions) {
        let Some(thread) = self.thread(&ctx.thread_id) else { return };
        let idle = thread
            .session
            .as_ref()
            .is_some_and(|s| s.status != OrchestrationSessionStatus::Stopped && s.active_turn_id.is_none());
        if !idle || self.live_session(&ctx.thread_id).is_none() {
            return;
        }
        if let Err(error) = self.ensure_session(ctx, options) {
            tracing::warn!(thread = %ctx.thread_id, "chat: could not reconcile the session: {}", error.detail);
        }
    }

    /// Synara `processThreadSessionStop` (PCR:6227): stop the CLI, keep its conversation for the
    /// next turn, and show the session stopped.
    fn process_session_stop(&mut self, ctx: &mut Ctx, at: &IsoDateTime) {
        if let Some(entry) = self.entry_mut(&ctx.thread_id) {
            entry.queue.clear();
            entry.reservation = None;
            entry.terminal_before_bind.clear();
        }
        let stopped = self
            .thread(&ctx.thread_id)
            .and_then(|t| t.session.as_ref())
            .is_none_or(|s| s.status == OrchestrationSessionStatus::Stopped);
        if let Some(live) = self.sessions.remove(&ctx.thread_id) {
            if !stopped {
                self.stop_in_background(&ctx.thread_id, live.handle, true);
            }
        }
        let Some(session) = self.thread(&ctx.thread_id).and_then(|t| t.session.clone()) else { return };
        self.set_session(
            ctx,
            OrchestrationSession {
                status: OrchestrationSessionStatus::Stopped,
                active_turn_id: None,
                updated_at: at.clone(),
                ..session
            },
            "thread-session-stop",
        );
    }

    fn on_thread_deleted(&mut self, ctx: &mut Ctx) {
        if let Some(entry) = self.entry_mut(&ctx.thread_id) {
            entry.queue.clear();
            entry.reservation = None;
        }
        if let Some(live) = self.sessions.remove(&ctx.thread_id) {
            self.stop_in_background(&ctx.thread_id, live.handle, false);
        }
        self.generations.remove(&ctx.thread_id);
    }

    // --- turns (PCR:4118-4510, 2756-3766) ---

    /// The provider turn running now: the session is live and the read model has it running.
    fn live_turn(&self, thread_id: &ThreadId) -> Option<TurnId> {
        self.live_session(thread_id)?;
        let session = self.thread(thread_id)?.session.as_ref()?;
        (session.status == OrchestrationSessionStatus::Running).then(|| session.active_turn_id.clone()).flatten()
    }

    /// Synara `processTurnStartRequestedWithoutLease` (PCR:4118)
    fn on_turn_start_requested(&mut self, ctx: &mut Ctx, event: &OrchestrationEvent, payload: &ThreadTurnStartRequestedPayload) {
        // A turn must not start against a workspace an edit is about to restore, nor be stopped
        // by that edit's reset: it starts once the edit is done.
        if let Some(entry) = self.entry_mut(&ctx.thread_id) {
            if entry.edit_in_flight {
                entry.deferred_turn_starts.push((event.clone(), payload.clone()));
                return;
            }
        }
        let Some(thread) = self.thread(&ctx.thread_id).cloned() else { return };
        let Some(message) = thread.messages.iter().find(|m| m.id == payload.message_id).cloned() else {
            self.append_provider_failure(
                ctx,
                "provider.turn.start.failed",
                "Provider turn start failed",
                json!({ "detail": format!("User message '{}' was not found for turn start request.", payload.message_id) }),
                None,
            );
            return;
        };
        let live_turn = self.live_turn(&ctx.thread_id);
        let provider = self
            .live_session(&ctx.thread_id)
            .map(|l| l.provider)
            .unwrap_or_else(|| model_selection_provider(&thread.model_selection));
        let steers = self.adapters.get(&provider).is_some_and(|a| a.capabilities().supports_turn_steering);
        let steer = payload.dispatch_mode == TurnDispatchMode::Steer;
        let native_steer = steer && steers && live_turn.is_some();
        if steer {
            self.run_logged(
                ctx,
                InternalThreadCommand::MessageUserSetTurnBoundary(ThreadMessageUserSetTurnBoundaryCommand {
                    command_id: CommandId::new(format!(
                        "server:message-turn-boundary:{}:{}",
                        event.event_id,
                        if native_steer { "continuation" } else { "new-turn" }
                    )),
                    thread_id: ctx.thread_id.clone(),
                    message_id: payload.message_id.clone(),
                    starts_new_turn: !native_steer,
                    created_at: payload.created_at.clone(),
                }),
            );
        }
        if !native_steer && live_turn.is_some() {
            // Steer by interrupt, then queue: the turn runs when the live one ends.
            if let Some(entry) = self.entry_mut(&ctx.thread_id) {
                entry.queue.push_back(payload.clone());
            }
            if steer {
                self.interrupt_provider_turn(ctx, live_turn, &payload.created_at);
            }
            return;
        }
        self.maybe_rename_thread_for_first_turn(ctx, &message);
        self.dispatch_turn(ctx, payload.clone(), message, native_steer, false);
    }

    /// Synara `dispatchTurnForThreadCore`: have a session, then send (or steer) the turn beside
    /// the engine. The workspace is checkpointed before a new turn starts.
    fn dispatch_turn(
        &mut self,
        ctx: &mut Ctx,
        payload: ThreadTurnStartRequestedPayload,
        message: OrchestrationMessage,
        native_steer: bool,
        retried: bool,
    ) {
        if message.text.trim().is_empty() && message.attachments.as_ref().is_none_or(Vec::is_empty) {
            self.turn_start_failed(ctx, &payload, "Either input text or at least one attachment is required", false);
            return;
        }
        let options = EnsureOptions {
            model_selection: payload.model_selection.clone(),
            provider_options: payload.provider_options.clone(),
            runtime_mode: Some(payload.runtime_mode),
        };
        let session = match self.ensure_session(ctx, options) {
            Ok(session) => session,
            Err(error) => {
                self.turn_start_failed(ctx, &payload, &error.detail, error.reconfigure);
                return;
            }
        };
        let Some(entry) = self.entries.get(&ctx.thread_id) else { return };
        let thread = entry.thread.as_ref().expect("a turn's thread exists");
        let baseline_count = thread.checkpoints.iter().map(|c| c.checkpoint_turn_count).max().unwrap_or(0);
        let input = send_turn_input(&ctx.thread_id, &message, &session.model_selection, payload.interaction_mode);
        let lease = entry.lease.clone();
        let checkpoints = self.checkpoints.clone();
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        let cwd = PathBuf::from(&session.cwd);
        tokio::spawn(async move {
            let _lease = lease.lock().await;
            let message_start = checkpoint_ref_for_message_start(&thread_id, &payload.message_id);
            let checkpointed = !native_steer && checkpoints.is_git_repository(&cwd).await;
            if checkpointed {
                // Synara `captureMessageStartCheckpoint` and `ensurePreTurnBaselineFromDomainTurnStart`.
                if let Err(error) = checkpoints.capture_checkpoint(&cwd, &message_start, true).await {
                    tracing::warn!(thread = %thread_id, "chat: message-start checkpoint failed: {error:#}");
                }
                let baseline = checkpoint_ref_for_thread_turn(&thread_id, baseline_count);
                if let Err(error) = checkpoints.capture_checkpoint(&cwd, &baseline, true).await {
                    tracing::warn!(thread = %thread_id, "chat: baseline checkpoint failed: {error:#}");
                }
            }
            // Synara `dispatchTurnForThreadCore` (PCR:3482): a turn that carries a review target
            // is the provider's native review (`ProviderService.startReview`), not a message.
            let result = match (&payload.review_target, native_steer) {
                (Some(target), _) => session.handle.start_review(target.clone()).await,
                (None, true) => session.handle.steer_turn(input).await,
                (None, false) => session.handle.send_turn(input).await,
            };
            if let (true, Ok(started)) = (checkpointed, &result) {
                // Synara copies message-start to turn-start on `turn.started` (CR:806).
                let turn_start = checkpoint_ref_for_turn_start(&thread_id, &started.turn_id);
                match checkpoints.copy_checkpoint_ref(&cwd, &message_start, &turn_start).await {
                    Ok(true) => {}
                    _ => {
                        if let Err(error) = checkpoints.capture_checkpoint(&cwd, &turn_start, true).await {
                            tracing::warn!(thread = %thread_id, "chat: turn-start checkpoint failed: {error:#}");
                        }
                    }
                }
            }
            let _ = internal.send(Internal::TurnSent {
                thread_id,
                generation: session.generation,
                payload,
                native_steer,
                retried,
                result: result.map_err(|error| format!("{error:#}")),
            });
        });
    }

    /// The failure path of a turn start (PCR:4388)
    fn turn_start_failed(&mut self, ctx: &mut Ctx, payload: &ThreadTurnStartRequestedPayload, detail: &str, reconfigure: bool) {
        self.append_provider_failure(
            ctx,
            "provider.turn.start.failed",
            "Provider turn start failed",
            json!({ "detail": detail }),
            None,
        );
        if reconfigure {
            // The live session keeps running its turn: undo only an optimistic "starting".
            if let Some(session) = self.thread(&ctx.thread_id).and_then(|t| t.session.clone()) {
                if session.status == OrchestrationSessionStatus::Starting && self.live_session(&ctx.thread_id).is_some() {
                    self.set_session(
                        ctx,
                        OrchestrationSession { status: OrchestrationSessionStatus::Ready, updated_at: now_iso(), ..session },
                        "thread-session-reconfigure",
                    );
                }
            }
        } else {
            self.set_session_error(ctx, detail, Some(payload.runtime_mode));
        }
        if let Some(entry) = self.entry_mut(&ctx.thread_id) {
            if entry.reservation.as_ref().is_some_and(|r| r.message_id == payload.message_id) {
                entry.reservation = None;
            }
        }
        self.drain_queued_turns(ctx);
    }

    fn on_turn_sent(
        &mut self,
        ctx: &mut Ctx,
        generation: String,
        payload: ThreadTurnStartRequestedPayload,
        native_steer: bool,
        retried: bool,
        result: Result<crate::contracts::provider::ProviderTurnStartResult, String>,
    ) {
        match result {
            Ok(started) => {
                if let Some(cursor) = started.resume_cursor.clone() {
                    let provider = self
                        .sessions
                        .get(&ctx.thread_id)
                        .filter(|live| live.generation == generation)
                        .map(|live| live.provider);
                    if let Some(provider) = provider {
                        self.set_record(ctx, provider, cursor);
                    }
                }
                if payload.dispatch_mode == TurnDispatchMode::Steer && !native_steer {
                    self.run_logged(
                        ctx,
                        InternalThreadCommand::MessageUserBindTurn(ThreadMessageUserBindTurnCommand {
                            command_id: CommandId::new(format!("server:message-turn-bind:{}:{}", payload.message_id, started.turn_id)),
                            thread_id: ctx.thread_id.clone(),
                            message_id: payload.message_id.clone(),
                            turn_id: started.turn_id.clone(),
                            created_at: payload.created_at.clone(),
                        }),
                    );
                }
                let mut drain = false;
                if let Some(entry) = self.entry_mut(&ctx.thread_id) {
                    if entry.reservation.as_ref().is_some_and(|r| r.message_id == payload.message_id) {
                        if entry.terminal_before_bind.remove(&started.turn_id) {
                            entry.reservation = None;
                            drain = true;
                        } else if let Some(reservation) = entry.reservation.as_mut() {
                            reservation.turn_id = Some(started.turn_id.clone());
                        }
                    }
                    entry.terminal_before_bind.clear();
                }
                if drain {
                    self.drain_queued_turns(ctx);
                }
            }
            Err(detail) if !retried && is_stale_claude_resume_error(&detail) => {
                // Synara's stale-resume retry (PCR:3591): forget the conversation and send again.
                self.reset_provider_conversation(ctx);
                let message = self
                    .thread(&ctx.thread_id)
                    .and_then(|t| t.messages.iter().find(|m| m.id == payload.message_id).cloned());
                match message {
                    Some(message) => self.dispatch_turn(ctx, payload, message, native_steer, true),
                    None => self.turn_start_failed(ctx, &payload, &detail, false),
                }
            }
            Err(detail) => self.turn_start_failed(ctx, &payload, &detail, false),
        }
    }

    /// Synara `maybeGenerateAndRenameThreadTitleForFirstTurn` (PCR:4026) without a text model:
    /// the first user message names a thread that has the generic title.
    fn maybe_rename_thread_for_first_turn(&mut self, ctx: &mut Ctx, message: &OrchestrationMessage) {
        let Some(thread) = self.thread(&ctx.thread_id) else { return };
        let mut natives = thread.messages.iter().filter(|m| {
            m.role == OrchestrationMessageRole::User
                && matches!(m.source, OrchestrationMessageSource::Native | OrchestrationMessageSource::AsyncUserInput)
        });
        let (Some(first), None) = (natives.next(), natives.next()) else { return };
        if first.id != message.id {
            return;
        }
        let seed = match message.text.trim() {
            "" => message.attachments.as_ref().and_then(|a| a.first()).map(attachment_title_seed).unwrap_or_default(),
            text => text.to_owned(),
        };
        let fallback = build_prompt_thread_title_fallback(&seed);
        let current = thread.title.trim().to_owned();
        if normalize_title_whitespace(&current) != GENERIC_CHAT_THREAD_TITLE && current != fallback {
            return;
        }
        if fallback == current {
            return;
        }
        let command: ClientThreadCommand = match serde_json::from_value(json!({
            "type": "thread.meta.update",
            "commandId": server_command_id("thread-title-fallback-rename"),
            "threadId": ctx.thread_id,
            "title": fallback,
        })) {
            Ok(command) => command,
            Err(error) => {
                tracing::error!("chat: the title command did not build: {error}");
                return;
            }
        };
        self.run_logged(ctx, command);
    }

    // --- interrupts (PCR:5538-5692) ---

    /// Synara `interruptProviderTurn`
    fn interrupt_provider_turn(&mut self, ctx: &mut Ctx, requested_turn: Option<TurnId>, at: &IsoDateTime) {
        let Some(thread) = self.thread(&ctx.thread_id).cloned() else { return };
        let session = thread.session.as_ref();
        // A subagent shares its parent's session: its run is stopped, not the session (PCR:6304).
        let child = thread.parent_thread_id.as_ref().and_then(|parent| {
            Some((parent.clone(), resolve_subagent_provider_thread_id(&thread.id, Some(parent))?))
        });
        if let Some((parent_id, provider_thread_id)) = child {
            let running_turn = session
                .filter(|s| s.status == OrchestrationSessionStatus::Running)
                .and_then(|s| s.active_turn_id.clone());
            let parent_handle = self.live_session(&parent_id).map(|live| live.handle.clone());
            if let (Some(turn_id), Some(handle)) = (running_turn, parent_handle) {
                let internal = self.internal.clone();
                let thread_id = ctx.thread_id.clone();
                tokio::spawn(async move {
                    let call = handle.interrupt_subagent(Some(turn_id.clone()), provider_thread_id);
                    let outcome = match tokio::time::timeout(PROVIDER_COMMAND_INTERRUPT_TIMEOUT, call).await {
                        Ok(Ok(())) => CallOutcome::Ok,
                        Ok(Err(error)) => CallOutcome::Failed(format!("{error:#}")),
                        Err(_) => CallOutcome::TimedOut,
                    };
                    let _ = internal.send(Internal::Interrupted { thread_id, turn_id: Some(turn_id), outcome });
                });
                return;
            }
        }
        let live_turn = self.live_turn(&ctx.thread_id);
        let latest_running = thread.latest_turn.as_ref().is_some_and(|t| t.state == OrchestrationLatestTurnState::Running);
        let stuck = session.is_some_and(|s| {
            matches!(s.status, OrchestrationSessionStatus::Starting | OrchestrationSessionStatus::Running)
                && s.active_turn_id.is_none()
        });
        if stuck && !latest_running && live_turn.is_none() {
            // No provider turn to interrupt: stopping is the way out of a stuck start.
            self.process_session_stop(ctx, at);
            return;
        }
        let stopped = session.is_none_or(|s| s.status == OrchestrationSessionStatus::Stopped);
        let Some(handle) = self.live_session(&ctx.thread_id).filter(|_| !stopped).map(|l| l.handle.clone()) else {
            self.append_provider_failure(
                ctx,
                "provider.turn.interrupt.failed",
                "Provider turn interrupt failed",
                json!({ "detail": "No active provider session is bound to this thread." }),
                requested_turn,
            );
            self.settle_interrupted_turn(ctx, at);
            return;
        };
        let turn_id = live_turn.or(requested_turn).or_else(|| session.and_then(|s| s.active_turn_id.clone()));
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        tokio::spawn(async move {
            let outcome = match tokio::time::timeout(PROVIDER_COMMAND_INTERRUPT_TIMEOUT, handle.interrupt_turn(turn_id.clone())).await {
                Ok(Ok(())) => CallOutcome::Ok,
                Ok(Err(error)) => CallOutcome::Failed(format!("{error:#}")),
                Err(_) => CallOutcome::TimedOut,
            };
            let _ = internal.send(Internal::Interrupted { thread_id, turn_id, outcome });
        });
    }

    fn on_interrupted(&mut self, ctx: &mut Ctx, turn_id: Option<TurnId>, outcome: CallOutcome) {
        let now = now_iso();
        match outcome {
            CallOutcome::Ok => {}
            // The parent was never told to end the child's turn, so no terminal child event is
            // coming: the child's turn is settled here (PCR:6330).
            CallOutcome::TimedOut if self.thread(&ctx.thread_id).is_some_and(|t| t.parent_thread_id.is_some()) => {
                self.append_provider_failure(
                    ctx,
                    "provider.turn.interrupt.failed",
                    "Provider turn interrupt failed",
                    json!({
                        "detail": format!("The provider did not confirm the interrupt within {}ms.", PROVIDER_COMMAND_INTERRUPT_TIMEOUT.as_millis()),
                        "settlementStatus": "uncertain",
                    }),
                    turn_id,
                );
                self.settle_interrupted_turn(ctx, &now);
            }
            CallOutcome::TimedOut => {
                self.append_provider_failure(
                    ctx,
                    "provider.turn.interrupt.failed",
                    "Provider turn interrupt failed",
                    json!({
                        "detail": format!(
                            "The provider did not confirm the interrupt within {}ms. Stopping the provider session to settle the turn.",
                            PROVIDER_COMMAND_INTERRUPT_TIMEOUT.as_millis()
                        ),
                        "settlementStatus": "uncertain",
                    }),
                    turn_id,
                );
                self.process_session_stop(ctx, &now);
            }
            CallOutcome::Failed(detail) => {
                self.append_provider_failure(
                    ctx,
                    "provider.turn.interrupt.failed",
                    "Provider turn interrupt failed",
                    json!({ "detail": detail }),
                    turn_id,
                );
                self.settle_interrupted_turn(ctx, &now);
            }
        }
    }

    // --- approvals and user input (PCR:5764-5960) ---

    #[allow(clippy::too_many_arguments)]
    fn respond_to_interaction(
        &mut self,
        ctx: &mut Ctx,
        event: &OrchestrationEvent,
        approval: bool,
        request_id: &str,
        lifecycle_generation: Option<String>,
        decision: Option<ProviderApprovalDecision>,
        answers: Option<ProviderUserInputAnswers>,
    ) {
        let command_id = event.command_id.as_ref().map(|c| c.as_str().to_owned());
        let stopped = self
            .thread(&ctx.thread_id)
            .and_then(|t| t.session.as_ref())
            .is_none_or(|s| s.status == OrchestrationSessionStatus::Stopped);
        let Some(live) = self.live_session(&ctx.thread_id).filter(|_| !stopped) else {
            self.append_interaction_failure(
                ctx,
                approval,
                request_id,
                command_id,
                lifecycle_generation,
                &stale_pending_request_failure_detail(approval, request_id),
                "uncertain",
            );
            return;
        };
        let handle = live.handle.clone();
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        let request = crate::contracts::base::ApprovalRequestId::new(request_id);
        let request_id = request_id.to_owned();
        tokio::spawn(async move {
            let outcome = match (decision, answers) {
                (Some(decision), _) => handle.respond_to_request(request, decision).await,
                (None, Some(answers)) => handle.respond_to_user_input(request, answers).await,
                (None, None) => Ok(()),
            };
            if let Err(error) = outcome {
                let _ = internal.send(Internal::Responded { thread_id, approval, request_id, command_id, error: format!("{error:#}") });
            }
        });
    }

    /// Synara `appendInteractionResponseFailure` (PCR:5764)
    #[allow(clippy::too_many_arguments)]
    fn append_interaction_failure(
        &mut self,
        ctx: &mut Ctx,
        approval: bool,
        request_id: &str,
        command_id: Option<String>,
        lifecycle_generation: Option<String>,
        detail: &str,
        settlement_status: &str,
    ) {
        let Some(command_id) = command_id else { return };
        let (kind, summary) = if approval {
            ("provider.approval.respond.failed", "Provider approval response failed")
        } else {
            ("provider.user-input.respond.failed", "Provider user input response failed")
        };
        let mut payload = json!({
            "detail": detail,
            "requestId": request_id,
            "responseCommandId": command_id,
            "settlementStatus": settlement_status,
        });
        if let Some(generation) = lifecycle_generation {
            payload["lifecycleGeneration"] = json!(generation);
        }
        self.append_provider_failure(ctx, kind, summary, payload, None);
    }

    // --- runtime events (PRI and PS `updateSessionBindingFromRuntimeEvent`) ---

    /// One provider runtime event: ingestion's commands, then what the session, the queue and the
    /// checkpoints make of it.
    pub(super) fn ingest_runtime(&mut self, ctx: &mut Ctx, event: &ProviderRuntimeEvent) {
        let Some(entry) = self.entries.get_mut(&ctx.thread_id) else { return };
        // One order for runtime and engine rows: never behind the thread's own sequence.
        entry.runtime_sequence = entry.runtime_sequence.max(entry.sequence) + 1;
        let runtime_sequence = entry.runtime_sequence;
        let Some(thread) = self.entries.get(&ctx.thread_id).and_then(|e| e.thread.as_ref()) else { return };
        let commands = self.ingestion.ingest(thread, event, runtime_sequence);
        for command in commands {
            self.run_logged(ctx, command);
        }
        match &event.body {
            ProviderRuntimeEventBody::SessionStarted(payload) => {
                let cursor = payload
                    .resume
                    .clone()
                    .filter(|r| r.as_object().is_some_and(|o| o.contains_key("resume") || o.contains_key("threadId")));
                let provider = self.live_session(&ctx.thread_id).map(|l| l.provider);
                if let (Some(cursor), Some(provider)) = (cursor, provider) {
                    self.set_record(ctx, provider, cursor);
                }
            }
            ProviderRuntimeEventBody::TurnCompleted(_) | ProviderRuntimeEventBody::TurnAborted(_) => {
                self.capture_turn_checkpoint(ctx, event);
                self.on_terminal_turn(ctx, event.turn_id.as_ref());
            }
            ProviderRuntimeEventBody::SessionExited(_) => {
                let ended = self.sessions.get(&ctx.thread_id).is_some_and(|live| {
                    event.lifecycle_generation.as_ref().is_none_or(|g| *g == live.generation)
                });
                if ended {
                    self.sessions.remove(&ctx.thread_id);
                }
                if let Some(entry) = self.entry_mut(&ctx.thread_id) {
                    entry.reservation = None;
                    entry.terminal_before_bind.clear();
                }
            }
            _ => {}
        }
    }

    /// A subagent's runtime event, ingested against its child thread. What follows a parent's
    /// events (the session's binding, checkpoints, the queue) is the parent session's and is left
    /// alone, as Synara's `updateSessionBindingFromRuntimeEvent` leaves subagent events.
    pub(super) fn ingest_subagent_runtime(&mut self, ctx: &mut Ctx, event: &ProviderRuntimeEvent) {
        let Some(entry) = self.entries.get_mut(&ctx.thread_id) else { return };
        entry.runtime_sequence = entry.runtime_sequence.max(entry.sequence) + 1;
        let runtime_sequence = entry.runtime_sequence;
        let Some(thread) = self.entries.get(&ctx.thread_id).and_then(|e| e.thread.as_ref()) else { return };
        let commands = self.ingestion.ingest(thread, event, runtime_sequence);
        for command in commands {
            self.run_logged(ctx, command);
        }
    }

    // --- queued turns (PCR:5040-5160, 5478-5536) ---

    /// Synara `processQueueDrainEvent`: a terminal turn releases the queued turn it was, then the
    /// next one goes.
    fn on_terminal_turn(&mut self, ctx: &mut Ctx, turn_id: Option<&TurnId>) {
        let Some(entry) = self.entry_mut(&ctx.thread_id) else { return };
        if let Some(reservation) = &entry.reservation {
            match &reservation.turn_id {
                Some(bound) if turn_id.is_none_or(|t| t == bound) => entry.reservation = None,
                Some(_) => return,
                None => {
                    if let Some(turn_id) = turn_id {
                        entry.terminal_before_bind.insert(turn_id.clone());
                    }
                    return;
                }
            }
        }
        self.drain_queued_turns(ctx);
    }

    /// Synara `drainQueuedTurnsForThread`: hand the next queued turn to the decider, one at a time.
    fn drain_queued_turns(&mut self, ctx: &mut Ctx) {
        if self.live_turn(&ctx.thread_id).is_some() {
            return;
        }
        let Some(entry) = self.entry_mut(&ctx.thread_id) else { return };
        if entry.reservation.is_some() {
            return;
        }
        let Some(next) = entry.queue.pop_front() else { return };
        entry.reservation = Some(Reservation { message_id: next.message_id.clone(), turn_id: None });
        let command = InternalThreadCommand::TurnDispatchQueued(ThreadDispatchQueuedTurnCommand {
            command_id: server_command_id("dispatch-queued-turn"),
            thread_id: ctx.thread_id.clone(),
            message_id: next.message_id.clone(),
            model_selection: next.model_selection.clone(),
            provider_options: next.provider_options.clone(),
            review_target: next.review_target.clone(),
            assistant_delivery_mode: next.assistant_delivery_mode,
            dispatch_mode: next.dispatch_mode,
            dispatch_origin: next.dispatch_origin,
            runtime_mode: next.runtime_mode,
            interaction_mode: next.interaction_mode,
            source_proposed_plan: next.source_proposed_plan.clone(),
            created_at: now_iso(),
        });
        if let Err(error) = self.run_command(ctx, command.into()) {
            tracing::warn!(thread = %ctx.thread_id, %error, "chat: a queued turn could not be dispatched");
            if let Some(entry) = self.entry_mut(&ctx.thread_id) {
                if entry.reservation.as_ref().is_some_and(|r| r.message_id == next.message_id) {
                    entry.reservation = None;
                }
            }
        }
    }

    // --- checkpoints (CR:403-686) ---

    /// Synara `captureCheckpointFromTurnCompletion` (CR:585)
    fn capture_turn_checkpoint(&mut self, ctx: &mut Ctx, event: &ProviderRuntimeEvent) {
        let Some(turn_id) = event.turn_id.clone() else { return };
        let Some(entry) = self.entries.get(&ctx.thread_id) else { return };
        let Some(thread) = entry.thread.as_ref() else { return };
        if thread.session.as_ref().and_then(|s| s.active_turn_id.as_ref()).is_some_and(|active| *active != turn_id) {
            return;
        }
        let existing = thread.checkpoints.iter().find(|c| c.turn_id == turn_id);
        if existing.is_some_and(|c| c.status != OrchestrationCheckpointStatus::Missing) {
            return;
        }
        let cwd = match self.sessions.get(&ctx.thread_id) {
            Some(live) => live.cwd.clone(),
            None => match resolve_cwd(thread) {
                Ok(cwd) => cwd,
                Err(_) => return,
            },
        };
        let turn_count = existing
            .map(|c| c.checkpoint_turn_count)
            .unwrap_or_else(|| thread.checkpoints.iter().map(|c| c.checkpoint_turn_count).max().unwrap_or(0) + 1);
        // Synara `checkpointStatusFromRuntime` (CR:84)
        let status = match (&event.body, runtime_turn_state(event)) {
            (ProviderRuntimeEventBody::TurnAborted(_), _) => OrchestrationCheckpointStatus::Missing,
            (_, RuntimeTurnState::Failed) => OrchestrationCheckpointStatus::Error,
            (_, RuntimeTurnState::Interrupted | RuntimeTurnState::Cancelled) => OrchestrationCheckpointStatus::Missing,
            _ => OrchestrationCheckpointStatus::Ready,
        };
        let lease = entry.lease.clone();
        let checkpoints = self.checkpoints.clone();
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        let completed_at = event.created_at.clone();
        tokio::spawn(async move {
            let _lease = lease.lock().await;
            let cwd = PathBuf::from(cwd);
            if !checkpoints.is_git_repository(&cwd).await {
                return;
            }
            let checkpoint_ref = checkpoint_ref_for_thread_turn(&thread_id, turn_count);
            if let Err(error) = checkpoints.capture_checkpoint(&cwd, &checkpoint_ref, false).await {
                tracing::warn!(thread = %thread_id, "chat: turn checkpoint failed: {error:#}");
                return;
            }
            let from = checkpoint_ref_for_turn_start(&thread_id, &turn_id);
            let (status, files, failure) = match checkpoints.has_checkpoint_ref(&cwd, &from).await {
                Ok(true) => match checkpoints.diff_checkpoints(&cwd, &from, &checkpoint_ref).await {
                    Ok(diff) => match parse_checkpoint_files_from_unified_diff(&diff) {
                        Some(mut files) => {
                            files.sort_by(|l, r| l.path.cmp(&r.path));
                            (status, files, None)
                        }
                        None => (status, vec![], Some("Checkpoint captured, but turn diff summary is unavailable: the diff could not be read.".to_owned())),
                    },
                    Err(error) => (status, vec![], Some(format!("Checkpoint captured, but turn diff summary is unavailable: {error:#}"))),
                },
                _ => (
                    OrchestrationCheckpointStatus::Missing,
                    vec![],
                    Some("Checkpoint captured, but the turn start baseline is unavailable.".to_owned()),
                ),
            };
            let _ = internal.send(Internal::CheckpointCaptured(CapturedCheckpoint {
                thread_id,
                turn_id,
                turn_count,
                checkpoint_ref,
                status,
                files,
                failure,
                completed_at,
            }));
        });
    }

    /// Synara `captureAndDispatchCheckpoint` (CR:403): the turn's diff, then its activities.
    fn on_checkpoint_captured(&mut self, ctx: &mut Ctx, captured: CapturedCheckpoint) {
        let assistant_message_id = self.thread(&ctx.thread_id).and_then(|t| {
            t.messages
                .iter()
                .rev()
                .find(|m| m.role == OrchestrationMessageRole::Assistant && m.turn_id.as_ref() == Some(&captured.turn_id))
                .map(|m| m.id.clone())
        });
        self.run_logged(
            ctx,
            InternalThreadCommand::TurnDiffComplete(ThreadTurnDiffCompleteCommand {
                command_id: server_command_id("checkpoint-turn-diff-complete"),
                thread_id: ctx.thread_id.clone(),
                turn_id: captured.turn_id.clone(),
                completed_at: captured.completed_at.clone(),
                checkpoint_ref: captured.checkpoint_ref,
                status: captured.status,
                files: captured.files,
                assistant_message_id,
                checkpoint_turn_count: captured.turn_count,
                preserve_latest_turn: None,
                checkpoint_revert_turn_count: None,
                created_at: now_iso(),
            }),
        );
        if let Some(detail) = captured.failure {
            self.append_activity(
                ctx,
                OrchestrationThreadActivityTone::Error,
                "checkpoint.capture.failed",
                "Checkpoint capture failed",
                json!({ "detail": detail }),
                Some(captured.turn_id.clone()),
            );
        }
        self.append_activity(
            ctx,
            OrchestrationThreadActivityTone::Info,
            "checkpoint.captured",
            "Checkpoint captured",
            json!({ "turnCount": captured.turn_count, "status": captured.status }),
            Some(captured.turn_id),
        );
    }

    // --- revert (CR:983-1510) ---

    /// Synara `appendRevertFailureActivity` (CR:243)
    fn append_revert_failure(&mut self, ctx: &mut Ctx, turn_count: u64, detail: &str) {
        let turn_id = self.thread(&ctx.thread_id).and_then(|t| {
            t.checkpoints
                .iter()
                .find(|c| c.checkpoint_turn_count == turn_count)
                .or_else(|| t.checkpoints.iter().max_by_key(|c| c.checkpoint_turn_count))
                .map(|c| c.turn_id.clone())
                .or_else(|| t.latest_turn.as_ref().map(|l| l.turn_id.clone()))
        });
        self.append_activity(
            ctx,
            OrchestrationThreadActivityTone::Error,
            CHECKPOINT_REVERT_FAILED_ACTIVITY_KIND,
            "Checkpoint revert failed",
            json!({ "turnCount": turn_count, "detail": detail }),
            turn_id,
        );
    }

    fn on_checkpoint_revert_requested(&mut self, ctx: &mut Ctx, payload: &ThreadCheckpointRevertRequestedPayload) {
        let turn_count = payload.turn_count;
        let Some(thread) = self.thread(&ctx.thread_id).cloned() else { return };
        let current = thread.checkpoints.iter().map(|c| c.checkpoint_turn_count).max().unwrap_or(0);
        if turn_count > current {
            self.append_revert_failure(
                ctx,
                turn_count,
                &format!("Checkpoint turn count {turn_count} exceeds current turn count {current}."),
            );
            return;
        }
        let files_scope = payload.scope == ThreadCheckpointRevertScope::Files;
        let cwd = match self.sessions.get(&ctx.thread_id).map(|l| l.cwd.clone()).ok_or(()).or_else(|_| resolve_cwd(&thread)) {
            Ok(cwd) if is_inside_git_work_tree(std::path::Path::new(&cwd)) => PathBuf::from(cwd),
            _ => {
                let detail = if files_scope {
                    "No git workspace is available for file Undo."
                } else {
                    "No git workspace is available for this thread's checkpoints."
                };
                self.append_revert_failure(ctx, turn_count, detail);
                return;
            }
        };
        if files_scope {
            self.undo_turn_files(ctx, &thread, turn_count, cwd);
            return;
        }
        let target = if turn_count == 0 {
            Some(checkpoint_ref_for_thread_turn(&ctx.thread_id, 0))
        } else {
            thread
                .checkpoints
                .iter()
                .find(|c| c.checkpoint_turn_count == turn_count && is_managed_checkpoint_ref(c.checkpoint_ref.as_str()))
                .map(|c| c.checkpoint_ref.clone())
        };
        let Some(target) = target else {
            self.append_revert_failure(ctx, turn_count, &format!("Filesystem checkpoint is unavailable for turn {turn_count}."));
            return;
        };
        let mut obsolete: Vec<_> = thread
            .checkpoints
            .iter()
            .filter(|c| c.checkpoint_turn_count > turn_count && is_managed_checkpoint_ref(c.checkpoint_ref.as_str()))
            .map(|c| c.checkpoint_ref.clone())
            .collect();
        let rescue = revert_rescue_checkpoint_ref(&ctx.thread_id, &uuid::Uuid::new_v4().to_string());
        obsolete.push(rescue.clone());
        let Some(lease) = self.entries.get(&ctx.thread_id).map(|e| e.lease.clone()) else { return };
        let checkpoints = self.checkpoints.clone();
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        let rolled_back_turns = current - turn_count;
        tokio::spawn(async move {
            let _lease = lease.lock().await;
            let result = async {
                if turn_count != 0 && !checkpoints.has_checkpoint_ref(&cwd, &target).await.unwrap_or(false) {
                    return Err(format!("Filesystem checkpoint is unavailable for turn {turn_count}."));
                }
                if let Err(error) = checkpoints.capture_checkpoint(&cwd, &rescue, false).await {
                    return Err(format!(
                        "The pre-revert workspace snapshot could not be captured, so the revert was refused: {error:#}"
                    ));
                }
                match checkpoints.restore_checkpoint(&cwd, &target, turn_count == 0).await {
                    Ok(true) => Ok(RevertOutcome { rolled_back_turns, cwd: cwd.clone(), obsolete_refs: obsolete }),
                    Ok(false) => Err(format!("Filesystem checkpoint became unavailable for turn {turn_count} during the revert.")),
                    Err(error) => Err(match checkpoints.restore_checkpoint(&cwd, &rescue, false).await {
                        Ok(true) => {
                            let _ = checkpoints.delete_checkpoint_refs(&cwd, std::slice::from_ref(&rescue)).await;
                            format!("Filesystem restore failed and the workspace was put back: {error:#}")
                        }
                        Ok(false) => format!("Filesystem restore failed and the workspace could not be put back (the snapshot is gone): {error:#}"),
                        Err(rescue_error) => format!(
                            "Filesystem restore failed and the workspace could not be put back ({rescue_error:#}): {error:#}"
                        ),
                    }),
                }
            }
            .await;
            let _ = internal.send(Internal::Reverted { thread_id, turn_count, result });
        });
    }

    /// Synara's `scope: "files"` branch of `handleRevertRequestedWithoutLease` (CR:1082-1220):
    /// take back the newest undoable turn's file changes, leaving the conversation as it is.
    fn undo_turn_files(&mut self, ctx: &mut Ctx, thread: &OrchestrationThread, turn_count: u64, cwd: PathBuf) {
        let thread_id = ctx.thread_id.clone();
        let is_undoable = |c: &OrchestrationCheckpointSummary| {
            c.status == OrchestrationCheckpointStatus::Ready
                && !c.files.is_empty()
                && is_managed_checkpoint_ref_for_thread(c.checkpoint_ref.as_str(), &thread_id)
        };
        let Some(target) = thread.checkpoints.iter().find(|c| c.checkpoint_turn_count == turn_count).filter(|c| is_undoable(c)).cloned()
        else {
            self.append_revert_failure(
                ctx,
                turn_count,
                &format!("File changes for turn {turn_count} are unavailable or already undone."),
            );
            return;
        };
        let latest_undoable = thread.checkpoints.iter().filter(|c| is_undoable(c)).map(|c| c.checkpoint_turn_count).max().unwrap_or(0);
        if target.checkpoint_turn_count != latest_undoable {
            self.append_revert_failure(ctx, turn_count, "Undo newer file changes before undoing this turn.");
            return;
        }
        let turn_start = checkpoint_ref_for_turn_start_in_managed_family(target.checkpoint_ref.as_str(), &thread_id, &target.turn_id)
            .unwrap_or_else(|| checkpoint_ref_for_turn_start(&thread_id, &target.turn_id));
        let previous = if turn_count == 1 {
            Some(
                checkpoint_ref_for_thread_turn_in_managed_family(target.checkpoint_ref.as_str(), &thread_id, 0)
                    .unwrap_or_else(|| checkpoint_ref_for_thread_turn(&thread_id, 0)),
            )
        } else {
            thread.checkpoints.iter().find(|c| c.checkpoint_turn_count + 1 == turn_count).map(|c| c.checkpoint_ref.clone())
        };
        // The later turns' refs, end and start, are moved onto the undone workspace.
        let later: Vec<crate::contracts::base::CheckpointRef> = thread
            .checkpoints
            .iter()
            .filter(|c| {
                c.checkpoint_turn_count > target.checkpoint_turn_count
                    && is_managed_checkpoint_ref_for_thread(c.checkpoint_ref.as_str(), &thread_id)
            })
            .flat_map(|c| {
                let start = checkpoint_ref_for_turn_start_in_managed_family(c.checkpoint_ref.as_str(), &thread_id, &c.turn_id)
                    .unwrap_or_else(|| checkpoint_ref_for_turn_start(&thread_id, &c.turn_id));
                [c.checkpoint_ref.clone(), start]
            })
            .collect();
        let Some(lease) = self.entries.get(&ctx.thread_id).map(|e| e.lease.clone()) else { return };
        let checkpoints = self.checkpoints.clone();
        let internal = self.internal.clone();
        tokio::spawn(async move {
            let _lease = lease.lock().await;
            let result = async {
                let from = match checkpoints.has_checkpoint_ref(&cwd, &turn_start).await {
                    Ok(true) => turn_start,
                    _ => previous.ok_or_else(|| format!("Starting checkpoint for turn {turn_count} is unavailable."))?,
                };
                match checkpoints.reverse_checkpoint_diff(&cwd, &from, &target.checkpoint_ref).await {
                    Ok(true) => {}
                    Ok(false) => return Err(format!("Filesystem checkpoints for turn {turn_count} are unavailable.")),
                    Err(error) => return Err(format!("{error:#}")),
                }
                checkpoints.capture_checkpoint(&cwd, &target.checkpoint_ref, false).await.map_err(|e| format!("{e:#}"))?;
                for reference in &later {
                    checkpoints.copy_checkpoint_ref(&cwd, &target.checkpoint_ref, reference).await.map_err(|e| format!("{e:#}"))?;
                }
                Ok(target)
            }
            .await;
            let _ = internal.send(Internal::FilesUndone { thread_id, turn_count, result });
        });
    }

    /// The files-scope undo finished: the turn's diff is now empty, the latest turn stays.
    fn on_files_undone(&mut self, ctx: &mut Ctx, turn_count: u64, result: Result<OrchestrationCheckpointSummary, String>) {
        match result {
            Ok(target) => self.run_logged(
                ctx,
                InternalThreadCommand::TurnDiffComplete(ThreadTurnDiffCompleteCommand {
                    command_id: server_command_id("checkpoint-files-undone"),
                    thread_id: ctx.thread_id.clone(),
                    turn_id: target.turn_id,
                    completed_at: target.completed_at,
                    checkpoint_ref: target.checkpoint_ref,
                    status: target.status,
                    files: vec![],
                    assistant_message_id: target.assistant_message_id,
                    checkpoint_turn_count: target.checkpoint_turn_count,
                    preserve_latest_turn: Some(true),
                    checkpoint_revert_turn_count: Some(turn_count),
                    created_at: now_iso(),
                }),
            ),
            Err(detail) => self.append_revert_failure(ctx, turn_count, &detail),
        }
    }

    fn on_reverted(&mut self, ctx: &mut Ctx, turn_count: u64, result: Result<RevertOutcome, String>) {
        match result {
            Ok(outcome) => {
                if outcome.rolled_back_turns > 0 {
                    self.reset_provider_conversation(ctx);
                }
                self.run_logged(
                    ctx,
                    InternalThreadCommand::RevertComplete(ThreadRevertCompleteCommand {
                        command_id: server_command_id("checkpoint-revert-complete"),
                        thread_id: ctx.thread_id.clone(),
                        turn_count,
                        created_at: now_iso(),
                    }),
                );
                let checkpoints = self.checkpoints.clone();
                tokio::spawn(async move {
                    let _ = checkpoints.delete_checkpoint_refs(&outcome.cwd, &outcome.obsolete_refs).await;
                });
            }
            Err(detail) => self.append_revert_failure(ctx, turn_count, &detail),
        }
    }

    // --- rollback and edit (PCR:5962-6225) ---

    fn on_conversation_rollback_requested(&mut self, ctx: &mut Ctx, payload: &ThreadConversationRollbackRequestedPayload) {
        let Some(thread) = self.thread(&ctx.thread_id) else { return };
        let removed = collect_tail_turn_ids(&thread.messages, &payload.message_id);
        if removed.len() as u64 != payload.num_turns {
            tracing::warn!(
                thread = %ctx.thread_id,
                "Conversation rollback target '{}' is no longer valid for {} turn(s).",
                payload.message_id,
                payload.num_turns
            );
            return;
        }
        if payload.num_turns > 0 {
            if let (Some(turn), Some(live)) = (self.live_turn(&ctx.thread_id), self.live_session(&ctx.thread_id)) {
                let handle = live.handle.clone();
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(PROVIDER_COMMAND_INTERRUPT_TIMEOUT, handle.interrupt_turn(Some(turn))).await;
                });
            }
            self.reset_provider_conversation(ctx);
        }
        self.run_logged(
            ctx,
            InternalThreadCommand::ConversationRollbackComplete(ThreadConversationRollbackCompleteCommand {
                command_id: server_command_id("conversation-rollback-complete"),
                thread_id: ctx.thread_id.clone(),
                message_id: payload.message_id.clone(),
                num_turns: payload.num_turns,
                removed_turn_ids: Some(removed),
                skip_attachment_prune: None,
                created_at: now_iso(),
            }),
        );
    }

    /// Synara `processMessageEditResendPayload` (PCR:6018): roll the conversation and the
    /// workspace back to before the edited message, then send it again.
    fn on_message_edit_resend_requested(&mut self, ctx: &mut Ctx, payload: &ThreadMessageEditResendRequestedPayload) {
        if self.entries.get(&ctx.thread_id).is_some_and(|e| e.edit_in_flight) {
            self.set_session_error(ctx, "Another message edit is still being applied.", Some(payload.runtime_mode));
            return;
        }
        if let Some(entry) = self.entry_mut(&ctx.thread_id) {
            entry.queue.clear();
            entry.reservation = None;
        }
        let Some(thread) = self.thread(&ctx.thread_id).cloned() else { return };
        let Some(original) = thread
            .messages
            .iter()
            .find(|m| m.id == payload.message_id && m.role == OrchestrationMessageRole::User)
            .cloned()
        else {
            self.set_session_error(ctx, &format!("Cannot edit missing user message '{}'.", payload.message_id), Some(payload.runtime_mode));
            return;
        };
        let removed = payload.removed_turn_ids.clone().unwrap_or_default();
        let removed_counts: Vec<u64> = thread
            .checkpoints
            .iter()
            .filter(|c| removed.contains(&c.turn_id))
            .map(|c| c.checkpoint_turn_count)
            .collect();
        let cwd = resolve_cwd(&thread).ok().filter(|cwd| is_inside_git_work_tree(std::path::Path::new(cwd)));
        let edit = PendingEdit { payload: payload.clone(), original };
        let (Some(min_removed), Some(cwd)) = (removed_counts.iter().min().copied(), cwd) else {
            if self.edit_resets_conversation(ctx, &edit) {
                self.reset_provider_conversation(ctx);
            }
            self.finish_message_edit(ctx, edit);
            return;
        };
        // Synara `planWorkspaceRestoreForEditReplay`: the target is resolved, and then found in
        // git, before the conversation is reset, so a missing checkpoint leaves everything as it was.
        let target_count = min_removed.saturating_sub(1);
        let target = if target_count == 0 {
            Some(checkpoint_ref_for_thread_turn(&ctx.thread_id, 0))
        } else {
            thread
                .checkpoints
                .iter()
                .find(|c| c.checkpoint_turn_count == target_count && is_managed_checkpoint_ref(c.checkpoint_ref.as_str()))
                .map(|c| c.checkpoint_ref.clone())
        };
        let Some(target) = target else {
            self.set_session_error(
                ctx,
                &format!("Filesystem checkpoint for edit replay turn {target_count} is unavailable."),
                Some(payload.runtime_mode),
            );
            return;
        };
        let Some(lease) = self.entries.get(&ctx.thread_id).map(|e| e.lease.clone()) else { return };
        let checkpoints = self.checkpoints.clone();
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        let restore = EditRestore { edit, cwd: PathBuf::from(cwd), target, target_count };
        if let Some(entry) = self.entry_mut(&ctx.thread_id) {
            entry.edit_in_flight = true;
        }
        tokio::spawn(async move {
            let found = {
                let _lease = lease.lock().await;
                checkpoints.has_checkpoint_ref(&restore.cwd, &restore.target).await
            };
            let result = match found {
                Ok(true) => Ok(()),
                Ok(false) => Err(format!("Filesystem checkpoint for edit replay turn {target_count} is unavailable.")),
                Err(error) => Err(format!("{error:#}")),
            };
            let _ = internal.send(Internal::EditChecked { thread_id, restore, result });
        });
    }

    /// Synara resets the provider's conversation for an edit that rolls turns back or lands on a
    /// running turn.
    fn edit_resets_conversation(&self, ctx: &Ctx, edit: &PendingEdit) -> bool {
        edit.payload.rollback_turn_count.unwrap_or(0) > 0 || self.live_turn(&ctx.thread_id).is_some()
    }

    /// Synara `executeEditReplayWorkspaceRestore`: the checkpoint exists, so reset the
    /// conversation, wait for the CLI to be gone, keep a rescue snapshot, then restore.
    fn on_edit_checked(&mut self, ctx: &mut Ctx, restore: EditRestore, result: Result<(), String>) {
        if let Err(detail) = result {
            self.set_session_error(ctx, &detail, Some(restore.edit.payload.runtime_mode));
            return;
        }
        let stopping =
            if self.edit_resets_conversation(ctx, &restore.edit) { self.take_provider_conversation(ctx) } else { None };
        let Some(lease) = self.entries.get(&ctx.thread_id).map(|e| e.lease.clone()) else { return };
        let checkpoints = self.checkpoints.clone();
        let internal = self.internal.clone();
        let thread_id = ctx.thread_id.clone();
        let rescue = revert_rescue_checkpoint_ref(&ctx.thread_id, &uuid::Uuid::new_v4().to_string());
        tokio::spawn(async move {
            if let Some(handle) = stopping {
                let _ = tokio::time::timeout(PROVIDER_COMMAND_STOP_TIMEOUT, handle.stop()).await;
            }
            let _lease = lease.lock().await;
            let EditRestore { edit, cwd, target, target_count } = restore;
            let result = async {
                if let Err(error) = checkpoints.capture_checkpoint(&cwd, &rescue, false).await {
                    return Err(format!(
                        "The pre-edit workspace snapshot could not be captured, so the edit was refused: {error:#}"
                    ));
                }
                match checkpoints.restore_checkpoint(&cwd, &target, false).await {
                    Ok(true) => {
                        let _ = checkpoints.delete_checkpoint_refs(&cwd, std::slice::from_ref(&rescue)).await;
                        Ok(())
                    }
                    Ok(false) => {
                        let _ = checkpoints.delete_checkpoint_refs(&cwd, std::slice::from_ref(&rescue)).await;
                        Err(format!(
                            "Filesystem checkpoint for edit replay turn {target_count} became unavailable during the rollback."
                        ))
                    }
                    Err(error) => Err(match checkpoints.restore_checkpoint(&cwd, &rescue, false).await {
                        Ok(true) => {
                            let _ = checkpoints.delete_checkpoint_refs(&cwd, std::slice::from_ref(&rescue)).await;
                            format!("Filesystem restore failed and the workspace was put back: {error:#}")
                        }
                        Ok(false) => format!("Filesystem restore failed and the workspace could not be put back (the snapshot is gone): {error:#}"),
                        Err(rescue_error) => format!(
                            "Filesystem restore failed and the workspace could not be put back ({rescue_error:#}): {error:#}"
                        ),
                    }),
                }
            }
            .await;
            let _ = internal.send(Internal::EditRestored { thread_id, edit, result });
        });
    }

    /// The edit is done: start the turns that waited for it, in the order they came.
    fn end_edit_in_flight(&mut self, ctx: &mut Ctx) {
        let deferred = match self.entry_mut(&ctx.thread_id) {
            Some(entry) => {
                entry.edit_in_flight = false;
                std::mem::take(&mut entry.deferred_turn_starts)
            }
            None => return,
        };
        for (event, payload) in deferred {
            self.on_turn_start_requested(ctx, &event, &payload);
        }
    }

    fn finish_message_edit(&mut self, ctx: &mut Ctx, edit: PendingEdit) {
        let PendingEdit { payload, original } = edit;
        self.run_logged(
            ctx,
            InternalThreadCommand::ConversationRollbackComplete(ThreadConversationRollbackCompleteCommand {
                command_id: server_command_id("message-edit-rollback-complete"),
                thread_id: ctx.thread_id.clone(),
                message_id: payload.message_id.clone(),
                num_turns: payload.rollback_turn_count.unwrap_or(0),
                removed_turn_ids: payload.removed_turn_ids.clone(),
                skip_attachment_prune: Some(true),
                created_at: now_iso(),
            }),
        );
        let attachments = original.attachments.clone().unwrap_or_default().into_iter().map(upload_attachment).collect();
        let command = ClientThreadCommand::TurnStart(ClientThreadTurnStartCommand {
            async_user_input_response: None,
            command_id: server_command_id("message-edit-resend-turn-start"),
            thread_id: ctx.thread_id.clone(),
            message: ClientThreadTurnStartMessage {
                message_id: payload.message_id.clone(),
                role: TurnStartMessageRole::User,
                text: payload.text.clone(),
                attachments,
                skills: original.skills.clone(),
                mentions: original.mentions.clone(),
            },
            model_selection: payload.model_selection.clone(),
            provider_options: payload.provider_options.clone(),
            review_target: None,
            assistant_delivery_mode: payload.assistant_delivery_mode,
            dispatch_mode: TurnDispatchMode::Queue,
            runtime_mode: payload.runtime_mode,
            interaction_mode: payload.interaction_mode,
            source_proposed_plan: None,
            created_at: now_iso(),
        });
        if let Err(error) = self.run_command(ctx, command.into()) {
            self.set_session_error(ctx, &error.to_string(), Some(payload.runtime_mode));
        }
    }

    // --- answers from beside the engine ---

    pub(super) fn handle_internal(&mut self, ctx: &mut Ctx, message: Internal) {
        match message {
            Internal::TurnSent { generation, payload, native_steer, retried, result, .. } => {
                self.on_turn_sent(ctx, generation, payload, native_steer, retried, result)
            }
            Internal::Interrupted { turn_id, outcome, .. } => self.on_interrupted(ctx, turn_id, outcome),
            Internal::Responded { approval, request_id, command_id, error, .. } => {
                let unknown = error.contains("Unknown pending") || error.contains("session has ended") || error.contains("ended before");
                let detail = if unknown { stale_pending_request_failure_detail(approval, &request_id) } else { error };
                let status = if unknown { "uncertain" } else { "retryable" };
                self.append_interaction_failure(ctx, approval, &request_id, command_id, None, &detail, status);
            }
            Internal::StopFailed { detail, .. } => self.append_provider_failure(
                ctx,
                "provider.session.stop.failed",
                "Provider session stop failed",
                json!({ "detail": detail, "settlementStatus": "uncertain" }),
                None,
            ),
            Internal::CheckpointCaptured(captured) => self.on_checkpoint_captured(ctx, captured),
            Internal::Reverted { turn_count, result, .. } => self.on_reverted(ctx, turn_count, result),
            Internal::FilesUndone { turn_count, result, .. } => self.on_files_undone(ctx, turn_count, result),
            Internal::EditChecked { restore, result, .. } => {
                let failed = result.is_err();
                self.on_edit_checked(ctx, restore, result);
                if failed {
                    self.end_edit_in_flight(ctx);
                }
            }
            Internal::EditRestored { edit, result, .. } => {
                match result {
                    Ok(()) => self.finish_message_edit(ctx, edit),
                    Err(detail) => self.set_session_error(ctx, &detail, Some(edit.payload.runtime_mode)),
                }
                self.end_edit_in_flight(ctx);
            }
        }
    }
}

/// Synara `claudeSelectionRequiresRestart` (shared/model.ts:931): a Claude session is spawned
/// with its maximum effort and its auto-compact window, so a change to either restarts it.
fn claude_selection_requires_restart(previous: &ModelSelection, next: &ModelSelection) -> bool {
    let ModelSelection::ClaudeAgent(next) = next else { return false };
    let ModelSelection::ClaudeAgent(previous) = previous else { return true };
    let profile = |selection: &ClaudeModelSelection| {
        let options = selection.options.as_ref();
        (
            options.and_then(|o| o.effort) == Some(crate::contracts::model::ClaudeCodeEffort::Max),
            options.and_then(|o| o.auto_compact_window.clone().or_else(|| o.context_window.clone())),
        )
    };
    profile(previous) != profile(next)
}

/// Synara `isStaleClaudeResumeError`
fn is_stale_claude_resume_error(detail: &str) -> bool {
    detail.to_lowercase().contains("no conversation found with session id")
}

/// Synara `buildStalePendingRequestFailureDetail` (shared/threadSummary.ts:165)
fn stale_pending_request_failure_detail(approval: bool, request_id: &str) -> String {
    let kind = if approval { "approval" } else { "user-input" };
    format!(
        "Stale pending {kind} request: {request_id}. Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
    )
}

fn upload_attachment(attachment: ChatAttachment) -> UploadChatAttachment {
    match attachment {
        ChatAttachment::Image(image) => UploadChatAttachment::Image(image),
        ChatAttachment::File(file) => UploadChatAttachment::File(file),
        ChatAttachment::AssistantSelection(selection) => {
            UploadChatAttachment::AssistantSelection(UploadChatAssistantSelectionAttachment {
                assistant_message_id: selection.assistant_message_id,
                text: selection.text,
            })
        }
    }
}

/// Synara `attachmentTitleSeed`
fn attachment_title_seed(attachment: &ChatAttachment) -> String {
    match attachment {
        ChatAttachment::Image(image) => image.name.clone(),
        ChatAttachment::File(file) => file.name.clone(),
        ChatAttachment::AssistantSelection(selection) => selection.text.clone(),
    }
}

/// Synara `normalizeTitleWhitespace` (chatThreads.ts:27)
fn normalize_title_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Synara `titleWords` (chatThreads.ts:35)
fn title_words(value: &str) -> Vec<String> {
    normalize_title_whitespace(value)
        .split(' ')
        .map(|token| {
            token
                .trim_start_matches(|c: char| c.is_whitespace() || "\"'`([{".contains(c))
                .trim_end_matches(|c: char| c.is_whitespace() || "\"'`)]}:;,.!?".contains(c))
                .to_owned()
        })
        .filter(|token| !token.is_empty())
        .collect()
}

/// Synara `truncateChatThreadTitle` (chatThreads.ts:141)
fn truncate_chat_thread_title(text: &str) -> String {
    let trimmed = normalize_title_whitespace(text);
    if trimmed.chars().count() <= MAX_CHAT_THREAD_TITLE_LENGTH {
        return trimmed;
    }
    format!("{}...", trimmed.chars().take(MAX_CHAT_THREAD_TITLE_LENGTH).collect::<String>())
}

/// Synara `buildPromptThreadTitleFallback` (chatThreads.ts:153)
pub(super) fn build_prompt_thread_title_fallback(message: &str) -> String {
    let words: Vec<String> = title_words(message).into_iter().take(MAX_CHAT_THREAD_TITLE_WORDS).collect();
    if words.is_empty() {
        return GENERIC_CHAT_THREAD_TITLE.to_owned();
    }
    truncate_chat_thread_title(&words.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_message_names_the_thread() {
        assert_eq!(build_prompt_thread_title_fallback("  Fix the (flaky) build, please! Now and then  "), "Fix the flaky build please Now");
        assert_eq!(build_prompt_thread_title_fallback("   "), "New thread");
        let long = "Supercalifragilisticexpialidocious ".repeat(3);
        assert_eq!(build_prompt_thread_title_fallback(&long).chars().count(), 63);
    }
}
