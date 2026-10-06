//! Ported from Synara `packages/contracts/src/orchestration.ts`: threads, messages, activities,
//! the client's thread commands and the thread events. Spaces, projects, sidechats, handoffs,
//! pull requests, Claude cache, computer control and goals are left out; each struct that has
//! fields from those families says which it omits.
//!
//! Synara's command and event structs each carry a `type` literal and are unioned. Here the
//! structs are without it and [`ClientThreadCommand`] and [`OrchestrationEventBody`] carry the tag,
//! so a bare struct such as [`ThreadTurnStartCommand`] does not write its own `type`. A field that
//! `Schema.optional(Schema.NullOr(T))` accepts as absent or `null` is `Option<Option<T>>` with
//! [`optional_nullable`]; one that decodes with a default is written with that default.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::base::{
    optional_nullable, ApprovalRequestId, CheckpointRef, CommandId, EventId, IsoDateTime, MessageId,
    ProjectId, ProviderDriverKind, ProviderInstanceId, ThreadId, TurnId,
};
use super::model::{ClaudeModelOptions, CodexModelOptions};
use super::provider::{ProviderMentionReference, ProviderSkillReference};

/// Synara `AsyncUserInputQuestion` (asyncUserInput.ts:6)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AsyncUserInputQuestion {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<String>>,
}

/// Synara `AsyncUserInputQuestions` (asyncUserInput.ts:10)
pub type AsyncUserInputQuestions = Vec<AsyncUserInputQuestion>;

/// Synara `AsyncUserInputResponse` (asyncUserInput.ts:15)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AsyncUserInputResponse {
    pub message_id: MessageId,
    pub answers: Vec<String>,
}

/// Synara `AsyncUserInput` (asyncUserInput.ts:21)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AsyncUserInput {
    pub questions: AsyncUserInputQuestions,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response: Option<AsyncUserInputResponse>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_sequence: Option<u64>,
}

/// Synara `ProviderKind` (orchestration.ts:76)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderKind {
    Codex,
    ClaudeAgent,
    Cursor,
    Antigravity,
    Grok,
    Droid,
    Opencode,
    Pi,
    Devin,
    Omp,
}

impl ProviderKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeAgent => "claudeAgent",
            Self::Cursor => "cursor",
            Self::Antigravity => "antigravity",
            Self::Grok => "grok",
            Self::Droid => "droid",
            Self::Opencode => "opencode",
            Self::Pi => "pi",
            Self::Devin => "devin",
            Self::Omp => "omp",
        }
    }
}

impl From<ProviderKind> for ProviderDriverKind {
    fn from(kind: ProviderKind) -> Self {
        ProviderDriverKind::new(kind.as_str())
    }
}

/// Synara `LEGACY_PROVIDER_MIGRATIONS` (orchestration.ts:96)
pub fn legacy_provider_migration(name: &str) -> Option<ProviderKind> {
    match name {
        "gemini" => Some(ProviderKind::Antigravity),
        "kilo" => Some(ProviderKind::Opencode),
        _ => None,
    }
}

/// Synara `ProviderApprovalPolicy` (orchestration.ts:116)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderApprovalPolicy {
    Untrusted,
    OnFailure,
    OnRequest,
    Never,
}

/// Synara `ProviderSandboxMode` (orchestration.ts:123)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderSandboxMode {
    ReadOnly,
    WorkspaceWrite,
    DangerFullAccess,
}

/// Synara `CodexModelSelection` (orchestration.ts:241), without its `provider` literal:
/// [`ModelSelection`] carries it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexModelSelection {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instance_id: Option<ProviderInstanceId>,
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<CodexModelOptions>,
}

/// Synara `ClaudeModelSelection` (orchestration.ts:249), without its `provider` literal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeModelSelection {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instance_id: Option<ProviderInstanceId>,
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<ClaudeModelOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supports_auto_mode: Option<bool>,
}

/// Synara `ModelSelection` (orchestration.ts:354), the Codex and Claude members. Synara's decoder
/// also infers a missing `provider` from `instanceId` or the model name; this one requires it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "provider")]
pub enum ModelSelection {
    #[serde(rename = "codex")]
    Codex(CodexModelSelection),
    #[serde(rename = "claudeAgent")]
    ClaudeAgent(ClaudeModelSelection),
}

/// Synara `CodexProviderStartOptions` (orchestration.ts:388)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProviderStartOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow_home_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<BTreeMap<String, String>>,
}

/// Synara `ClaudeProviderStartOptions` (orchestration.ts:396)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeProviderStartOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_thinking_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enable_artifacts: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<BTreeMap<String, String>>,
}

/// Synara `ProviderStartOptions` (orchestration.ts:450), Codex and Claude only.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStartOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex: Option<CodexProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_agent: Option<ClaudeProviderStartOptions>,
}

/// Synara `RuntimeMode` (orchestration.ts:464)
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeMode {
    ApprovalRequired,
    Auto,
    #[default]
    FullAccess,
}

/// Synara `DEFAULT_RUNTIME_MODE` (orchestration.ts:466)
pub const DEFAULT_RUNTIME_MODE: RuntimeMode = RuntimeMode::FullAccess;

/// Synara `ProviderInteractionMode` (orchestration.ts:467)
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderInteractionMode {
    #[default]
    Default,
    Plan,
    Debug,
}

/// Synara `DEFAULT_PROVIDER_INTERACTION_MODE` (orchestration.ts:469)
pub const DEFAULT_PROVIDER_INTERACTION_MODE: ProviderInteractionMode =
    ProviderInteractionMode::Default;

/// Synara `ProviderRequestKind` (orchestration.ts:495)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderRequestKind {
    Command,
    FileRead,
    FileChange,
    Permissions,
    Tool,
}

/// Synara `AssistantDeliveryMode` (orchestration.ts:503)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AssistantDeliveryMode {
    Buffered,
    Streaming,
}

/// Synara `TurnDispatchMode` (orchestration.ts:506): queue is the default send, steer an urgent redirect.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TurnDispatchMode {
    #[default]
    Queue,
    Steer,
}

/// Synara `DEFAULT_TURN_DISPATCH_MODE` (orchestration.ts:508)
pub const DEFAULT_TURN_DISPATCH_MODE: TurnDispatchMode = TurnDispatchMode::Queue;

/// Synara `MessageDispatchOrigin` (orchestration.ts:512)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageDispatchOrigin {
    User,
    Automation,
    Agent,
}

/// Synara `ThreadCreationSource` (orchestration.ts:517)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadCreationSource {
    SynaraMcp,
    ExternalMcp,
    ProviderNative,
    AutomationRun,
}

/// Synara `ProviderReviewTarget` (orchestration.ts:524)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ProviderReviewTarget {
    #[serde(rename = "uncommittedChanges")]
    UncommittedChanges,
    #[serde(rename = "baseBranch")]
    BaseBranch { branch: String },
}

/// Synara `ProviderApprovalDecision` (orchestration.ts:534)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderApprovalDecision {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

/// Synara `ProviderUserInputAnswer` (orchestration.ts:541): a string, a list of strings or `null`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProviderUserInputAnswer {
    Text(String),
    Many(Vec<String>),
    Null,
}

/// Synara `ProviderUserInputAnswers` (orchestration.ts:545)
pub type ProviderUserInputAnswers = BTreeMap<String, ProviderUserInputAnswer>;

/// Synara `ThreadEnvironmentMode` (orchestration.ts:549)
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadEnvironmentMode {
    #[default]
    Local,
    Worktree,
}

/// Synara `OrchestrationMessageSource` (orchestration.ts:552)
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OrchestrationMessageSource {
    #[default]
    Native,
    AsyncUserInput,
    HandoffImport,
    ForkImport,
}

