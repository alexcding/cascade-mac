//! Ported from Synara `packages/contracts/src/providerRuntime.ts`: what an adapter says about a
//! running session, as one tagged event.
//!
//! Synara declares one struct per event (`ProviderRuntimeSessionStartedEvent`, ...) from the
//! shared base fields, a `type` literal and a payload, and unions them. Here the base fields are
//! [`ProviderRuntimeEvent`] and the `type` literal and payload are
//! [`ProviderRuntimeEventBody`], adjacently tagged and flattened in, which reads and writes the
//! same JSON. The per-event structs, their `*Type` literals and the legacy `ProviderRuntime*`
//! aliases (providerRuntime.ts:1216-1228) are therefore not repeated.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::base::{
    optional_nullable, EventId, IsoDateTime, ProviderDriverKind, ProviderInstanceId, ProviderItemId,
    RuntimeItemId, RuntimeRequestId, RuntimeTaskId, ThreadId, TurnId,
};
use super::orchestration::AsyncUserInputQuestion;

/// Synara `RuntimeEventRawSource` (providerRuntime.ts:22)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RuntimeEventRawSource {
    #[serde(rename = "codex.app-server.notification")]
    CodexAppServerNotification,
    #[serde(rename = "codex.app-server.request")]
    CodexAppServerRequest,
    #[serde(rename = "codex.eventmsg")]
    CodexEventmsg,
    #[serde(rename = "claude.sdk.message")]
    ClaudeSdkMessage,
    #[serde(rename = "claude.sdk.permission")]
    ClaudeSdkPermission,
    #[serde(rename = "claude.sdk.hook")]
    ClaudeSdkHook,
    #[serde(rename = "codex.sdk.thread-event")]
    CodexSdkThreadEvent,
    #[serde(rename = "antigravity.cli.event")]
    AntigravityCliEvent,
    #[serde(rename = "acp.jsonrpc")]
    AcpJsonrpc,
    #[serde(rename = "acp.cursor.extension")]
    AcpCursorExtension,
    #[serde(rename = "opencode.sdk.event")]
    OpencodeSdkEvent,
    #[serde(rename = "pi.sdk.event")]
    PiSdkEvent,
}

/// Synara `RuntimeEventRaw` (providerRuntime.ts:38)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeEventRaw {
    pub source: RuntimeEventRawSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_type: Option<String>,
    #[serde(default)]
    pub payload: Value,
}

/// Synara `ProviderRequestId` (providerRuntime.ts:46)
pub type ProviderRequestId = String;

/// Synara `ProviderRefs` (providerRuntime.ts:49)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRefs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_thread_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_parent_thread_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_provider_turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_item_id: Option<ProviderItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_request_id: Option<ProviderRequestId>,
}

/// Synara `RuntimeSessionState` (providerRuntime.ts:59)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeSessionState {
    Starting,
    Ready,
    Running,
    Waiting,
    Stopped,
    Error,
}

/// Synara `RuntimeThreadState` (providerRuntime.ts:69)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeThreadState {
    Active,
    Idle,
    Archived,
    Closed,
    Compacted,
    Error,
}

/// Synara `RuntimeTurnState` (providerRuntime.ts:79)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeTurnState {
    Completed,
    Failed,
    Interrupted,
    Cancelled,
}

/// Synara `RuntimeTaskStatus` (providerRuntime.ts:82)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeTaskStatus {
    Pending,
    InProgress,
    Completed,
}

/// Synara `RuntimeItemStatus` (providerRuntime.ts:85)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeItemStatus {
    InProgress,
    Completed,
    Failed,
    Declined,
}

/// Synara `RuntimeContentStreamKind` (providerRuntime.ts:88)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeContentStreamKind {
    AssistantText,
    ReasoningText,
    ReasoningSummaryText,
    PlanText,
    CommandOutput,
    FileChangeOutput,
    Unknown,
}

/// Synara `RuntimeSessionExitKind` (providerRuntime.ts:99)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeSessionExitKind {
    Graceful,
    Error,
}

/// Synara `RuntimeErrorClass` (providerRuntime.ts:102)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeErrorClass {
    ProviderError,
    TransportError,
    PermissionError,
    ValidationError,
    Unknown,
}

