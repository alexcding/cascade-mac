//! Ported from Synara `apps/server/src/orchestration/decider.ts` (the thread commands) with the
//! single-thread invariants of `commandInvariants.ts`, and the helpers they use from
//! `@synara/shared` (`conversationEdit.ts`, `runtimeMode.ts`, `threadWorkspace.ts`,
//! `asyncUserInput.ts`, `providerMetadata.ts`) and `messageTurnId.ts`.
//!
//! Synara decides against the whole read model; this decider sees one thread, so what needs
//! another thread or a project is reduced: `thread.create` does not check its project, archiving
//! does not cascade to subagent threads, and a proposed plan from another thread is passed in
//! ([`decide_turn_start`]). Spaces, projects, sidechats, handoffs, forks, goals, the Claude cache
//! and computer control are not ported. Events come out without a `sequence` (0): the engine
//! numbers them as it stores them.

use std::collections::BTreeMap;
use std::fmt;

use chrono::DateTime;
use serde_json::json;

use crate::contracts::base::{
    ApprovalRequestId, CommandId, EventId, IsoDateTime, MessageId, ThreadId, TurnId,
};
use crate::contracts::orchestration::*;

/// Commands from the web client always carry an explicit mode; this covers omitted fields.
const DEFAULT_ASSISTANT_DELIVERY_MODE: AssistantDeliveryMode = AssistantDeliveryMode::Streaming;

/// Synara `CHECKPOINT_REVERT_STARTED_ACTIVITY_KIND` (commandInvariants.ts:63)
pub const CHECKPOINT_REVERT_STARTED_ACTIVITY_KIND: &str = "checkpoint.revert.started";
/// Synara `CHECKPOINT_REVERT_SUCCEEDED_ACTIVITY_KIND` (commandInvariants.ts:64)
pub const CHECKPOINT_REVERT_SUCCEEDED_ACTIVITY_KIND: &str = "checkpoint.revert.succeeded";
/// Synara `CHECKPOINT_REVERT_FAILED_ACTIVITY_KIND` (commandInvariants.ts:65)
pub const CHECKPOINT_REVERT_FAILED_ACTIVITY_KIND: &str = "checkpoint.revert.failed";
/// Synara `ASYNC_USER_INPUT_ALREADY_ANSWERED` (asyncUserInput.ts:3)
pub const ASYNC_USER_INPUT_ALREADY_ANSWERED: &str =
    "This asynchronous question has already been answered.";
/// Synara `APPROVAL_ALREADY_ANSWERED_INVARIANT_MARKER` (errorMessages.ts)
pub const APPROVAL_ALREADY_ANSWERED_INVARIANT_MARKER: &str = "was already answered.";
/// Synara `THREAD_NOT_ARCHIVED_INVARIANT_MARKER` (errorMessages.ts)
pub const THREAD_NOT_ARCHIVED_INVARIANT_MARKER: &str = "is not archived for command";

/// Synara `ThreadResumePreconditionViolation` (commandInvariants.ts)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResumePreconditionViolation {
    ThreadArchived,
    TurnCompleted,
    TurnInFlight,
}