/// Synara `PROVIDER_SEND_TURN_MAX_INPUT_CHARS` (orchestration.ts:560)
pub const PROVIDER_SEND_TURN_MAX_INPUT_CHARS: usize = 120_000;
/// Synara `PROVIDER_SEND_TURN_MAX_ATTACHMENTS` (orchestration.ts:561)
pub const PROVIDER_SEND_TURN_MAX_ATTACHMENTS: usize = 8;
/// Synara `PROVIDER_SEND_TURN_MAX_IMAGE_BYTES` (orchestration.ts:562)
pub const PROVIDER_SEND_TURN_MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;
/// Synara `PROVIDER_SEND_TURN_MAX_IMAGE_IMPORT_BYTES` (orchestration.ts:565)
pub const PROVIDER_SEND_TURN_MAX_IMAGE_IMPORT_BYTES: u64 = 32 * 1024 * 1024;
/// Synara `PROVIDER_SEND_TURN_MAX_FILE_BYTES` (orchestration.ts:566)
pub const PROVIDER_SEND_TURN_MAX_FILE_BYTES: u64 = 25 * 1024 * 1024;
/// Synara `CHAT_ASSISTANT_SELECTION_TEXT_MAX_CHARS` (orchestration.ts:569)
pub const CHAT_ASSISTANT_SELECTION_TEXT_MAX_CHARS: usize = 4_000;
/// Synara `THREAD_NOTES_MAX_CHARS` (orchestration.ts:570)
pub const THREAD_NOTES_MAX_CHARS: usize = 16_384;
/// Synara `PINNED_MESSAGES_MAX_COUNT` (orchestration.ts:577)
pub const PINNED_MESSAGES_MAX_COUNT: usize = 100;
/// Synara `PINNED_MESSAGE_LABEL_MAX_CHARS` (orchestration.ts:578)
pub const PINNED_MESSAGE_LABEL_MAX_CHARS: usize = 60;

/// Synara `CorrelationId` (orchestration.ts:580): the command id by design.
pub type CorrelationId = CommandId;

/// Synara `ChatAttachmentId` (orchestration.ts:583)
pub type ChatAttachmentId = String;

/// Synara `ChatImageAttachment` (orchestration.ts:589), without its `type` literal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatImageAttachment {
    pub id: ChatAttachmentId,
    pub name: String,
    pub mime_type: String,
    pub size_bytes: u64,
}

/// Synara `ChatFileAttachment` (orchestration.ts:598), without its `type` literal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatFileAttachment {
    pub id: ChatAttachmentId,
    pub name: String,
    pub mime_type: String,
    pub size_bytes: u64,
}

/// Synara `ChatAssistantSelectionAttachment` (orchestration.ts:607), without its `type` literal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatAssistantSelectionAttachment {
    pub id: ChatAttachmentId,
    pub assistant_message_id: MessageId,
    pub text: String,
}

/// Synara `UploadChatAssistantSelectionAttachment` (orchestration.ts:615), without its `type` literal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadChatAssistantSelectionAttachment {
    pub assistant_message_id: MessageId,
    pub text: String,
}

/// Synara `ChatAttachment` (orchestration.ts:623)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ChatAttachment {
    #[serde(rename = "image")]
    Image(ChatImageAttachment),
    #[serde(rename = "file")]
    File(ChatFileAttachment),
    #[serde(rename = "assistant-selection")]
    AssistantSelection(ChatAssistantSelectionAttachment),
}

/// Synara `UploadChatAttachment` (orchestration.ts:632)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum UploadChatAttachment {
    #[serde(rename = "image")]
    Image(ChatImageAttachment),
    #[serde(rename = "file")]
    File(ChatFileAttachment),
    #[serde(rename = "assistant-selection")]
    AssistantSelection(UploadChatAssistantSelectionAttachment),
}

/// Synara `OrchestrationMessageRole` (orchestration.ts:753)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationMessageRole {
    User,
    Assistant,
    System,
}

/// Synara `OrchestrationMessageTextSegment` (orchestration.ts:756)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationMessageTextSegment {
    /// Causal orchestration-event order; disambiguates equal timestamps.
    pub sequence: u64,
    pub started_at: IsoDateTime,
    pub ended_at: IsoDateTime,
    pub text: String,
}

/// Synara `OrchestrationMessage` (orchestration.ts:769)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationMessage {
    pub id: MessageId,
    pub role: OrchestrationMessageRole,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_segments: Option<Vec<OrchestrationMessageTextSegment>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub async_user_input: Option<AsyncUserInput>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<ChatAttachment>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<ProviderSkillReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Vec<ProviderMentionReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_mode: Option<TurnDispatchMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_origin: Option<MessageDispatchOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub starts_new_turn: Option<bool>,
    pub turn_id: Option<TurnId>,
    pub streaming: bool,
    #[serde(default)]
    pub source: OrchestrationMessageSource,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
}

/// Synara `OrchestrationProposedPlanId` (orchestration.ts:799)
pub type OrchestrationProposedPlanId = String;

/// Synara `OrchestrationProposedPlan` (orchestration.ts:802)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationProposedPlan {
    pub id: OrchestrationProposedPlanId,
    pub turn_id: Option<TurnId>,
    pub plan_markdown: String,
    #[serde(default)]
    pub implemented_at: Option<IsoDateTime>,
    #[serde(default)]
    pub implementation_thread_id: Option<ThreadId>,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
}

/// Synara `SourceProposedPlanReference` (orchestration.ts:813)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceProposedPlanReference {
    pub thread_id: ThreadId,
    pub plan_id: OrchestrationProposedPlanId,
}

/// Synara `OrchestrationSessionStatus` (orchestration.ts:818)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationSessionStatus {
    Idle,
    Starting,
    Running,
    Ready,
    Interrupted,
    Stopped,
    Error,
}

/// Synara `OrchestrationSession` (orchestration.ts:829)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationSession {
    pub thread_id: ThreadId,
    pub status: OrchestrationSessionStatus,
    pub provider_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_instance_id: Option<ProviderInstanceId>,
    #[serde(default)]
    pub runtime_mode: RuntimeMode,
    pub active_turn_id: Option<TurnId>,
    pub last_error: Option<String>,
    /// Last provider-runtime activity of any kind observed on the thread.
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_activity_at: Option<Option<IsoDateTime>>,
    /// Last activity that produced real work; a steer or nudge echo does not advance it.
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_progress_at: Option<Option<IsoDateTime>>,
    pub updated_at: IsoDateTime,
}

/// Synara `OrchestrationCheckpointFile` (orchestration.ts:848)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationCheckpointFile {
    pub path: String,
    pub kind: String,
    pub additions: u64,
    pub deletions: u64,
}

/// Synara `OrchestrationCheckpointStatus` (orchestration.ts:856)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationCheckpointStatus {
    Ready,
    Missing,
    Error,
}

/// Synara `OrchestrationCheckpointSummary` (orchestration.ts:859)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationCheckpointSummary {
    pub turn_id: TurnId,
    pub checkpoint_turn_count: u64,
    pub checkpoint_ref: CheckpointRef,
    pub status: OrchestrationCheckpointStatus,
    pub files: Vec<OrchestrationCheckpointFile>,
    pub assistant_message_id: Option<MessageId>,
    pub completed_at: IsoDateTime,
}

/// Synara `OrchestrationThreadActivityTone` (orchestration.ts:870)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationThreadActivityTone {
    Info,
    Tool,
    Approval,
    Error,
}

/// Synara `OrchestrationThreadActivity` (orchestration.ts:878)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationThreadActivity {
    pub id: EventId,
    pub tone: OrchestrationThreadActivityTone,
    pub kind: String,
    pub summary: String,
    pub payload: Value,
    pub turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<u64>,
    pub created_at: IsoDateTime,
}

/// Synara `OrchestrationLatestTurnState` (orchestration.ts:890)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationLatestTurnState {
    Running,
    Interrupted,
    Completed,
    Error,
}

/// Synara `OrchestrationLatestTurn` (orchestration.ts:898)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationLatestTurn {
    pub turn_id: TurnId,
    pub state: OrchestrationLatestTurnState,
    pub requested_at: IsoDateTime,
    pub started_at: Option<IsoDateTime>,
    pub completed_at: Option<IsoDateTime>,
    pub assistant_message_id: Option<MessageId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_proposed_plan: Option<SourceProposedPlanReference>,
}

/// Synara `ThreadNotes` (orchestration.ts:932)
pub type ThreadNotes = String;

/// Synara `PinnedMessageLabel` (orchestration.ts:973)
pub type PinnedMessageLabel = String;

/// Synara `PinnedMessage` (orchestration.ts:977): a message pinned to the chat's checklist.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinnedMessage {
    pub message_id: MessageId,
    #[serde(default)]
    pub label: Option<PinnedMessageLabel>,
    #[serde(default)]
    pub done: bool,
    pub pinned_at: IsoDateTime,
}

/// Synara `ThreadPinnedMessages` (orchestration.ts:986)
pub type ThreadPinnedMessages = Vec<PinnedMessage>;