/// Synara `TOOL_LIFECYCLE_ITEM_TYPES` (providerRuntime.ts:111)
pub const TOOL_LIFECYCLE_ITEM_TYPES: &[&str] = &[
    "command_execution",
    "file_change",
    "mcp_tool_call",
    "dynamic_tool_call",
    "collab_agent_tool_call",
    "web_search",
    "image_view",
    "image_generation",
];

/// Synara `ToolLifecycleItemType` (providerRuntime.ts:122)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolLifecycleItemType {
    CommandExecution,
    FileChange,
    McpToolCall,
    DynamicToolCall,
    CollabAgentToolCall,
    WebSearch,
    ImageView,
    ImageGeneration,
}

/// Synara `isToolLifecycleItemType` (providerRuntime.ts:125)
pub fn is_tool_lifecycle_item_type(value: &str) -> bool {
    TOOL_LIFECYCLE_ITEM_TYPES.contains(&value)
}

/// Synara `CanonicalItemType` (providerRuntime.ts:129)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CanonicalItemType {
    UserMessage,
    AssistantMessage,
    Reasoning,
    Plan,
    CommandExecution,
    FileChange,
    McpToolCall,
    DynamicToolCall,
    CollabAgentToolCall,
    WebSearch,
    ImageView,
    ImageGeneration,
    ReviewEntered,
    ReviewExited,
    ContextCompaction,
    Error,
    Unknown,
}

/// Synara `CanonicalRequestType` (providerRuntime.ts:143)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CanonicalRequestType {
    CommandExecutionApproval,
    FileReadApproval,
    FileChangeApproval,
    PermissionsApproval,
    ApplyPatchApproval,
    ExecCommandApproval,
    ToolUserInput,
    ToolApproval,
    DynamicToolCall,
    AuthTokensRefresh,
    Unknown,
}

/// Synara `ProviderRuntimeEventType` (providerRuntime.ts:158)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProviderRuntimeEventType {
    #[serde(rename = "session.started")]
    SessionStarted,
    #[serde(rename = "session.configured")]
    SessionConfigured,
    #[serde(rename = "session.state.changed")]
    SessionStateChanged,
    #[serde(rename = "session.exited")]
    SessionExited,
    #[serde(rename = "thread.started")]
    ThreadStarted,
    #[serde(rename = "thread.state.changed")]
    ThreadStateChanged,
    #[serde(rename = "thread.metadata.updated")]
    ThreadMetadataUpdated,
    #[serde(rename = "thread.token-usage.updated")]
    ThreadTokenUsageUpdated,
    #[serde(rename = "thread.realtime.started")]
    ThreadRealtimeStarted,
    #[serde(rename = "thread.realtime.item-added")]
    ThreadRealtimeItemAdded,
    #[serde(rename = "thread.realtime.audio.delta")]
    ThreadRealtimeAudioDelta,
    #[serde(rename = "thread.realtime.error")]
    ThreadRealtimeError,
    #[serde(rename = "thread.realtime.closed")]
    ThreadRealtimeClosed,
    #[serde(rename = "turn.started")]
    TurnStarted,
    #[serde(rename = "turn.completed")]
    TurnCompleted,
    #[serde(rename = "turn.aborted")]
    TurnAborted,
    #[serde(rename = "turn.tasks.updated")]
    TurnTasksUpdated,
    #[serde(rename = "turn.proposed.delta")]
    TurnProposedDelta,
    #[serde(rename = "turn.proposed.completed")]
    TurnProposedCompleted,
    #[serde(rename = "turn.diff.updated")]
    TurnDiffUpdated,
    #[serde(rename = "turn.steered")]
    TurnSteered,
    #[serde(rename = "item.started")]
    ItemStarted,
    #[serde(rename = "item.updated")]
    ItemUpdated,
    #[serde(rename = "item.completed")]
    ItemCompleted,
    #[serde(rename = "content.delta")]
    ContentDelta,
    #[serde(rename = "request.opened")]
    RequestOpened,
    #[serde(rename = "request.resolved")]
    RequestResolved,
    #[serde(rename = "user-input.requested")]
    UserInputRequested,
    #[serde(rename = "user-input.resolved")]
    UserInputResolved,
    #[serde(rename = "task.started")]
    TaskStarted,
    #[serde(rename = "task.progress")]
    TaskProgress,
    #[serde(rename = "task.updated")]
    TaskUpdated,
    #[serde(rename = "task.completed")]
    TaskCompleted,
    #[serde(rename = "hook.started")]
    HookStarted,
    #[serde(rename = "hook.progress")]
    HookProgress,
    #[serde(rename = "hook.completed")]
    HookCompleted,
    #[serde(rename = "tool.progress")]
    ToolProgress,
    #[serde(rename = "tool.summary")]
    ToolSummary,
    #[serde(rename = "auth.status")]
    AuthStatus,
    #[serde(rename = "account.updated")]
    AccountUpdated,
    #[serde(rename = "account.rate-limits.updated")]
    AccountRateLimitsUpdated,
    #[serde(rename = "mcp.status.updated")]
    McpStatusUpdated,
    #[serde(rename = "mcp.oauth.completed")]
    McpOauthCompleted,
    #[serde(rename = "model.rerouted")]
    ModelRerouted,
    #[serde(rename = "config.warning")]
    ConfigWarning,
    #[serde(rename = "deprecation.notice")]
    DeprecationNotice,
    #[serde(rename = "files.persisted")]
    FilesPersisted,
    #[serde(rename = "vcs.state.changed")]
    VcsStateChanged,
    #[serde(rename = "runtime.warning")]
    RuntimeWarning,
    #[serde(rename = "runtime.error")]
    RuntimeError,
    #[serde(rename = "event.unmapped")]
    EventUnmapped,
}