/// Synara `OrchestrationCommandInvariantError`, one variant per invariant. `Display` writes
/// Synara's `detail` text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DecideError {
    ThreadMissing { command_type: &'static str, thread_id: ThreadId },
    ThreadDeleted { command_type: &'static str, thread_id: ThreadId },
    ThreadAlreadyExists { command_type: &'static str, thread_id: ThreadId },
    ThreadAlreadyArchived { command_type: &'static str, thread_id: ThreadId },
    ThreadNotArchived { command_type: &'static str, thread_id: ThreadId },
    CheckpointRevertInProgress { command_type: &'static str, thread_id: ThreadId },
    CheckpointRevertDeleteInProgress { command_type: &'static str, thread_id: ThreadId },
    CheckpointRevertActiveTurn { command_type: &'static str, thread_id: ThreadId },
    ApprovalAlreadyAnswered { command_type: &'static str, thread_id: ThreadId, request_id: ApprovalRequestId },
    ResumePrecondition { command_type: &'static str, thread_id: ThreadId, violation: ResumePreconditionViolation },
    AutoRuntimeMode { command_type: &'static str, detail: String },
    PinnedMessagesFull { command_type: &'static str, thread_id: ThreadId },
    SnoozeChanged { command_type: &'static str, thread_id: ThreadId },
    SnoozeNotDue { command_type: &'static str, thread_id: ThreadId },
    AsyncUserInputUnavailable { command_type: &'static str },
    AsyncUserInputAlreadyAnswered { command_type: &'static str },
    AsyncUserInputAnswerCount { command_type: &'static str },
    MessageTooLong { command_type: &'static str },
    ProposedPlanMissing { command_type: &'static str, plan_id: String, thread_id: ThreadId },
    ProposedPlanOtherProject { command_type: &'static str, plan_id: String, thread_id: ThreadId },
    RollbackTargetNotUser { command_type: &'static str },
    RollbackTurnCount { command_type: &'static str, requested: u64, message_id: MessageId, would_remove: usize },
    EditTarget { command_type: &'static str, reason: &'static str },
    UserMessageMissing { command_type: &'static str, message_id: MessageId, thread_id: ThreadId },
    UserMessageBound { command_type: &'static str, message_id: MessageId, turn_id: TurnId },
    SessionChanged { command_type: &'static str, thread_id: ThreadId },
    /// A command whose family is not ported (`thread.fork.create`).
    Unsupported { command_type: &'static str },
}

impl DecideError {
    pub fn command_type(&self) -> &'static str {
        use DecideError::*;
        match self {
            ThreadMissing { command_type, .. }
            | ThreadDeleted { command_type, .. }
            | ThreadAlreadyExists { command_type, .. }
            | ThreadAlreadyArchived { command_type, .. }
            | ThreadNotArchived { command_type, .. }
            | CheckpointRevertInProgress { command_type, .. }
            | CheckpointRevertDeleteInProgress { command_type, .. }
            | CheckpointRevertActiveTurn { command_type, .. }
            | ApprovalAlreadyAnswered { command_type, .. }
            | ResumePrecondition { command_type, .. }
            | AutoRuntimeMode { command_type, .. }
            | PinnedMessagesFull { command_type, .. }
            | SnoozeChanged { command_type, .. }
            | SnoozeNotDue { command_type, .. }
            | AsyncUserInputUnavailable { command_type }
            | AsyncUserInputAlreadyAnswered { command_type }
            | AsyncUserInputAnswerCount { command_type }
            | MessageTooLong { command_type }
            | ProposedPlanMissing { command_type, .. }
            | ProposedPlanOtherProject { command_type, .. }
            | RollbackTargetNotUser { command_type }
            | RollbackTurnCount { command_type, .. }
            | EditTarget { command_type, .. }
            | UserMessageMissing { command_type, .. }
            | UserMessageBound { command_type, .. }
            | SessionChanged { command_type, .. }
            | Unsupported { command_type } => command_type,
        }
    }
}

impl fmt::Display for DecideError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        use DecideError::*;
        match self {
            ThreadMissing { command_type, thread_id } => {
                write!(f, "Thread '{thread_id}' does not exist for command '{command_type}'.")
            }
            ThreadDeleted { command_type, thread_id } => write!(
                f,
                "Thread '{thread_id}' was deleted and cannot handle command '{command_type}'."
            ),
            ThreadAlreadyExists { thread_id, .. } => {
                write!(f, "Thread '{thread_id}' already exists and cannot be created twice.")
            }
            ThreadAlreadyArchived { command_type, thread_id } => write!(
                f,
                "Thread '{thread_id}' is already archived and cannot handle command '{command_type}'."
            ),
            ThreadNotArchived { command_type, thread_id } => write!(
                f,
                "Thread '{thread_id}' {THREAD_NOT_ARCHIVED_INVARIANT_MARKER} '{command_type}'."
            ),
            CheckpointRevertInProgress { thread_id, .. } => write!(
                f,
                "Thread '{thread_id}' has a checkpoint revert in progress. Wait for it to finish before starting a turn."
            ),
            CheckpointRevertDeleteInProgress { thread_id, .. } => write!(
                f,
                "Thread '{thread_id}' has a checkpoint revert in progress. Wait for it to finish before deleting the thread."
            ),
            CheckpointRevertActiveTurn { thread_id, .. } => write!(
                f,
                "Thread '{thread_id}' has an active turn. Interrupt the current turn before reverting checkpoints."
            ),
            ApprovalAlreadyAnswered { thread_id, request_id, .. } => write!(
                f,
                "Approval request '{request_id}' on thread '{thread_id}' {APPROVAL_ALREADY_ANSWERED_INVARIANT_MARKER}"
            ),
            ResumePrecondition { thread_id, violation, .. } => match violation {
                ResumePreconditionViolation::ThreadArchived => write!(
                    f,
                    "Thread '{thread_id}' was archived after it was remembered for resume."
                ),
                ResumePreconditionViolation::TurnCompleted => write!(
                    f,
                    "Thread '{thread_id}' finished on its own; there is nothing to resume."
                ),
                ResumePreconditionViolation::TurnInFlight => {
                    write!(f, "Thread '{thread_id}' already has a turn in flight.")
                }
            },
            AutoRuntimeMode { detail, .. } => f.write_str(detail),
            PinnedMessagesFull { thread_id, .. } => write!(
                f,
                "Thread '{thread_id}' already has the maximum of {PINNED_MESSAGES_MAX_COUNT} pinned messages."
            ),
            SnoozeChanged { thread_id, .. } => {
                write!(f, "Thread '{thread_id}' snooze deadline changed before expiry.")
            }
            SnoozeNotDue { thread_id, .. } => {
                write!(f, "Thread '{thread_id}' snooze reminder is not due.")
            }
            AsyncUserInputUnavailable { .. } => {
                f.write_str("This asynchronous question is unavailable in this Codex thread.")
            }
            AsyncUserInputAlreadyAnswered { .. } => f.write_str(ASYNC_USER_INPUT_ALREADY_ANSWERED),
            AsyncUserInputAnswerCount { .. } => {
                f.write_str("Provide one answer per question and a new response message id.")
            }
            MessageTooLong { .. } => {
                f.write_str("The question response exceeds the maximum message length.")
            }
            ProposedPlanMissing { plan_id, thread_id, .. } => write!(
                f,
                "Proposed plan '{plan_id}' does not exist on thread '{thread_id}'."
            ),
            ProposedPlanOtherProject { plan_id, thread_id, .. } => write!(
                f,
                "Proposed plan '{plan_id}' belongs to thread '{thread_id}' in a different project."
            ),
            RollbackTargetNotUser { .. } => {
                f.write_str("Conversation rollback must target an existing user message.")
            }
            RollbackTurnCount { requested, message_id, would_remove, .. } => write!(
                f,
                "Conversation rollback requested {requested} turn(s), but target message '{message_id}' would remove {would_remove} turn(s)."
            ),
            EditTarget { reason, .. } => write!(
                f,
                "Only the latest rollbackable user message can be edited and resent ({reason})."
            ),
            UserMessageMissing { message_id, thread_id, .. } => write!(
                f,
                "User message '{message_id}' does not exist on thread '{thread_id}'."
            ),
            UserMessageBound { message_id, turn_id, .. } => write!(
                f,
                "User message '{message_id}' is already bound to turn '{turn_id}'."
            ),
            SessionChanged { thread_id, .. } => write!(
                f,
                "Thread '{thread_id}' session changed before the conditional update."
            ),
            Unsupported { command_type } => {
                write!(f, "Command '{command_type}' is not supported here.")
            }
        }
    }
}

impl std::error::Error for DecideError {}

/// The `type` literal of a command.
pub fn command_type(command: &OrchestrationCommand) -> &'static str {
    match command {
        OrchestrationCommand::Client(command) => match command {
            ClientThreadCommand::Create(_) => "thread.create",
            ClientThreadCommand::ForkCreate(_) => "thread.fork.create",
            ClientThreadCommand::Delete(_) => "thread.delete",
            ClientThreadCommand::Archive(_) => "thread.archive",
            ClientThreadCommand::Unarchive(_) => "thread.unarchive",
            ClientThreadCommand::MetaUpdate(_) => "thread.meta.update",
            ClientThreadCommand::PinnedMessageAdd(_) => "thread.pinned-message.add",
            ClientThreadCommand::PinnedMessageRemove(_) => "thread.pinned-message.remove",
            ClientThreadCommand::PinnedMessageDoneSet(_) => "thread.pinned-message.done.set",
            ClientThreadCommand::PinnedMessageLabelSet(_) => "thread.pinned-message.label.set",
            ClientThreadCommand::RuntimeModeSet(_) => "thread.runtime-mode.set",
            ClientThreadCommand::InteractionModeSet(_) => "thread.interaction-mode.set",
            ClientThreadCommand::TurnStart(_) => "thread.turn.start",
            ClientThreadCommand::TurnInterrupt(_) => "thread.turn.interrupt",
            ClientThreadCommand::TaskStop(_) => "thread.task.stop",
            ClientThreadCommand::TaskBackground(_) => "thread.task.background",
            ClientThreadCommand::TurnDispatchQueued(_) => "thread.turn.dispatch-queued",
            ClientThreadCommand::ApprovalRespond(_) => "thread.approval.respond",
            ClientThreadCommand::UserInputRespond(_) => "thread.user-input.respond",
            ClientThreadCommand::CheckpointRevert(_) => "thread.checkpoint.revert",
            ClientThreadCommand::ConversationRollback(_) => "thread.conversation.rollback",
            ClientThreadCommand::MessageEditAndResend(_) => "thread.message.edit-and-resend",
            ClientThreadCommand::ActivityAppend(_) => "thread.activity.append",
            ClientThreadCommand::SessionStop(_) => "thread.session.stop",
        },
        OrchestrationCommand::Internal(command) => match command {
            InternalThreadCommand::SessionSet(_) => "thread.session.set",
            InternalThreadCommand::MessagesImport(_) => "thread.messages.import",
            InternalThreadCommand::MessageAssistantDelta(_) => "thread.message.assistant.delta",
            InternalThreadCommand::MessageAssistantComplete(_) => "thread.message.assistant.complete",
            InternalThreadCommand::MessageUserBindTurn(_) => "thread.message.user.bind-turn",
            InternalThreadCommand::MessageUserSetTurnBoundary(_) => {
                "thread.message.user.set-turn-boundary"
            }
            InternalThreadCommand::ProposedPlanUpsert(_) => "thread.proposed-plan.upsert",
            InternalThreadCommand::TurnDiffComplete(_) => "thread.turn.diff.complete",
            InternalThreadCommand::ActivityAppend(_) => "thread.activity.append",
            InternalThreadCommand::RevertComplete(_) => "thread.revert.complete",
            InternalThreadCommand::ConversationRollback(_) => "thread.conversation.rollback",
            InternalThreadCommand::ConversationRollbackComplete(_) => {
                "thread.conversation.rollback.complete"
            }
            InternalThreadCommand::TurnDispatchQueued(_) => "thread.turn.dispatch-queued",
        },
    }
}

/// The thread a command addresses.
pub fn command_thread_id(command: &OrchestrationCommand) -> &ThreadId {
    match command {
        OrchestrationCommand::Client(command) => match command {
            ClientThreadCommand::Create(c) => &c.thread_id,
            ClientThreadCommand::ForkCreate(c) => &c.thread_id,
            ClientThreadCommand::Delete(c) => &c.thread_id,
            ClientThreadCommand::Archive(c) => &c.thread_id,
            ClientThreadCommand::Unarchive(c) => &c.thread_id,
            ClientThreadCommand::MetaUpdate(c) => &c.thread_id,
            ClientThreadCommand::PinnedMessageAdd(c) => &c.thread_id,
            ClientThreadCommand::PinnedMessageRemove(c) => &c.thread_id,
            ClientThreadCommand::PinnedMessageDoneSet(c) => &c.thread_id,
            ClientThreadCommand::PinnedMessageLabelSet(c) => &c.thread_id,
            ClientThreadCommand::RuntimeModeSet(c) => &c.thread_id,
            ClientThreadCommand::InteractionModeSet(c) => &c.thread_id,
            ClientThreadCommand::TurnStart(c) => &c.thread_id,
            ClientThreadCommand::TurnInterrupt(c) => &c.thread_id,
            ClientThreadCommand::TaskStop(c) => &c.thread_id,
            ClientThreadCommand::TaskBackground(c) => &c.thread_id,
            ClientThreadCommand::TurnDispatchQueued(c) => &c.thread_id,
            ClientThreadCommand::ApprovalRespond(c) => &c.thread_id,
            ClientThreadCommand::UserInputRespond(c) => &c.thread_id,
            ClientThreadCommand::CheckpointRevert(c) => &c.thread_id,
            ClientThreadCommand::ConversationRollback(c) => &c.thread_id,
            ClientThreadCommand::MessageEditAndResend(c) => &c.thread_id,
            ClientThreadCommand::ActivityAppend(c) => &c.thread_id,
            ClientThreadCommand::SessionStop(c) => &c.thread_id,
        },
        OrchestrationCommand::Internal(command) => match command {
            InternalThreadCommand::SessionSet(c) => &c.thread_id,
            InternalThreadCommand::MessagesImport(c) => &c.thread_id,
            InternalThreadCommand::MessageAssistantDelta(c) => &c.thread_id,
            InternalThreadCommand::MessageAssistantComplete(c) => &c.thread_id,
            InternalThreadCommand::MessageUserBindTurn(c) => &c.thread_id,
            InternalThreadCommand::MessageUserSetTurnBoundary(c) => &c.thread_id,
            InternalThreadCommand::ProposedPlanUpsert(c) => &c.thread_id,
            InternalThreadCommand::TurnDiffComplete(c) => &c.thread_id,
            InternalThreadCommand::ActivityAppend(c) => &c.thread_id,
            InternalThreadCommand::RevertComplete(c) => &c.thread_id,
            InternalThreadCommand::ConversationRollback(c) => &c.thread_id,
            InternalThreadCommand::ConversationRollbackComplete(c) => &c.thread_id,
            InternalThreadCommand::TurnDispatchQueued(c) => &c.thread_id,
        },
    }
}

// --- commandInvariants.ts ---

/// Synara `threadHasInFlightTurn` (commandInvariants.ts:46)
pub fn thread_has_in_flight_turn(thread: &OrchestrationThread) -> bool {
    let session = thread.session.as_ref();
    session.is_some_and(|s| {
        (s.status != OrchestrationSessionStatus::Error && s.active_turn_id.is_some())
            || s.status == OrchestrationSessionStatus::Starting
            || s.status == OrchestrationSessionStatus::Running
    }) || thread
        .latest_turn
        .as_ref()
        .is_some_and(|t| t.state == OrchestrationLatestTurnState::Running)
}

/// Synara `threadHasCheckpointRevertInProgress` (commandInvariants.ts:73)
pub fn thread_has_checkpoint_revert_in_progress(thread: &OrchestrationThread) -> bool {
    thread
        .activities
        .iter()
        .filter(|activity| {
            activity.kind == CHECKPOINT_REVERT_STARTED_ACTIVITY_KIND
                || activity.kind == CHECKPOINT_REVERT_SUCCEEDED_ACTIVITY_KIND
                || activity.kind == CHECKPOINT_REVERT_FAILED_ACTIVITY_KIND
        })
        .max_by(|left, right| {
            let left_seq = left.sequence.map(|s| s as i128).unwrap_or(-1);
            let right_seq = right.sequence.map(|s| s as i128).unwrap_or(-1);
            left_seq
                .cmp(&right_seq)
                .then_with(|| left.created_at.as_str().cmp(right.created_at.as_str()))
                .then_with(|| left.id.as_str().cmp(right.id.as_str()))
        })
        .is_some_and(|latest| latest.kind == CHECKPOINT_REVERT_STARTED_ACTIVITY_KIND)
}

/// Synara `requireThread` (commandInvariants.ts:368)
fn require_thread<'a>(
    command_type: &'static str,
    thread: Option<&'a OrchestrationThread>,
    thread_id: &ThreadId,
) -> Result<&'a OrchestrationThread, DecideError> {
    match thread {
        Some(thread) if thread.deleted_at.is_none() => Ok(thread),
        Some(_) => Err(DecideError::ThreadDeleted { command_type, thread_id: thread_id.clone() }),
        None => Err(DecideError::ThreadMissing { command_type, thread_id: thread_id.clone() }),
    }
}

/// Synara `requireThreadAbsent` (commandInvariants.ts:412)
fn require_thread_absent(
    command_type: &'static str,
    thread: Option<&OrchestrationThread>,
    thread_id: &ThreadId,
) -> Result<(), DecideError> {
    match thread {
        None => Ok(()),
        Some(_) => Err(DecideError::ThreadAlreadyExists { command_type, thread_id: thread_id.clone() }),
    }
}

/// Synara `requireThreadArchived` (commandInvariants.ts:428)
fn require_thread_archived<'a>(
    command_type: &'static str,
    thread: Option<&'a OrchestrationThread>,
    thread_id: &ThreadId,
) -> Result<&'a OrchestrationThread, DecideError> {
    let thread = require_thread(command_type, thread, thread_id)?;
    if thread.archived_at.is_some() {
        Ok(thread)
    } else {
        Err(DecideError::ThreadNotArchived { command_type, thread_id: thread_id.clone() })
    }
}

/// Synara `requireThreadNotArchived` (commandInvariants.ts:448)
fn require_thread_not_archived<'a>(
    command_type: &'static str,
    thread: Option<&'a OrchestrationThread>,
    thread_id: &ThreadId,
) -> Result<&'a OrchestrationThread, DecideError> {
    let thread = require_thread(command_type, thread, thread_id)?;
    if thread.archived_at.is_none() {
        Ok(thread)
    } else {
        Err(DecideError::ThreadAlreadyArchived { command_type, thread_id: thread_id.clone() })
    }
}

/// Synara `requireApprovalNotResponded` (commandInvariants.ts:386)
fn require_approval_not_responded(
    command_type: &'static str,
    thread: &OrchestrationThread,
    request_id: &ApprovalRequestId,
    lifecycle_generation: Option<&String>,
) -> Result<(), DecideError> {
    let interaction = thread.pending_interactions.as_ref().and_then(|rows| {
        rows.iter().find(|entry| {
            entry.interaction_kind == ProjectionPendingInteractionKind::Approval
                && &entry.request_id == request_id
                && lifecycle_generation.is_none_or(|g| entry.lifecycle_generation.as_ref() == Some(g))
        })
    });
    match interaction {
        None => Ok(()),
        Some(row)
            if row.status == ProjectionPendingInteractionStatus::Pending
                || row.status == ProjectionPendingInteractionStatus::Retryable =>
        {
            Ok(())
        }
        Some(_) => Err(DecideError::ApprovalAlreadyAnswered {
            command_type,
            thread_id: thread.id.clone(),
            request_id: request_id.clone(),
        }),
    }
}

/// Synara `threadResumePreconditionViolation` (commandInvariants.ts:494)
pub fn thread_resume_precondition_violation(
    thread: &OrchestrationThread,
    precondition: &ThreadTurnResumePrecondition,
) -> Option<ResumePreconditionViolation> {
    if thread.archived_at.is_some() {
        return Some(ResumePreconditionViolation::ThreadArchived);
    }
    if thread_has_in_flight_turn(thread) {
        return Some(ResumePreconditionViolation::TurnInFlight);
    }
    let latest_turn = thread.latest_turn.as_ref()?;
    let finished_since = latest_turn.state == OrchestrationLatestTurnState::Completed
        && (Some(&latest_turn.turn_id) == precondition.recorded_turn_id.as_ref()
            || latest_turn
                .completed_at
                .as_ref()
                .is_none_or(|at| at.as_str() >= precondition.recorded_at.as_str()));
    finished_since.then_some(ResumePreconditionViolation::TurnCompleted)
}

// --- @synara/shared helpers ---

/// Synara `autoRuntimeModeSelectionIssue` (runtimeMode.ts). Codex and Claude are the providers
/// that support Auto; this crate has no other.
fn auto_runtime_mode_selection_issue(
    runtime_mode: RuntimeMode,
    model_selection: &ModelSelection,
) -> Option<String> {
    if runtime_mode != RuntimeMode::Auto {
        return None;
    }
    match model_selection {
        ModelSelection::Codex(_) => None,
        ModelSelection::ClaudeAgent(selection) => match selection.supports_auto_mode {
            Some(true) => None,
            Some(false) => Some(format!(
                "Claude model \"{}\" does not support Auto mode.",
                selection.model
            )),
            None => Some(format!(
                "Claude model \"{}\" has not been verified to support Auto mode.",
                selection.model
            )),
        },
    }
}

fn validate_auto_runtime_mode(
    command_type: &'static str,
    model_selection: &ModelSelection,
    runtime_mode: RuntimeMode,
) -> Result<(), DecideError> {
    match auto_runtime_mode_selection_issue(runtime_mode, model_selection) {
        None => Ok(()),
        Some(detail) => Err(DecideError::AutoRuntimeMode { command_type, detail }),
    }
}

/// The `provider` of a model selection.
pub fn model_selection_provider(selection: &ModelSelection) -> ProviderKind {
    match selection {
        ModelSelection::Codex(_) => ProviderKind::Codex,
        ModelSelection::ClaudeAgent(_) => ProviderKind::ClaudeAgent,
    }
}

/// The `instanceId` of a model selection.
pub fn model_selection_instance_id(
    selection: &ModelSelection,
) -> Option<&crate::contracts::base::ProviderInstanceId> {
    match selection {
        ModelSelection::Codex(s) => s.instance_id.as_ref(),
        ModelSelection::ClaudeAgent(s) => s.instance_id.as_ref(),
    }
}

/// Synara `providerSupportsNativeTurnSteering` (providerMetadata.ts:151)
pub fn provider_supports_native_turn_steering(kind: &str) -> bool {
    matches!(kind, "codex" | "claudeAgent" | "pi")
}

/// Synara `formatAsyncUserInputResponse` (asyncUserInput.ts)
fn format_async_user_input_response(questions: &[AsyncUserInputQuestion], answers: &[String]) -> String {
    questions
        .iter()
        .enumerate()
        .map(|(index, question)| {
            format!("{}\n{}", question.title, answers.get(index).map(String::as_str).unwrap_or(""))
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Synara `collectTailTurnIds` (conversationEdit.ts)
pub fn collect_tail_turn_ids(messages: &[OrchestrationMessage], message_id: &MessageId) -> Vec<TurnId> {
    let Some(index) = messages.iter().position(|m| &m.id == message_id) else {
        return vec![];
    };
    let mut unique: Vec<TurnId> = vec![];
    for message in &messages[index..] {
        if let Some(turn_id) = &message.turn_id {
            if !unique.contains(turn_id) {
                unique.push(turn_id.clone());
            }
        }
    }
    unique
}

fn is_native_editable_source(source: OrchestrationMessageSource) -> bool {
    source == OrchestrationMessageSource::Native
}

/// Synara `TailUserMessageEditTarget` (conversationEdit.ts)
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TailUserMessageEditTarget {
    Editable { rollback_turn_count: u64, removed_turn_ids: Vec<TurnId> },
    NotEditable { reason: &'static str },
}

/// Synara `resolveTailUserMessageEditTarget` (conversationEdit.ts)
pub fn resolve_tail_user_message_edit_target(
    messages: &[OrchestrationMessage],
    message_id: &MessageId,
    active_turn_id: Option<&TurnId>,
) -> TailUserMessageEditTarget {
    use TailUserMessageEditTarget::*;
    let Some(message_index) = messages.iter().position(|m| &m.id == message_id) else {
        return NotEditable { reason: "missing-message" };
    };
    let message = &messages[message_index];
    if message.role != OrchestrationMessageRole::User {
        return NotEditable { reason: "not-user-message" };
    }
    if !is_native_editable_source(message.source) {
        return NotEditable { reason: "non-native-message" };
    }
    if messages.iter().any(|entry| {
        entry
            .async_user_input
            .as_ref()
            .and_then(|input| input.response.as_ref())
            .is_some_and(|response| &response.message_id == message_id)
    }) {
        return NotEditable { reason: "structured-answer" };
    }
    let latest_native_user_index = messages.iter().rposition(|m| {
        m.role == OrchestrationMessageRole::User
            && (is_native_editable_source(m.source)
                || m.source == OrchestrationMessageSource::AsyncUserInput)
    });
    if latest_native_user_index != Some(message_index) {
        return NotEditable { reason: "not-latest-native-user-message" };
    }
    let removed_turn_ids = collect_tail_turn_ids(messages, message_id);
    if removed_turn_ids.len() > 1 {
        return NotEditable { reason: "spans-multiple-turns" };
    }
    if removed_turn_ids.len() == 1 {
        return Editable { rollback_turn_count: 1, removed_turn_ids };
    }
    if active_turn_id.is_some() {
        return Editable { rollback_turn_count: 0, removed_turn_ids: vec![] };
    }
    NotEditable { reason: "missing-turn-metadata" }
}

/// Synara `resolveStableMessageTurnId` (messageTurnId.ts)
pub fn resolve_stable_message_turn_id(
    existing_turn_id: Option<&TurnId>,
    incoming_turn_id: Option<&TurnId>,
) -> Option<TurnId> {
    existing_turn_id.or(incoming_turn_id).cloned()
}

/// Synara `deriveAssociatedWorktreeMetadata` (threadWorkspace.ts:119). `None` is "derive",
/// `Some(None)` is "explicitly none".
fn derive_associated_worktree_metadata(
    branch: Option<&String>,
    worktree_path: Option<&String>,
    associated_worktree_path: &Option<Option<String>>,
    associated_worktree_branch: &Option<Option<String>>,
    associated_worktree_ref: &Option<Option<String>>,
) -> (Option<String>, Option<String>, Option<String>) {
    let path = match associated_worktree_path {
        Some(value) => value.clone(),
        None => worktree_path.cloned(),
    };
    let derived_branch = || if worktree_path.is_some() { branch.cloned() } else { None };
    let branch_out = match associated_worktree_branch {
        Some(value) => value.clone(),
        None => derived_branch(),
    };
    let reference = match (associated_worktree_ref, associated_worktree_branch) {
        (Some(value), _) => value.clone(),
        (None, Some(value)) => value.clone(),
        (None, None) => derived_branch(),
    };
    (path, branch_out, reference)
}

/// Synara `deriveAssociatedWorktreeMetadataPatch` (threadWorkspace.ts:152)
#[allow(clippy::type_complexity)]
fn derive_associated_worktree_metadata_patch(
    branch: &Option<Option<String>>,
    worktree_path: &Option<Option<String>>,
    associated_worktree_path: &Option<Option<String>>,
    associated_worktree_branch: &Option<Option<String>>,
    associated_worktree_ref: &Option<Option<String>>,
) -> (Option<Option<String>>, Option<Option<String>>, Option<Option<String>>) {
    let has_worktree = matches!(worktree_path, Some(Some(_)));
    let branch_value = || branch.clone().flatten();
    let path = match associated_worktree_path {
        Some(value) => Some(value.clone()),
        None if has_worktree => worktree_path.clone(),
        None => None,
    };
    let branch_out = match associated_worktree_branch {
        Some(value) => Some(value.clone()),
        None if has_worktree => Some(branch_value()),
        None => None,
    };
    let reference = match (associated_worktree_ref, associated_worktree_branch) {
        (Some(value), _) => Some(value.clone()),
        (None, Some(value)) => Some(value.clone()),
        (None, None) if has_worktree => Some(branch_value()),
        (None, None) => None,
    };
    (path, branch_out, reference)
}

fn parse_instant(value: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(value).ok().map(|d| d.timestamp_millis())
}

// --- event construction (decider.ts `withEventBase`) ---

fn new_event_id() -> EventId {
    EventId::new(uuid::Uuid::new_v4().to_string())
}

fn with_event_base(
    command_id: &CommandId,
    thread_id: &ThreadId,
    occurred_at: &IsoDateTime,
    metadata: OrchestrationEventMetadata,
    body: OrchestrationEventBody,
) -> OrchestrationEvent {
    OrchestrationEvent {
        sequence: 0,
        event_id: new_event_id(),
        aggregate_kind: OrchestrationAggregateKind::Thread,
        aggregate_id: thread_id.to_string(),
        occurred_at: occurred_at.clone(),
        command_id: Some(command_id.clone()),
        causation_event_id: None,
        correlation_id: Some(command_id.clone()),
        metadata,
        body,
    }
}

fn event(
    command_id: &CommandId,
    thread_id: &ThreadId,
    occurred_at: &IsoDateTime,
    body: OrchestrationEventBody,
) -> OrchestrationEvent {
    with_event_base(command_id, thread_id, occurred_at, OrchestrationEventMetadata::default(), body)
}

fn caused_by(mut event: OrchestrationEvent, cause: &OrchestrationEvent) -> OrchestrationEvent {
    event.causation_event_id = Some(cause.event_id.clone());
    event
}

/// Synara `userMessageUpsertEvent` (decider.ts:206)
fn user_message_upsert_event(
    command_id: &CommandId,
    thread_id: &ThreadId,
    message: &OrchestrationMessage,
    turn_id: Option<TurnId>,
    starts_new_turn: Option<bool>,
    occurred_at: &IsoDateTime,
) -> OrchestrationEvent {
    event(
        command_id,
        thread_id,
        occurred_at,
        OrchestrationEventBody::ThreadMessageSent(ThreadMessageSentPayload {
            async_user_input: None,
            thread_id: thread_id.clone(),
            message_id: message.id.clone(),
            role: OrchestrationMessageRole::User,
            text: message.text.clone(),
            segment_started_at: None,
            segment_sequence: None,
            attachments: message.attachments.clone(),
            skills: message.skills.clone(),
            mentions: message.mentions.clone(),
            dispatch_mode: message.dispatch_mode,
            dispatch_origin: message.dispatch_origin,
            starts_new_turn: starts_new_turn.or(message.starts_new_turn),
            turn_id,
            streaming: false,
            source: message.source,
            created_at: message.created_at.clone(),
            updated_at: message.updated_at.clone(),
        }),
    )
}

/// Synara `checkpointRevertSucceededEvent` (decider.ts:252)
fn checkpoint_revert_succeeded_event(
    command_id: &CommandId,
    thread_id: &ThreadId,
    turn_count: u64,
    created_at: &IsoDateTime,
    cause: &OrchestrationEvent,
) -> OrchestrationEvent {
    caused_by(
        event(
            command_id,
            thread_id,
            created_at,
            OrchestrationEventBody::ThreadActivityAppended(ThreadActivityAppendedPayload {
                thread_id: thread_id.clone(),
                activity: OrchestrationThreadActivity {
                    id: new_event_id(),
                    tone: OrchestrationThreadActivityTone::Info,
                    kind: CHECKPOINT_REVERT_SUCCEEDED_ACTIVITY_KIND.into(),
                    summary: "Checkpoint revert completed".into(),
                    payload: json!({ "turnCount": turn_count }),
                    turn_id: None,
                    sequence: None,
                    created_at: created_at.clone(),
                },
            }),
        ),
        cause,
    )
}

/// The server form of a client's `thread.turn.start`, as Synara's `dispatchCommandNormalization`
/// writes it: upload attachments become chat attachments, and an assistant selection gets an id
/// (`{threadId}-{uuid}` there; derived from the command id here so the decider stays pure).
pub fn normalize_client_turn_start(command: &ClientThreadTurnStartCommand) -> ThreadTurnStartCommand {
    let attachments = command
        .message
        .attachments
        .iter()
        .enumerate()
        .map(|(index, attachment)| match attachment {
            UploadChatAttachment::Image(image) => ChatAttachment::Image(image.clone()),
            UploadChatAttachment::File(file) => ChatAttachment::File(file.clone()),
            UploadChatAttachment::AssistantSelection(selection) => {
                ChatAttachment::AssistantSelection(ChatAssistantSelectionAttachment {
                    id: format!("{}-{}-{index}", command.thread_id, command.command_id),
                    assistant_message_id: selection.assistant_message_id.clone(),
                    text: selection.text.clone(),
                })
            }
        })
        .collect();
    ThreadTurnStartCommand {
        async_user_input_response: command.async_user_input_response.clone(),
        command_id: command.command_id.clone(),
        thread_id: command.thread_id.clone(),
        message: ThreadTurnStartMessage {
            message_id: command.message.message_id.clone(),
            role: command.message.role,
            text: command.message.text.clone(),
            attachments,
            skills: command.message.skills.clone(),
            mentions: command.message.mentions.clone(),
        },
        model_selection: command.model_selection.clone(),
        provider_options: command.provider_options.clone(),
        review_target: command.review_target.clone(),
        assistant_delivery_mode: command.assistant_delivery_mode,
        dispatch_mode: command.dispatch_mode,
        dispatch_origin: None,
        runtime_mode: command.runtime_mode,
        interaction_mode: command.interaction_mode,
        source_proposed_plan: command.source_proposed_plan.clone(),
        resume_precondition: None,
        created_at: command.created_at.clone(),
    }
}

/// Synara `decideOrchestrationCommand` for one thread: the events a command produces, or the
/// invariant it breaks. `thread` is the command's thread as the read model has it (deleted ones
/// included), `now` the time Synara reads from the clock (`nowIso()`).
pub fn decide(
    command: &OrchestrationCommand,
    thread: Option<&OrchestrationThread>,
    now: &IsoDateTime,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    let command_type = command_type(command);
    match command {
        OrchestrationCommand::Client(client) => decide_client(command_type, client, thread, now),
        OrchestrationCommand::Internal(internal) => decide_internal(command_type, internal, thread),
    }
}

fn decide_client(
    command_type: &'static str,
    command: &ClientThreadCommand,
    thread: Option<&OrchestrationThread>,
    now: &IsoDateTime,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    match command {
        ClientThreadCommand::Create(command) => {
            require_thread_absent(command_type, thread, &command.thread_id)?;
            // Provider-native threads mirror subagents the provider already runs.
            if command.creation_source != Some(ThreadCreationSource::ProviderNative) {
                validate_auto_runtime_mode(command_type, &command.model_selection, command.runtime_mode)?;
            }
            let (associated_worktree_path, associated_worktree_branch, associated_worktree_ref) =
                derive_associated_worktree_metadata(
                    command.branch.as_ref(),
                    command.worktree_path.as_ref(),
                    &command.associated_worktree_path,
                    &command.associated_worktree_branch,
                    &command.associated_worktree_ref,
                );
            let has_source = command.creation_source.is_some();
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadCreated(ThreadCreatedPayload {
                    thread_id: command.thread_id.clone(),
                    project_id: command.project_id.clone(),
                    title: command.title.clone(),
                    model_selection: command.model_selection.clone(),
                    runtime_mode: command.runtime_mode,
                    interaction_mode: command.interaction_mode,
                    env_mode: command.env_mode,
                    branch: command.branch.clone(),
                    worktree_path: command.worktree_path.clone(),
                    working_directory: command.working_directory.clone().flatten(),
                    associated_worktree_path,
                    associated_worktree_branch,
                    associated_worktree_ref,
                    create_branch_flow_completed: command.create_branch_flow_completed,
                    is_pinned: command.is_pinned,
                    parent_thread_id: command.parent_thread_id.clone(),
                    creation_source: has_source.then_some(command.creation_source),
                    source_thread_id: has_source.then(|| command.source_thread_id.clone()),
                    source_turn_id: has_source.then(|| command.source_turn_id.clone()),
                    gateway_operation_id: has_source.then(|| command.gateway_operation_id.clone()),
                    gateway_operation_index: has_source.then_some(command.gateway_operation_index),
                    subagent_agent_id: command.subagent_agent_id.clone(),
                    subagent_nickname: command.subagent_nickname.clone(),
                    subagent_role: command.subagent_role.clone(),
                    fork_source_thread_id: None,
                    created_at: command.created_at.clone(),
                    updated_at: command.created_at.clone(),
                }),
            )])
        }

        ClientThreadCommand::ForkCreate(_) => Err(DecideError::Unsupported { command_type }),

        ClientThreadCommand::Delete(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            if thread_has_checkpoint_revert_in_progress(thread) {
                return Err(DecideError::CheckpointRevertDeleteInProgress {
                    command_type,
                    thread_id: command.thread_id.clone(),
                });
            }
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadDeleted(ThreadDeletedPayload {
                    thread_id: command.thread_id.clone(),
                    deleted_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::Archive(command) => {
            require_thread_not_archived(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadArchived(ThreadArchivedPayload {
                    thread_id: command.thread_id.clone(),
                    archived_at: Some(now.clone()),
                    updated_at: Some(now.clone()),
                }),
            )])
        }

        ClientThreadCommand::Unarchive(command) => {
            require_thread_archived(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadUnarchived(ThreadUnarchivedPayload {
                    thread_id: command.thread_id.clone(),
                    unarchived_at: None,
                    updated_at: Some(now.clone()),
                }),
            )])
        }

        ClientThreadCommand::MetaUpdate(command) => {
            decide_meta_update(command_type, command, thread, now)
        }

        ClientThreadCommand::PinnedMessageAdd(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            let pins = thread.pinned_messages.as_deref().unwrap_or(&[]);
            let existing_pin = pins.iter().find(|pin| pin.message_id == command.message_id);
            if existing_pin.is_none() && pins.len() >= PINNED_MESSAGES_MAX_COUNT {
                return Err(DecideError::PinnedMessagesFull {
                    command_type,
                    thread_id: command.thread_id.clone(),
                });
            }
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadPinnedMessageAdded(ThreadPinnedMessageAddedPayload {
                    thread_id: command.thread_id.clone(),
                    pin: existing_pin.cloned().unwrap_or_else(|| PinnedMessage {
                        message_id: command.message_id.clone(),
                        label: None,
                        done: false,
                        pinned_at: now.clone(),
                    }),
                    updated_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::PinnedMessageRemove(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadPinnedMessageRemoved(ThreadPinnedMessageRemovedPayload {
                    thread_id: command.thread_id.clone(),
                    message_id: command.message_id.clone(),
                    updated_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::PinnedMessageDoneSet(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadPinnedMessageDoneSet(ThreadPinnedMessageDoneSetPayload {
                    thread_id: command.thread_id.clone(),
                    message_id: command.message_id.clone(),
                    done: command.done,
                    updated_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::PinnedMessageLabelSet(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadPinnedMessageLabelSet(ThreadPinnedMessageLabelSetPayload {
                    thread_id: command.thread_id.clone(),
                    message_id: command.message_id.clone(),
                    label: command.label.clone(),
                    updated_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::RuntimeModeSet(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            validate_auto_runtime_mode(command_type, &thread.model_selection, command.runtime_mode)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadRuntimeModeSet(ThreadRuntimeModeSetPayload {
                    thread_id: command.thread_id.clone(),
                    runtime_mode: command.runtime_mode,
                    updated_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::InteractionModeSet(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                now,
                OrchestrationEventBody::ThreadInteractionModeSet(ThreadInteractionModeSetPayload {
                    thread_id: command.thread_id.clone(),
                    previous_interaction_mode: Some(thread.interaction_mode),
                    interaction_mode: command.interaction_mode,
                    updated_at: now.clone(),
                }),
            )])
        }

        ClientThreadCommand::TurnStart(command) => {
            decide_turn_start(&normalize_client_turn_start(command), thread, None)
        }

        ClientThreadCommand::TurnInterrupt(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadTurnInterruptRequested(ThreadTurnInterruptRequestedPayload {
                    thread_id: command.thread_id.clone(),
                    turn_id: command.turn_id.clone(),
                    created_at: command.created_at.clone(),
                }),
            )])
        }

        ClientThreadCommand::TaskStop(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadTaskStopRequested(ThreadTaskStopRequestedPayload {
                    thread_id: command.thread_id.clone(),
                    task_id: command.task_id.clone(),
                    created_at: command.created_at.clone(),
                }),
            )])
        }

        ClientThreadCommand::TaskBackground(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadTaskBackgroundRequested(ThreadTaskBackgroundRequestedPayload {
                    thread_id: command.thread_id.clone(),
                    tool_use_id: command.tool_use_id.clone(),
                    created_at: command.created_at.clone(),
                }),
            )])
        }

        ClientThreadCommand::TurnDispatchQueued(command) => {
            decide_dispatch_queued(command_type, command, thread)
        }

        ClientThreadCommand::ApprovalRespond(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            require_approval_not_responded(
                command_type,
                thread,
                &command.request_id,
                command.lifecycle_generation.as_ref(),
            )?;
            Ok(vec![with_event_base(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventMetadata {
                    request_id: Some(command.request_id.clone()),
                    ..Default::default()
                },
                OrchestrationEventBody::ThreadApprovalResponseRequested(
                    ThreadApprovalResponseRequestedPayload {
                        thread_id: command.thread_id.clone(),
                        request_id: command.request_id.clone(),
                        lifecycle_generation: command.lifecycle_generation.clone(),
                        decision: command.decision,
                        created_at: command.created_at.clone(),
                    },
                ),
            )])
        }

        ClientThreadCommand::UserInputRespond(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            let answers: BTreeMap<String, ProviderUserInputAnswer> = command
                .answers
                .iter()
                .filter(|(_, answer)| **answer != ProviderUserInputAnswer::Null)
                .map(|(key, answer)| (key.clone(), answer.clone()))
                .collect();
            Ok(vec![with_event_base(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventMetadata {
                    request_id: Some(command.request_id.clone()),
                    ..Default::default()
                },
                OrchestrationEventBody::ThreadUserInputResponseRequested(
                    ThreadUserInputResponseRequestedPayload {
                        thread_id: command.thread_id.clone(),
                        request_id: command.request_id.clone(),
                        lifecycle_generation: command.lifecycle_generation.clone(),
                        answers,
                        created_at: command.created_at.clone(),
                    },
                ),
            )])
        }

        ClientThreadCommand::CheckpointRevert(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            if thread_has_in_flight_turn(thread) {
                return Err(DecideError::CheckpointRevertActiveTurn {
                    command_type,
                    thread_id: command.thread_id.clone(),
                });
            }
            if thread_has_checkpoint_revert_in_progress(thread) {
                return Err(DecideError::CheckpointRevertInProgress {
                    command_type,
                    thread_id: command.thread_id.clone(),
                });
            }
            let scope = command.scope.unwrap_or_default();
            let started = event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadActivityAppended(ThreadActivityAppendedPayload {
                    thread_id: command.thread_id.clone(),
                    activity: OrchestrationThreadActivity {
                        id: new_event_id(),
                        tone: OrchestrationThreadActivityTone::Info,
                        kind: CHECKPOINT_REVERT_STARTED_ACTIVITY_KIND.into(),
                        summary: "Checkpoint revert started".into(),
                        payload: json!({ "turnCount": command.turn_count, "scope": scope }),
                        turn_id: None,
                        sequence: None,
                        created_at: command.created_at.clone(),
                    },
                }),
            );
            let requested = event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadCheckpointRevertRequested(
                    ThreadCheckpointRevertRequestedPayload {
                        thread_id: command.thread_id.clone(),
                        turn_count: command.turn_count,
                        scope,
                        created_at: command.created_at.clone(),
                    },
                ),
            );
            Ok(vec![started, requested])
        }

        ClientThreadCommand::ConversationRollback(command) => {
            decide_conversation_rollback(command_type, command, thread)
        }

        ClientThreadCommand::MessageEditAndResend(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            if thread_has_checkpoint_revert_in_progress(thread) {
                return Err(DecideError::CheckpointRevertInProgress {
                    command_type,
                    thread_id: command.thread_id.clone(),
                });
            }
            validate_auto_runtime_mode(
                command_type,
                command.model_selection.as_ref().unwrap_or(&thread.model_selection),
                command.runtime_mode,
            )?;
            let active_turn_id = thread
                .session
                .as_ref()
                .filter(|s| s.status == OrchestrationSessionStatus::Running)
                .and_then(|s| s.active_turn_id.as_ref());
            let (rollback_turn_count, removed_turn_ids) =
                match resolve_tail_user_message_edit_target(&thread.messages, &command.message_id, active_turn_id) {
                    TailUserMessageEditTarget::Editable { rollback_turn_count, removed_turn_ids } => {
                        (rollback_turn_count, removed_turn_ids)
                    }
                    TailUserMessageEditTarget::NotEditable { reason } => {
                        return Err(DecideError::EditTarget { command_type, reason });
                    }
                };
            let requested = event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadMessageEditResendRequested(
                    ThreadMessageEditResendRequestedPayload {
                        thread_id: command.thread_id.clone(),
                        message_id: command.message_id.clone(),
                        text: command.text.clone(),
                        rollback_turn_count: Some(rollback_turn_count),
                        removed_turn_ids: Some(removed_turn_ids),
                        model_selection: command.model_selection.clone(),
                        provider_options: command.provider_options.clone(),
                        assistant_delivery_mode: command.assistant_delivery_mode,
                        runtime_mode: command.runtime_mode,
                        interaction_mode: command.interaction_mode,
                        created_at: command.created_at.clone(),
                    },
                ),
            );
            let session_status = thread.session.as_ref().map(|s| s.status);
            if matches!(
                session_status,
                Some(OrchestrationSessionStatus::Starting | OrchestrationSessionStatus::Running)
            ) {
                return Ok(vec![requested]);
            }
            let starting = event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadSessionSet(ThreadSessionSetPayload {
                    thread_id: command.thread_id.clone(),
                    session: OrchestrationSession {
                        thread_id: command.thread_id.clone(),
                        status: OrchestrationSessionStatus::Starting,
                        provider_name: Some(
                            thread
                                .session
                                .as_ref()
                                .and_then(|s| s.provider_name.clone())
                                .unwrap_or_else(|| {
                                    model_selection_provider(&thread.model_selection).as_str().to_string()
                                }),
                        ),
                        provider_instance_id: None,
                        runtime_mode: command.runtime_mode,
                        active_turn_id: None,
                        last_error: None,
                        last_activity_at: None,
                        last_progress_at: None,
                        updated_at: command.created_at.clone(),
                    },
                }),
            );
            let requested = caused_by(requested, &starting);
            Ok(vec![starting, requested])
        }

        ClientThreadCommand::ActivityAppend(command) => decide_activity_append(command_type, command, thread),

        ClientThreadCommand::SessionStop(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadSessionStopRequested(ThreadSessionStopRequestedPayload {
                    thread_id: command.thread_id.clone(),
                    created_at: command.created_at.clone(),
                }),
            )])
        }
    }
}

fn decide_meta_update(
    command_type: &'static str,
    command: &ThreadMetaUpdateCommand,
    thread: Option<&OrchestrationThread>,
    now: &IsoDateTime,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    let current = require_thread(command_type, thread, &command.thread_id)?;
    let expected_snoozed_until = &command.expected_snoozed_until;
    let expires_snooze = expected_snoozed_until.is_some();
    if matches!(command.snoozed_until, Some(Some(_))) || expires_snooze {
        require_thread_not_archived(command_type, thread, &command.thread_id)?;
    }
    if let Some(expected) = expected_snoozed_until {
        let current_deadline = current.snoozed_until.as_ref().and_then(|s| parse_instant(s.as_str()));
        let expected_deadline = expected.as_ref().and_then(|s| parse_instant(s.as_str()));
        if command.snoozed_until != Some(None)
            || expected.is_none()
            || current.snoozed_until.is_none()
            || current_deadline != expected_deadline
        {
            return Err(DecideError::SnoozeChanged { command_type, thread_id: command.thread_id.clone() });
        }
        if current_deadline.zip(parse_instant(now.as_str())).is_some_and(|(deadline, now)| deadline > now) {
            return Err(DecideError::SnoozeNotDue { command_type, thread_id: command.thread_id.clone() });
        }
    }
    if let Some(selection) = &command.model_selection {
        if current.creation_source != Some(ThreadCreationSource::ProviderNative) {
            validate_auto_runtime_mode(command_type, selection, current.runtime_mode)?;
        }
    }
    let (associated_worktree_path, associated_worktree_branch, associated_worktree_ref) =
        derive_associated_worktree_metadata_patch(
            &command.branch,
            &command.worktree_path,
            &command.associated_worktree_path,
            &command.associated_worktree_branch,
            &command.associated_worktree_ref,
        );
    let mut settled_at = command.is_settled.map(|settled| settled.then(|| now.clone()));
    let mut snooze_reminder_at = command.snoozed_until.as_ref().map(|_| None);
    if expires_snooze {
        snooze_reminder_at = Some(Some(now.clone()));
        settled_at = Some(None);
    }
    Ok(vec![event(
        &command.command_id,
        &command.thread_id,
        now,
        OrchestrationEventBody::ThreadMetaUpdated(ThreadMetaUpdatedPayload {
            thread_id: command.thread_id.clone(),
            title: command.title.clone(),
            model_selection: command.model_selection.clone(),
            env_mode: command.env_mode,
            branch: command.branch.clone(),
            worktree_path: command.worktree_path.clone(),
            working_directory: command.working_directory.clone(),
            associated_worktree_path,
            associated_worktree_branch,
            associated_worktree_ref,
            create_branch_flow_completed: command.create_branch_flow_completed,
            is_pinned: command.is_pinned,
            settled_at,
            snoozed_until: command.snoozed_until.clone(),
            snooze_reminder_at,
            parent_thread_id: command.parent_thread_id.clone(),
            subagent_agent_id: command.subagent_agent_id.clone(),
            subagent_nickname: command.subagent_nickname.clone(),
            subagent_role: command.subagent_role.clone(),
            pinned_messages: command.pinned_messages.clone(),
            notes: command.notes.clone(),
            updated_at: now.clone(),
        }),
    )])
}

/// Synara decider.ts `thread.turn.start` for the server form of the command. `source_thread` is
/// the thread a `sourceProposedPlan` names when that is not `thread` itself.
pub fn decide_turn_start(
    command: &ThreadTurnStartCommand,
    thread: Option<&OrchestrationThread>,
    source_thread: Option<&OrchestrationThread>,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    let command_type = "thread.turn.start";
    let target = require_thread(command_type, thread, &command.thread_id)?;
    if let Some(precondition) = &command.resume_precondition {
        if let Some(violation) = thread_resume_precondition_violation(target, precondition) {
            return Err(DecideError::ResumePrecondition {
                command_type,
                thread_id: command.thread_id.clone(),
                violation,
            });
        }
    }
    if thread_has_checkpoint_revert_in_progress(target) {
        return Err(DecideError::CheckpointRevertInProgress { command_type, thread_id: command.thread_id.clone() });
    }
    let question_response = command.async_user_input_response.as_ref();
    let question_message = question_response
        .and_then(|response| target.messages.iter().find(|m| m.id == response.message_id));
    if let Some(response) = question_response {
        let session_provider = target.session.as_ref().and_then(|s| s.provider_name.as_deref());
        let unavailable = question_message.is_none_or(|m| m.async_user_input.is_none())
            || question_message.is_some_and(|m| m.role != OrchestrationMessageRole::Assistant)
            || !matches!(target.model_selection, ModelSelection::Codex(_))
            || session_provider.is_some_and(|p| p != "codex")
            || command.model_selection.as_ref().is_some_and(|s| !matches!(s, ModelSelection::Codex(_)))
            || target.parent_thread_id.is_some();
        if unavailable {
            return Err(DecideError::AsyncUserInputUnavailable { command_type });
        }
        let input = question_message.and_then(|m| m.async_user_input.as_ref()).expect("checked above");
        if input.response.is_some() {
            return Err(DecideError::AsyncUserInputAlreadyAnswered { command_type });
        }
        if response.answers.len() != input.questions.len()
            || target.messages.iter().any(|m| m.id == command.message.message_id)
        {
            return Err(DecideError::AsyncUserInputAnswerCount { command_type });
        }
    }
    let question_input = question_message.and_then(|m| m.async_user_input.as_ref());
    let message_text = match (question_response, question_input) {
        (Some(response), Some(input)) => format_async_user_input_response(&input.questions, &response.answers),
        _ => command.message.text.clone(),
    };
    if message_text.chars().count() > PROVIDER_SEND_TURN_MAX_INPUT_CHARS {
        return Err(DecideError::MessageTooLong { command_type });
    }
    // A quit-resume or answer command respects the thread's current modes.
    let replays_thread_modes = command.resume_precondition.is_some() || question_response.is_some();
    let runtime_mode = if replays_thread_modes { target.runtime_mode } else { command.runtime_mode };
    let interaction_mode = if replays_thread_modes { target.interaction_mode } else { command.interaction_mode };
    validate_auto_runtime_mode(
        command_type,
        command.model_selection.as_ref().unwrap_or(&target.model_selection),
        runtime_mode,
    )?;
    if let Some(reference) = &command.source_proposed_plan {
        let source = if reference.thread_id == target.id {
            Some(target)
        } else {
            source_thread.filter(|t| t.id == reference.thread_id && t.deleted_at.is_none())
        };
        let Some(source) = source else {
            return Err(DecideError::ThreadMissing { command_type, thread_id: reference.thread_id.clone() });
        };
        if !source.proposed_plans.iter().any(|plan| plan.id == reference.plan_id) {
            return Err(DecideError::ProposedPlanMissing {
                command_type,
                plan_id: reference.plan_id.clone(),
                thread_id: reference.thread_id.clone(),
            });
        }
        if source.project_id != target.project_id {
            return Err(DecideError::ProposedPlanOtherProject {
                command_type,
                plan_id: reference.plan_id.clone(),
                thread_id: source.id.clone(),
            });
        }
    }
    let dispatch_mode = if question_response.is_some() { TurnDispatchMode::Steer } else { command.dispatch_mode };
    let active_provider = target
        .session
        .as_ref()
        .and_then(|s| s.provider_name.clone())
        .unwrap_or_else(|| model_selection_provider(&target.model_selection).as_str().to_string());
    let is_thread_running = target.session.as_ref().is_some_and(|s| {
        s.status == OrchestrationSessionStatus::Running && s.active_turn_id.is_some()
    });
    // Subagent threads never queue; steers ride the live turn only where the runtime can
    // inject mid-turn input, and queue and interrupt everywhere else.
    let should_queue = target.parent_thread_id.is_none()
        && is_thread_running
        && (dispatch_mode == TurnDispatchMode::Queue
            || !provider_supports_native_turn_steering(&active_provider));
    let dispatch_origin = command.dispatch_origin.unwrap_or(MessageDispatchOrigin::User);
    let mut events = vec![];
    if dispatch_origin == MessageDispatchOrigin::User
        && (target.snoozed_until.is_some() || target.snooze_reminder_at.is_some())
    {
        events.push(event(
            &command.command_id,
            &command.thread_id,
            &command.created_at,
            OrchestrationEventBody::ThreadMetaUpdated(ThreadMetaUpdatedPayload {
                thread_id: command.thread_id.clone(),
                title: None,
                model_selection: None,
                env_mode: None,
                branch: None,
                worktree_path: None,
                working_directory: None,
                associated_worktree_path: None,
                associated_worktree_branch: None,
                associated_worktree_ref: None,
                create_branch_flow_completed: None,
                is_pinned: None,
                settled_at: None,
                snoozed_until: Some(None),
                snooze_reminder_at: Some(None),
                parent_thread_id: None,
                subagent_agent_id: None,
                subagent_nickname: None,
                subagent_role: None,
                pinned_messages: None,
                notes: None,
                updated_at: command.created_at.clone(),
            }),
        ));
    }
    let user_message = event(
        &command.command_id,
        &command.thread_id,
        &command.created_at,
        OrchestrationEventBody::ThreadMessageSent(ThreadMessageSentPayload {
            async_user_input: None,
            thread_id: command.thread_id.clone(),
            message_id: command.message.message_id.clone(),
            role: OrchestrationMessageRole::User,
            text: message_text,
            segment_started_at: None,
            segment_sequence: None,
            attachments: Some(command.message.attachments.clone()),
            skills: command.message.skills.clone(),
            mentions: command.message.mentions.clone(),
            dispatch_mode: Some(dispatch_mode),
            // Explicit "user" (not absent): a human resend must overwrite a stale origin.
            dispatch_origin: Some(dispatch_origin),
            starts_new_turn: Some(dispatch_mode != TurnDispatchMode::Steer || !is_thread_running || should_queue),
            turn_id: None,
            streaming: false,
            source: if question_response.is_some() {
                OrchestrationMessageSource::AsyncUserInput
            } else {
                OrchestrationMessageSource::Native
            },
            created_at: command.created_at.clone(),
            updated_at: command.created_at.clone(),
        }),
    );
    let turn_request = ThreadTurnStartRequestedPayload {
        thread_id: command.thread_id.clone(),
        message_id: command.message.message_id.clone(),
        model_selection: command.model_selection.clone(),
        provider_options: command.provider_options.clone(),
        review_target: command.review_target.clone(),
        assistant_delivery_mode: Some(command.assistant_delivery_mode.unwrap_or(DEFAULT_ASSISTANT_DELIVERY_MODE)),
        dispatch_mode,
        dispatch_origin: Some(dispatch_origin),
        runtime_mode,
        interaction_mode,
        source_proposed_plan: command.source_proposed_plan.clone(),
        created_at: command.created_at.clone(),
    };
    let queued = caused_by(
        event(
            &command.command_id,
            &command.thread_id,
            &command.created_at,
            if should_queue {
                OrchestrationEventBody::ThreadTurnQueued(turn_request)
            } else {
                OrchestrationEventBody::ThreadTurnStartRequested(turn_request)
            },
        ),
        &user_message,
    );
    if should_queue && dispatch_mode == TurnDispatchMode::Steer {
        let interrupt = caused_by(
            event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadTurnInterruptRequested(ThreadTurnInterruptRequestedPayload {
                    thread_id: command.thread_id.clone(),
                    turn_id: target.session.as_ref().and_then(|s| s.active_turn_id.clone()),
                    created_at: command.created_at.clone(),
                }),
            ),
            &queued,
        );
        events.extend([user_message, queued, interrupt]);
        return Ok(events);
    }
    if let (Some(response), Some(message)) = (question_response, question_message) {
        events.push(event(
            &command.command_id,
            &command.thread_id,
            &command.created_at,
            OrchestrationEventBody::ThreadAsyncUserInputAnswered(ThreadAsyncUserInputAnsweredPayload {
                thread_id: command.thread_id.clone(),
                message_id: message.id.clone(),
                response: AsyncUserInputResponse {
                    message_id: command.message.message_id.clone(),
                    answers: response.answers.clone(),
                },
            }),
        ));
    }
    events.extend([user_message, queued]);
    Ok(events)
}

fn decide_dispatch_queued(
    command_type: &'static str,
    command: &ThreadDispatchQueuedTurnCommand,
    thread: Option<&OrchestrationThread>,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    let thread = require_thread(command_type, thread, &command.thread_id)?;
    if thread_has_checkpoint_revert_in_progress(thread) {
        return Err(DecideError::CheckpointRevertInProgress { command_type, thread_id: command.thread_id.clone() });
    }
    validate_auto_runtime_mode(
        command_type,
        command.model_selection.as_ref().unwrap_or(&thread.model_selection),
        command.runtime_mode,
    )?;
    Ok(vec![event(
        &command.command_id,
        &command.thread_id,
        &command.created_at,
        OrchestrationEventBody::ThreadTurnStartRequested(ThreadTurnStartRequestedPayload {
            thread_id: command.thread_id.clone(),
            message_id: command.message_id.clone(),
            model_selection: command.model_selection.clone(),
            provider_options: command.provider_options.clone(),
            review_target: command.review_target.clone(),
            assistant_delivery_mode: Some(command.assistant_delivery_mode.unwrap_or(DEFAULT_ASSISTANT_DELIVERY_MODE)),
            dispatch_mode: command.dispatch_mode,
            dispatch_origin: Some(command.dispatch_origin.unwrap_or(MessageDispatchOrigin::User)),
            runtime_mode: command.runtime_mode,
            interaction_mode: command.interaction_mode,
            source_proposed_plan: command.source_proposed_plan.clone(),
            created_at: command.created_at.clone(),
        }),
    )])
}

fn decide_conversation_rollback(
    command_type: &'static str,
    command: &ThreadConversationRollbackCommand,
    thread: Option<&OrchestrationThread>,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    let thread = require_thread(command_type, thread, &command.thread_id)?;
    if thread_has_checkpoint_revert_in_progress(thread) {
        return Err(DecideError::CheckpointRevertInProgress { command_type, thread_id: command.thread_id.clone() });
    }
    let Some(target) = thread.messages.iter().find(|m| m.id == command.message_id) else {
        return Err(DecideError::RollbackTargetNotUser { command_type });
    };
    if target.role != OrchestrationMessageRole::User {
        return Err(DecideError::RollbackTargetNotUser { command_type });
    }
    let removed = collect_tail_turn_ids(&thread.messages, &command.message_id).len();
    if command.num_turns == 0 || removed as u64 != command.num_turns {
        return Err(DecideError::RollbackTurnCount {
            command_type,
            requested: command.num_turns,
            message_id: command.message_id.clone(),
            would_remove: removed,
        });
    }
    Ok(vec![event(
        &command.command_id,
        &command.thread_id,
        &command.created_at,
        OrchestrationEventBody::ThreadConversationRollbackRequested(
            ThreadConversationRollbackRequestedPayload {
                thread_id: command.thread_id.clone(),
                message_id: command.message_id.clone(),
                num_turns: command.num_turns,
                created_at: command.created_at.clone(),
            },
        ),
    )])
}

fn decide_activity_append(
    command_type: &'static str,
    command: &ThreadActivityAppendCommand,
    thread: Option<&OrchestrationThread>,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    if command.require_unarchived == Some(true) {
        require_thread_not_archived(command_type, thread, &command.thread_id)?;
    } else {
        require_thread(command_type, thread, &command.thread_id)?;
    }
    let request_id = command
        .activity
        .payload
        .get("requestId")
        .and_then(|v| v.as_str())
        .map(ApprovalRequestId::new);
    Ok(vec![with_event_base(
        &command.command_id,
        &command.thread_id,
        &command.created_at,
        OrchestrationEventMetadata { request_id, ..Default::default() },
        OrchestrationEventBody::ThreadActivityAppended(ThreadActivityAppendedPayload {
            thread_id: command.thread_id.clone(),
            activity: command.activity.clone(),
        }),
    )])
}

fn decide_internal(
    command_type: &'static str,
    command: &InternalThreadCommand,
    thread: Option<&OrchestrationThread>,
) -> Result<Vec<OrchestrationEvent>, DecideError> {
    match command {
        InternalThreadCommand::SessionSet(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            let current = thread.session.as_ref();
            let session_changed = command
                .expected_session_status
                .is_some_and(|expected| current.map(|s| s.status) != Some(expected))
                || command
                    .expected_session_updated_at
                    .as_ref()
                    .is_some_and(|expected| current.map(|s| &s.updated_at) != Some(expected));
            if session_changed {
                return Err(DecideError::SessionChanged { command_type, thread_id: command.thread_id.clone() });
            }
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadSessionSet(ThreadSessionSetPayload {
                    thread_id: command.thread_id.clone(),
                    session: command.session.clone(),
                }),
            )])
        }

        InternalThreadCommand::MessagesImport(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(command
                .messages
                .iter()
                .map(|message| {
                    event(
                        &command.command_id,
                        &command.thread_id,
                        &command.created_at,
                        OrchestrationEventBody::ThreadMessageSent(ThreadMessageSentPayload {
                            async_user_input: None,
                            thread_id: command.thread_id.clone(),
                            message_id: message.message_id.clone(),
                            role: match message.role {
                                ThreadHandoffImportedMessageRole::User => OrchestrationMessageRole::User,
                                ThreadHandoffImportedMessageRole::Assistant => OrchestrationMessageRole::Assistant,
                            },
                            text: message.text.clone(),
                            segment_started_at: None,
                            segment_sequence: None,
                            attachments: message.attachments.clone(),
                            skills: None,
                            mentions: None,
                            dispatch_mode: None,
                            dispatch_origin: None,
                            starts_new_turn: None,
                            turn_id: None,
                            streaming: false,
                            source: OrchestrationMessageSource::Native,
                            created_at: message.created_at.clone(),
                            updated_at: message.updated_at.clone(),
                        }),
                    )
                })
                .collect())
        }

        InternalThreadCommand::MessageAssistantDelta(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            let existing = thread.messages.iter().find(|m| m.id == command.message_id);
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadMessageSent(ThreadMessageSentPayload {
                    async_user_input: None,
                    thread_id: command.thread_id.clone(),
                    message_id: command.message_id.clone(),
                    role: OrchestrationMessageRole::Assistant,
                    text: command.delta.clone(),
                    segment_started_at: command.segment_started_at.clone(),
                    segment_sequence: command.segment_sequence,
                    attachments: None,
                    skills: None,
                    mentions: None,
                    dispatch_mode: None,
                    dispatch_origin: None,
                    starts_new_turn: None,
                    turn_id: resolve_stable_message_turn_id(
                        existing.and_then(|m| m.turn_id.as_ref()),
                        command.turn_id.as_ref(),
                    ),
                    streaming: true,
                    source: OrchestrationMessageSource::Native,
                    created_at: command.created_at.clone(),
                    updated_at: command.created_at.clone(),
                }),
            )])
        }

        InternalThreadCommand::MessageAssistantComplete(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            let existing = thread.messages.iter().find(|m| m.id == command.message_id);
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadMessageSent(ThreadMessageSentPayload {
                    async_user_input: command.async_questions.as_ref().map(|questions| {
                        existing.and_then(|m| m.async_user_input.clone()).unwrap_or_else(|| AsyncUserInput {
                            questions: questions.clone(),
                            response: None,
                            response_sequence: None,
                        })
                    }),
                    thread_id: command.thread_id.clone(),
                    message_id: command.message_id.clone(),
                    role: OrchestrationMessageRole::Assistant,
                    text: existing.map(|m| m.text.clone()).unwrap_or_default(),
                    segment_started_at: None,
                    segment_sequence: None,
                    attachments: None,
                    skills: None,
                    mentions: None,
                    dispatch_mode: None,
                    dispatch_origin: None,
                    starts_new_turn: None,
                    turn_id: resolve_stable_message_turn_id(
                        existing.and_then(|m| m.turn_id.as_ref()),
                        command.turn_id.as_ref(),
                    ),
                    streaming: false,
                    source: OrchestrationMessageSource::Native,
                    created_at: command.created_at.clone(),
                    updated_at: command.created_at.clone(),
                }),
            )])
        }

        InternalThreadCommand::MessageUserBindTurn(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            let message = thread
                .messages
                .iter()
                .find(|m| m.id == command.message_id)
                .filter(|m| m.role == OrchestrationMessageRole::User)
                .ok_or_else(|| DecideError::UserMessageMissing {
                    command_type,
                    message_id: command.message_id.clone(),
                    thread_id: command.thread_id.clone(),
                })?;
            if let Some(bound) = message.turn_id.as_ref().filter(|t| **t != command.turn_id) {
                return Err(DecideError::UserMessageBound {
                    command_type,
                    message_id: command.message_id.clone(),
                    turn_id: bound.clone(),
                });
            }
            // Re-emit the canonical upsert when already bound so retries stay idempotent.
            Ok(vec![user_message_upsert_event(
                &command.command_id,
                &command.thread_id,
                message,
                Some(command.turn_id.clone()),
                None,
                &command.created_at,
            )])
        }

        InternalThreadCommand::MessageUserSetTurnBoundary(command) => {
            let thread = require_thread(command_type, thread, &command.thread_id)?;
            let message = thread
                .messages
                .iter()
                .find(|m| m.id == command.message_id)
                .filter(|m| m.role == OrchestrationMessageRole::User)
                .ok_or_else(|| DecideError::UserMessageMissing {
                    command_type,
                    message_id: command.message_id.clone(),
                    thread_id: command.thread_id.clone(),
                })?;
            Ok(vec![user_message_upsert_event(
                &command.command_id,
                &command.thread_id,
                message,
                message.turn_id.clone(),
                Some(command.starts_new_turn),
                &command.created_at,
            )])
        }

        InternalThreadCommand::ProposedPlanUpsert(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadProposedPlanUpserted(ThreadProposedPlanUpsertedPayload {
                    thread_id: command.thread_id.clone(),
                    proposed_plan: command.proposed_plan.clone(),
                }),
            )])
        }

        InternalThreadCommand::TurnDiffComplete(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            let diff_completed = event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadTurnDiffCompleted(ThreadTurnDiffCompletedPayload {
                    thread_id: command.thread_id.clone(),
                    turn_id: command.turn_id.clone(),
                    checkpoint_turn_count: command.checkpoint_turn_count,
                    checkpoint_ref: command.checkpoint_ref.clone(),
                    status: command.status,
                    files: command.files.clone(),
                    assistant_message_id: command.assistant_message_id.clone(),
                    completed_at: command.completed_at.clone(),
                    preserve_latest_turn: (command.preserve_latest_turn == Some(true)).then_some(true),
                }),
            );
            match command.checkpoint_revert_turn_count {
                None => Ok(vec![diff_completed]),
                Some(turn_count) => {
                    let succeeded = checkpoint_revert_succeeded_event(
                        &command.command_id,
                        &command.thread_id,
                        turn_count,
                        &command.created_at,
                        &diff_completed,
                    );
                    Ok(vec![diff_completed, succeeded])
                }
            }
        }

        InternalThreadCommand::ActivityAppend(command) => decide_activity_append(command_type, command, thread),

        InternalThreadCommand::RevertComplete(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            let reverted = event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadReverted(ThreadRevertedPayload {
                    thread_id: command.thread_id.clone(),
                    turn_count: command.turn_count,
                }),
            );
            let succeeded = checkpoint_revert_succeeded_event(
                &command.command_id,
                &command.thread_id,
                command.turn_count,
                &command.created_at,
                &reverted,
            );
            Ok(vec![reverted, succeeded])
        }

        InternalThreadCommand::ConversationRollback(command) => {
            decide_conversation_rollback(command_type, command, thread)
        }

        InternalThreadCommand::ConversationRollbackComplete(command) => {
            require_thread(command_type, thread, &command.thread_id)?;
            Ok(vec![event(
                &command.command_id,
                &command.thread_id,
                &command.created_at,
                OrchestrationEventBody::ThreadConversationRolledBack(ThreadConversationRolledBackPayload {
                    thread_id: command.thread_id.clone(),
                    message_id: command.message_id.clone(),
                    num_turns: command.num_turns,
                    removed_turn_ids: command.removed_turn_ids.clone(),
                    skip_attachment_prune: command.skip_attachment_prune,
                }),
            )])
        }

        InternalThreadCommand::TurnDispatchQueued(command) => decide_dispatch_queued(command_type, command, thread),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use serde_json::json;

    use super::*;
    use crate::orchestration::projector::project;

    pub(crate) const T0: &str = "2026-10-05T10:00:00.000Z";

    pub(crate) fn iso(value: &str) -> IsoDateTime {
        IsoDateTime::new(value)
    }

    pub(crate) fn client(value: serde_json::Value) -> OrchestrationCommand {
        OrchestrationCommand::Client(serde_json::from_value(value).unwrap())
    }

    pub(crate) fn internal(value: serde_json::Value) -> OrchestrationCommand {
        OrchestrationCommand::Internal(serde_json::from_value(value).unwrap())
    }

    /// Decide a command against `thread` and project its events in order, numbering them from
    /// `next_sequence`, the way the engine does.
    pub(crate) fn apply(
        thread: Option<OrchestrationThread>,
        command: &OrchestrationCommand,
        next_sequence: &mut u64,
    ) -> Result<(Option<OrchestrationThread>, Vec<OrchestrationEvent>), DecideError> {
        let events = decide(command, thread.as_ref(), &iso(T0))?;
        let mut thread = thread;
        let mut numbered = vec![];
        for mut event in events {
            *next_sequence += 1;
            event.sequence = *next_sequence;
            thread = project(thread, &event);
            numbered.push(event);
        }
        Ok((thread, numbered))
    }

    pub(crate) fn create_thread(provider: &str) -> OrchestrationCommand {
        client(json!({
            "type": "thread.create",
            "commandId": "cmd-create",
            "threadId": "thread-1",
            "projectId": "project-1",
            "title": "Fix the build",
            "modelSelection": { "provider": provider, "model": "model-1" },
            "runtimeMode": "approval-required",
            "branch": null,
            "worktreePath": null,
            "createdAt": T0,
        }))
    }

    pub(crate) fn created_thread() -> (OrchestrationThread, u64) {
        let mut sequence = 0;
        let (thread, _) = apply(None, &create_thread("codex"), &mut sequence).unwrap();
        (thread.unwrap(), sequence)
    }

    fn turn_start(message_id: &str, dispatch_mode: &str) -> OrchestrationCommand {
        client(json!({
            "type": "thread.turn.start",
            "commandId": format!("cmd-{message_id}"),
            "threadId": "thread-1",
            "message": { "messageId": message_id, "role": "user", "text": "Fix it", "attachments": [] },
            "dispatchMode": dispatch_mode,
            "runtimeMode": "approval-required",
            "interactionMode": "default",
            "createdAt": T0,
        }))
    }

    fn type_of(event: &OrchestrationEvent) -> String {
        serde_json::to_value(event).unwrap()["type"].as_str().unwrap().to_string()
    }

    #[test]
    fn create_rejects_an_existing_thread() {
        let (thread, _) = created_thread();
        let error = decide(&create_thread("codex"), Some(&thread), &iso(T0)).unwrap_err();
        assert_eq!(error.to_string(), "Thread 'thread-1' already exists and cannot be created twice.");
    }

    #[test]
    fn commands_on_a_missing_thread_name_the_command() {
        let error = decide(&turn_start("msg-1", "queue"), None, &iso(T0)).unwrap_err();
        assert_eq!(error.to_string(), "Thread 'thread-1' does not exist for command 'thread.turn.start'.");
    }

    #[test]
    fn turn_start_on_an_idle_thread_requests_a_turn() {
        let (thread, mut sequence) = created_thread();
        let (thread, events) = apply(Some(thread), &turn_start("msg-1", "queue"), &mut sequence).unwrap();
        let kinds: Vec<_> = events.iter().map(type_of).collect();
        assert_eq!(kinds, ["thread.message-sent", "thread.turn-start-requested"]);
        assert_eq!(events[1].causation_event_id.as_ref(), Some(&events[0].event_id));
        let thread = thread.unwrap();
        let message = &thread.messages[0];
        assert_eq!(message.role, OrchestrationMessageRole::User);
        assert_eq!(message.dispatch_origin, Some(MessageDispatchOrigin::User));
        assert_eq!(message.starts_new_turn, Some(true));
        let session = thread.session.unwrap();
        assert_eq!(session.status, OrchestrationSessionStatus::Starting);
        assert_eq!(session.provider_name.as_deref(), Some("codex"));
    }

    fn running(mut thread: OrchestrationThread, provider: &str) -> OrchestrationThread {
        thread.session = Some(OrchestrationSession {
            thread_id: thread.id.clone(),
            status: OrchestrationSessionStatus::Running,
            provider_name: Some(provider.into()),
            provider_instance_id: None,
            runtime_mode: RuntimeMode::ApprovalRequired,
            active_turn_id: Some(TurnId::new("turn-1")),
            last_error: None,
            last_activity_at: None,
            last_progress_at: None,
            updated_at: iso(T0),
        });
        thread
    }

    #[test]
    fn queue_dispatch_on_a_running_thread_queues_the_turn() {
        let (thread, _) = created_thread();
        let thread = running(thread, "codex");
        let events = decide(&turn_start("msg-2", "queue"), Some(&thread), &iso(T0)).unwrap();
        let kinds: Vec<_> = events.iter().map(type_of).collect();
        assert_eq!(kinds, ["thread.message-sent", "thread.turn-queued"]);
    }

    #[test]
    fn steer_rides_a_native_steering_provider_and_interrupts_elsewhere() {
        let (thread, _) = created_thread();
        let codex = running(thread.clone(), "codex");
        let events = decide(&turn_start("msg-2", "steer"), Some(&codex), &iso(T0)).unwrap();
        let kinds: Vec<_> = events.iter().map(type_of).collect();
        assert_eq!(kinds, ["thread.message-sent", "thread.turn-start-requested"]);
        let OrchestrationEventBody::ThreadMessageSent(sent) = &events[0].body else { panic!() };
        assert_eq!(sent.starts_new_turn, Some(false));

        let cursor = running(thread, "cursor");
        let events = decide(&turn_start("msg-2", "steer"), Some(&cursor), &iso(T0)).unwrap();
        let kinds: Vec<_> = events.iter().map(type_of).collect();
        assert_eq!(kinds, ["thread.message-sent", "thread.turn-queued", "thread.turn-interrupt-requested"]);
        let OrchestrationEventBody::ThreadTurnInterruptRequested(interrupt) = &events[2].body else { panic!() };
        assert_eq!(interrupt.turn_id, Some(TurnId::new("turn-1")));
    }

    #[test]
    fn auto_mode_needs_a_verified_claude_model() {
        let mut sequence = 0;
        let (thread, _) = apply(None, &create_thread("claudeAgent"), &mut sequence).unwrap();
        let command = client(json!({
            "type": "thread.runtime-mode.set", "commandId": "cmd-mode", "threadId": "thread-1",
            "runtimeMode": "auto", "createdAt": T0,
        }));
        let error = decide(&command, thread.as_ref(), &iso(T0)).unwrap_err();
        assert_eq!(error.to_string(), "Claude model \"model-1\" has not been verified to support Auto mode.");
    }

    #[test]
    fn archive_and_unarchive_guard_each_other() {
        let (thread, mut sequence) = created_thread();
        let unarchive = client(json!({ "type": "thread.unarchive", "commandId": "c1", "threadId": "thread-1" }));
        let error = decide(&unarchive, Some(&thread), &iso(T0)).unwrap_err();
        assert!(error.to_string().contains(THREAD_NOT_ARCHIVED_INVARIANT_MARKER));
        let archive = client(json!({ "type": "thread.archive", "commandId": "c2", "threadId": "thread-1" }));
        let (thread, _) = apply(Some(thread), &archive, &mut sequence).unwrap();
        let thread = thread.unwrap();
        assert_eq!(thread.archived_at, Some(iso(T0)));
        assert!(decide(&archive, Some(&thread), &iso(T0)).is_err());
        let (thread, _) = apply(Some(thread), &unarchive, &mut sequence).unwrap();
        assert_eq!(thread.unwrap().archived_at, None);
    }

    #[test]
    fn delete_is_refused_during_a_checkpoint_revert() {
        let (thread, mut sequence) = created_thread();
        let revert = client(json!({
            "type": "thread.checkpoint.revert", "commandId": "c-revert", "threadId": "thread-1",
            "turnCount": 0, "createdAt": T0,
        }));
        let (thread, events) = apply(Some(thread), &revert, &mut sequence).unwrap();
        assert_eq!(events.iter().map(type_of).collect::<Vec<_>>(), ["thread.activity-appended", "thread.checkpoint-revert-requested"]);
        let thread = thread.unwrap();
        assert!(thread_has_checkpoint_revert_in_progress(&thread));
        let delete = client(json!({ "type": "thread.delete", "commandId": "c-del", "threadId": "thread-1" }));
        assert!(matches!(
            decide(&delete, Some(&thread), &iso(T0)),
            Err(DecideError::CheckpointRevertDeleteInProgress { .. })
        ));
        let complete = internal(json!({
            "type": "thread.revert.complete", "commandId": "c-done", "threadId": "thread-1",
            "turnCount": 0, "createdAt": T0,
        }));
        let (thread, _) = apply(Some(thread), &complete, &mut sequence).unwrap();
        assert!(!thread_has_checkpoint_revert_in_progress(thread.as_ref().unwrap()));
    }

    #[test]
    fn checkpoint_revert_is_refused_while_a_turn_runs() {
        let (thread, _) = created_thread();
        let thread = running(thread, "codex");
        let revert = client(json!({
            "type": "thread.checkpoint.revert", "commandId": "c-revert", "threadId": "thread-1",
            "turnCount": 0, "createdAt": T0,
        }));
        assert!(matches!(
            decide(&revert, Some(&thread), &iso(T0)),
            Err(DecideError::CheckpointRevertActiveTurn { .. })
        ));
    }

    #[test]
    fn approval_respond_is_refused_once_answered() {
        let (mut thread, _) = created_thread();
        thread.pending_interactions = Some(vec![OrchestrationPendingInteraction {
            interaction_kind: ProjectionPendingInteractionKind::Approval,
            request_id: ApprovalRequestId::new("req-1"),
            thread_id: thread.id.clone(),
            turn_id: None,
            lifecycle_generation: None,
            status: ProjectionPendingInteractionStatus::Confirmed,
            decision: Some(ProviderApprovalDecision::Accept),
            response_command_id: None,
            response_requested_at: None,
            created_at: iso(T0),
            resolved_at: None,
        }]);
        let respond = client(json!({
            "type": "thread.approval.respond", "commandId": "c-ok", "threadId": "thread-1",
            "requestId": "req-1", "decision": "accept", "createdAt": T0,
        }));
        let error = decide(&respond, Some(&thread), &iso(T0)).unwrap_err();
        assert!(error.to_string().ends_with(APPROVAL_ALREADY_ANSWERED_INVARIANT_MARKER));
        thread.pending_interactions.as_mut().unwrap()[0].status = ProjectionPendingInteractionStatus::Pending;
        let events = decide(&respond, Some(&thread), &iso(T0)).unwrap();
        assert_eq!(events[0].metadata.request_id, Some(ApprovalRequestId::new("req-1")));
    }

    #[test]
    fn user_input_respond_drops_null_answers() {
        let (thread, _) = created_thread();
        let respond = client(json!({
            "type": "thread.user-input.respond", "commandId": "c-in", "threadId": "thread-1",
            "requestId": "req-2", "answers": { "a": "yes", "b": null }, "createdAt": T0,
        }));
        let events = decide(&respond, Some(&thread), &iso(T0)).unwrap();
        let OrchestrationEventBody::ThreadUserInputResponseRequested(payload) = &events[0].body else { panic!() };
        assert_eq!(payload.answers.len(), 1);
    }

    #[test]
    fn pinned_messages_add_once_and_toggle() {
        let (thread, mut sequence) = created_thread();
        let add = client(json!({ "type": "thread.pinned-message.add", "commandId": "p1", "threadId": "thread-1", "messageId": "msg-1" }));
        let (thread, _) = apply(Some(thread), &add, &mut sequence).unwrap();
        let (thread, _) = apply(thread, &add, &mut sequence).unwrap();
        let done = client(json!({ "type": "thread.pinned-message.done.set", "commandId": "p2", "threadId": "thread-1", "messageId": "msg-1", "done": true }));
        let label = client(json!({ "type": "thread.pinned-message.label.set", "commandId": "p3", "threadId": "thread-1", "messageId": "msg-1", "label": "  Ship it  " }));
        let (thread, _) = apply(thread, &done, &mut sequence).unwrap();
        let (thread, _) = apply(thread, &label, &mut sequence).unwrap();
        let pins = thread.clone().unwrap().pinned_messages.unwrap();
        assert_eq!(pins.len(), 1);
        assert!(pins[0].done);
        assert_eq!(pins[0].label.as_deref(), Some("Ship it"));
        let remove = client(json!({ "type": "thread.pinned-message.remove", "commandId": "p4", "threadId": "thread-1", "messageId": "msg-1" }));
        let (thread, _) = apply(thread, &remove, &mut sequence).unwrap();
        assert!(thread.unwrap().pinned_messages.unwrap().is_empty());
    }

    #[test]
    fn interaction_mode_set_records_the_previous_mode() {
        let (thread, mut sequence) = created_thread();
        let set = client(json!({ "type": "thread.interaction-mode.set", "commandId": "m1", "threadId": "thread-1", "interactionMode": "plan", "createdAt": T0 }));
        let (thread, events) = apply(Some(thread), &set, &mut sequence).unwrap();
        let OrchestrationEventBody::ThreadInteractionModeSet(payload) = &events[0].body else { panic!() };
        assert_eq!(payload.previous_interaction_mode, Some(ProviderInteractionMode::Default));
        assert_eq!(thread.unwrap().interaction_mode, ProviderInteractionMode::Plan);
    }

    fn thread_with_turns() -> (OrchestrationThread, u64) {
        let (thread, mut sequence) = created_thread();
        let (thread, _) = apply(Some(thread), &turn_start("msg-1", "queue"), &mut sequence).unwrap();
        let bind = internal(json!({ "type": "thread.message.user.bind-turn", "commandId": "b1", "threadId": "thread-1", "messageId": "msg-1", "turnId": "turn-1", "createdAt": T0 }));
        let (thread, _) = apply(thread, &bind, &mut sequence).unwrap();
        let mut thread = thread.unwrap();
        thread.session = None;
        (thread, sequence)
    }

    #[test]
    fn bind_turn_refuses_a_second_turn() {
        let (thread, _) = thread_with_turns();
        assert_eq!(thread.messages[0].turn_id, Some(TurnId::new("turn-1")));
        let rebind = internal(json!({ "type": "thread.message.user.bind-turn", "commandId": "b2", "threadId": "thread-1", "messageId": "msg-1", "turnId": "turn-2", "createdAt": T0 }));
        assert!(matches!(decide(&rebind, Some(&thread), &iso(T0)), Err(DecideError::UserMessageBound { .. })));
    }

    #[test]
    fn conversation_rollback_checks_the_turn_count() {
        let (thread, mut sequence) = thread_with_turns();
        let wrong = client(json!({ "type": "thread.conversation.rollback", "commandId": "r1", "threadId": "thread-1", "messageId": "msg-1", "numTurns": 2, "createdAt": T0 }));
        assert!(matches!(decide(&wrong, Some(&thread), &iso(T0)), Err(DecideError::RollbackTurnCount { would_remove: 1, .. })));
        let right = client(json!({ "type": "thread.conversation.rollback", "commandId": "r2", "threadId": "thread-1", "messageId": "msg-1", "numTurns": 1, "createdAt": T0 }));
        assert!(decide(&right, Some(&thread), &iso(T0)).is_ok());
        let complete = internal(json!({ "type": "thread.conversation.rollback.complete", "commandId": "r3", "threadId": "thread-1", "messageId": "msg-1", "numTurns": 1, "createdAt": T0 }));
        let (thread, _) = apply(Some(thread), &complete, &mut sequence).unwrap();
        assert!(thread.unwrap().messages.is_empty());
    }

    #[test]
    fn edit_and_resend_starts_a_session_when_idle() {
        let (thread, _) = thread_with_turns();
        let edit = client(json!({
            "type": "thread.message.edit-and-resend", "commandId": "e1", "threadId": "thread-1",
            "messageId": "msg-1", "text": "Fix it properly", "runtimeMode": "approval-required",
            "interactionMode": "default", "createdAt": T0,
        }));
        let events = decide(&edit, Some(&thread), &iso(T0)).unwrap();
        assert_eq!(events.iter().map(type_of).collect::<Vec<_>>(), ["thread.session-set", "thread.message-edit-resend-requested"]);
        let OrchestrationEventBody::ThreadMessageEditResendRequested(payload) = &events[1].body else { panic!() };
        assert_eq!(payload.rollback_turn_count, Some(1));
        assert_eq!(payload.removed_turn_ids, Some(vec![TurnId::new("turn-1")]));
    }

    #[test]
    fn session_set_honours_its_condition() {
        let (thread, _) = created_thread();
        let set = internal(json!({
            "type": "thread.session.set", "commandId": "s1", "threadId": "thread-1",
            "session": { "threadId": "thread-1", "status": "ready", "providerName": "codex", "runtimeMode": "full-access", "activeTurnId": null, "lastError": null, "updatedAt": T0 },
            "expectedSessionStatus": "running", "createdAt": T0,
        }));
        assert!(matches!(decide(&set, Some(&thread), &iso(T0)), Err(DecideError::SessionChanged { .. })));
    }

    #[test]
    fn meta_update_derives_worktree_association_and_settles() {
        let (thread, mut sequence) = created_thread();
        let update = client(json!({
            "type": "thread.meta.update", "commandId": "u1", "threadId": "thread-1",
            "title": "Renamed", "branch": "fix/x", "worktreePath": "/w/x", "isSettled": true,
        }));
        let (thread, events) = apply(Some(thread), &update, &mut sequence).unwrap();
        let OrchestrationEventBody::ThreadMetaUpdated(payload) = &events[0].body else { panic!() };
        assert_eq!(payload.associated_worktree_path, Some(Some("/w/x".into())));
        assert_eq!(payload.associated_worktree_ref, Some(Some("fix/x".into())));
        let thread = thread.unwrap();
        assert_eq!(thread.title, "Renamed");
        assert_eq!(thread.settled_at, Some(iso(T0)));
        assert_eq!(thread.associated_worktree_branch.as_deref(), Some("fix/x"));
    }
}