/// Synara `ProjectionPendingInteractionKind` (orchestration.ts:991)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProjectionPendingInteractionKind {
    Approval,
    UserInput,
}

/// Synara `ProjectionPendingInteractionStatus` (orchestration.ts:994)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProjectionPendingInteractionStatus {
    Pending,
    Responding,
    Confirmed,
    Retryable,
    Uncertain,
}

/// Synara `ProjectionPendingInteractionDecision` (orchestration.ts:1003)
pub type ProjectionPendingInteractionDecision = Option<ProviderApprovalDecision>;

/// Synara `OrchestrationPendingInteraction` (orchestration.ts:1007): an unresolved provider
/// interaction settlement exposed to thread-detail consumers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationPendingInteraction {
    pub interaction_kind: ProjectionPendingInteractionKind,
    pub request_id: ApprovalRequestId,
    pub thread_id: ThreadId,
    pub turn_id: Option<TurnId>,
    pub lifecycle_generation: Option<String>,
    pub status: ProjectionPendingInteractionStatus,
    pub decision: ProjectionPendingInteractionDecision,
    pub response_command_id: Option<CommandId>,
    pub response_requested_at: Option<IsoDateTime>,
    pub created_at: IsoDateTime,
    pub resolved_at: Option<IsoDateTime>,
}

// Omitted: `claudeCacheReview`, `sidechatSourceThreadId`, `sidechatContext`,
// `sidechatLastActivityAt`, `sidechatExpiredAt`, `lastKnownPr`, `handoff`, `goal`,
// `goalStartedAt`, `goalPausedAt` and `goalAchievements`.
/// Synara `OrchestrationThread` (orchestration.ts:1037)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationThread {
    /// Durable project-import provenance; ordinary chats never request imported history.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_project_import: Option<bool>,
    pub id: ThreadId,
    pub project_id: ProjectId,
    pub title: String,
    pub model_selection: ModelSelection,
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default)]
    pub env_mode: ThreadEnvironmentMode,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    #[serde(default)]
    pub working_directory: Option<String>,
    #[serde(default)]
    pub associated_worktree_path: Option<String>,
    #[serde(default)]
    pub associated_worktree_branch: Option<String>,
    #[serde(default)]
    pub associated_worktree_ref: Option<String>,
    #[serde(default)]
    pub create_branch_flow_completed: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub parent_thread_id: Option<ThreadId>,
    #[serde(default)]
    pub creation_source: Option<ThreadCreationSource>,
    #[serde(default)]
    pub source_thread_id: Option<ThreadId>,
    #[serde(default)]
    pub source_turn_id: Option<TurnId>,
    #[serde(default)]
    pub gateway_operation_id: Option<String>,
    #[serde(default)]
    pub gateway_operation_index: Option<u64>,
    #[serde(default)]
    pub subagent_agent_id: Option<String>,
    #[serde(default)]
    pub subagent_nickname: Option<String>,
    #[serde(default)]
    pub subagent_role: Option<String>,
    #[serde(default)]
    pub fork_source_thread_id: Option<ThreadId>,
    pub latest_turn: Option<OrchestrationLatestTurn>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub latest_user_message_at: Option<Option<IsoDateTime>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub latest_human_message_at: Option<Option<IsoDateTime>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_pending_approvals: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_pending_user_input: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_actionable_proposed_plan: Option<bool>,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
    #[serde(default)]
    pub archived_at: Option<IsoDateTime>,
    #[serde(default)]
    pub settled_at: Option<IsoDateTime>,
    #[serde(default)]
    pub snoozed_until: Option<IsoDateTime>,
    #[serde(default)]
    pub snooze_reminder_at: Option<IsoDateTime>,
    pub deleted_at: Option<IsoDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_messages: Option<ThreadPinnedMessages>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<ThreadNotes>,
    pub messages: Vec<OrchestrationMessage>,
    #[serde(default)]
    pub proposed_plans: Vec<OrchestrationProposedPlan>,
    pub activities: Vec<OrchestrationThreadActivity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_interactions: Option<Vec<OrchestrationPendingInteraction>>,
    pub checkpoints: Vec<OrchestrationCheckpointSummary>,
    pub session: Option<OrchestrationSession>,
}

// Omitted: the same families as `OrchestrationThread`.
/// Synara `OrchestrationThreadShell` (orchestration.ts:1139)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationThreadShell {
    /// Durable project-import provenance; ordinary chats never request imported history.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_project_import: Option<bool>,
    pub id: ThreadId,
    pub project_id: ProjectId,
    pub title: String,
    pub model_selection: ModelSelection,
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default)]
    pub env_mode: ThreadEnvironmentMode,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    #[serde(default)]
    pub working_directory: Option<String>,
    #[serde(default)]
    pub associated_worktree_path: Option<String>,
    #[serde(default)]
    pub associated_worktree_branch: Option<String>,
    #[serde(default)]
    pub associated_worktree_ref: Option<String>,
    #[serde(default)]
    pub create_branch_flow_completed: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub parent_thread_id: Option<ThreadId>,
    #[serde(default)]
    pub creation_source: Option<ThreadCreationSource>,
    #[serde(default)]
    pub source_thread_id: Option<ThreadId>,
    #[serde(default)]
    pub source_turn_id: Option<TurnId>,
    #[serde(default)]
    pub gateway_operation_id: Option<String>,
    #[serde(default)]
    pub gateway_operation_index: Option<u64>,
    #[serde(default)]
    pub subagent_agent_id: Option<String>,
    #[serde(default)]
    pub subagent_nickname: Option<String>,
    #[serde(default)]
    pub subagent_role: Option<String>,
    #[serde(default)]
    pub fork_source_thread_id: Option<ThreadId>,
    pub latest_turn: Option<OrchestrationLatestTurn>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub latest_user_message_at: Option<Option<IsoDateTime>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub latest_human_message_at: Option<Option<IsoDateTime>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_pending_approvals: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_pending_user_input: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_actionable_proposed_plan: Option<bool>,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
    #[serde(default)]
    pub archived_at: Option<IsoDateTime>,
    #[serde(default)]
    pub settled_at: Option<IsoDateTime>,
    #[serde(default)]
    pub snoozed_until: Option<IsoDateTime>,
    #[serde(default)]
    pub snooze_reminder_at: Option<IsoDateTime>,
    pub session: Option<OrchestrationSession>,
}

// Omitted: `lastKnownPr`, `sidechatContext`, a computer-control mode.
/// Synara `ThreadCreateCommand` (orchestration.ts:1390)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadCreateCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub project_id: ProjectId,
    pub title: String,
    pub model_selection: ModelSelection,
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default)]
    pub env_mode: ThreadEnvironmentMode,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub working_directory: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_path: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_branch: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_ref: Option<Option<String>>,
    #[serde(default)]
    pub create_branch_flow_completed: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub parent_thread_id: Option<ThreadId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creation_source: Option<ThreadCreationSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_thread_id: Option<ThreadId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gateway_operation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gateway_operation_index: Option<u64>,
    #[serde(default)]
    pub subagent_agent_id: Option<String>,
    #[serde(default)]
    pub subagent_nickname: Option<String>,
    #[serde(default)]
    pub subagent_role: Option<String>,
    /// Cascade, not Synara: what the new chat starts knowing (`ThreadKnowledgeSource`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub knowledge_source: Option<ThreadKnowledgeSource>,
    pub created_at: IsoDateTime,
}

/// Cascade, not Synara: a new chat that starts with what another agent conversation knows (a
/// terminal session's agent), without showing that conversation's messages. Its first session
/// forks `conversation_id` natively when it runs the same provider (Claude `--resume
/// --fork-session`, Codex `thread/fork`); on another provider its first turn carries `recap` as
/// hidden context, as Synara bootstraps a provider handoff. Either way it is used once: when the
/// chat's own first session binds (`fork_bindings`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadKnowledgeSource {
    /// The provider whose conversation it is.
    pub provider: ProviderKind,
    /// That provider's conversation id: a Claude session id, a Codex thread id.
    pub conversation_id: String,
    /// The model the conversation last ran, for the divider; unknown when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The conversation's transcript as text, for a chat on another provider.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recap: Option<String>,
}

impl ThreadKnowledgeSource {
    /// The conversation as both providers' resume cursors read it: Claude's `resume`, Codex's
    /// `threadId`.
    pub fn resume_cursor(&self) -> serde_json::Value {
        serde_json::json!({ "threadId": self.conversation_id, "resume": self.conversation_id })
    }
}