/// Synara `ProviderRuntimeEventBase` (providerRuntime.ts:265), with the event's `type` and
/// `payload` flattened in as [`ProviderRuntimeEventBody`]. Synara's `ProviderRuntimeEventV2` and
/// `ProviderRuntimeEvent` (providerRuntime.ts:1158) are this type.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRuntimeEvent {
    pub event_id: EventId,
    pub provider: ProviderDriverKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_instance_id: Option<ProviderInstanceId>,
    pub thread_id: ThreadId,
    pub created_at: IsoDateTime,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<RuntimeItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<RuntimeRequestId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_refs: Option<ProviderRefs>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw: Option<RuntimeEventRaw>,
    #[serde(flatten)]
    pub body: ProviderRuntimeEventBody,
}

/// Synara `ProviderRuntimeEventV2` (providerRuntime.ts:1158)
pub type ProviderRuntimeEventV2 = ProviderRuntimeEvent;

/// Synara `SessionStartedPayload` (providerRuntime.ts:281)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStartedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<Value>,
}

/// Synara `SessionConfiguredPayload` (providerRuntime.ts:287)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfiguredPayload {
    pub config: Map<String, Value>,
}

/// Synara `SessionStateChangedPayload` (providerRuntime.ts:292)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStateChangedPayload {
    pub state: RuntimeSessionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<Value>,
}

/// Synara `SessionExitedPayload` (providerRuntime.ts:299)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionExitedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recoverable: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_kind: Option<RuntimeSessionExitKind>,
}

/// Synara `ThreadStartedPayload` (providerRuntime.ts:306)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadStartedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_thread_id: Option<String>,
}

/// Synara `ThreadStateChangedPayload` (providerRuntime.ts:311)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadStateChangedPayload {
    pub state: RuntimeThreadState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<Value>,
}

/// Synara `ThreadMetadataUpdatedPayload` (providerRuntime.ts:317)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMetadataUpdatedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Map<String, Value>>,
}

/// The `cumulativeUsage` struct inside Synara `ThreadTokenUsageSnapshot` (providerRuntime.ts:326)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTokenCumulativeUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_creation_input_tokens: Option<u64>,
}

// Omitted: `claudeCache`, a Claude-cache field. `tokenAccountingVersion` is `Literal(1)` there.
/// Synara `ThreadTokenUsageSnapshot` (providerRuntime.ts:323)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTokenUsageSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cumulative_usage: Option<ThreadTokenCumulativeUsage>,
    pub used_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_percent: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_processed_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_accounting_version: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_cached_input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_reasoning_output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_uses: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compacts_automatically: Option<bool>,
}

