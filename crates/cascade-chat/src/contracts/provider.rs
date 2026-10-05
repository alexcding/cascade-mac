//! Ported from Synara `packages/contracts/src/provider.ts`, with the skill and mention
//! references from `providerDiscovery.ts` that its inputs use.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::base::{
    ApprovalRequestId, EventId, IsoDateTime, ProviderDriverKind, ProviderInstanceId, ProviderItemId,
    ThreadId, TurnId,
};
use super::orchestration::{
    ChatAttachment, ModelSelection, ProviderApprovalDecision, ProviderApprovalPolicy,
    ProviderInteractionMode, ProviderRequestKind, ProviderSandboxMode, ProviderStartOptions,
    ProviderUserInputAnswers, RuntimeMode,
};

/// Synara `ProviderSkillReference` (providerDiscovery.ts:41)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSkillReference {
    pub name: String,
    pub path: String,
}

/// Synara `ProviderMentionReference` (providerDiscovery.ts:47)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderMentionReference {
    pub name: String,
    pub path: String,
}

/// Synara `ProviderSessionStatus` (provider.ts:29)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderSessionStatus {
    Connecting,
    Ready,
    Running,
    Error,
    Closed,
}

/// Synara `ProviderSession` (provider.ts:37)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSession {
    pub provider: ProviderDriverKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_instance_id: Option<ProviderInstanceId>,
    pub status: ProviderSessionStatus,
    pub runtime_mode: RuntimeMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_cursor: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_turn_id: Option<TurnId>,
    pub created_at: IsoDateTime,
    pub updated_at: IsoDateTime,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

// Omitted: `enableComputerControl`, a computer-control field.
/// Synara `ProviderSessionStartInput` (provider.ts:53)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSessionStartInput {
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<ProviderDriverKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_instance_id: Option<ProviderInstanceId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_cursor: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_source_resume_cursor: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<ProviderApprovalPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<ProviderSandboxMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_options: Option<ProviderStartOptions>,
    /// Pre-approve the Synara group/gateway MCP tools for this session even when the runtime
    /// mode would ask. File edits and shell commands still ask.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_approve_synara_tools: Option<bool>,
    pub runtime_mode: RuntimeMode,
}

/// Synara `ProviderSendTurnInput` (provider.ts:79)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSendTurnInput {
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachments: Option<Vec<ChatAttachment>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<ProviderSkillReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Vec<ProviderMentionReference>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction_mode: Option<ProviderInteractionMode>,
}

/// Synara `ProviderSteerTurnInput` (provider.ts:93)
pub type ProviderSteerTurnInput = ProviderSendTurnInput;

/// Synara `ProviderTurnStartResult` (provider.ts:130)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderTurnStartResult {
    pub thread_id: ThreadId,
    pub turn_id: TurnId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_cursor: Option<Value>,
}

/// Synara `ProviderInterruptTurnInput` (provider.ts:143)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInterruptTurnInput {
    pub thread_id: ThreadId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_thread_id: Option<String>,
}

/// Synara `ProviderStopTaskInput` (provider.ts:150)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStopTaskInput {
    pub thread_id: ThreadId,
    pub task_id: String,
}

/// Synara `ProviderStopSessionInput` (provider.ts:176)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStopSessionInput {
    pub thread_id: ThreadId,
}

/// Synara `ProviderRespondToRequestInput` (provider.ts:186)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRespondToRequestInput {
    pub thread_id: ThreadId,
    pub request_id: ApprovalRequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    pub decision: ProviderApprovalDecision,
}

/// Synara `ProviderRespondToUserInputInput` (provider.ts:194)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRespondToUserInputInput {
    pub thread_id: ThreadId,
    pub request_id: ApprovalRequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    pub answers: ProviderUserInputAnswers,
}

/// Synara `ProviderEventKind` (provider.ts:202)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderEventKind {
    Session,
    Notification,
    Request,
    Error,
}

/// Synara `ProviderEvent` (provider.ts:204)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderEvent {
    pub id: EventId,
    pub kind: ProviderEventKind,
    pub provider: ProviderDriverKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_instance_id: Option<ProviderInstanceId>,
    pub thread_id: ThreadId,
    pub created_at: IsoDateTime,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_turn_id: Option<TurnId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<ProviderItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<ApprovalRequestId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_kind: Option<ProviderRequestKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_generation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_thread_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_parent_thread_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_delta: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Value>,
}