/// Synara `ThreadHandoffImportedMessage` (orchestration.ts:1437): what a fork imports.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadHandoffImportedMessage {
    pub message_id: MessageId,
    pub role: ThreadHandoffImportedMessageRole,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<ChatAttachment>>,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
}

/// The `role` literals of [`ThreadHandoffImportedMessage`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadHandoffImportedMessageRole {
    User,
    Assistant,
}

// Omitted: `sidechatSourceThreadId`.
/// Synara `ThreadForkCreateCommand` (orchestration.ts:1473)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadForkCreateCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub source_thread_id: ThreadId,
    pub project_id: ProjectId,
    pub title: String,
    pub model_selection: ModelSelection,
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default)]
    pub env_mode: ThreadEnvironmentMode,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub working_directory: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_path: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_branch: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_ref: Option<Option<String>>,
    #[serde(default)]
    pub create_branch_flow_completed: bool,
    pub imported_messages: Vec<ThreadHandoffImportedMessage>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadDeleteCommand` (orchestration.ts:1500)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadDeleteCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
}

/// Synara `ThreadArchiveCommand` (orchestration.ts:1506)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadArchiveCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
}

/// Synara `ThreadUnarchiveCommand` (orchestration.ts:1512)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUnarchiveCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
}

// Omitted: `handoff`, `lastKnownPr`, `goal`, `goalStartBehavior`, `goalPaused`, `goalAchieved`
// and `providerHandoff`.
/// Synara `ThreadMetaUpdateCommand` (orchestration.ts:1518)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMetaUpdateCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Apply the title only while no newer durable title event exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_title_sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env_mode: Option<ThreadEnvironmentMode>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub branch: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub worktree_path: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub working_directory: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_path: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_branch: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_ref: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_branch_flow_completed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_pinned: Option<bool>,
    /// Desired settled state; the decider stamps the authoritative `settledAt`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_settled: Option<bool>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub snoozed_until: Option<Option<IsoDateTime>>,
    /// A matching due deadline authorizes the server to deliver the reminder.
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub expected_snoozed_until: Option<Option<IsoDateTime>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_thread_id: Option<Option<ThreadId>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub subagent_agent_id: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub subagent_nickname: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub subagent_role: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_messages: Option<ThreadPinnedMessages>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<ThreadNotes>,
}

/// Synara `ThreadPinnedMessageAddCommand` (orchestration.ts:1560)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageAddCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
}

/// Synara `ThreadPinnedMessageRemoveCommand` (orchestration.ts:1567)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageRemoveCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
}

/// Synara `ThreadPinnedMessageDoneSetCommand` (orchestration.ts:1574)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageDoneSetCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub done: bool,
}

/// Synara `ThreadPinnedMessageLabelSetCommand` (orchestration.ts:1582)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageLabelSetCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub label: Option<PinnedMessageLabel>,
}

/// Synara `ThreadRuntimeModeSetCommand` (orchestration.ts:1590)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRuntimeModeSetCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub runtime_mode: RuntimeMode,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadInteractionModeSetCommand` (orchestration.ts:1598)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInteractionModeSetCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub interaction_mode: ProviderInteractionMode,
    pub created_at: IsoDateTime,
}

/// The `role` literal of the message in a turn start: only a user sends one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TurnStartMessageRole {
    #[serde(rename = "user")]
    User,
}

/// The `message` of Synara `ThreadTurnStartCommand` (orchestration.ts:1614). Synara also checks
/// that it carries text or attachments (`TurnMessageContentCheck`); callers check it here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnStartMessage {
    pub message_id: MessageId,
    pub role: TurnStartMessageRole,
    pub text: String,
    pub attachments: Vec<ChatAttachment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<ProviderSkillReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Vec<ProviderMentionReference>>,
}

/// The `resumePrecondition` of Synara `ThreadTurnStartCommand` (orchestration.ts:1644)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnResumePrecondition {
    /// Turn in flight when the chat was recorded; null while the provider was still connecting.
    pub recorded_turn_id: Option<TurnId>,
    pub recorded_at: IsoDateTime,
}

// Omitted: `enableComputerControl`, `computerControlMode`, `computerControlGeneration`.
/// Synara `ThreadTurnStartCommand` (orchestration.ts:1609): the server's form, with
/// `dispatchOrigin` and `resumePrecondition` that a client cannot set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnStartCommand {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub async_user_input_response: Option<AsyncUserInputResponse>,
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message: ThreadTurnStartMessage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_target: Option<ProviderReviewTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_delivery_mode: Option<AssistantDeliveryMode>,
    #[serde(default)]
    pub dispatch_mode: TurnDispatchMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_origin: Option<MessageDispatchOrigin>,
    #[serde(default)]
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_proposed_plan: Option<SourceProposedPlanReference>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_precondition: Option<ThreadTurnResumePrecondition>,
    pub created_at: IsoDateTime,
}

/// The `message` of Synara `ClientThreadTurnStartCommand` (orchestration.ts:1659): its
/// attachments are uploads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientThreadTurnStartMessage {
    pub message_id: MessageId,
    pub role: TurnStartMessageRole,
    pub text: String,
    pub attachments: Vec<UploadChatAttachment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<ProviderSkillReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Vec<ProviderMentionReference>>,
}

// Omitted: `enableComputerControl`, `computerControlMode`, `computerControlGeneration`.
/// Synara `ClientThreadTurnStartCommand` (orchestration.ts:1654)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientThreadTurnStartCommand {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub async_user_input_response: Option<AsyncUserInputResponse>,
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message: ClientThreadTurnStartMessage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_target: Option<ProviderReviewTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_delivery_mode: Option<AssistantDeliveryMode>,
    #[serde(default)]
    pub dispatch_mode: TurnDispatchMode,
    pub runtime_mode: RuntimeMode,
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_proposed_plan: Option<SourceProposedPlanReference>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTurnInterruptCommand` (orchestration.ts:1714)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnInterruptCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTaskStopCommand` (orchestration.ts:1722)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTaskStopCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub task_id: String,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTaskBackgroundCommand` (orchestration.ts:1730)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTaskBackgroundCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub tool_use_id: String,
    pub created_at: IsoDateTime,
}

// Omitted: `enableComputerControl`, `computerControlMode`, `computerControlGeneration`.
/// Synara `ThreadDispatchQueuedTurnCommand` (orchestration.ts:1738)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadDispatchQueuedTurnCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_target: Option<ProviderReviewTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_delivery_mode: Option<AssistantDeliveryMode>,
    #[serde(default)]
    pub dispatch_mode: TurnDispatchMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_origin: Option<MessageDispatchOrigin>,
    #[serde(default)]
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_proposed_plan: Option<SourceProposedPlanReference>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadApprovalRespondCommand` (orchestration.ts:1762)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadApprovalRespondCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub request_id: ApprovalRequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    pub decision: ProviderApprovalDecision,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadUserInputRespondCommand` (orchestration.ts:1772)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUserInputRespondCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub request_id: ApprovalRequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    pub answers: ProviderUserInputAnswers,
    pub created_at: IsoDateTime,
}

/// The `scope` literals of a checkpoint revert (orchestration.ts:1787)
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadCheckpointRevertScope {
    #[default]
    Thread,
    Files,
}

/// Synara `ThreadCheckpointRevertCommand` (orchestration.ts:1782)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadCheckpointRevertCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub turn_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<ThreadCheckpointRevertScope>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadConversationRollbackCommand` (orchestration.ts:1791)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadConversationRollbackCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub num_turns: u64,
    pub created_at: IsoDateTime,
}

// Omitted: `enableComputerControl`, `computerControlMode`, `computerControlGeneration`.
/// Synara `ThreadMessageEditAndResendCommand` (orchestration.ts:1800)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageEditAndResendCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_delivery_mode: Option<AssistantDeliveryMode>,
    pub runtime_mode: RuntimeMode,
    pub interaction_mode: ProviderInteractionMode,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadSessionStopCommand` (orchestration.ts:1817)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSessionStopCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadActivityAppendCommand` (orchestration.ts:1824)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadActivityAppendCommand {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub require_unarchived: Option<bool>,
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub activity: OrchestrationThreadActivity,
    pub created_at: IsoDateTime,
}