/// Synara `ThreadTokenUsageUpdatedPayload` (providerRuntime.ts:357)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTokenUsageUpdatedPayload {
    pub usage: ThreadTokenUsageSnapshot,
}

/// Synara `ThreadRealtimeStartedPayload` (providerRuntime.ts:362)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRealtimeStartedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub realtime_session_id: Option<String>,
}

/// Synara `ThreadRealtimeItemAddedPayload` (providerRuntime.ts:367)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRealtimeItemAddedPayload {
    #[serde(default)]
    pub item: Value,
}

/// Synara `ThreadRealtimeAudioDeltaPayload` (providerRuntime.ts:372)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRealtimeAudioDeltaPayload {
    #[serde(default)]
    pub audio: Value,
}

/// Synara `ThreadRealtimeErrorPayload` (providerRuntime.ts:377)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRealtimeErrorPayload {
    pub message: String,
}

/// Synara `ThreadRealtimeClosedPayload` (providerRuntime.ts:382)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadRealtimeClosedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Synara `TurnStartedPayload` (providerRuntime.ts:387)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnStartedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

/// Synara `TurnCompletedPayload` (providerRuntime.ts:393). `tokenAccountingVersion` is
/// `Literal(1)` there; `stopReason` is `optional(NullOr(..))`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnCompletedPayload {
    pub state: RuntimeTurnState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_compacted: Option<bool>,
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub stop_reason: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_usage: Option<Map<String, Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_accounting_version: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_loop_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cumulative_cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

/// Synara `TurnAbortedPayload` (providerRuntime.ts:409)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnAbortedPayload {
    pub reason: String,
}

/// Synara `RuntimeTaskListItem` (providerRuntime.ts:414)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeTaskListItem {
    pub task: String,
    pub status: RuntimeTaskStatus,
}

/// Synara `TurnTasksUpdatedPayload` (providerRuntime.ts:420)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnTasksUpdatedPayload {
    #[serde(
        default,
        with = "optional_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    pub explanation: Option<Option<String>>,
    pub tasks: Vec<RuntimeTaskListItem>,
}

/// Synara `TurnProposedDeltaPayload` (providerRuntime.ts:426)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnProposedDeltaPayload {
    pub delta: String,
}

/// Synara `TurnProposedCompletedPayload` (providerRuntime.ts:431)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnProposedCompletedPayload {
    pub plan_markdown: String,
}

/// Synara `TurnDiffUpdatedPayload` (providerRuntime.ts:436)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnDiffUpdatedPayload {
    pub unified_diff: String,
}

/// Synara `ItemLifecyclePayload` (providerRuntime.ts:441)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemLifecyclePayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub async_questions: Option<Vec<AsyncUserInputQuestion>>,
    pub item_type: CanonicalItemType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<RuntimeItemStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Free-form body (raw tool output): unconstrained, whitespace and all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// Synara `CODEX_GENERATED_IMAGE_ARTIFACT_KIND` (providerRuntime.ts:457)
pub const CODEX_GENERATED_IMAGE_ARTIFACT_KIND: &str = "codex.generated_image";

/// The `kind` literal of [`CodexGeneratedImageArtifact`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CodexGeneratedImageArtifactKind {
    #[serde(rename = "codex.generated_image")]
    CodexGeneratedImage,
}

/// Synara `CodexGeneratedImageArtifact` (providerRuntime.ts:458)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexGeneratedImageArtifact {
    pub kind: CodexGeneratedImageArtifactKind,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
}

/// Synara `ContentDeltaPayload` (providerRuntime.ts:465)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentDeltaPayload {
    pub stream_kind: RuntimeContentStreamKind,
    pub delta: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_index: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary_index: Option<i64>,
}

/// Synara `RequestOpenedPayload` (providerRuntime.ts:473)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestOpenedPayload {
    pub request_type: CanonicalRequestType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub args: Option<Value>,
}

/// Synara `RequestResolvedPayload` (providerRuntime.ts:480)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestResolvedPayload {
    pub request_type: CanonicalRequestType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<Value>,
}