/// Synara `ClientOrchestrationCommand` (orchestration.ts:1870), the thread commands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ClientThreadCommand {
    #[serde(rename = "thread.create")]
    Create(ThreadCreateCommand),
    #[serde(rename = "thread.fork.create")]
    ForkCreate(ThreadForkCreateCommand),
    #[serde(rename = "thread.delete")]
    Delete(ThreadDeleteCommand),
    #[serde(rename = "thread.archive")]
    Archive(ThreadArchiveCommand),
    #[serde(rename = "thread.unarchive")]
    Unarchive(ThreadUnarchiveCommand),
    #[serde(rename = "thread.meta.update")]
    MetaUpdate(ThreadMetaUpdateCommand),
    #[serde(rename = "thread.pinned-message.add")]
    PinnedMessageAdd(ThreadPinnedMessageAddCommand),
    #[serde(rename = "thread.pinned-message.remove")]
    PinnedMessageRemove(ThreadPinnedMessageRemoveCommand),
    #[serde(rename = "thread.pinned-message.done.set")]
    PinnedMessageDoneSet(ThreadPinnedMessageDoneSetCommand),
    #[serde(rename = "thread.pinned-message.label.set")]
    PinnedMessageLabelSet(ThreadPinnedMessageLabelSetCommand),
    #[serde(rename = "thread.runtime-mode.set")]
    RuntimeModeSet(ThreadRuntimeModeSetCommand),
    #[serde(rename = "thread.interaction-mode.set")]
    InteractionModeSet(ThreadInteractionModeSetCommand),
    #[serde(rename = "thread.turn.start")]
    TurnStart(ClientThreadTurnStartCommand),
    #[serde(rename = "thread.turn.interrupt")]
    TurnInterrupt(ThreadTurnInterruptCommand),
    #[serde(rename = "thread.task.stop")]
    TaskStop(ThreadTaskStopCommand),
    #[serde(rename = "thread.task.background")]
    TaskBackground(ThreadTaskBackgroundCommand),
    #[serde(rename = "thread.turn.dispatch-queued")]
    TurnDispatchQueued(ThreadDispatchQueuedTurnCommand),
    #[serde(rename = "thread.approval.respond")]
    ApprovalRespond(ThreadApprovalRespondCommand),
    #[serde(rename = "thread.user-input.respond")]
    UserInputRespond(ThreadUserInputRespondCommand),
    #[serde(rename = "thread.checkpoint.revert")]
    CheckpointRevert(ThreadCheckpointRevertCommand),
    #[serde(rename = "thread.conversation.rollback")]
    ConversationRollback(ThreadConversationRollbackCommand),
    #[serde(rename = "thread.message.edit-and-resend")]
    MessageEditAndResend(ThreadMessageEditAndResendCommand),
    #[serde(rename = "thread.activity.append")]
    ActivityAppend(ThreadActivityAppendCommand),
    #[serde(rename = "thread.session.stop")]
    SessionStop(ThreadSessionStopCommand),
}

/// Synara `OrchestrationEventType` (orchestration.ts:2063), the thread events.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum OrchestrationEventType {
    #[serde(rename = "thread.created")]
    ThreadCreated,
    #[serde(rename = "thread.deleted")]
    ThreadDeleted,
    #[serde(rename = "thread.archived")]
    ThreadArchived,
    #[serde(rename = "thread.unarchived")]
    ThreadUnarchived,
    #[serde(rename = "thread.meta-updated")]
    ThreadMetaUpdated,
    #[serde(rename = "thread.pinned-message-added")]
    ThreadPinnedMessageAdded,
    #[serde(rename = "thread.pinned-message-removed")]
    ThreadPinnedMessageRemoved,
    #[serde(rename = "thread.pinned-message-done-set")]
    ThreadPinnedMessageDoneSet,
    #[serde(rename = "thread.pinned-message-label-set")]
    ThreadPinnedMessageLabelSet,
    #[serde(rename = "thread.runtime-mode-set")]
    ThreadRuntimeModeSet,
    #[serde(rename = "thread.interaction-mode-set")]
    ThreadInteractionModeSet,
    #[serde(rename = "thread.message-sent")]
    ThreadMessageSent,
    #[serde(rename = "thread.async-user-input-answered")]
    ThreadAsyncUserInputAnswered,
    #[serde(rename = "thread.turn-queued")]
    ThreadTurnQueued,
    #[serde(rename = "thread.turn-start-requested")]
    ThreadTurnStartRequested,
    #[serde(rename = "thread.turn-interrupt-requested")]
    ThreadTurnInterruptRequested,
    #[serde(rename = "thread.task-stop-requested")]
    ThreadTaskStopRequested,
    #[serde(rename = "thread.task-background-requested")]
    ThreadTaskBackgroundRequested,
    #[serde(rename = "thread.approval-response-requested")]
    ThreadApprovalResponseRequested,
    #[serde(rename = "thread.user-input-response-requested")]
    ThreadUserInputResponseRequested,
    #[serde(rename = "thread.checkpoint-revert-requested")]
    ThreadCheckpointRevertRequested,
    #[serde(rename = "thread.reverted")]
    ThreadReverted,
    #[serde(rename = "thread.conversation-rollback-requested")]
    ThreadConversationRollbackRequested,
    #[serde(rename = "thread.conversation-rolled-back")]
    ThreadConversationRolledBack,
    #[serde(rename = "thread.message-edit-resend-requested")]
    ThreadMessageEditResendRequested,
    #[serde(rename = "thread.session-stop-requested")]
    ThreadSessionStopRequested,
    #[serde(rename = "thread.session-set")]
    ThreadSessionSet,
    #[serde(rename = "thread.proposed-plan-upserted")]
    ThreadProposedPlanUpserted,
    #[serde(rename = "thread.turn-diff-completed")]
    ThreadTurnDiffCompleted,
    #[serde(rename = "thread.activity-appended")]
    ThreadActivityAppended,
}

/// Synara `OrchestrationAggregateKind` (orchestration.ts:2110). Only `thread` is written here.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationAggregateKind {
    Space,
    Project,
    Thread,
}

/// Synara `OrchestrationActorKind` (orchestration.ts:2112)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrchestrationActorKind {
    Client,
    Server,
    Provider,
}