/// Synara `UserInputQuestionOption` (providerRuntime.ts:487)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInputQuestionOption {
    pub label: String,
    pub description: String,
}

/// Synara `UserInputQuestion` (providerRuntime.ts:493). `multiSelect` defaults to false on
/// construction only; decoding leaves it absent.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInputQuestion {
    pub id: String,
    pub header: String,
    pub question: String,
    pub options: Vec<UserInputQuestionOption>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub multi_select: Option<bool>,
}

/// Synara `UserInputRequestedPayload` (providerRuntime.ts:504)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInputRequestedPayload {
    pub questions: Vec<UserInputQuestion>,
}

/// Synara `UserInputResolvedPayload` (providerRuntime.ts:509)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInputResolvedPayload {
    pub answers: Map<String, Value>,
}

/// Synara `WorkflowPhase` (providerRuntime.ts:515)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowPhase {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Synara `WorkflowAgentSnapshot` (providerRuntime.ts:522)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowAgentSnapshot {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase_index: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_preview: Option<String>,
}

/// The `state` literals of [`WorkflowAgentRuntimeSnapshot`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WorkflowAgentRuntimeState {
    Running,
    Completed,
}

/// Synara `WorkflowAgentRuntimeSnapshot` (providerRuntime.ts:545)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowAgentRuntimeSnapshot {
    pub agent_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<WorkflowAgentRuntimeState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recent_tool_names: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_preview: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
}

/// Synara `WorkflowAgentPlan` (providerRuntime.ts:563)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowAgentPlan {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

/// Synara `TaskStartedPayload` (providerRuntime.ts:570)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskStartedPayload {
    pub task_id: RuntimeTaskId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_task_id: Option<RuntimeTaskId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_phases: Option<Vec<WorkflowPhase>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_agent_phases: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_agent_plans: Option<BTreeMap<String, WorkflowAgentPlan>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
}

/// Synara `TaskProgressPayload` (providerRuntime.ts:589)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskProgressPayload {
    pub task_id: RuntimeTaskId,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_task_id: Option<RuntimeTaskId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_agents: Option<Vec<WorkflowAgentRuntimeSnapshot>>,
}

/// The `status` literals of [`TaskUpdatedPayload`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskUpdatedStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Killed,
    Paused,
}

/// Synara `TaskUpdatedPayload` (providerRuntime.ts:602)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskUpdatedPayload {
    pub task_id: RuntimeTaskId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskUpdatedStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_backgrounded: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_task_id: Option<RuntimeTaskId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_script_path: Option<String>,
}

/// The `status` literals of [`TaskCompletedPayload`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskCompletedStatus {
    Completed,
    Failed,
    Stopped,
}

/// Synara `TaskCompletedPayload` (providerRuntime.ts:619)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskCompletedPayload {
    pub task_id: RuntimeTaskId,
    pub status: TaskCompletedStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_task_id: Option<RuntimeTaskId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_agents: Option<Vec<WorkflowAgentSnapshot>>,
}

/// The `target` literals of [`TurnSteeredPayload`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TurnSteeredTarget {
    Turn,
    Subagent,
}

/// Synara `TurnSteeredPayload` (providerRuntime.ts:635). Absent `target` means `subagent`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnSteeredPayload {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TurnSteeredTarget>,
}

/// Synara `HookStartedPayload` (providerRuntime.ts:641)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookStartedPayload {
    pub hook_id: String,
    pub hook_name: String,
    pub hook_event: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// Synara `HookProgressPayload` (providerRuntime.ts:650)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookProgressPayload {
    pub hook_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr: Option<String>,
}

/// The `outcome` literals of [`HookCompletedPayload`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HookOutcome {
    Success,
    Error,
    Cancelled,
}

/// The `status` literals of [`HookCompletedPayload`]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HookCompletedStatus {
    Completed,
    Failed,
    Blocked,
    Stopped,
}

/// Synara `HookCompletedPayload` (providerRuntime.ts:658)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookCompletedPayload {
    pub hook_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hook_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hook_event: Option<String>,
    pub outcome: HookOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<HookCompletedStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// Synara `ToolProgressPayload` (providerRuntime.ts:674)
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolProgressPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elapsed_seconds: Option<f64>,
}

/// Synara `ToolSummaryPayload` (providerRuntime.ts:682)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolSummaryPayload {
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preceding_tool_use_ids: Option<Vec<String>>,
}

/// Synara `AuthStatusPayload` (providerRuntime.ts:688)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatusPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_authenticating: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Synara `AccountUpdatedPayload` (providerRuntime.ts:695)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountUpdatedPayload {
    #[serde(default)]
    pub account: Value,
}

/// Synara `AccountRateLimitsUpdatedPayload` (providerRuntime.ts:700)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountRateLimitsUpdatedPayload {
    #[serde(default)]
    pub rate_limits: Value,
}

/// Synara `McpStatusUpdatedPayload` (providerRuntime.ts:705)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpStatusUpdatedPayload {
    #[serde(default)]
    pub status: Value,
}

/// Synara `McpOauthCompletedPayload` (providerRuntime.ts:710)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpOauthCompletedPayload {
    pub success: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Synara `ModelReroutedPayload` (providerRuntime.ts:717)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelReroutedPayload {
    pub from_model: String,
    pub to_model: String,
    pub reason: String,
}

/// Synara `ConfigWarningPayload` (providerRuntime.ts:724)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigWarningPayload {
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<Value>,
}

/// Synara `DeprecationNoticePayload` (providerRuntime.ts:732)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeprecationNoticePayload {
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

/// An entry of `files` in Synara `FilesPersistedPayload` (providerRuntime.ts:739)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilesPersistedFile {
    pub filename: String,
    pub file_id: String,
}

/// An entry of `failed` in Synara `FilesPersistedPayload` (providerRuntime.ts:745)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilesPersistedFailure {
    pub filename: String,
    pub error: String,
}

/// Synara `FilesPersistedPayload` (providerRuntime.ts:738)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilesPersistedPayload {
    pub files: Vec<FilesPersistedFile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failed: Option<Vec<FilesPersistedFailure>>,
}

/// Synara `VcsStateChangedPayload` (providerRuntime.ts:756)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VcsStateChangedPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
}

/// Synara `RuntimeWarningPayload` (providerRuntime.ts:762)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeWarningPayload {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<Value>,
}

/// Synara `RuntimeErrorPayload` (providerRuntime.ts:768)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeErrorPayload {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<RuntimeErrorClass>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<Value>,
}

/// Synara `EventUnmappedPayload` (providerRuntime.ts:777): a forward-compatible diagnostic for a
/// provider event without an explicit mapping.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventUnmappedPayload {
    pub native_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// The `type` and `payload` of Synara's `ProviderRuntimeEventV2` union (providerRuntime.ts:1158),