// Omitted: `sidechatSourceThreadId`, `sidechatContext`, `sidechatLastActivityAt`,
// `sidechatExpiredAt`, `lastKnownPr` and `handoff`.
/// Synara `ThreadCreatedPayload` (orchestration.ts:2171)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadCreatedPayload {
    pub thread_id: ThreadId,
    pub project_id: ProjectId,
    pub title: String,
    pub model_selection: ModelSelection,
    #[serde(default)]
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default)]
    pub env_mode: ThreadEnvironmentMode,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    #[serde(default)]
    pub working_directory: Option<String>,
    #[serde(default)]
    pub associated_worktree_path: Option<String>,
    #[serde(default)]
    pub associated_worktree_branch: Option<String>,
    #[serde(default)]
    pub associated_worktree_ref: Option<String>,
    #[serde(default)]
    pub create_branch_flow_completed: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub parent_thread_id: Option<ThreadId>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub creation_source: Option<Option<ThreadCreationSource>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub source_thread_id: Option<Option<ThreadId>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub source_turn_id: Option<Option<TurnId>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub gateway_operation_id: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub gateway_operation_index: Option<Option<u64>>,
    #[serde(default)]
    pub subagent_agent_id: Option<String>,
    #[serde(default)]
    pub subagent_nickname: Option<String>,
    #[serde(default)]
    pub subagent_role: Option<String>,
    #[serde(default)]
    pub fork_source_thread_id: Option<ThreadId>,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadDeletedPayload` (orchestration.ts:2231)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadDeletedPayload {
    pub thread_id: ThreadId,
    pub deleted_at: IsoDateTime,
}

/// Synara `ThreadArchivedPayload` (orchestration.ts:2247)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadArchivedPayload {
    pub thread_id: ThreadId,
    /// Required for new events, optional for legacy events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<IsoDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<IsoDateTime>,
}

/// Synara `ThreadUnarchivedPayload` (orchestration.ts:2254)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUnarchivedPayload {
    pub thread_id: ThreadId,
    /// Legacy field, kept for old events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unarchived_at: Option<IsoDateTime>,
    /// Required for new events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<IsoDateTime>,
}

// Omitted: `handoff`, `lastKnownPr`, `goal`, `goalStartBehavior`, `goalStartedAt`,
// `goalPausedAt`, `goalAchievements` and `providerHandoff`.
/// Synara `ThreadMetaUpdatedPayload` (orchestration.ts:2267)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMetaUpdatedPayload {
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env_mode: Option<ThreadEnvironmentMode>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub branch: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub worktree_path: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub working_directory: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_path: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_branch: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub associated_worktree_ref: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_branch_flow_completed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_pinned: Option<bool>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub settled_at: Option<Option<IsoDateTime>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub snoozed_until: Option<Option<IsoDateTime>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub snooze_reminder_at: Option<Option<IsoDateTime>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_thread_id: Option<Option<ThreadId>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub subagent_agent_id: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub subagent_nickname: Option<Option<String>>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub subagent_role: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_messages: Option<ThreadPinnedMessages>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<ThreadNotes>,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadPinnedMessageAddedPayload` (orchestration.ts:2300)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageAddedPayload {
    pub thread_id: ThreadId,
    pub pin: PinnedMessage,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadPinnedMessageRemovedPayload` (orchestration.ts:2306)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageRemovedPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadPinnedMessageDoneSetPayload` (orchestration.ts:2312)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageDoneSetPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub done: bool,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadPinnedMessageLabelSetPayload` (orchestration.ts:2319)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPinnedMessageLabelSetPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub label: Option<PinnedMessageLabel>,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadRuntimeModeSetPayload` (orchestration.ts:2326)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRuntimeModeSetPayload {
    pub thread_id: ThreadId,
    pub runtime_mode: RuntimeMode,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadInteractionModeSetPayload` (orchestration.ts:2332)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInteractionModeSetPayload {
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_interaction_mode: Option<ProviderInteractionMode>,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadMessageSentPayload` (orchestration.ts:2341)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageSentPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub async_user_input: Option<AsyncUserInput>,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub role: OrchestrationMessageRole,
    pub text: String,
    /// Set on the first delta of a new text segment (after a row-making event).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub segment_started_at: Option<IsoDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub segment_sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<ChatAttachment>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<ProviderSkillReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Vec<ProviderMentionReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_mode: Option<TurnDispatchMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_origin: Option<MessageDispatchOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub starts_new_turn: Option<bool>,
    pub turn_id: Option<TurnId>,
    pub streaming: bool,
    #[serde(default)]
    pub source: OrchestrationMessageSource,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadAsyncUserInputAnsweredPayload` (orchestration.ts:2365)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadAsyncUserInputAnsweredPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub response: AsyncUserInputResponse,
}

// Omitted: `enableComputerControl`, `computerControlMode`, `computerControlGeneration`.
/// Synara `ThreadTurnStartRequestedPayload` (orchestration.ts:2383)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnStartRequestedPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_target: Option<ProviderReviewTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_delivery_mode: Option<AssistantDeliveryMode>,
    #[serde(default)]
    pub dispatch_mode: TurnDispatchMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_origin: Option<MessageDispatchOrigin>,
    #[serde(default)]
    pub runtime_mode: RuntimeMode,
    #[serde(default)]
    pub interaction_mode: ProviderInteractionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_proposed_plan: Option<SourceProposedPlanReference>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTurnQueuedPayload` (orchestration.ts:2403)
pub type ThreadTurnQueuedPayload = ThreadTurnStartRequestedPayload;

/// Synara `ThreadTurnInterruptRequestedPayload` (orchestration.ts:2413)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnInterruptRequestedPayload {
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTaskStopRequestedPayload` (orchestration.ts:2419)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTaskStopRequestedPayload {
    pub thread_id: ThreadId,
    pub task_id: String,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTaskBackgroundRequestedPayload` (orchestration.ts:2425)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTaskBackgroundRequestedPayload {
    pub thread_id: ThreadId,
    pub tool_use_id: String,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadApprovalResponseRequestedPayload` (orchestration.ts:2431)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadApprovalResponseRequestedPayload {
    pub thread_id: ThreadId,
    pub request_id: ApprovalRequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    pub decision: ProviderApprovalDecision,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadUserInputResponseRequestedPayload` (orchestration.ts:2439)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUserInputResponseRequestedPayload {
    pub thread_id: ThreadId,
    pub request_id: ApprovalRequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    pub answers: ProviderUserInputAnswers,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadCheckpointRevertRequestedPayload` (orchestration.ts:2447)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadCheckpointRevertRequestedPayload {
    pub thread_id: ThreadId,
    pub turn_count: u64,
    #[serde(default)]
    pub scope: ThreadCheckpointRevertScope,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadRevertedPayload` (orchestration.ts:2456)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRevertedPayload {
    pub thread_id: ThreadId,
    pub turn_count: u64,
}

/// Synara `ThreadConversationRollbackRequestedPayload` (orchestration.ts:2461)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadConversationRollbackRequestedPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub num_turns: u64,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadConversationRolledBackPayload` (orchestration.ts:2468)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadConversationRolledBackPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub num_turns: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed_turn_ids: Option<Vec<TurnId>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skip_attachment_prune: Option<bool>,
}

// Omitted: `enableComputerControl`, `computerControlMode`, `computerControlGeneration`.
/// Synara `ThreadMessageEditResendRequestedPayload` (orchestration.ts:2476)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageEditResendRequestedPayload {
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rollback_turn_count: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed_turn_ids: Option<Vec<TurnId>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_delivery_mode: Option<AssistantDeliveryMode>,
    pub runtime_mode: RuntimeMode,
    pub interaction_mode: ProviderInteractionMode,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadSessionStopRequestedPayload` (orchestration.ts:2493)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSessionStopRequestedPayload {
    pub thread_id: ThreadId,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadSessionSetPayload` (orchestration.ts:2498)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSessionSetPayload {
    pub thread_id: ThreadId,
    pub session: OrchestrationSession,
}

/// Synara `ThreadProposedPlanUpsertedPayload` (orchestration.ts:2503)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadProposedPlanUpsertedPayload {
    pub thread_id: ThreadId,
    pub proposed_plan: OrchestrationProposedPlan,
}

/// Synara `ThreadTurnDiffCompletedPayload` (orchestration.ts:2508)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnDiffCompletedPayload {
    pub thread_id: ThreadId,
    pub turn_id: TurnId,
    pub checkpoint_turn_count: u64,
    pub checkpoint_ref: CheckpointRef,
    pub status: OrchestrationCheckpointStatus,
    pub files: Vec<OrchestrationCheckpointFile>,
    pub assistant_message_id: Option<MessageId>,
    pub completed_at: IsoDateTime,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preserve_latest_turn: Option<bool>,
}

/// Synara `ThreadActivityAppendedPayload` (orchestration.ts:2520)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadActivityAppendedPayload {
    pub thread_id: ThreadId,
    pub activity: OrchestrationThreadActivity,
}

/// Synara `OrchestrationEventMetadata` (orchestration.ts:2525)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationEventMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_item_id: Option<super::base::ProviderItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adapter_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<ApprovalRequestId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ingested_at: Option<IsoDateTime>,
}

/// Synara `EventBaseFields` (orchestration.ts:2534) with the event's `type` and `payload`
/// flattened in as [`OrchestrationEventBody`]: Synara's `OrchestrationEvent`
/// (orchestration.ts:2546) is this type. `aggregateId` is a space, project or thread id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationEvent {
    pub sequence: u64,
    pub event_id: EventId,
    pub aggregate_kind: OrchestrationAggregateKind,
    pub aggregate_id: String,
    pub occurred_at: IsoDateTime,
    pub command_id: Option<CommandId>,
    pub causation_event_id: Option<EventId>,
    pub correlation_id: Option<CommandId>,
    pub metadata: OrchestrationEventMetadata,
    #[serde(flatten)]
    pub body: OrchestrationEventBody,
}

/// The `type` and `payload` of Synara's `OrchestrationEvent` union (orchestration.ts:2546), the
/// thread events, in the union's order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum OrchestrationEventBody {
    #[serde(rename = "thread.created")]
    ThreadCreated(ThreadCreatedPayload),
    #[serde(rename = "thread.deleted")]
    ThreadDeleted(ThreadDeletedPayload),
    #[serde(rename = "thread.archived")]
    ThreadArchived(ThreadArchivedPayload),
    #[serde(rename = "thread.unarchived")]
    ThreadUnarchived(ThreadUnarchivedPayload),
    #[serde(rename = "thread.meta-updated")]
    ThreadMetaUpdated(ThreadMetaUpdatedPayload),
    #[serde(rename = "thread.pinned-message-added")]
    ThreadPinnedMessageAdded(ThreadPinnedMessageAddedPayload),
    #[serde(rename = "thread.pinned-message-removed")]
    ThreadPinnedMessageRemoved(ThreadPinnedMessageRemovedPayload),
    #[serde(rename = "thread.pinned-message-done-set")]
    ThreadPinnedMessageDoneSet(ThreadPinnedMessageDoneSetPayload),
    #[serde(rename = "thread.pinned-message-label-set")]
    ThreadPinnedMessageLabelSet(ThreadPinnedMessageLabelSetPayload),
    #[serde(rename = "thread.runtime-mode-set")]
    ThreadRuntimeModeSet(ThreadRuntimeModeSetPayload),
    #[serde(rename = "thread.interaction-mode-set")]
    ThreadInteractionModeSet(ThreadInteractionModeSetPayload),
    #[serde(rename = "thread.message-sent")]
    ThreadMessageSent(ThreadMessageSentPayload),
    #[serde(rename = "thread.async-user-input-answered")]
    ThreadAsyncUserInputAnswered(ThreadAsyncUserInputAnsweredPayload),
    #[serde(rename = "thread.turn-queued")]
    ThreadTurnQueued(ThreadTurnQueuedPayload),
    #[serde(rename = "thread.turn-start-requested")]
    ThreadTurnStartRequested(ThreadTurnStartRequestedPayload),
    #[serde(rename = "thread.turn-interrupt-requested")]
    ThreadTurnInterruptRequested(ThreadTurnInterruptRequestedPayload),
    #[serde(rename = "thread.task-stop-requested")]
    ThreadTaskStopRequested(ThreadTaskStopRequestedPayload),
    #[serde(rename = "thread.task-background-requested")]
    ThreadTaskBackgroundRequested(ThreadTaskBackgroundRequestedPayload),
    #[serde(rename = "thread.approval-response-requested")]
    ThreadApprovalResponseRequested(ThreadApprovalResponseRequestedPayload),
    #[serde(rename = "thread.user-input-response-requested")]
    ThreadUserInputResponseRequested(ThreadUserInputResponseRequestedPayload),
    #[serde(rename = "thread.checkpoint-revert-requested")]
    ThreadCheckpointRevertRequested(ThreadCheckpointRevertRequestedPayload),
    #[serde(rename = "thread.reverted")]
    ThreadReverted(ThreadRevertedPayload),
    #[serde(rename = "thread.conversation-rollback-requested")]
    ThreadConversationRollbackRequested(ThreadConversationRollbackRequestedPayload),
    #[serde(rename = "thread.conversation-rolled-back")]
    ThreadConversationRolledBack(ThreadConversationRolledBackPayload),
    #[serde(rename = "thread.message-edit-resend-requested")]
    ThreadMessageEditResendRequested(ThreadMessageEditResendRequestedPayload),
    #[serde(rename = "thread.session-stop-requested")]
    ThreadSessionStopRequested(ThreadSessionStopRequestedPayload),
    #[serde(rename = "thread.session-set")]
    ThreadSessionSet(ThreadSessionSetPayload),
    #[serde(rename = "thread.proposed-plan-upserted")]
    ThreadProposedPlanUpserted(ThreadProposedPlanUpsertedPayload),
    #[serde(rename = "thread.turn-diff-completed")]
    ThreadTurnDiffCompleted(ThreadTurnDiffCompletedPayload),
    #[serde(rename = "thread.activity-appended")]
    ThreadActivityAppended(ThreadActivityAppendedPayload),
}