/// one variant per member in the union's order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum ProviderRuntimeEventBody {
    #[serde(rename = "session.started")]
    SessionStarted(SessionStartedPayload),
    #[serde(rename = "session.configured")]
    SessionConfigured(SessionConfiguredPayload),
    #[serde(rename = "session.state.changed")]
    SessionStateChanged(SessionStateChangedPayload),
    #[serde(rename = "session.exited")]
    SessionExited(SessionExitedPayload),
    #[serde(rename = "thread.started")]
    ThreadStarted(ThreadStartedPayload),
    #[serde(rename = "thread.state.changed")]
    ThreadStateChanged(ThreadStateChangedPayload),
    #[serde(rename = "thread.metadata.updated")]
    ThreadMetadataUpdated(ThreadMetadataUpdatedPayload),
    #[serde(rename = "thread.token-usage.updated")]
    ThreadTokenUsageUpdated(ThreadTokenUsageUpdatedPayload),
    #[serde(rename = "thread.realtime.started")]
    ThreadRealtimeStarted(ThreadRealtimeStartedPayload),
    #[serde(rename = "thread.realtime.item-added")]
    ThreadRealtimeItemAdded(ThreadRealtimeItemAddedPayload),
    #[serde(rename = "thread.realtime.audio.delta")]
    ThreadRealtimeAudioDelta(ThreadRealtimeAudioDeltaPayload),
    #[serde(rename = "thread.realtime.error")]
    ThreadRealtimeError(ThreadRealtimeErrorPayload),
    #[serde(rename = "thread.realtime.closed")]
    ThreadRealtimeClosed(ThreadRealtimeClosedPayload),
    #[serde(rename = "turn.started")]
    TurnStarted(TurnStartedPayload),
    #[serde(rename = "turn.completed")]
    TurnCompleted(TurnCompletedPayload),
    #[serde(rename = "turn.aborted")]
    TurnAborted(TurnAbortedPayload),
    #[serde(rename = "turn.tasks.updated")]
    TurnTasksUpdated(TurnTasksUpdatedPayload),
    #[serde(rename = "turn.proposed.delta")]
    TurnProposedDelta(TurnProposedDeltaPayload),
    #[serde(rename = "turn.proposed.completed")]
    TurnProposedCompleted(TurnProposedCompletedPayload),
    #[serde(rename = "turn.diff.updated")]
    TurnDiffUpdated(TurnDiffUpdatedPayload),
    #[serde(rename = "turn.steered")]
    TurnSteered(TurnSteeredPayload),
    #[serde(rename = "item.started")]
    ItemStarted(ItemLifecyclePayload),
    #[serde(rename = "item.updated")]
    ItemUpdated(ItemLifecyclePayload),
    #[serde(rename = "item.completed")]
    ItemCompleted(ItemLifecyclePayload),
    #[serde(rename = "content.delta")]
    ContentDelta(ContentDeltaPayload),
    #[serde(rename = "request.opened")]
    RequestOpened(RequestOpenedPayload),
    #[serde(rename = "request.resolved")]
    RequestResolved(RequestResolvedPayload),
    #[serde(rename = "user-input.requested")]
    UserInputRequested(UserInputRequestedPayload),
    #[serde(rename = "user-input.resolved")]
    UserInputResolved(UserInputResolvedPayload),
    #[serde(rename = "task.started")]
    TaskStarted(TaskStartedPayload),
    #[serde(rename = "task.progress")]
    TaskProgress(TaskProgressPayload),
    #[serde(rename = "task.updated")]
    TaskUpdated(TaskUpdatedPayload),
    #[serde(rename = "task.completed")]
    TaskCompleted(TaskCompletedPayload),
    #[serde(rename = "hook.started")]
    HookStarted(HookStartedPayload),
    #[serde(rename = "hook.progress")]
    HookProgress(HookProgressPayload),
    #[serde(rename = "hook.completed")]
    HookCompleted(HookCompletedPayload),
    #[serde(rename = "tool.progress")]
    ToolProgress(ToolProgressPayload),
    #[serde(rename = "tool.summary")]
    ToolSummary(ToolSummaryPayload),
    #[serde(rename = "auth.status")]
    AuthStatus(AuthStatusPayload),
    #[serde(rename = "account.updated")]
    AccountUpdated(AccountUpdatedPayload),
    #[serde(rename = "account.rate-limits.updated")]
    AccountRateLimitsUpdated(AccountRateLimitsUpdatedPayload),
    #[serde(rename = "mcp.status.updated")]
    McpStatusUpdated(McpStatusUpdatedPayload),
    #[serde(rename = "mcp.oauth.completed")]
    McpOauthCompleted(McpOauthCompletedPayload),
    #[serde(rename = "model.rerouted")]
    ModelRerouted(ModelReroutedPayload),
    #[serde(rename = "config.warning")]
    ConfigWarning(ConfigWarningPayload),
    #[serde(rename = "deprecation.notice")]
    DeprecationNotice(DeprecationNoticePayload),
    #[serde(rename = "files.persisted")]
    FilesPersisted(FilesPersistedPayload),
    #[serde(rename = "vcs.state.changed")]
    VcsStateChanged(VcsStateChangedPayload),
    #[serde(rename = "runtime.warning")]
    RuntimeWarning(RuntimeWarningPayload),
    #[serde(rename = "runtime.error")]
    RuntimeError(RuntimeErrorPayload),
    #[serde(rename = "event.unmapped")]
    EventUnmapped(EventUnmappedPayload),
}

/// Synara `ProviderRuntimeToolKind` (providerRuntime.ts:1231)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderRuntimeToolKind {
    Command,
    FileRead,
    FileChange,
    Other,
}

/// Synara `ProviderRuntimeTurnStatus` (providerRuntime.ts:1234)
pub type ProviderRuntimeTurnStatus = RuntimeTurnState;

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn round_trip(sample: Value) -> ProviderRuntimeEvent {
        let event: ProviderRuntimeEvent = serde_json::from_value(sample.clone()).unwrap();
        assert_eq!(serde_json::to_value(&event).unwrap(), sample);
        event
    }

    #[test]
    fn item_started_round_trips() {
        let event = round_trip(json!({
            "eventId": "evt-1",
            "provider": "claudeAgent",
            "providerInstanceId": "claudeAgent",
            "threadId": "thread-1",
            "createdAt": "2026-10-05T10:00:00.000Z",
            "turnId": "turn-1",
            "itemId": "item-1",
            "providerRefs": { "providerTurnId": "t1", "providerItemId": "toolu_1" },
            "raw": { "source": "claude.sdk.message", "messageType": "assistant", "payload": { "a": 1 } },
            "type": "item.started",
            "payload": {
                "itemType": "command_execution",
                "status": "inProgress",
                "title": "Ran command",
                "detail": "  ls -la\n",
                "data": { "command": "ls -la" }
            }
        }));
        let ProviderRuntimeEventBody::ItemStarted(payload) = event.body else {
            panic!("not an item.started event");
        };
        assert_eq!(payload.item_type, CanonicalItemType::CommandExecution);
        assert_eq!(payload.status, Some(RuntimeItemStatus::InProgress));
    }

    #[test]
    fn content_delta_round_trips() {
        let event = round_trip(json!({
            "eventId": "evt-2",
            "provider": "codex",
            "threadId": "thread-1",
            "createdAt": "2026-10-05T10:00:01.000Z",
            "type": "content.delta",
            "payload": { "streamKind": "assistant_text", "delta": "Hello", "contentIndex": 0 }
        }));
        let ProviderRuntimeEventBody::ContentDelta(payload) = event.body else {
            panic!("not a content.delta event");
        };
        assert_eq!(payload.stream_kind, RuntimeContentStreamKind::AssistantText);
        assert_eq!(payload.content_index, Some(0));
    }

    #[test]
    fn request_opened_round_trips() {
        let event = round_trip(json!({
            "eventId": "evt-3",
            "provider": "claudeAgent",
            "threadId": "thread-1",
            "createdAt": "2026-10-05T10:00:02.000Z",
            "requestId": "req-1",
            "type": "request.opened",
            "payload": {
                "requestType": "command_execution_approval",
                "detail": "Bash: rm -rf build",
                "args": { "command": "rm -rf build" }
            }
        }));
        let ProviderRuntimeEventBody::RequestOpened(payload) = event.body else {
            panic!("not a request.opened event");
        };
        assert_eq!(payload.request_type, CanonicalRequestType::CommandExecutionApproval);
    }

    #[test]
    fn turn_completed_keeps_a_null_stop_reason() {
        let event = round_trip(json!({
            "eventId": "evt-4",
            "provider": "codex",
            "threadId": "thread-1",
            "createdAt": "2026-10-05T10:00:03.000Z",
            "type": "turn.completed",
            "payload": { "state": "completed", "stopReason": null, "totalCostUsd": 0.5 }
        }));
        let ProviderRuntimeEventBody::TurnCompleted(payload) = event.body else {
            panic!("not a turn.completed event");
        };
        assert_eq!(payload.stop_reason, Some(None));
    }

    #[test]
    fn tool_lifecycle_types_are_the_item_types() {
        for name in TOOL_LIFECYCLE_ITEM_TYPES {
            let parsed: CanonicalItemType = serde_json::from_value(json!(name)).unwrap();
            assert_ne!(parsed, CanonicalItemType::Unknown);
            assert!(is_tool_lifecycle_item_type(name));
        }
        assert!(!is_tool_lifecycle_item_type("assistant_message"));
    }
}