/// Synara `ThreadSessionSetCommand` (orchestration.ts:1904)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSessionSetCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub session: OrchestrationSession,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_session_status: Option<OrchestrationSessionStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_session_updated_at: Option<IsoDateTime>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadMessagesImportCommand` (orchestration.ts:1924)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessagesImportCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub messages: Vec<ThreadHandoffImportedMessage>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadMessageAssistantDeltaCommand` (orchestration.ts:1932)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageAssistantDeltaCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub delta: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    /// Present only when this delta starts a new text segment: a row-making provider event
    /// intervened since the previous assistant delta.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub segment_started_at: Option<IsoDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub segment_sequence: Option<u64>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadMessageAssistantCompleteCommand` (orchestration.ts:1947)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageAssistantCompleteCommand {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub async_questions: Option<AsyncUserInputQuestions>,
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadMessageUserBindTurnCommand` (orchestration.ts:1957)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageUserBindTurnCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub turn_id: TurnId,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadMessageUserSetTurnBoundaryCommand` (orchestration.ts:1966)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessageUserSetTurnBoundaryCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub starts_new_turn: bool,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadProposedPlanUpsertCommand` (orchestration.ts:1975)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadProposedPlanUpsertCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub proposed_plan: OrchestrationProposedPlan,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadTurnDiffCompleteCommand` (orchestration.ts:1983)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnDiffCompleteCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub turn_id: TurnId,
    pub completed_at: IsoDateTime,
    pub checkpoint_ref: CheckpointRef,
    pub status: OrchestrationCheckpointStatus,
    pub files: Vec<OrchestrationCheckpointFile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_message_id: Option<MessageId>,
    pub checkpoint_turn_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preserve_latest_turn: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint_revert_turn_count: Option<u64>,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadRevertCompleteCommand` (orchestration.ts:1999)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRevertCompleteCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub turn_count: u64,
    pub created_at: IsoDateTime,
}

/// Synara `ThreadConversationRollbackCompleteCommand` (orchestration.ts:2007)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadConversationRollbackCompleteCommand {
    pub command_id: CommandId,
    pub thread_id: ThreadId,
    pub message_id: MessageId,
    pub num_turns: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed_turn_ids: Option<Vec<TurnId>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skip_attachment_prune: Option<bool>,
    pub created_at: IsoDateTime,
}

// Omitted: the Claude-cache, goal and sidechat commands.
/// Synara `InternalOrchestrationCommand` (orchestration.ts:2032), the thread commands the server
/// dispatches itself (provider runtime ingestion, checkpoints, the queued-turn reactor).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum InternalThreadCommand {
    #[serde(rename = "thread.session.set")]
    SessionSet(ThreadSessionSetCommand),
    #[serde(rename = "thread.messages.import")]
    MessagesImport(ThreadMessagesImportCommand),
    #[serde(rename = "thread.message.assistant.delta")]
    MessageAssistantDelta(ThreadMessageAssistantDeltaCommand),
    #[serde(rename = "thread.message.assistant.complete")]
    MessageAssistantComplete(ThreadMessageAssistantCompleteCommand),
    #[serde(rename = "thread.message.user.bind-turn")]
    MessageUserBindTurn(ThreadMessageUserBindTurnCommand),
    #[serde(rename = "thread.message.user.set-turn-boundary")]
    MessageUserSetTurnBoundary(ThreadMessageUserSetTurnBoundaryCommand),
    #[serde(rename = "thread.proposed-plan.upsert")]
    ProposedPlanUpsert(ThreadProposedPlanUpsertCommand),
    #[serde(rename = "thread.turn.diff.complete")]
    TurnDiffComplete(ThreadTurnDiffCompleteCommand),
    #[serde(rename = "thread.activity.append")]
    ActivityAppend(ThreadActivityAppendCommand),
    #[serde(rename = "thread.revert.complete")]
    RevertComplete(ThreadRevertCompleteCommand),
    #[serde(rename = "thread.conversation.rollback")]
    ConversationRollback(ThreadConversationRollbackCommand),
    #[serde(rename = "thread.conversation.rollback.complete")]
    ConversationRollbackComplete(ThreadConversationRollbackCompleteCommand),
    #[serde(rename = "thread.turn.dispatch-queued")]
    TurnDispatchQueued(ThreadDispatchQueuedTurnCommand),
}

/// Synara `OrchestrationCommand` (orchestration.ts:2053): what the decider takes. A client's
/// `thread.turn.start` carries upload attachments; the decider normalizes it to the server form
/// ([`ThreadTurnStartCommand`]) the way Synara's `dispatchCommandNormalization.ts` does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OrchestrationCommand {
    Client(ClientThreadCommand),
    Internal(InternalThreadCommand),
}

impl From<ClientThreadCommand> for OrchestrationCommand {
    fn from(command: ClientThreadCommand) -> Self {
        Self::Client(command)
    }
}

impl From<InternalThreadCommand> for OrchestrationCommand {
    fn from(command: InternalThreadCommand) -> Self {
        Self::Internal(command)
    }
}

/// Synara `OrchestrationShellSnapshot` (orchestration.ts:1241), without spaces' and projects'
/// shells: those are the app's, and the lists are always empty.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationShellSnapshot {
    pub snapshot_sequence: u64,
    pub spaces: Vec<Value>,
    pub projects: Vec<Value>,
    pub threads: Vec<OrchestrationThreadShell>,
    pub updated_at: IsoDateTime,
}

/// Synara `ThreadTurnDiff` (orchestration.ts:2795): the result of `orchestration.getTurnDiff` and
/// `orchestration.getFullThreadDiff`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTurnDiff {
    pub thread_id: ThreadId,
    pub from_turn_count: u64,
    pub to_turn_count: u64,
    pub diff: String,
}

/// Synara `OrchestrationGetTurnDiffInput` (orchestration.ts:2863). `fromTurnCount <= toTurnCount`
/// is checked where it is served.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationGetTurnDiffInput {
    pub thread_id: ThreadId,
    pub from_turn_count: u64,
    pub to_turn_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignore_whitespace: Option<bool>,
}

/// Synara `OrchestrationGetFullThreadDiffInput` (orchestration.ts:2875)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrchestrationGetFullThreadDiffInput {
    pub thread_id: ThreadId,
    pub to_turn_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignore_whitespace: Option<bool>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn turn_start_command_round_trips() {
        let sample = json!({
            "type": "thread.turn.start",
            "commandId": "cmd-1",
            "threadId": "thread-1",
            "message": {
                "messageId": "msg-1",
                "role": "user",
                "text": "Fix the build",
                "attachments": [
                    { "type": "file", "id": "att-1", "name": "log.txt", "mimeType": "text/plain", "sizeBytes": 12 },
                    { "type": "assistant-selection", "assistantMessageId": "msg-0", "text": "quoted" }
                ],
                "skills": [{ "name": "review", "path": "/skills/review" }]
            },
            "modelSelection": {
                "provider": "claudeAgent",
                "model": "claude-sonnet-5",
                "options": { "effort": "high", "thinking": true }
            },
            "reviewTarget": { "type": "baseBranch", "branch": "main" },
            "dispatchMode": "queue",
            "runtimeMode": "approval-required",
            "interactionMode": "plan",
            "createdAt": "2026-10-05T10:00:00.000Z"
        });
        let command: ClientThreadCommand = serde_json::from_value(sample.clone()).unwrap();
        assert_eq!(serde_json::to_value(&command).unwrap(), sample);
        let ClientThreadCommand::TurnStart(start) = command else {
            panic!("not a thread.turn.start command");
        };
        assert_eq!(start.runtime_mode, RuntimeMode::ApprovalRequired);
        assert_eq!(start.message.attachments.len(), 2);
    }

    #[test]
    fn thread_with_a_message_and_an_activity_round_trips() {
        let sample = json!({
            "id": "thread-1",
            "projectId": "project-1",
            "title": "Fix the build",
            "modelSelection": { "provider": "codex", "instanceId": "codex", "model": "gpt-6-astra", "options": { "reasoningEffort": "high" } },
            "runtimeMode": "full-access",
            "interactionMode": "default",
            "envMode": "worktree",
            "branch": "fix/build",
            "worktreePath": "/work/tree",
            "workingDirectory": null,
            "associatedWorktreePath": null,
            "associatedWorktreeBranch": null,
            "associatedWorktreeRef": null,
            "createBranchFlowCompleted": false,
            "isPinned": false,
            "parentThreadId": null,
            "creationSource": null,
            "sourceThreadId": null,
            "sourceTurnId": null,
            "gatewayOperationId": null,
            "gatewayOperationIndex": null,
            "subagentAgentId": null,
            "subagentNickname": null,
            "subagentRole": null,
            "forkSourceThreadId": null,
            "latestTurn": {
                "turnId": "turn-1",
                "state": "completed",
                "requestedAt": "2026-10-05T10:00:00.000Z",
                "startedAt": "2026-10-05T10:00:01.000Z",
                "completedAt": "2026-10-05T10:00:09.000Z",
                "assistantMessageId": "msg-2"
            },
            "latestUserMessageAt": "2026-10-05T10:00:00.000Z",
            "createdAt": "2026-10-05T09:59:00.000Z",
            "updatedAt": "2026-10-05T10:00:09.000Z",
            "archivedAt": null,
            "settledAt": null,
            "snoozedUntil": null,
            "snoozeReminderAt": null,
            "deletedAt": null,
            "messages": [
                {
                    "id": "msg-1",
                    "role": "user",
                    "text": "Fix the build",
                    "turnId": "turn-1",
                    "streaming": false,
                    "source": "native",
                    "createdAt": "2026-10-05T10:00:00.000Z",
                    "updatedAt": "2026-10-05T10:00:00.000Z"
                },
                {
                    "id": "msg-2",
                    "role": "assistant",
                    "text": "Done.",
                    "textSegments": [
                        { "sequence": 4, "startedAt": "2026-10-05T10:00:05.000Z", "endedAt": "2026-10-05T10:00:08.000Z", "text": "Done." }
                    ],
                    "turnId": "turn-1",
                    "streaming": false,
                    "source": "native",
                    "createdAt": "2026-10-05T10:00:05.000Z",
                    "updatedAt": "2026-10-05T10:00:09.000Z"
                }
            ],
            "proposedPlans": [],
            "activities": [
                {
                    "id": "evt-1",
                    "tone": "tool",
                    "kind": "tool.completed",
                    "summary": "Ran cargo build",
                    "payload": { "itemType": "command_execution", "detail": "ok" },
                    "turnId": "turn-1",
                    "sequence": 3,
                    "createdAt": "2026-10-05T10:00:04.000Z"
                }
            ],
            "checkpoints": [],
            "session": {
                "threadId": "thread-1",
                "status": "ready",
                "providerName": "codex",
                "runtimeMode": "full-access",
                "activeTurnId": null,
                "lastError": null,
                "lastActivityAt": null,
                "updatedAt": "2026-10-05T10:00:09.000Z"
            }
        });
        let thread: OrchestrationThread = serde_json::from_value(sample.clone()).unwrap();
        assert_eq!(serde_json::to_value(&thread).unwrap(), sample);
        assert_eq!(thread.messages.len(), 2);
        assert_eq!(thread.activities[0].tone, OrchestrationThreadActivityTone::Tool);
        assert_eq!(thread.env_mode, ThreadEnvironmentMode::Worktree);
    }

    #[test]
    fn message_sent_event_round_trips() {
        let sample = json!({
            "sequence": 7,
            "eventId": "evt-9",
            "aggregateKind": "thread",
            "aggregateId": "thread-1",
            "occurredAt": "2026-10-05T10:00:00.000Z",
            "commandId": "cmd-1",
            "causationEventId": null,
            "correlationId": "cmd-1",
            "metadata": { "providerTurnId": "t1" },
            "type": "thread.message-sent",
            "payload": {
                "threadId": "thread-1",
                "messageId": "msg-2",
                "role": "assistant",
                "text": "Hel",
                "turnId": "turn-1",
                "streaming": true,
                "source": "native",
                "createdAt": "2026-10-05T10:00:00.000Z",
                "updatedAt": "2026-10-05T10:00:00.000Z"
            }
        });
        let event: OrchestrationEvent = serde_json::from_value(sample.clone()).unwrap();
        assert_eq!(serde_json::to_value(&event).unwrap(), sample);
        assert!(matches!(event.body, OrchestrationEventBody::ThreadMessageSent(_)));
    }

    #[test]
    fn user_input_answers_take_text_lists_and_null() {
        let sample = json!({ "a": "yes", "b": ["x", "y"], "c": null });
        let answers: ProviderUserInputAnswers = serde_json::from_value(sample.clone()).unwrap();
        assert_eq!(answers["b"], ProviderUserInputAnswer::Many(vec!["x".into(), "y".into()]));
        assert_eq!(answers["c"], ProviderUserInputAnswer::Null);
        assert_eq!(serde_json::to_value(&answers).unwrap(), sample);
    }
}
