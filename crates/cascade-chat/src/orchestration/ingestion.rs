//! Ported from Synara `apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.ts`: turns
//! provider runtime events into the server-internal commands that build a thread (session state,
//! streamed assistant messages, tool and approval activities, proposed plans, provider diffs).
//!
//! Synara's ingestion is an Effect service that reads the projection and dispatches each command
//! as it goes. Here [`ProviderRuntimeIngestion::ingest`] takes the thread as the read model has it
//! and returns the commands in dispatch order; the caller decides and projects them one by one, in
//! that order, so a later command (an assistant `complete` after its final `delta`) sees the
//! effect of an earlier one, as in Synara. The per-thread buffers (assistant text and its segments,
//! reasoning summaries, tool output, proposed plans, delivery-mode bindings) are this struct's
//! fields; Synara's TTL caches are plain maps cleared at the same points.
//!
//! Not ported: provider-native subagent threads (`ensureSubagentThread`), the durable runtime
//! journal and its replay, worker-activity and in-flight-tool tracking (`touchLastActivity`,
//! `markToolStarted`), computer-control leases, goals, Studio image copies and the persisted
//! generated-image recovery, and marking a source proposed plan implemented. Pending interactions
//! are read from the thread's `pendingInteractions`, or derived from its approval and user-input
//! activities when the read model does not carry them. Whether a thread's workspace is a git
//! repository and whether a provider's live diff can be parsed are asked of
//! [`IngestionEnvironment`].

use std::collections::{BTreeMap, HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::contracts::base::{
    CheckpointRef, CommandId, EventId, IsoDateTime, MessageId, ProviderDriverKind, ThreadId, TurnId,
};
use crate::contracts::orchestration::*;
use crate::contracts::provider_runtime::{
    is_tool_lifecycle_item_type, CanonicalItemType, ContentDeltaPayload, ItemLifecyclePayload,
    ProviderRuntimeEvent, ProviderRuntimeEventBody, RuntimeContentStreamKind, RuntimeItemStatus,
    RuntimeSessionExitKind, RuntimeSessionState, RuntimeTurnState, TurnStartedPayload,
};

use super::activity_projection::{
    js_len, project_provider_runtime_activities, provider_activity_update_dedupe_key,
    provider_activity_update_fingerprint, readable_reasoning_detail, runtime_payload_record,
    runtime_turn_state, wire,
};
use super::decider::{model_selection_instance_id, model_selection_provider, provider_supports_native_turn_steering};

fn provider_turn_key(thread_id: &ThreadId, turn_id: &TurnId) -> String {
    format!("{thread_id}:{turn_id}")
}

fn provider_command_id(event: &ProviderRuntimeEvent, tag: &str, target: &str) -> CommandId {
    CommandId::new(format!("provider:{}:{tag}:{target}", event.event_id))
}

/// Unbound turns stream: only a dispatch that asked for "buffered" holds text until completion.
const DEFAULT_ASSISTANT_DELIVERY_MODE: AssistantDeliveryMode = AssistantDeliveryMode::Streaming;
const MAX_PENDING_GENERATED_IMAGES_PER_TURN: usize = 32;
const MAX_BUFFERED_ASSISTANT_CHARS: usize = 24_000;
const MAX_BUFFERED_PROPOSED_PLAN_CHARS: usize = 64_000;
const MAX_BUFFERED_TOOL_OUTPUT_CHARS: usize = 24_000;
const MAX_BUFFERED_REASONING_SUMMARY_CHARS: usize = 8_000;
const MAX_BUFFERED_REASONING_SUMMARY_PARTS: i64 = 24;
const REASONING_PREVIEW_INTERVAL_MS: i64 = 250;
const BUFFERED_TEXT_TRUNCATION_MARKER: &str = "... [truncated]";
const STRICT_PROVIDER_LIFECYCLE_GUARD: bool = true;

/// What ingestion asks of the world outside the read model (Synara reads the file system and the
/// provider's capabilities). Both answer `false` by default, which skips live provider diffs.
pub struct IngestionEnvironment {
    /// Synara `isGitRepoForThread`.
    pub is_git_repo: Box<dyn Fn(&OrchestrationThread) -> bool + Send + Sync>,
    /// Synara `supportsLiveTurnDiffPatch`: the provider's `turn.diff.updated` is a parseable patch.
    pub supports_live_turn_diff_patch: Box<dyn Fn(&ProviderDriverKind) -> bool + Send + Sync>,
}

impl Default for IngestionEnvironment {
    fn default() -> Self {
        Self { is_git_repo: Box::new(|_| false), supports_live_turn_diff_patch: Box::new(|_| false) }
    }
}

#[derive(Clone, Debug)]
struct BufferedToolOutput {
    text: String,
    truncated: bool,
}

#[derive(Clone, Debug)]
struct BufferedReasoningSummary {
    parts: BTreeMap<i64, String>,
    source_event: ProviderRuntimeEvent,
    created_at: IsoDateTime,
    sequence: Option<u64>,
    last_preview_at: Option<i64>,
}

#[derive(Clone, Debug)]
struct ProviderDiffPlaceholder {
    checkpoint_ref: CheckpointRef,
    checkpoint_turn_count: u64,
    files: Vec<OrchestrationCheckpointFile>,
}

#[derive(Clone, Copy, Debug, Default)]
struct SegmentState {
    has_text: bool,
    split_pending: bool,
}

#[derive(Clone, Debug)]
struct BufferedTextSegment {
    sequence: u64,
    started_at: IsoDateTime,
    text: String,
}

/// An unsettled pending interaction (Synara `ProjectionPendingInteraction`, the fields used here).
#[derive(Clone, Debug, PartialEq, Eq)]
struct PendingRow {
    approval: bool,
    request_id: String,
    turn_id: Option<TurnId>,
    lifecycle_generation: Option<String>,
}

/// Synara `ProviderRuntimeIngestion`: the per-thread aggregation state between runtime events.
#[derive(Default)]
pub struct ProviderRuntimeIngestion {
    pub environment: IngestionEnvironment,
    outstanding_turn_ids_by_thread: HashMap<ThreadId, Vec<TurnId>>,
    pending_modes_by_thread: HashMap<ThreadId, Vec<AssistantDeliveryMode>>,
    unmatched_turn_ids_by_thread: HashMap<ThreadId, Vec<TurnId>>,
    settled_unmatched_request_debt_by_thread: HashMap<ThreadId, u64>,
    assistant_delivery_mode_by_turn_key: HashMap<String, AssistantDeliveryMode>,
    turn_message_ids_by_turn_key: HashMap<String, Vec<MessageId>>,
    buffered_assistant_text_by_message_id: HashMap<MessageId, String>,
    buffered_proposed_plan_by_id: HashMap<String, (String, String)>,
    buffered_tool_output_by_key: HashMap<String, BufferedToolOutput>,
    buffered_reasoning_summary_by_key: BTreeMap<String, BufferedReasoningSummary>,
    claude_reasoning_activity_by_id: HashMap<EventId, OrchestrationThreadActivity>,
    pending_generated_images_by_turn_key: HashMap<String, Vec<String>>,
    latest_activity_update_fingerprint_by_key: HashMap<String, String>,
    provider_diff_placeholders: HashMap<String, ProviderDiffPlaceholder>,
    segment_state_by_thread: HashMap<ThreadId, HashMap<MessageId, SegmentState>>,
    buffered_text_segments_by_message_key: HashMap<String, Vec<BufferedTextSegment>>,
    buffered_text_spilled_by_message_key: HashSet<String>,
    /// The commands of the event being ingested, in dispatch order.
    out: Vec<OrchestrationCommand>,
}

fn dispatch_internal(out: &mut Vec<OrchestrationCommand>, command: InternalThreadCommand) {
    out.push(OrchestrationCommand::Internal(command));
}

/// Synara `appendCappedBufferedText`
pub fn append_capped_buffered_text(existing: &str, delta: &str, limit: usize) -> String {
    if limit == 0 {
        return String::new();
    }
    let next = format!("{existing}{delta}");
    if js_len(&next) <= limit {
        return next;
    }
    let marker_len = js_len(BUFFERED_TEXT_TRUNCATION_MARKER);
    if limit <= marker_len {
        return BUFFERED_TEXT_TRUNCATION_MARKER.chars().take(limit).collect();
    }
    let kept: String = next.chars().take(limit - marker_len).collect();
    format!("{kept}{BUFFERED_TEXT_TRUNCATION_MARKER}")
}

fn item_payload(event: &ProviderRuntimeEvent) -> Option<&ItemLifecyclePayload> {
    match &event.body {
        ProviderRuntimeEventBody::ItemStarted(p)
        | ProviderRuntimeEventBody::ItemUpdated(p)
        | ProviderRuntimeEventBody::ItemCompleted(p) => Some(p),
        _ => None,
    }
}

fn content_delta(event: &ProviderRuntimeEvent) -> Option<&ContentDeltaPayload> {
    match &event.body {
        ProviderRuntimeEventBody::ContentDelta(p) => Some(p),
        _ => None,
    }
}

/// Synara `isRowMakingProviderRuntimeEvent`: an event the timeline draws as its own row, which
/// closes the current assistant text segment.
fn is_row_making_provider_runtime_event(event: &ProviderRuntimeEvent) -> bool {
    use ProviderRuntimeEventBody as B;
    match &event.body {
        B::ItemStarted(p) | B::ItemUpdated(p) | B::ItemCompleted(p) => {
            is_tool_lifecycle_item_type(&wire(&p.item_type)) || p.item_type == CanonicalItemType::ContextCompaction
        }
        B::RuntimeWarning(_) | B::UserInputRequested(_) | B::UserInputResolved(_) => true,
        B::ContentDelta(p) => matches!(
            p.stream_kind,
            RuntimeContentStreamKind::CommandOutput | RuntimeContentStreamKind::FileChangeOutput
        ),
        _ => false,
    }
}

fn assistant_message_segment_key(thread_id: &ThreadId, message_id: &MessageId) -> String {
    serde_json::to_string(&json!([thread_id, message_id])).unwrap_or_default()
}

fn reasoning_summary_buffer_key(event: &ProviderRuntimeEvent, thread_id: &ThreadId) -> Option<String> {
    let provider = event.provider.as_str();
    if !matches!(provider, "codex" | "antigravity" | "claudeAgent") {
        return None;
    }
    let item_id = event.item_id.as_ref()?;
    let key = || {
        format!(
            "{}:{}:{}",
            thread_id,
            event.turn_id.as_ref().map(|t| t.as_str()).unwrap_or("no-turn"),
            item_id
        )
    };
    if let Some(delta) = content_delta(event) {
        let reasoning = delta.stream_kind == RuntimeContentStreamKind::ReasoningSummaryText
            || (matches!(provider, "antigravity" | "claudeAgent")
                && delta.stream_kind == RuntimeContentStreamKind::ReasoningText);
        return reasoning.then(key);
    }
    item_payload(event)
        .filter(|p| p.item_type == CanonicalItemType::Reasoning)
        .map(|_| key())
}

fn joined_buffered_reasoning_summary(summary: Option<&BufferedReasoningSummary>) -> Option<String> {
    let summary = summary?;
    let joined = summary
        .parts
        .values()
        .map(|text| text.trim())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    readable_reasoning_detail(Some(&joined))
}

fn with_buffered_reasoning_summary(
    event: &ProviderRuntimeEvent,
    summary: Option<&BufferedReasoningSummary>,
) -> ProviderRuntimeEvent {
    let ProviderRuntimeEventBody::ItemCompleted(payload) = &event.body else {
        return event.clone();
    };
    if !matches!(event.provider.as_str(), "codex" | "antigravity" | "claudeAgent")
        || payload.item_type != CanonicalItemType::Reasoning
        || readable_reasoning_detail(payload.detail.as_deref()).is_some()
    {
        return event.clone();
    }
    let Some(detail) = joined_buffered_reasoning_summary(summary) else {
        return event.clone();
    };
    let mut next = event.clone();
    next.body = ProviderRuntimeEventBody::ItemCompleted(ItemLifecyclePayload { detail: Some(detail), ..payload.clone() });
    next
}

fn has_non_empty_string(value: Option<&Value>) -> bool {
    value.and_then(Value::as_str).is_some_and(|s| !s.trim().is_empty())
}

fn merge_buffered_tool_output_data(data: Option<&Value>, buffered: &BufferedToolOutput) -> Value {
    let mut base: Map<String, Value> = data.and_then(Value::as_object).cloned().unwrap_or_default();
    let mut raw_output: Map<String, Value> = match base.get("rawOutput") {
        Some(Value::Object(raw)) => raw.clone(),
        Some(Value::String(raw)) if !raw.trim().is_empty() => {
            let mut map = Map::new();
            map.insert("output".into(), json!(raw));
            map
        }
        _ => Map::new(),
    };
    let has_structured_output = has_non_empty_string(raw_output.get("output"))
        || has_non_empty_string(raw_output.get("stdout"))
        || has_non_empty_string(raw_output.get("stderr"));
    if !has_structured_output {
        raw_output.insert("output".into(), json!(buffered.text));
    }
    if buffered.truncated {
        raw_output.insert("truncated".into(), json!(true));
    }
    base.insert("rawOutput".into(), Value::Object(raw_output));
    Value::Object(base)
}

fn with_buffered_tool_output_data(event: &ProviderRuntimeEvent, buffered: Option<&BufferedToolOutput>) -> ProviderRuntimeEvent {
    let Some(buffered) = buffered else { return event.clone() };
    let (payload, completed) = match &event.body {
        ProviderRuntimeEventBody::ItemUpdated(p) => (p, false),
        ProviderRuntimeEventBody::ItemCompleted(p) => (p, true),
        _ => return event.clone(),
    };
    if !matches!(payload.item_type, CanonicalItemType::CommandExecution | CanonicalItemType::FileChange) {
        return event.clone();
    }
    let payload = ItemLifecyclePayload {
        data: Some(merge_buffered_tool_output_data(payload.data.as_ref(), buffered)),
        ..payload.clone()
    };
    let mut next = event.clone();
    next.body = if completed {
        ProviderRuntimeEventBody::ItemCompleted(payload)
    } else {
        ProviderRuntimeEventBody::ItemUpdated(payload)
    };
    next
}

fn normalize_non_empty_string(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn has_renderable_assistant_text(text: &str) -> bool {
    !text.trim().is_empty()
}

fn proposed_plan_id_for_turn(thread_id: &ThreadId, turn_id: &TurnId) -> String {
    format!("plan:{thread_id}:turn:{turn_id}")
}

fn proposed_plan_id_from_event(event: &ProviderRuntimeEvent, thread_id: &ThreadId) -> String {
    if let Some(turn_id) = &event.turn_id {
        return proposed_plan_id_for_turn(thread_id, turn_id);
    }
    if let Some(item_id) = &event.item_id {
        return format!("plan:{thread_id}:item:{item_id}");
    }
    format!("plan:{thread_id}:event:{}", event.event_id)
}

fn infer_runtime_mode_from_user_input_answers(answers: &Map<String, Value>) -> Option<RuntimeMode> {
    let sandbox_mode = answers.get("sandbox_mode").and_then(Value::as_str);
    let approval_policy = answers.get("approval_policy").and_then(Value::as_str);
    match sandbox_mode {
        Some("danger-full-access") => {
            return Some(if approval_policy.is_none_or(|p| p == "never") {
                RuntimeMode::FullAccess
            } else {
                RuntimeMode::ApprovalRequired
            })
        }
        Some("read-only" | "workspace-write") => return Some(RuntimeMode::ApprovalRequired),
        _ => {}
    }
    match approval_policy {
        Some("never") => Some(RuntimeMode::FullAccess),
        Some("untrusted" | "on-failure" | "on-request") => Some(RuntimeMode::ApprovalRequired),
        _ => None,
    }
}

/// Synara `generatedImageMarkdown` / `markdownImagePath` (codexGeneratedImages.ts)
fn generated_image_markdown(file_path: &str) -> String {
    let trimmed = file_path.trim();
    let path = if trimmed.contains(')') || trimmed.contains(' ') || trimmed.contains('%') {
        format!("<{}>", trimmed.replace('%', "%25").replace('>', "%3E").replace(')', "%29"))
    } else {
        trimmed.to_string()
    };
    format!("![Generated image]({path})")
}

/// Synara `generatedImagePathFromRuntimeEvent` (codexGeneratedImages.ts)
fn generated_image_path_from_runtime_event(event: &ProviderRuntimeEvent) -> Option<String> {
    let ProviderRuntimeEventBody::ItemCompleted(payload) = &event.body else { return None };
    if payload.item_type != CanonicalItemType::ImageGeneration {
        return None;
    }
    let data = payload.data.as_ref()?.as_object()?;
    let path = data.get("path")?.as_str()?;
    (data.get("kind").and_then(Value::as_str) == Some(CODEX_GENERATED_IMAGE_ARTIFACT_KIND) && !path.trim().is_empty())
        .then(|| path.to_string())
}

use crate::contracts::provider_runtime::CODEX_GENERATED_IMAGE_ARTIFACT_KIND;

/// Synara `isStartedTurnApplicable` (terminalTurnApplicability.ts): a started event may confirm the
/// active turn, never hand the lifecycle from one active turn to another.
fn is_started_turn_applicable(active_turn_id: Option<&TurnId>, event_turn_id: Option<&TurnId>) -> bool {
    match (active_turn_id, event_turn_id) {
        (Some(active), Some(event)) => active == event,
        _ => true,
    }
}

/// Synara `classifyTerminalTurnApplicability` (terminalTurnApplicability.ts)
#[derive(Clone, Debug, PartialEq, Eq)]
struct TerminalTurnApplicability {
    applicable: bool,
    resolved_turn_id: Option<TurnId>,
    ambiguous: bool,
}

fn classify_terminal_turn_applicability(
    active_turn_id: Option<&TurnId>,
    event_turn_id: Option<&TurnId>,
    has_ambiguous_turns: bool,
) -> TerminalTurnApplicability {
    match (active_turn_id, event_turn_id) {
        (Some(active), Some(event)) => TerminalTurnApplicability {
            applicable: event == active,
            resolved_turn_id: Some(event.clone()),
            ambiguous: false,
        },
        (Some(_), None) if has_ambiguous_turns => {
            TerminalTurnApplicability { applicable: false, resolved_turn_id: None, ambiguous: true }
        }
        (Some(active), None) => TerminalTurnApplicability {
            applicable: true,
            resolved_turn_id: Some(active.clone()),
            ambiguous: false,
        },
        (None, event) => TerminalTurnApplicability { applicable: true, resolved_turn_id: event.cloned(), ambiguous: false },
    }
}

/// Synara `buildStalePendingRequestFailureDetail` (threadSummary.ts)
fn stale_pending_request_failure_detail(request_kind: &str, request_id: &str) -> String {
    format!(
        "Stale pending {request_kind} request: {request_id}. Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
    )
}

/// The thread's unsettled pending interactions (Synara `pendingInteractions.listUnsettled`): its
/// `pendingInteractions` when the read model carries them, else derived from the approval and
/// user-input activities, a request being settled by its resolution or a respond failure.
fn unsettled_pending_interactions(thread: &OrchestrationThread) -> Vec<PendingRow> {
    if let Some(rows) = &thread.pending_interactions {
        return rows
            .iter()
            .filter(|row| {
                !matches!(
                    row.status,
                    ProjectionPendingInteractionStatus::Confirmed | ProjectionPendingInteractionStatus::Uncertain
                )
            })
            .map(|row| PendingRow {
                approval: row.interaction_kind == ProjectionPendingInteractionKind::Approval,
                request_id: row.request_id.to_string(),
                turn_id: row.turn_id.clone(),
                lifecycle_generation: row.lifecycle_generation.clone(),
            })
            .collect();
    }
    let mut rows: Vec<PendingRow> = vec![];
    for activity in &thread.activities {
        let Some(request_id) = activity.payload.get("requestId").and_then(Value::as_str) else { continue };
        match activity.kind.as_str() {
            "approval.requested" | "user-input.requested" => {
                rows.retain(|row| row.request_id != request_id);
                rows.push(PendingRow {
                    approval: activity.kind == "approval.requested",
                    request_id: request_id.to_string(),
                    turn_id: activity.turn_id.clone(),
                    lifecycle_generation: activity
                        .payload
                        .get("lifecycleGeneration")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                });
            }
            "approval.resolved"
            | "user-input.resolved"
            | "provider.approval.respond.failed"
            | "provider.user-input.respond.failed" => rows.retain(|row| row.request_id != request_id),
            _ => {}
        }
    }
    rows
}

fn parse_millis(value: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value).ok().map(|d| d.timestamp_millis())
}

impl ProviderRuntimeIngestion {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_environment(environment: IngestionEnvironment) -> Self {
        Self { environment, ..Self::default() }
    }

    fn dispatch(&mut self, command: InternalThreadCommand) {
        dispatch_internal(&mut self.out, command);
    }

    // --- delivery-mode bindings (request queue ↔ runtime turn lifecycle) ---

    fn match_assistant_delivery_mode_request(&mut self, thread_id: &ThreadId, mode: AssistantDeliveryMode) -> Option<TurnId> {
        let debt = self.settled_unmatched_request_debt_by_thread.get(thread_id).copied().unwrap_or(0);
        if debt > 0 {
            if debt == 1 {
                self.settled_unmatched_request_debt_by_thread.remove(thread_id);
            } else {
                self.settled_unmatched_request_debt_by_thread.insert(thread_id.clone(), debt - 1);
            }
            return None;
        }
        let unmatched = shift_queue(&mut self.unmatched_turn_ids_by_thread, thread_id);
        match &unmatched {
            Some(turn_id) => {
                self.assistant_delivery_mode_by_turn_key.insert(provider_turn_key(thread_id, turn_id), mode);
            }
            None => self.pending_modes_by_thread.entry(thread_id.clone()).or_default().push(mode),
        }
        unmatched
    }

    fn match_started_turn_assistant_delivery_mode(&mut self, thread_id: &ThreadId, turn_id: &TurnId, record_unmatched: bool) {
        let key = provider_turn_key(thread_id, turn_id);
        if self.assistant_delivery_mode_by_turn_key.contains_key(&key) {
            return;
        }
        match shift_queue(&mut self.pending_modes_by_thread, thread_id) {
            Some(mode) => {
                self.assistant_delivery_mode_by_turn_key.insert(key, mode);
            }
            None if !record_unmatched => {
                // A terminated turn must not be claimable by a later, unrelated request.
                let unmatched = self.unmatched_turn_ids_by_thread.entry(thread_id.clone()).or_default();
                let before = unmatched.len();
                unmatched.retain(|t| t != turn_id);
                let removed = unmatched.len() != before;
                if unmatched.is_empty() {
                    self.unmatched_turn_ids_by_thread.remove(thread_id);
                }
                if removed {
                    *self.settled_unmatched_request_debt_by_thread.entry(thread_id.clone()).or_default() += 1;
                }
            }
            None => {
                let unmatched = self.unmatched_turn_ids_by_thread.entry(thread_id.clone()).or_default();
                if !unmatched.contains(turn_id) {
                    unmatched.push(turn_id.clone());
                }
            }
        }
    }

    fn get_assistant_delivery_mode(&self, thread_id: &ThreadId, turn_id: Option<&TurnId>) -> AssistantDeliveryMode {
        turn_id
            .and_then(|turn_id| self.assistant_delivery_mode_by_turn_key.get(&provider_turn_key(thread_id, turn_id)).copied())
            .unwrap_or(DEFAULT_ASSISTANT_DELIVERY_MODE)
    }

    fn clear_assistant_delivery_mode_bindings_for_thread(&mut self, thread_id: &ThreadId) {
        self.pending_modes_by_thread.remove(thread_id);
        self.unmatched_turn_ids_by_thread.remove(thread_id);
        self.settled_unmatched_request_debt_by_thread.remove(thread_id);
    }

    // --- assistant message bookkeeping ---

    fn remember_assistant_message_id(&mut self, thread_id: &ThreadId, turn_id: &TurnId, message_id: &MessageId) {
        let ids = self.turn_message_ids_by_turn_key.entry(provider_turn_key(thread_id, turn_id)).or_default();
        if !ids.contains(message_id) {
            ids.push(message_id.clone());
        }
    }

    fn forget_assistant_message_id(&mut self, thread_id: &ThreadId, turn_id: &TurnId, message_id: &MessageId) {
        let key = provider_turn_key(thread_id, turn_id);
        if let Some(ids) = self.turn_message_ids_by_turn_key.get_mut(&key) {
            ids.retain(|id| id != message_id);
            if ids.is_empty() {
                self.turn_message_ids_by_turn_key.remove(&key);
            }
        }
    }

    fn assistant_message_ids_for_turn(&self, thread_id: &ThreadId, turn_id: &TurnId) -> Vec<MessageId> {
        self.turn_message_ids_by_turn_key
            .get(&provider_turn_key(thread_id, turn_id))
            .cloned()
            .unwrap_or_default()
    }

    /// Returns the spilled text when the buffer outgrows its cap.
    fn append_buffered_assistant_text(&mut self, message_id: &MessageId, delta: &str) -> String {
        let next = format!("{}{delta}", self.buffered_assistant_text_by_message_id.get(message_id).map(String::as_str).unwrap_or(""));
        if js_len(&next) <= MAX_BUFFERED_ASSISTANT_CHARS {
            self.buffered_assistant_text_by_message_id.insert(message_id.clone(), next);
            return String::new();
        }
        self.buffered_assistant_text_by_message_id.remove(message_id);
        next
    }

    fn buffered_assistant_text(&self, message_id: &MessageId) -> String {
        self.buffered_assistant_text_by_message_id.get(message_id).cloned().unwrap_or_default()
    }

    fn clear_assistant_message_state(&mut self, thread_id: &ThreadId, message_id: &MessageId) {
        let segment_key = assistant_message_segment_key(thread_id, message_id);
        self.buffered_text_segments_by_message_key.remove(&segment_key);
        self.buffered_text_spilled_by_message_key.remove(&segment_key);
        if let Some(states) = self.segment_state_by_thread.get_mut(thread_id) {
            states.remove(message_id);
            if states.is_empty() {
                self.segment_state_by_thread.remove(thread_id);
            }
        }
        self.buffered_assistant_text_by_message_id.remove(message_id);
    }

    fn clear_segment_buffers(&mut self, thread_id: &ThreadId, message_id: &MessageId) {
        let segment_key = assistant_message_segment_key(thread_id, message_id);
        self.buffered_text_segments_by_message_key.remove(&segment_key);
        self.buffered_text_spilled_by_message_key.remove(&segment_key);
    }

    fn resolve_assistant_completion_message_id(
        &self,
        event: &ProviderRuntimeEvent,
        thread: &OrchestrationThread,
        turn_id: Option<&TurnId>,
    ) -> MessageId {
        if let Some(turn_id) = turn_id {
            let known = self.assistant_message_ids_for_turn(&thread.id, turn_id);
            if let Some(item_id) = &event.item_id {
                let event_message_id = MessageId::new(format!("assistant:{item_id}"));
                if known.contains(&event_message_id) {
                    return event_message_id;
                }
            }
            if known.len() == 1 {
                return known[0].clone();
            }
            if known.len() > 1 {
                let preferred = thread
                    .messages
                    .iter()
                    .filter(|m| {
                        m.role == OrchestrationMessageRole::Assistant
                            && m.turn_id.as_ref() == Some(turn_id)
                            && known.contains(&m.id)
                    })
                    .min_by(|l, r| {
                        r.streaming
                            .cmp(&l.streaming)
                            .then_with(|| r.created_at.as_str().cmp(l.created_at.as_str()))
                            .then_with(|| r.id.as_str().cmp(l.id.as_str()))
                    });
                if let Some(preferred) = preferred {
                    return preferred.id.clone();
                }
            }
            return match &event.item_id {
                Some(item_id) => MessageId::new(format!("assistant:{item_id}")),
                None => MessageId::new(format!("assistant:{turn_id}")),
            };
        }
        match &event.item_id {
            Some(item_id) => MessageId::new(format!("assistant:{item_id}")),
            None => MessageId::new(format!("assistant:{}", event.event_id)),
        }
    }

    /// Synara `dispatchFinalAssistantTextSegments`: buffered text fans back out per segment so the
    /// projection keeps the interleaved timeline; a spilled buffer flushes as one delta.
    #[allow(clippy::too_many_arguments)]
    fn dispatch_final_assistant_text_segments(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        message_id: &MessageId,
        turn_id: Option<&TurnId>,
        created_at: &IsoDateTime,
        tag_base: &str,
        text: &str,
    ) {
        let segment_key = assistant_message_segment_key(thread_id, message_id);
        let segments = self.buffered_text_segments_by_message_key.get(&segment_key).cloned().unwrap_or_default();
        let spilled = self.buffered_text_spilled_by_message_key.contains(&segment_key);
        if segments.len() > 1 && !spilled {
            for (index, segment) in segments.iter().enumerate() {
                self.dispatch(InternalThreadCommand::MessageAssistantDelta(ThreadMessageAssistantDeltaCommand {
                    command_id: provider_command_id(event, &format!("{tag_base}-segment-{index}"), message_id.as_str()),
                    thread_id: thread_id.clone(),
                    message_id: message_id.clone(),
                    delta: segment.text.clone(),
                    turn_id: turn_id.cloned(),
                    segment_started_at: Some(segment.started_at.clone()),
                    segment_sequence: Some(segment.sequence),
                    created_at: created_at.clone(),
                }));
            }
        } else {
            let first = if spilled { None } else { segments.first() };
            self.dispatch(InternalThreadCommand::MessageAssistantDelta(ThreadMessageAssistantDeltaCommand {
                command_id: provider_command_id(event, tag_base, message_id.as_str()),
                thread_id: thread_id.clone(),
                message_id: message_id.clone(),
                delta: text.to_string(),
                turn_id: turn_id.cloned(),
                segment_started_at: first.map(|s| s.started_at.clone()),
                segment_sequence: first.map(|s| s.sequence),
                created_at: created_at.clone(),
            }));
        }
        self.clear_segment_buffers(thread_id, message_id);
    }

    fn flush_buffered_assistant_message_delta(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        message_id: &MessageId,
        turn_id: Option<&TurnId>,
        created_at: &IsoDateTime,
        command_tag: &str,
    ) -> bool {
        let buffered = self.buffered_assistant_text(message_id);
        if !has_renderable_assistant_text(&buffered) {
            self.clear_segment_buffers(thread_id, message_id);
            return false;
        }
        self.dispatch_final_assistant_text_segments(event, thread_id, message_id, turn_id, created_at, command_tag, &buffered);
        self.buffered_assistant_text_by_message_id.remove(message_id);
        true
    }

    fn flush_buffered_assistant_messages_for_turn(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        turn_id: &TurnId,
        created_at: &IsoDateTime,
        command_tag: &str,
    ) {
        for message_id in self.assistant_message_ids_for_turn(thread_id, turn_id) {
            self.flush_buffered_assistant_message_delta(event, thread_id, &message_id, Some(turn_id), created_at, command_tag);
        }
    }

    fn finalize_buffered_assistant_messages_for_turn(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        turn_id: &TurnId,
        created_at: &IsoDateTime,
        command_tag: &str,
        final_delta_command_tag: &str,
    ) {
        for message_id in self.assistant_message_ids_for_turn(thread_id, turn_id) {
            self.finalize_assistant_message(event, thread_id, &message_id, Some(turn_id), created_at, command_tag, final_delta_command_tag, None, None);
        }
        self.turn_message_ids_by_turn_key.remove(&provider_turn_key(thread_id, turn_id));
    }

    #[allow(clippy::too_many_arguments)]
    fn finalize_assistant_message(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        message_id: &MessageId,
        turn_id: Option<&TurnId>,
        created_at: &IsoDateTime,
        command_tag: &str,
        final_delta_command_tag: &str,
        fallback_text: Option<&str>,
        async_questions: Option<&AsyncUserInputQuestions>,
    ) {
        let buffered = self.buffered_assistant_text(message_id);
        let text = if !buffered.is_empty() {
            buffered
        } else {
            fallback_text.filter(|t| !t.trim().is_empty()).unwrap_or("").to_string()
        };
        if has_renderable_assistant_text(&text) {
            self.dispatch_final_assistant_text_segments(event, thread_id, message_id, turn_id, created_at, final_delta_command_tag, &text);
        } else {
            self.clear_segment_buffers(thread_id, message_id);
        }
        self.dispatch(InternalThreadCommand::MessageAssistantComplete(ThreadMessageAssistantCompleteCommand {
            async_questions: async_questions.cloned(),
            command_id: provider_command_id(event, command_tag, message_id.as_str()),
            thread_id: thread_id.clone(),
            message_id: message_id.clone(),
            turn_id: turn_id.cloned(),
            created_at: created_at.clone(),
        }));
        self.clear_assistant_message_state(thread_id, message_id);
    }

    /// Synara `appendGeneratedImagesToAssistantMessage`
    #[allow(clippy::too_many_arguments)]
    fn append_generated_images_to_assistant_message(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        target_message: Option<&OrchestrationMessage>,
        new_message_id: MessageId,
        image_paths: &[String],
        turn_id: Option<&TurnId>,
        created_at: &IsoDateTime,
    ) {
        let target_id = target_message.map(|m| m.id.clone()).unwrap_or(new_message_id);
        let target_text = target_message.map(|m| m.text.as_str()).unwrap_or("");
        let target_is_streaming = target_message.is_some_and(|m| m.streaming);
        let mut missing: Vec<String> = vec![];
        for path in image_paths {
            let markdown = generated_image_markdown(path);
            if target_text.contains(path.as_str()) || target_text.contains(&markdown) || missing.contains(&markdown) {
                continue;
            }
            missing.push(markdown);
        }
        let mut dispatched_delta = false;
        if !missing.is_empty() {
            let joined = missing.join("\n\n");
            self.dispatch(InternalThreadCommand::MessageAssistantDelta(ThreadMessageAssistantDeltaCommand {
                command_id: provider_command_id(event, "generated-image-delta", target_id.as_str()),
                thread_id: thread_id.clone(),
                message_id: target_id.clone(),
                delta: if target_text.trim().is_empty() { joined } else { format!("\n\n{joined}") },
                turn_id: turn_id.cloned(),
                segment_started_at: None,
                segment_sequence: None,
                created_at: created_at.clone(),
            }));
            dispatched_delta = true;
        }
        if dispatched_delta || target_message.is_none() || target_is_streaming {
            self.dispatch(InternalThreadCommand::MessageAssistantComplete(ThreadMessageAssistantCompleteCommand {
                async_questions: None,
                command_id: provider_command_id(event, "generated-image-complete", target_id.as_str()),
                thread_id: thread_id.clone(),
                message_id: target_id,
                turn_id: turn_id.cloned(),
                created_at: created_at.clone(),
            }));
        }
    }

    fn remember_pending_generated_image(&mut self, thread_id: &ThreadId, turn_id: &TurnId, path: &str) {
        let paths = self.pending_generated_images_by_turn_key.entry(provider_turn_key(thread_id, turn_id)).or_default();
        if !paths.iter().any(|p| p == path) && paths.len() < MAX_PENDING_GENERATED_IMAGES_PER_TURN {
            paths.push(path.to_string());
        }
    }

    /// Synara `flushPendingGeneratedImagesForTurn`: the turn's images go to its terminal
    /// assistant message (the persisted-record recovery is not ported).
    fn flush_pending_generated_images_for_turn(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread: &OrchestrationThread,
        turn_id: &TurnId,
        created_at: &IsoDateTime,
    ) {
        let paths = self.pending_generated_images_by_turn_key.remove(&provider_turn_key(&thread.id, turn_id)).unwrap_or_default();
        if paths.is_empty() {
            return;
        }
        let terminal = thread
            .messages
            .iter()
            .filter(|m| m.role == OrchestrationMessageRole::Assistant && m.turn_id.as_ref() == Some(turn_id))
            .max_by(|l, r| {
                l.created_at.as_str().cmp(r.created_at.as_str()).then_with(|| l.id.as_str().cmp(r.id.as_str()))
            });
        self.append_generated_images_to_assistant_message(
            event,
            &thread.id,
            terminal,
            MessageId::new(format!("assistant:image:{turn_id}")),
            &paths,
            Some(turn_id),
            created_at,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn upsert_proposed_plan(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        thread_proposed_plans: &[OrchestrationProposedPlan],
        plan_id: &str,
        turn_id: Option<&TurnId>,
        plan_markdown: Option<&str>,
        created_at: &IsoDateTime,
        updated_at: &IsoDateTime,
    ) {
        let Some(plan_markdown) = normalize_non_empty_string(plan_markdown) else { return };
        let existing = thread_proposed_plans.iter().find(|p| p.id == plan_id);
        self.dispatch(InternalThreadCommand::ProposedPlanUpsert(ThreadProposedPlanUpsertCommand {
            command_id: provider_command_id(event, "proposed-plan-upsert", plan_id),
            thread_id: thread_id.clone(),
            proposed_plan: OrchestrationProposedPlan {
                id: plan_id.to_string(),
                turn_id: turn_id.cloned(),
                plan_markdown,
                implemented_at: existing.and_then(|p| p.implemented_at.clone()),
                implementation_thread_id: existing.and_then(|p| p.implementation_thread_id.clone()),
                created_at: existing.map(|p| p.created_at.clone()).unwrap_or_else(|| created_at.clone()),
                updated_at: updated_at.clone(),
            },
            created_at: updated_at.clone(),
        }));
    }

    #[allow(clippy::too_many_arguments)]
    fn finalize_buffered_proposed_plan(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread_id: &ThreadId,
        thread_proposed_plans: &[OrchestrationProposedPlan],
        plan_id: &str,
        turn_id: Option<&TurnId>,
        fallback_markdown: Option<&str>,
        updated_at: &IsoDateTime,
    ) {
        let buffered = self.buffered_proposed_plan_by_id.remove(plan_id);
        let markdown = normalize_non_empty_string(buffered.as_ref().map(|(text, _)| text.as_str()))
            .or_else(|| normalize_non_empty_string(fallback_markdown));
        let Some(markdown) = markdown else { return };
        let created_at = buffered
            .as_ref()
            .map(|(_, at)| at.as_str())
            .filter(|at| !at.is_empty())
            .map(IsoDateTime::new)
            .unwrap_or_else(|| updated_at.clone());
        self.upsert_proposed_plan(event, thread_id, thread_proposed_plans, plan_id, turn_id, Some(&markdown), &created_at, updated_at);
    }

    fn clear_turn_state_for_session(&mut self, thread_id: &ThreadId) {
        let prefix = format!("{thread_id}:");
        let keys: Vec<String> = self.turn_message_ids_by_turn_key.keys().filter(|k| k.starts_with(&prefix)).cloned().collect();
        for key in keys {
            for message_id in self.turn_message_ids_by_turn_key.remove(&key).unwrap_or_default() {
                self.clear_assistant_message_state(thread_id, &message_id);
            }
        }
        let plan_prefix = format!("plan:{thread_id}:");
        self.buffered_proposed_plan_by_id.retain(|key, _| !key.starts_with(&plan_prefix));
        self.pending_generated_images_by_turn_key.retain(|key, _| !key.starts_with(&prefix));
    }

    fn settle_unanswerable_pending_interactions(
        &mut self,
        thread: &OrchestrationThread,
        event: &ProviderRuntimeEvent,
        now: &IsoDateTime,
        scope: impl Fn(&PendingRow) -> bool,
    ) {
        for row in unsettled_pending_interactions(thread).into_iter().filter(|row| scope(row)) {
            let request_kind = if row.approval { "approval" } else { "user-input" };
            let command_id = provider_command_id(event, &format!("stale-pending-{request_kind}"), &row.request_id);
            let mut payload = Map::new();
            payload.insert("detail".into(), json!(stale_pending_request_failure_detail(request_kind, &row.request_id)));
            payload.insert("requestId".into(), json!(row.request_id));
            if let Some(generation) = row.lifecycle_generation.as_deref().filter(|g| !g.is_empty()) {
                payload.insert("lifecycleGeneration".into(), json!(generation));
            }
            self.dispatch(InternalThreadCommand::ActivityAppend(ThreadActivityAppendCommand {
                require_unarchived: None,
                command_id: command_id.clone(),
                thread_id: thread.id.clone(),
                activity: OrchestrationThreadActivity {
                    id: EventId::new(command_id.as_str()),
                    tone: OrchestrationThreadActivityTone::Error,
                    kind: if row.approval { "provider.approval.respond.failed" } else { "provider.user-input.respond.failed" }.into(),
                    summary: if row.approval { "Provider approval response failed" } else { "Provider user input response failed" }.into(),
                    payload: Value::Object(payload),
                    turn_id: None,
                    sequence: None,
                    created_at: now.clone(),
                },
                created_at: now.clone(),
            }));
        }
    }

    /// Synara `dispatchActivityUpdate`: append an activity unless it repeats the last update
    /// under the same dedupe key; a Claude reasoning row keeps its first position and never
    /// reopens once final.
    fn dispatch_activity_update(
        &mut self,
        event: &ProviderRuntimeEvent,
        thread: &OrchestrationThread,
        mut activity: OrchestrationThreadActivity,
    ) {
        let is_claude_reasoning = event.provider.as_str() == "claudeAgent"
            && matches!(&event.body, ProviderRuntimeEventBody::ItemUpdated(p) | ProviderRuntimeEventBody::ItemCompleted(p) if p.item_type == CanonicalItemType::Reasoning);
        if is_claude_reasoning {
            let previous = self
                .claude_reasoning_activity_by_id
                .get(&activity.id)
                .cloned()
                .or_else(|| thread.activities.iter().find(|a| a.id == activity.id).cloned());
            if let Some(previous) = previous {
                self.claude_reasoning_activity_by_id.insert(activity.id.clone(), previous.clone());
                let previous_status = previous.payload.get("status").and_then(Value::as_str);
                let status = activity.payload.get("status").and_then(Value::as_str);
                if previous_status == Some("failed") || (previous_status == Some("completed") && status != Some("completed")) {
                    return;
                }
                activity.created_at = previous.created_at.clone();
                activity.sequence = previous.sequence;
            }
        }
        let key = provider_activity_update_dedupe_key(event, &thread.id, &activity);
        let fingerprint = key.as_ref().map(|_| provider_activity_update_fingerprint(&activity));
        if let (Some(key), Some(fingerprint)) = (&key, &fingerprint) {
            if self.latest_activity_update_fingerprint_by_key.get(key) == Some(fingerprint) {
                return;
            }
        }
        self.dispatch(InternalThreadCommand::ActivityAppend(ThreadActivityAppendCommand {
            require_unarchived: None,
            command_id: provider_command_id(
                event,
                "thread-activity-append",
                &format!("{}:{}:{}", thread.id, activity.kind, activity.id),
            ),
            thread_id: thread.id.clone(),
            created_at: activity.created_at.clone(),
            activity: activity.clone(),
        }));
        if is_claude_reasoning {
            self.claude_reasoning_activity_by_id.insert(activity.id.clone(), activity);
        }
        if let (Some(key), Some(fingerprint)) = (key, fingerprint) {
            self.latest_activity_update_fingerprint_by_key.insert(key, fingerprint);
        }
    }

    fn append_buffered_reasoning_summary(&mut self, key: &str, event: &ProviderRuntimeEvent, delta: &ContentDeltaPayload, sequence: u64) {
        let summary_index = delta.summary_index.unwrap_or(0);
        if !(0..MAX_BUFFERED_REASONING_SUMMARY_PARTS).contains(&summary_index) || delta.delta.is_empty() {
            return;
        }
        let existing = self.buffered_reasoning_summary_by_key.get(key);
        let mut parts = existing.map(|s| s.parts.clone()).unwrap_or_default();
        let other_chars: usize = parts.iter().filter(|(i, _)| **i != summary_index).map(|(_, t)| js_len(t)).sum();
        let part_limit = MAX_BUFFERED_REASONING_SUMMARY_CHARS.saturating_sub(other_chars);
        if part_limit == 0 {
            return;
        }
        let existing_part = parts.get(&summary_index).cloned().unwrap_or_default();
        parts.insert(summary_index, append_capped_buffered_text(&existing_part, &delta.delta, part_limit));
        let summary = BufferedReasoningSummary {
            parts,
            source_event: event.clone(),
            created_at: existing.map(|s| s.created_at.clone()).unwrap_or_else(|| event.created_at.clone()),
            sequence: existing.map(|s| s.sequence).unwrap_or(Some(sequence)),
            last_preview_at: existing.and_then(|s| s.last_preview_at),
        };
        self.buffered_reasoning_summary_by_key.insert(key.to_string(), summary);
    }

    /// One stable reasoning row while Claude thinks, without a write per token.
    fn publish_reasoning_preview(&mut self, key: &str, thread: &OrchestrationThread) {
        let Some(summary) = self.buffered_reasoning_summary_by_key.get(key).cloned() else { return };
        if summary.source_event.provider.as_str() != "claudeAgent" {
            return;
        }
        let preview_at = parse_millis(summary.source_event.created_at.as_str()).unwrap_or(0);
        if summary.last_preview_at.is_some_and(|last| preview_at - last < REASONING_PREVIEW_INTERVAL_MS) {
            return;
        }
        let Some(detail) = joined_buffered_reasoning_summary(Some(&summary)) else { return };
        let mut preview = summary.source_event.clone();
        preview.created_at = summary.created_at.clone();
        preview.body = ProviderRuntimeEventBody::ItemUpdated(ItemLifecyclePayload {
            async_questions: None,
            item_type: CanonicalItemType::Reasoning,
            status: Some(RuntimeItemStatus::InProgress),
            title: None,
            detail: Some(detail),
            data: None,
        });
        for activity in project_provider_runtime_activities(&preview, summary.sequence) {
            self.dispatch_activity_update(&preview, thread, activity);
        }
        if let Some(stored) = self.buffered_reasoning_summary_by_key.get_mut(key) {
            stored.last_preview_at = Some(preview_at);
        }
    }

    fn settle_buffered_reasoning_summaries(
        &mut self,
        thread: &OrchestrationThread,
        terminal_event: &ProviderRuntimeEvent,
        turn_id: Option<&TurnId>,
    ) {
        let prefix = match turn_id {
            Some(turn_id) => format!("{}:{}:", thread.id, turn_id),
            None => format!("{}:", thread.id),
        };
        use ProviderRuntimeEventBody as B;
        let failed = match &terminal_event.body {
            B::RuntimeError(_) | B::TurnAborted(_) => true,
            B::TurnCompleted(p) => p.state != RuntimeTurnState::Completed,
            B::SessionExited(p) => p.exit_kind == Some(RuntimeSessionExitKind::Error),
            _ => false,
        };
        let keys: Vec<String> = self
            .buffered_reasoning_summary_by_key
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        for key in keys {
            let Some(summary) = self.buffered_reasoning_summary_by_key.remove(&key) else { continue };
            let Some(detail) = joined_buffered_reasoning_summary(Some(&summary)) else { continue };
            let Some(item_id) = summary.source_event.item_id.clone() else { continue };
            let is_claude = summary.source_event.provider.as_str() == "claudeAgent";
            let mut completion = summary.source_event.clone();
            completion.event_id = EventId::new(format!("{}:reasoning:{}", terminal_event.event_id, item_id));
            completion.thread_id = thread.id.clone();
            if is_claude {
                completion.created_at = summary.created_at.clone();
            }
            completion.body = B::ItemCompleted(ItemLifecyclePayload {
                async_questions: None,
                item_type: CanonicalItemType::Reasoning,
                status: Some(if failed { RuntimeItemStatus::Failed } else { RuntimeItemStatus::Completed }),
                title: Some("Reasoning".into()),
                detail: Some(detail),
                data: None,
            });
            let sequence = if is_claude { summary.sequence } else { None };
            for activity in project_provider_runtime_activities(&completion, sequence) {
                self.dispatch_activity_update(&completion, thread, activity);
            }
        }
    }

    /// Synara `processRuntimeEvent`: the commands one provider runtime event produces for
    /// `thread`, in dispatch order. `runtime_sequence` is the event's position in the provider
    /// runtime stream (Synara's journal sequence): it orders activities and text segments.
    pub fn ingest(
        &mut self,
        thread: &OrchestrationThread,
        event: &ProviderRuntimeEvent,
        runtime_sequence: u64,
    ) -> Vec<OrchestrationCommand> {
        self.out.clear();
        self.process_runtime_event(thread, event, runtime_sequence);
        std::mem::take(&mut self.out)
    }

    fn process_runtime_event(&mut self, thread: &OrchestrationThread, event: &ProviderRuntimeEvent, runtime_sequence: u64) {
        use ProviderRuntimeEventBody as B;
        let now = &event.created_at;

        if is_row_making_provider_runtime_event(event) {
            if let Some(states) = self.segment_state_by_thread.get_mut(&thread.id) {
                for state in states.values_mut().filter(|s| s.has_text) {
                    state.split_pending = true;
                }
            }
        }
        let active_turn_id = thread.session.as_ref().and_then(|s| s.active_turn_id.clone());
        let is_terminal_turn_event = matches!(event.body, B::TurnCompleted(_) | B::TurnAborted(_));
        let raw_event_turn_id = event.turn_id.clone();
        if let (B::TurnStarted(_), Some(turn_id)) = (&event.body, &raw_event_turn_id) {
            let outstanding = self.outstanding_turn_ids_by_thread.entry(thread.id.clone()).or_default();
            if !outstanding.contains(turn_id) {
                outstanding.push(turn_id.clone());
            }
        }
        let has_ambiguous_turns = is_terminal_turn_event
            && self.outstanding_turn_ids_by_thread.get(&thread.id).map_or(0, Vec::len) > 1;
        let terminal_applicability = is_terminal_turn_event.then(|| {
            classify_terminal_turn_applicability(active_turn_id.as_ref(), raw_event_turn_id.as_ref(), has_ambiguous_turns)
        });
        let event_turn_id = match &terminal_applicability {
            Some(applicability) if applicability.resolved_turn_id.is_some() => applicability.resolved_turn_id.clone(),
            _ => raw_event_turn_id.clone(),
        };

        let should_apply_thread_lifecycle = match &event.body {
            B::TurnStarted(_) => {
                !STRICT_PROVIDER_LIFECYCLE_GUARD
                    || is_started_turn_applicable(active_turn_id.as_ref(), event_turn_id.as_ref())
            }
            _ => !is_terminal_turn_event || terminal_applicability.as_ref().is_none_or(|a| a.applicable),
        };
        if is_terminal_turn_event {
            if let Some(turn_id) = &event_turn_id {
                if let Some(outstanding) = self.outstanding_turn_ids_by_thread.get_mut(&thread.id) {
                    outstanding.retain(|t| t != turn_id);
                    if outstanding.is_empty() {
                        self.outstanding_turn_ids_by_thread.remove(&thread.id);
                    }
                }
            }
        }
        // Even a turn.started that cannot replace the active lifecycle binds one queued delivery.
        if let (B::TurnStarted(_), Some(turn_id)) = (&event.body, &event_turn_id) {
            self.match_started_turn_assistant_delivery_mode(&thread.id, turn_id, true);
        }
        if let (true, Some(turn_id)) = (is_terminal_turn_event, &event_turn_id) {
            self.match_started_turn_assistant_delivery_mode(&thread.id, turn_id, false);
        }

        if matches!(event.body, B::SessionStarted(_)) {
            self.settle_unanswerable_pending_interactions(thread, event, now, |_| true);
        }

        if matches!(
            event.body,
            B::SessionStarted(_)
                | B::SessionStateChanged(_)
                | B::SessionExited(_)
                | B::ThreadStarted(_)
                | B::TurnStarted(_)
                | B::TurnCompleted(_)
                | B::TurnAborted(_)
        ) {
            let mut next_active_turn_id = active_turn_id.clone();
            match &event.body {
                B::TurnStarted(_) => next_active_turn_id = event_turn_id.clone(),
                B::TurnCompleted(_) | B::TurnAborted(_) | B::SessionExited(_) => next_active_turn_id = None,
                B::SessionStateChanged(p)
                    if matches!(p.state, RuntimeSessionState::Ready | RuntimeSessionState::Stopped | RuntimeSessionState::Error) =>
                {
                    next_active_turn_id = None
                }
                _ => {}
            }
            use OrchestrationSessionStatus as S;
            let status = match &event.body {
                B::SessionStateChanged(p) => match p.state {
                    RuntimeSessionState::Waiting | RuntimeSessionState::Running => S::Running,
                    RuntimeSessionState::Starting => S::Starting,
                    RuntimeSessionState::Ready => S::Ready,
                    RuntimeSessionState::Stopped => S::Stopped,
                    RuntimeSessionState::Error => S::Error,
                },
                B::TurnStarted(_) => S::Running,
                B::SessionExited(_) => S::Stopped,
                B::TurnCompleted(_) => match runtime_turn_state(event) {
                    RuntimeTurnState::Failed => S::Error,
                    RuntimeTurnState::Interrupted | RuntimeTurnState::Cancelled => S::Interrupted,
                    RuntimeTurnState::Completed => S::Ready,
                },
                B::TurnAborted(_) => S::Interrupted,
                // Start notifications can arrive during an active turn.
                _ => {
                    if active_turn_id.is_some() {
                        S::Running
                    } else {
                        S::Ready
                    }
                }
            };
            let mut last_error = thread.session.as_ref().and_then(|s| s.last_error.clone());
            match &event.body {
                B::SessionStateChanged(p) if p.state == RuntimeSessionState::Error => {
                    last_error = p.reason.clone().or(last_error).or_else(|| Some("Provider session error".into()));
                }
                _ if status == S::Error => {
                    last_error = runtime_payload_record(event)
                        .and_then(|p| p.get("errorMessage").and_then(Value::as_str).map(str::to_string))
                        .or(last_error)
                        .or_else(|| Some("Turn failed".into()));
                }
                _ if matches!(status, S::Ready | S::Interrupted) => last_error = None,
                _ => {}
            }
            if should_apply_thread_lifecycle {
                self.dispatch(InternalThreadCommand::SessionSet(ThreadSessionSetCommand {
                    command_id: provider_command_id(event, "thread-session-set", thread.id.as_str()),
                    thread_id: thread.id.clone(),
                    session: self.session_for(thread, event, status, next_active_turn_id, last_error),
                    expected_session_status: None,
                    expected_session_updated_at: None,
                    created_at: now.clone(),
                }));
            }
        }

        // A turn or session that ends without a restart takes its provider callbacks with it.
        // Claude settles its own requests from the callback owner.
        let has_parent_ref = event
            .provider_refs
            .as_ref()
            .and_then(|r| r.provider_parent_thread_id.as_deref())
            .is_some_and(|p| !p.is_empty());
        if event.provider.as_str() != "claudeAgent" && !has_parent_ref && is_terminal_turn_event && event_turn_id.is_some() {
            let settles_turnless_rows = self.outstanding_turn_ids_by_thread.get(&thread.id).is_none_or(Vec::is_empty);
            let terminal_generation = event.lifecycle_generation.clone();
            let terminal_turn = event_turn_id.clone();
            self.settle_unanswerable_pending_interactions(thread, event, now, |row| {
                row.turn_id == terminal_turn
                    || (row.turn_id.is_none()
                        && settles_turnless_rows
                        && (terminal_generation.is_none()
                            || row.lifecycle_generation.is_none()
                            || row.lifecycle_generation == terminal_generation))
            });
        } else if should_apply_thread_lifecycle && matches!(event.body, B::SessionExited(_)) {
            let exited_generation = event.lifecycle_generation.clone();
            self.settle_unanswerable_pending_interactions(thread, event, now, |row| {
                exited_generation.is_none() || row.lifecycle_generation == exited_generation
            });
        }

        if let B::UserInputResolved(payload) = &event.body {
            if let Some(mode) = infer_runtime_mode_from_user_input_answers(&payload.answers) {
                if mode != thread.runtime_mode {
                    self.out.push(OrchestrationCommand::Client(ClientThreadCommand::RuntimeModeSet(
                        ThreadRuntimeModeSetCommand {
                            command_id: provider_command_id(event, "thread-runtime-mode-set", thread.id.as_str()),
                            thread_id: thread.id.clone(),
                            runtime_mode: mode,
                            created_at: now.clone(),
                        },
                    )));
                }
            }
        }

        let tool_output_key = event.item_id.as_ref().map(|item_id| {
            format!(
                "{}:{}:{}",
                event.thread_id,
                event.turn_id.as_ref().map(|t| t.as_str()).unwrap_or("no-turn"),
                item_id
            )
        });
        if let (Some(key), Some(delta)) = (&tool_output_key, content_delta(event)) {
            if matches!(delta.stream_kind, RuntimeContentStreamKind::CommandOutput | RuntimeContentStreamKind::FileChangeOutput)
                && !delta.delta.is_empty()
            {
                let existing = self.buffered_tool_output_by_key.get(key).cloned();
                let existing_text = existing.as_ref().map(|e| e.text.as_str()).unwrap_or("");
                let truncated = js_len(existing_text) + js_len(&delta.delta) > MAX_BUFFERED_TOOL_OUTPUT_CHARS;
                self.buffered_tool_output_by_key.insert(
                    key.clone(),
                    BufferedToolOutput {
                        text: append_capped_buffered_text(existing_text, &delta.delta, MAX_BUFFERED_TOOL_OUTPUT_CHARS),
                        truncated: existing.is_some_and(|e| e.truncated) || truncated,
                    },
                );
            }
        }

        let reasoning_summary_key = reasoning_summary_buffer_key(event, &thread.id);
        if let (Some(key), Some(delta)) = (&reasoning_summary_key, content_delta(event)) {
            if !delta.delta.is_empty() {
                self.append_buffered_reasoning_summary(key, event, delta, runtime_sequence);
                self.publish_reasoning_preview(key, thread);
            }
        }

        if let Some(delta) = content_delta(event)
            .filter(|d| d.stream_kind == RuntimeContentStreamKind::AssistantText && !d.delta.is_empty())
            .map(|d| d.delta.clone())
        {
            self.ingest_assistant_delta(thread, event, &delta, active_turn_id.as_ref(), runtime_sequence);
        }

        if let B::TurnProposedDelta(payload) = &event.body {
            if !payload.delta.is_empty() {
                let plan_id = proposed_plan_id_from_event(event, &thread.id);
                let entry = self.buffered_proposed_plan_by_id.entry(plan_id).or_insert_with(|| (String::new(), String::new()));
                entry.0 = append_capped_buffered_text(&entry.0, &payload.delta, MAX_BUFFERED_PROPOSED_PLAN_CHARS);
                if entry.1.is_empty() {
                    entry.1 = now.to_string();
                }
            }
        }

        if let B::ItemCompleted(payload) = &event.body {
            if payload.item_type == CanonicalItemType::AssistantMessage {
                let async_questions = if thread.parent_thread_id.is_none() { payload.async_questions.as_ref() } else { None };
                let turn_id = event.turn_id.clone();
                let message_id = match (async_questions, &event.item_id) {
                    (Some(_), Some(item_id)) => MessageId::new(format!("assistant:{item_id}")),
                    _ => self.resolve_assistant_completion_message_id(event, thread, turn_id.as_ref()),
                };
                let existing = thread.messages.iter().find(|m| m.id == message_id);
                let apply_fallback = existing.is_none_or(|m| m.text.is_empty());
                if let Some(turn_id) = &turn_id {
                    self.remember_assistant_message_id(&thread.id, turn_id, &message_id);
                }
                self.finalize_assistant_message(
                    event,
                    &thread.id,
                    &message_id,
                    turn_id.as_ref(),
                    now,
                    "assistant-complete",
                    "assistant-delta-finalize",
                    if apply_fallback { payload.detail.as_deref() } else { None },
                    async_questions,
                );
                if let Some(turn_id) = &turn_id {
                    self.forget_assistant_message_id(&thread.id, turn_id, &message_id);
                }
            }
        }

        if let B::TurnProposedCompleted(payload) = &event.body {
            let plan_id = proposed_plan_id_from_event(event, &thread.id);
            self.finalize_buffered_proposed_plan(
                event,
                &thread.id,
                &thread.proposed_plans,
                &plan_id,
                event.turn_id.as_ref(),
                Some(&payload.plan_markdown),
                now,
            );
        }

        if let Some(image_path) = generated_image_path_from_runtime_event(event) {
            let image_turn_id = event.turn_id.clone().or_else(|| active_turn_id.clone());
            match &image_turn_id {
                // Deferred to turn settle; the work row shows progress meanwhile.
                Some(turn_id) => self.remember_pending_generated_image(&thread.id, turn_id, &image_path),
                None => {
                    let same_item = event.item_id.as_ref().map(|i| MessageId::new(format!("assistant:{i}")));
                    let markdown = generated_image_markdown(&image_path);
                    let target = thread.messages.iter().find(|m| {
                        m.role == OrchestrationMessageRole::Assistant
                            && (Some(&m.id) == same_item.as_ref() || m.text.contains(&image_path) || m.text.contains(&markdown))
                    });
                    let new_id = MessageId::new(format!(
                        "assistant:image:{}",
                        event.item_id.as_ref().map(|i| i.as_str()).unwrap_or(event.event_id.as_str())
                    ));
                    self.append_generated_images_to_assistant_message(event, &thread.id, target, new_id, &[image_path], None, now);
                }
            }
        }

        if is_terminal_turn_event {
            if let Some(turn_id) = event_turn_id.clone().or_else(|| active_turn_id.clone()) {
                for message_id in self.assistant_message_ids_for_turn(&thread.id, &turn_id) {
                    self.finalize_assistant_message(
                        event,
                        &thread.id,
                        &message_id,
                        Some(&turn_id),
                        now,
                        "assistant-complete-finalize",
                        "assistant-delta-finalize-fallback",
                        None,
                        None,
                    );
                }
                self.turn_message_ids_by_turn_key.remove(&provider_turn_key(&thread.id, &turn_id));
                self.flush_pending_generated_images_for_turn(event, thread, &turn_id, now);
                self.finalize_buffered_proposed_plan(
                    event,
                    &thread.id,
                    &thread.proposed_plans,
                    &proposed_plan_id_for_turn(&thread.id, &turn_id),
                    Some(&turn_id),
                    None,
                    now,
                );
                self.provider_diff_placeholders.remove(&provider_turn_key(&thread.id, &turn_id));
            }
        }

        if matches!(event.body, B::SessionExited(_)) {
            self.outstanding_turn_ids_by_thread.remove(&thread.id);
            if let Some(turn_id) = event_turn_id.clone().or_else(|| active_turn_id.clone()) {
                self.finalize_buffered_assistant_messages_for_turn(
                    event,
                    &thread.id,
                    &turn_id,
                    now,
                    "assistant-complete-session-exit",
                    "assistant-delta-session-exit",
                );
                self.flush_pending_generated_images_for_turn(event, thread, &turn_id, now);
                self.provider_diff_placeholders.remove(&provider_turn_key(&thread.id, &turn_id));
            }
            self.clear_turn_state_for_session(&thread.id);
        }

        if let B::RuntimeError(payload) = &event.body {
            let message = if payload.message.is_empty() { "Provider runtime error".to_string() } else { payload.message.clone() };
            if let Some(turn_id) = event_turn_id.clone().or_else(|| active_turn_id.clone()) {
                self.finalize_buffered_assistant_messages_for_turn(
                    event,
                    &thread.id,
                    &turn_id,
                    now,
                    "assistant-complete-runtime-error",
                    "assistant-delta-runtime-error",
                );
                self.flush_pending_generated_images_for_turn(event, thread, &turn_id, now);
                self.provider_diff_placeholders.remove(&provider_turn_key(&thread.id, &turn_id));
            }
            let should_apply = !STRICT_PROVIDER_LIFECYCLE_GUARD
                || active_turn_id.is_none()
                || event_turn_id.is_none()
                || active_turn_id == event_turn_id;
            if should_apply {
                self.dispatch(InternalThreadCommand::SessionSet(ThreadSessionSetCommand {
                    command_id: provider_command_id(event, "runtime-error-session-set", thread.id.as_str()),
                    thread_id: thread.id.clone(),
                    session: self.session_for(thread, event, OrchestrationSessionStatus::Error, event_turn_id.clone(), Some(message)),
                    expected_session_status: None,
                    expected_session_updated_at: None,
                    created_at: now.clone(),
                }));
            }
        }

        if let B::ThreadMetadataUpdated(payload) = &event.body {
            if let Some(name) = payload.name.as_deref().filter(|n| !n.is_empty()) {
                self.out.push(OrchestrationCommand::Client(ClientThreadCommand::MetaUpdate(ThreadMetaUpdateCommand {
                    command_id: provider_command_id(event, "thread-meta-update", thread.id.as_str()),
                    thread_id: thread.id.clone(),
                    title: Some(name.to_string()),
                    expected_title_sequence: None,
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
                    is_settled: None,
                    snoozed_until: None,
                    expected_snoozed_until: None,
                    parent_thread_id: None,
                    subagent_agent_id: None,
                    subagent_nickname: None,
                    subagent_role: None,
                    pinned_messages: None,
                    notes: None,
                })));
            }
        }

        if let B::TurnDiffUpdated(payload) = &event.body {
            if let Some(turn_id) = &event.turn_id {
                if (self.environment.is_git_repo)(thread) {
                    self.ingest_turn_diff(thread, event, turn_id, &payload.unified_diff);
                }
            }
        }

        let completed_reasoning = match (&event.body, &reasoning_summary_key) {
            (B::ItemCompleted(_), Some(key)) => self.buffered_reasoning_summary_by_key.remove(key),
            _ => None,
        };
        let activity_event = match (&event.body, &reasoning_summary_key, &tool_output_key) {
            (B::ItemCompleted(_), Some(_), _) => {
                let mut base = event.clone();
                if event.provider.as_str() == "claudeAgent" {
                    if let Some(summary) = &completed_reasoning {
                        base.created_at = summary.created_at.clone();
                    }
                }
                with_buffered_reasoning_summary(&base, completed_reasoning.as_ref())
            }
            (B::ItemCompleted(_), None, Some(key)) => {
                let buffered = self.buffered_tool_output_by_key.remove(key);
                with_buffered_tool_output_data(event, buffered.as_ref())
            }
            (B::ItemUpdated(_), _, Some(key)) => with_buffered_tool_output_data(event, self.buffered_tool_output_by_key.get(key)),
            _ => event.clone(),
        };
        let activity_sequence = if event.provider.as_str() == "claudeAgent" {
            completed_reasoning.as_ref().and_then(|s| s.sequence).or(Some(runtime_sequence))
        } else {
            Some(runtime_sequence)
        };
        for activity in project_provider_runtime_activities(&activity_event, activity_sequence) {
            self.dispatch_activity_update(&activity_event, thread, activity);
        }

        if is_terminal_turn_event {
            self.settle_buffered_reasoning_summaries(thread, event, event.turn_id.as_ref());
        } else if matches!(event.body, B::SessionExited(_)) {
            self.settle_buffered_reasoning_summaries(thread, event, None);
        } else if matches!(event.body, B::RuntimeError(_)) {
            let turn_id = event_turn_id.clone().or_else(|| active_turn_id.clone());
            self.settle_buffered_reasoning_summaries(thread, event, turn_id.as_ref());
        }

        // Exact-turn delivery modes survive terminal events; unbound state is cleared when the
        // session ends before the two sides can be matched.
        if matches!(event.body, B::SessionExited(_) | B::RuntimeError(_)) {
            self.clear_assistant_delivery_mode_bindings_for_thread(&thread.id);
        }
    }

    fn session_for(
        &self,
        thread: &OrchestrationThread,
        event: &ProviderRuntimeEvent,
        status: OrchestrationSessionStatus,
        active_turn_id: Option<TurnId>,
        last_error: Option<String>,
    ) -> OrchestrationSession {
        OrchestrationSession {
            thread_id: thread.id.clone(),
            status,
            provider_name: Some(event.provider.as_str().to_string()),
            provider_instance_id: event
                .provider_instance_id
                .clone()
                .or_else(|| thread.session.as_ref().and_then(|s| s.provider_instance_id.clone()))
                .or_else(|| model_selection_instance_id(&thread.model_selection).cloned()),
            runtime_mode: thread.session.as_ref().map(|s| s.runtime_mode).unwrap_or(RuntimeMode::FullAccess),
            active_turn_id,
            last_error,
            last_activity_at: None,
            last_progress_at: None,
            updated_at: event.created_at.clone(),
        }
    }

    fn ingest_assistant_delta(
        &mut self,
        thread: &OrchestrationThread,
        event: &ProviderRuntimeEvent,
        delta: &str,
        active_turn_id: Option<&TurnId>,
        runtime_sequence: u64,
    ) {
        let now = &event.created_at;
        let message_id = MessageId::new(format!(
            "assistant:{}",
            event
                .item_id
                .as_ref()
                .map(|i| i.as_str())
                .or(event.turn_id.as_ref().map(|t| t.as_str()))
                .unwrap_or(event.event_id.as_str())
        ));
        let turn_id = event.turn_id.clone();
        if let Some(turn_id) = &turn_id {
            self.remember_assistant_message_id(&thread.id, turn_id, &message_id);
            // Content before (or without) turn.started binds the queued delivery mode too.
            self.match_started_turn_assistant_delivery_mode(&thread.id, turn_id, true);
        }
        let mode = self.get_assistant_delivery_mode(&thread.id, turn_id.as_ref().or(active_turn_id));
        let state = self
            .segment_state_by_thread
            .entry(thread.id.clone())
            .or_default()
            .entry(message_id.clone())
            .or_default();
        let starts_new_segment = !state.has_text || state.split_pending;
        let segment_started_at = starts_new_segment.then(|| now.clone());
        state.has_text = true;
        state.split_pending = false;
        let segment_key = assistant_message_segment_key(&thread.id, &message_id);
        if mode == AssistantDeliveryMode::Buffered {
            if !self.buffered_text_spilled_by_message_key.contains(&segment_key) {
                let segments = self.buffered_text_segments_by_message_key.entry(segment_key.clone()).or_default();
                match (segment_started_at.is_none(), segments.last_mut()) {
                    (true, Some(tail)) => tail.text.push_str(delta),
                    _ => segments.push(BufferedTextSegment {
                        sequence: runtime_sequence,
                        started_at: segment_started_at.clone().unwrap_or_else(|| now.clone()),
                        text: delta.to_string(),
                    }),
                }
            }
            let spill = self.append_buffered_assistant_text(&message_id, delta);
            if !spill.is_empty() {
                // The spill boundary splits the buffer: fall back to one delta at completion.
                self.buffered_text_segments_by_message_key.remove(&segment_key);
                self.buffered_text_spilled_by_message_key.insert(segment_key);
                self.dispatch(InternalThreadCommand::MessageAssistantDelta(ThreadMessageAssistantDeltaCommand {
                    command_id: provider_command_id(event, "assistant-delta-buffer-spill", message_id.as_str()),
                    thread_id: thread.id.clone(),
                    message_id,
                    delta: spill,
                    turn_id,
                    segment_started_at: None,
                    segment_sequence: None,
                    created_at: now.clone(),
                }));
            }
        } else {
            self.dispatch(InternalThreadCommand::MessageAssistantDelta(ThreadMessageAssistantDeltaCommand {
                command_id: provider_command_id(event, "assistant-delta", message_id.as_str()),
                thread_id: thread.id.clone(),
                message_id,
                delta: delta.to_string(),
                turn_id,
                segment_sequence: segment_started_at.as_ref().map(|_| runtime_sequence),
                segment_started_at,
                created_at: now.clone(),
            }));
        }
    }

    /// Only provider-diff placeholders are live-updated; a real checkpoint stays authoritative.
    fn ingest_turn_diff(&mut self, thread: &OrchestrationThread, event: &ProviderRuntimeEvent, turn_id: &TurnId, unified_diff: &str) {
        let existing = thread.checkpoints.iter().find(|c| &c.turn_id == turn_id);
        let key = provider_turn_key(&thread.id, turn_id);
        let tracked = self.provider_diff_placeholders.get(&key).cloned();
        let existing_placeholder = existing.filter(|c| c.checkpoint_ref.as_str().starts_with("provider-diff:")).map(|c| {
            ProviderDiffPlaceholder {
                checkpoint_ref: c.checkpoint_ref.clone(),
                checkpoint_turn_count: c.checkpoint_turn_count,
                files: c.files.clone(),
            }
        });
        if existing.is_some() && existing_placeholder.is_none() {
            self.provider_diff_placeholders.remove(&key);
            return;
        }
        let can_parse = (self.environment.supports_live_turn_diff_patch)(&event.provider);
        let live = tracked.clone().or(existing_placeholder);
        let max_turn_count = thread.checkpoints.iter().map(|c| c.checkpoint_turn_count).max().unwrap_or(0);
        let files = (if can_parse { parse_checkpoint_files_from_unified_diff(unified_diff) } else { None })
            .or_else(|| tracked.as_ref().map(|t| t.files.clone()))
            .or_else(|| existing.map(|c| c.files.clone()))
            .unwrap_or_default();
        let checkpoint_ref = live
            .as_ref()
            .map(|p| p.checkpoint_ref.clone())
            .unwrap_or_else(|| CheckpointRef::new(format!("provider-diff:{}", event.event_id)));
        let checkpoint_turn_count = live.as_ref().map(|p| p.checkpoint_turn_count).unwrap_or(max_turn_count + 1);
        self.dispatch(InternalThreadCommand::TurnDiffComplete(ThreadTurnDiffCompleteCommand {
            command_id: provider_command_id(event, "thread-turn-diff-complete", &format!("{}:{}", thread.id, turn_id)),
            thread_id: thread.id.clone(),
            turn_id: turn_id.clone(),
            completed_at: event.created_at.clone(),
            checkpoint_ref: checkpoint_ref.clone(),
            status: OrchestrationCheckpointStatus::Missing,
            files: files.clone(),
            assistant_message_id: None,
            checkpoint_turn_count,
            preserve_latest_turn: None,
            checkpoint_revert_turn_count: None,
            created_at: event.created_at.clone(),
        }));
        if can_parse {
            self.provider_diff_placeholders.insert(key, ProviderDiffPlaceholder { checkpoint_ref, checkpoint_turn_count, files });
        }
    }

    /// Synara `processDomainEvent`: the orchestration events ingestion listens to. A requested
    /// turn queues its delivery mode for the provider turn that will answer it; a revert or
    /// rollback drops the thread's dedupe and binding state.
    pub fn ingest_domain_event(
        &mut self,
        thread: Option<&OrchestrationThread>,
        event: &OrchestrationEvent,
    ) -> Vec<OrchestrationCommand> {
        self.out.clear();
        match &event.body {
            OrchestrationEventBody::ThreadReverted(ThreadRevertedPayload { thread_id, .. })
            | OrchestrationEventBody::ThreadConversationRolledBack(ThreadConversationRolledBackPayload { thread_id, .. }) => {
                let prefix = format!("{thread_id}:");
                self.latest_activity_update_fingerprint_by_key.retain(|key, _| !key.starts_with(&prefix));
                self.clear_assistant_delivery_mode_bindings_for_thread(thread_id);
                self.outstanding_turn_ids_by_thread.remove(thread_id);
            }
            OrchestrationEventBody::ThreadTurnStartRequested(payload) => {
                let mode = payload.assistant_delivery_mode.unwrap_or(DEFAULT_ASSISTANT_DELIVERY_MODE);
                let steer_provider = thread.map(|t| {
                    t.session
                        .as_ref()
                        .and_then(|s| s.provider_name.clone())
                        .unwrap_or_else(|| model_selection_provider(&t.model_selection).as_str().to_string())
                });
                let is_native_steer = payload.dispatch_mode == TurnDispatchMode::Steer
                    && steer_provider.as_deref().is_some_and(provider_supports_native_turn_steering);
                let delivery_turn_id = if is_native_steer {
                    // A native steer rides the live turn: no turn.started will come to match it.
                    let Some(active) = thread.and_then(|t| t.session.as_ref()).and_then(|s| s.active_turn_id.clone()) else {
                        return vec![];
                    };
                    self.assistant_delivery_mode_by_turn_key.insert(provider_turn_key(&payload.thread_id, &active), mode);
                    Some(active)
                } else {
                    self.match_assistant_delivery_mode_request(&payload.thread_id, mode)
                };
                if let (Some(turn_id), AssistantDeliveryMode::Streaming) = (delivery_turn_id, mode) {
                    let flush_event = ProviderRuntimeEvent {
                        event_id: event.event_id.clone(),
                        provider: ProviderDriverKind::new(steer_provider.unwrap_or_else(|| "codex".into())),
                        provider_instance_id: None,
                        thread_id: payload.thread_id.clone(),
                        created_at: payload.created_at.clone(),
                        turn_id: Some(turn_id.clone()),
                        parent_turn_id: None,
                        item_id: None,
                        request_id: None,
                        lifecycle_generation: None,
                        provider_refs: None,
                        raw: None,
                        body: ProviderRuntimeEventBody::TurnStarted(TurnStartedPayload::default()),
                    };
                    self.flush_buffered_assistant_messages_for_turn(
                        &flush_event,
                        &payload.thread_id,
                        &turn_id,
                        &payload.created_at,
                        "assistant-delta-domain-flush",
                    );
                }
            }
            _ => {}
        }
        std::mem::take(&mut self.out)
    }
}

fn shift_queue<V>(queues: &mut HashMap<ThreadId, Vec<V>>, thread_id: &ThreadId) -> Option<V> {
    let values = queues.get_mut(thread_id)?;
    if values.is_empty() {
        queues.remove(thread_id);
        return None;
    }
    let value = values.remove(0);
    if values.is_empty() {
        queues.remove(thread_id);
    }
    Some(value)
}

/// Synara `parseCheckpointFilesFromUnifiedDiff` (checkpointing/Diffs.ts), which reads the patch
/// with `@pierre/diffs`: one summary per file, by path, with its kind and line counts.
pub fn parse_checkpoint_files_from_unified_diff(diff: &str) -> Option<Vec<OrchestrationCheckpointFile>> {
    let normalized = diff.replace("\r\n", "\n");
    let normalized = normalized.trim();
    if normalized.is_empty() {
        return Some(vec![]);
    }
    struct Current {
        path: String,
        old_path: Option<String>,
        kind: &'static str,
        additions: u64,
        deletions: u64,
    }
    let mut files: BTreeMap<String, OrchestrationCheckpointFile> = BTreeMap::new();
    let mut current: Option<Current> = None;
    let mut in_hunk = false;
    let flush = |current: &mut Option<Current>, files: &mut BTreeMap<String, OrchestrationCheckpointFile>| {
        if let Some(file) = current.take() {
            let path = if file.path.is_empty() { file.old_path.unwrap_or_default() } else { file.path };
            if path.is_empty() {
                return;
            }
            let entry = files.entry(path.clone()).or_insert(OrchestrationCheckpointFile {
                path,
                kind: file.kind.to_string(),
                additions: 0,
                deletions: 0,
            });
            entry.kind = file.kind.to_string();
            entry.additions += file.additions;
            entry.deletions += file.deletions;
        }
    };
    let strip = |p: &str| -> String {
        let p = p.trim();
        p.strip_prefix("a/").or_else(|| p.strip_prefix("b/")).unwrap_or(p).to_string()
    };
    for line in normalized.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            flush(&mut current, &mut files);
            in_hunk = false;
            let path = rest.rsplit_once(" b/").map(|(_, b)| b.to_string()).unwrap_or_default();
            current = Some(Current { path, old_path: None, kind: "modified", additions: 0, deletions: 0 });
            continue;
        }
        if line.starts_with("--- ") && !in_hunk {
            if current.as_ref().is_none_or(|c| c.additions + c.deletions > 0) {
                flush(&mut current, &mut files);
                current = Some(Current { path: String::new(), old_path: None, kind: "modified", additions: 0, deletions: 0 });
            }
            let old = &line[4..];
            if let Some(file) = current.as_mut() {
                if old.trim() == "/dev/null" {
                    file.kind = "added";
                } else {
                    file.old_path = Some(strip(old.split('\t').next().unwrap_or(old)));
                }
            }
            continue;
        }
        if line.starts_with("+++ ") && !in_hunk {
            let new = &line[4..];
            if let Some(file) = current.as_mut() {
                if new.trim() == "/dev/null" {
                    file.kind = "deleted";
                    if file.path.is_empty() {
                        file.path = file.old_path.clone().unwrap_or_default();
                    }
                } else {
                    file.path = strip(new.split('\t').next().unwrap_or(new));
                }
            }
            continue;
        }
        let Some(file) = current.as_mut() else { continue };
        if line.starts_with("new file mode") {
            file.kind = "added";
        } else if line.starts_with("deleted file mode") {
            file.kind = "deleted";
        } else if let Some(to) = line.strip_prefix("rename to ") {
            file.kind = "renamed";
            file.path = to.to_string();
        } else if line.starts_with("rename from ") {
            file.kind = "renamed";
        } else if line.starts_with("@@") {
            in_hunk = true;
        } else if in_hunk && line.starts_with('+') {
            file.additions += 1;
        } else if in_hunk && line.starts_with('-') {
            file.deletions += 1;
        } else if in_hunk && !line.starts_with(' ') && !line.starts_with('\\') {
            in_hunk = false;
        }
    }
    flush(&mut current, &mut files);
    Some(files.into_values().collect())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::orchestration::decider::decide;
    use crate::orchestration::decider::tests::{apply, client, created_thread, iso, T0};
    use crate::orchestration::projector::project;

    struct Harness {
        thread: Option<OrchestrationThread>,
        sequence: u64,
        runtime_sequence: u64,
        ingestion: ProviderRuntimeIngestion,
    }

    impl Harness {
        fn new() -> Self {
            let (thread, sequence) = created_thread();
            Self { thread: Some(thread), sequence, runtime_sequence: 0, ingestion: ProviderRuntimeIngestion::new() }
        }

        /// Decide, project and feed back to ingestion, as the engine does.
        fn run(&mut self, command: &OrchestrationCommand) -> Vec<OrchestrationEvent> {
            let (thread, events) = apply(self.thread.take(), command, &mut self.sequence)
                .unwrap_or_else(|error| panic!("{command:?} was refused: {error}"));
            self.thread = thread;
            for event in &events {
                let follow_ups = self.ingestion.ingest_domain_event(self.thread.as_ref(), event);
                for follow_up in follow_ups {
                    self.run(&follow_up);
                }
            }
            events
        }

        fn feed(&mut self, sample: serde_json::Value) -> Vec<OrchestrationCommand> {
            let event: ProviderRuntimeEvent = serde_json::from_value(sample).unwrap();
            self.runtime_sequence += 1;
            let commands = self.ingestion.ingest(self.thread.as_ref().unwrap(), &event, self.runtime_sequence);
            for command in &commands {
                self.run(command);
            }
            commands
        }
    }

    fn runtime(id: &str, at: &str, kind: &str, extra: serde_json::Value, payload: serde_json::Value) -> serde_json::Value {
        let mut event = json!({
            "eventId": id,
            "provider": "codex",
            "threadId": "thread-1",
            "createdAt": at,
            "turnId": "turn-1",
            "type": kind,
            "payload": payload,
        });
        for (key, value) in extra.as_object().unwrap() {
            event[key] = value.clone();
        }
        event
    }

    #[test]
    fn a_turn_streams_into_one_message_with_tool_and_approval_rows() {
        let mut h = Harness::new();
        h.run(&client(json!({
            "type": "thread.turn.start",
            "commandId": "cmd-turn",
            "threadId": "thread-1",
            "message": { "messageId": "msg-user", "role": "user", "text": "List the files", "attachments": [] },
            "assistantDeliveryMode": "streaming",
            "runtimeMode": "approval-required",
            "interactionMode": "default",
            "createdAt": T0,
        })));
        assert_eq!(h.thread.as_ref().unwrap().session.as_ref().unwrap().status, OrchestrationSessionStatus::Starting);

        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({}), json!({ "model": "gpt" })));
        let session = h.thread.as_ref().unwrap().session.clone().unwrap();
        assert_eq!(session.status, OrchestrationSessionStatus::Running);
        assert_eq!(session.active_turn_id, Some(TurnId::new("turn-1")));

        let delta = |id: &str, at: &str, text: &str| {
            runtime(id, at, "content.delta", json!({ "itemId": "msg-a" }), json!({ "streamKind": "assistant_text", "delta": text }))
        };
        h.feed(delta("e2", "2026-10-05T10:00:02.000Z", "I'll "));
        h.feed(delta("e3", "2026-10-05T10:00:03.000Z", "list them."));
        h.feed(runtime(
            "e4",
            "2026-10-05T10:00:04.000Z",
            "item.started",
            json!({ "itemId": "cmd-1" }),
            json!({ "itemType": "command_execution", "status": "inProgress", "title": "Ran ls", "data": { "command": "ls" } }),
        ));
        h.feed(runtime(
            "e5",
            "2026-10-05T10:00:05.000Z",
            "request.opened",
            json!({ "requestId": "req-1" }),
            json!({ "requestType": "command_execution_approval", "detail": "ls" }),
        ));
        h.feed(runtime(
            "e6",
            "2026-10-05T10:00:06.000Z",
            "request.resolved",
            json!({ "requestId": "req-1" }),
            json!({ "requestType": "command_execution_approval", "decision": "accept" }),
        ));
        h.feed(runtime(
            "e7",
            "2026-10-05T10:00:07.000Z",
            "content.delta",
            json!({ "itemId": "cmd-1" }),
            json!({ "streamKind": "command_output", "delta": "a.txt\nb.txt\n" }),
        ));
        h.feed(runtime(
            "e8",
            "2026-10-05T10:00:08.000Z",
            "item.completed",
            json!({ "itemId": "cmd-1" }),
            json!({ "itemType": "command_execution", "status": "completed", "title": "Ran ls" }),
        ));
        h.feed(delta("e9", "2026-10-05T10:00:09.000Z", " Done."));
        let completion = h.feed(runtime("e10", "2026-10-05T10:00:10.000Z", "turn.completed", json!({}), json!({ "state": "completed" })));
        assert!(completion.iter().any(|c| matches!(c, OrchestrationCommand::Internal(InternalThreadCommand::MessageAssistantComplete(_)))));

        let thread = h.thread.unwrap();
        let assistants: Vec<_> = thread.messages.iter().filter(|m| m.role == OrchestrationMessageRole::Assistant).collect();
        assert_eq!(assistants.len(), 1);
        let message = assistants[0];
        assert_eq!(message.id.as_str(), "assistant:msg-a");
        assert_eq!(message.text, "I'll list them. Done.");
        assert!(!message.streaming);
        assert_eq!(message.turn_id, Some(TurnId::new("turn-1")));
        // The tool row between the deltas split the text into two timeline segments.
        let segments = message.text_segments.as_ref().unwrap();
        assert_eq!(segments.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(), ["I'll list them.", " Done."]);
        assert_eq!(segments[1].started_at.as_str(), "2026-10-05T10:00:09.000Z");

        let kinds: Vec<_> = thread.activities.iter().map(|a| (a.kind.as_str(), a.tone)).collect();
        use OrchestrationThreadActivityTone as Tone;
        assert_eq!(
            kinds,
            [
                ("tool.started", Tone::Tool),
                ("approval.requested", Tone::Approval),
                ("approval.resolved", Tone::Approval),
                ("tool.completed", Tone::Tool),
                ("turn.completed", Tone::Info),
            ]
        );
        let started = &thread.activities[0];
        assert_eq!(started.summary, "Ran ls started");
        assert_eq!(started.turn_id, Some(TurnId::new("turn-1")));
        assert_eq!(started.payload, json!({ "itemType": "command_execution", "status": "inProgress", "title": "Ran ls", "data": { "command": "ls" } }));
        let completed = &thread.activities[3];
        assert_eq!(completed.summary, "Ran ls");
        assert_eq!(completed.payload["data"]["rawOutput"], json!({ "output": "a.txt\nb.txt\n" }));
        let requested = &thread.activities[1];
        assert_eq!(requested.summary, "Command approval requested");
        assert_eq!(requested.payload["requestId"], json!("req-1"));
        assert_eq!(requested.payload["requestKind"], json!("command"));
        assert_eq!(thread.activities[2].payload["decision"], json!("accept"));
        // Activities carry the runtime stream's order.
        assert!(thread.activities.windows(2).all(|w| w[0].sequence < w[1].sequence));

        let latest = thread.latest_turn.unwrap();
        assert_eq!(latest.turn_id, TurnId::new("turn-1"));
        assert_eq!(latest.state, OrchestrationLatestTurnState::Completed);
        assert_eq!(latest.completed_at.unwrap().as_str(), "2026-10-05T10:00:10.000Z");
        assert_eq!(latest.assistant_message_id, Some(MessageId::new("assistant:msg-a")));
        let session = thread.session.unwrap();
        assert_eq!(session.status, OrchestrationSessionStatus::Ready);
        assert_eq!(session.active_turn_id, None);
        assert_eq!(session.provider_name.as_deref(), Some("codex"));
    }

    #[test]
    fn buffered_delivery_holds_text_until_completion_and_keeps_segments() {
        let mut h = Harness::new();
        h.run(&client(json!({
            "type": "thread.turn.start",
            "commandId": "cmd-turn",
            "threadId": "thread-1",
            "message": { "messageId": "msg-user", "role": "user", "text": "Go", "attachments": [] },
            "assistantDeliveryMode": "buffered",
            "runtimeMode": "approval-required",
            "interactionMode": "default",
            "createdAt": T0,
        })));
        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({}), json!({})));
        let commands = h.feed(runtime("e2", "2026-10-05T10:00:02.000Z", "content.delta", json!({ "itemId": "m" }), json!({ "streamKind": "assistant_text", "delta": "One." })));
        assert!(commands.is_empty(), "buffered text is held");
        h.feed(runtime("e3", "2026-10-05T10:00:03.000Z", "runtime.warning", json!({}), json!({ "message": "slow" })));
        h.feed(runtime("e4", "2026-10-05T10:00:04.000Z", "content.delta", json!({ "itemId": "m" }), json!({ "streamKind": "assistant_text", "delta": " Two." })));
        h.feed(runtime("e5", "2026-10-05T10:00:05.000Z", "item.completed", json!({ "itemId": "m" }), json!({ "itemType": "assistant_message" })));
        let thread = h.thread.unwrap();
        let message = thread.messages.iter().find(|m| m.id.as_str() == "assistant:m").unwrap();
        assert_eq!(message.text, "One. Two.");
        assert!(!message.streaming);
        let segments = message.text_segments.as_ref().unwrap();
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].started_at.as_str(), "2026-10-05T10:00:02.000Z");
        assert_eq!(segments[1].started_at.as_str(), "2026-10-05T10:00:04.000Z");
    }

    #[test]
    fn an_assistant_item_without_deltas_uses_its_detail() {
        let mut h = Harness::new();
        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({}), json!({})));
        h.feed(runtime("e2", "2026-10-05T10:00:02.000Z", "item.completed", json!({ "itemId": "m" }), json!({ "itemType": "assistant_message", "detail": "Whole answer" })));
        let thread = h.thread.unwrap();
        assert_eq!(thread.messages.last().unwrap().text, "Whole answer");
    }

    #[test]
    fn interrupting_a_codex_turn_settles_its_open_approval() {
        let mut h = Harness::new();
        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({}), json!({})));
        h.feed(runtime("e2", "2026-10-05T10:00:02.000Z", "request.opened", json!({ "requestId": "req-9" }), json!({ "requestType": "file_change_approval" })));
        h.feed(runtime("e3", "2026-10-05T10:00:03.000Z", "turn.completed", json!({}), json!({ "state": "interrupted" })));
        let thread = h.thread.unwrap();
        let failure = thread.activities.iter().find(|a| a.kind == "provider.approval.respond.failed").unwrap();
        assert_eq!(failure.payload["requestId"], json!("req-9"));
        assert_eq!(failure.tone, OrchestrationThreadActivityTone::Error);
        assert_eq!(thread.session.unwrap().status, OrchestrationSessionStatus::Interrupted);
        assert_eq!(thread.latest_turn.unwrap().state, OrchestrationLatestTurnState::Interrupted);
    }

    #[test]
    fn a_stale_terminal_event_does_not_touch_the_newer_turn() {
        let mut h = Harness::new();
        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({ "turnId": "turn-2" }), json!({})));
        let commands = h.feed(runtime("e2", "2026-10-05T10:00:02.000Z", "turn.completed", json!({ "turnId": "turn-1" }), json!({ "state": "completed" })));
        assert!(!commands.iter().any(|c| matches!(c, OrchestrationCommand::Internal(InternalThreadCommand::SessionSet(_)))));
        assert_eq!(h.thread.unwrap().session.unwrap().active_turn_id, Some(TurnId::new("turn-2")));
    }

    #[test]
    fn runtime_errors_mark_the_session() {
        let mut h = Harness::new();
        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({}), json!({})));
        h.feed(runtime("e2", "2026-10-05T10:00:02.000Z", "runtime.error", json!({}), json!({ "message": "boom" })));
        let thread = h.thread.unwrap();
        let session = thread.session.unwrap();
        assert_eq!(session.status, OrchestrationSessionStatus::Error);
        assert_eq!(session.last_error.as_deref(), Some("boom"));
        assert_eq!(thread.latest_turn.unwrap().state, OrchestrationLatestTurnState::Error);
        assert!(thread.activities.iter().any(|a| a.kind == "runtime.error"));
    }

    #[test]
    fn proposed_plans_buffer_until_the_plan_completes() {
        let mut h = Harness::new();
        h.feed(runtime("e1", "2026-10-05T10:00:01.000Z", "turn.started", json!({}), json!({})));
        h.feed(runtime("e2", "2026-10-05T10:00:02.000Z", "turn.proposed.delta", json!({}), json!({ "delta": "1. Do it" })));
        assert!(h.thread.as_ref().unwrap().proposed_plans.is_empty());
        h.feed(runtime("e3", "2026-10-05T10:00:03.000Z", "turn.completed", json!({}), json!({ "state": "completed" })));
        let plans = &h.thread.as_ref().unwrap().proposed_plans;
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].id, "plan:thread-1:turn:turn-1");
        assert_eq!(plans[0].plan_markdown, "1. Do it");
    }

    #[test]
    fn repeated_progress_updates_are_deduplicated() {
        let mut h = Harness::new();
        let progress = |id: &str| runtime(id, "2026-10-05T10:00:01.000Z", "tool.progress", json!({}), json!({ "toolUseId": "t1", "toolName": "mcp" }));
        assert_eq!(h.feed(progress("p1")).len(), 1);
        assert!(h.feed(progress("p2")).is_empty());
    }

    #[test]
    fn claude_reasoning_previews_coalesce_into_one_row() {
        let mut h = Harness::new();
        let reasoning = |id: &str, at: &str, text: &str| {
            let mut event = runtime(id, at, "content.delta", json!({ "itemId": "think-1" }), json!({ "streamKind": "reasoning_text", "delta": text }));
            event["provider"] = json!("claudeAgent");
            event
        };
        h.feed(reasoning("r1", "2026-10-05T10:00:01.000Z", "Thinking"));
        h.feed(reasoning("r2", "2026-10-05T10:00:01.100Z", " more"));
        h.feed(reasoning("r3", "2026-10-05T10:00:02.000Z", " and more"));
        let mut done = runtime("r4", "2026-10-05T10:00:03.000Z", "turn.completed", json!({}), json!({ "state": "completed" }));
        done["provider"] = json!("claudeAgent");
        h.feed(done);
        let thread = h.thread.unwrap();
        let rows: Vec<_> = thread.activities.iter().filter(|a| a.kind == "task.progress").collect();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id.as_str(), "provider-reasoning:thread-1:think-1");
        assert_eq!(rows[0].payload["detail"], json!("Thinking more and more"));
        assert_eq!(rows[0].payload["status"], json!("completed"));
        assert_eq!(rows[0].created_at.as_str(), "2026-10-05T10:00:01.000Z");
    }

    #[test]
    fn unified_diffs_summarize_per_file() {
        let diff = "diff --git a/src/a.rs b/src/a.rs\nindex 1..2 100644\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,2 +1,3 @@\n line\n-old\n+new\n+more\ndiff --git a/b.txt b/b.txt\nnew file mode 100644\n--- /dev/null\n+++ b/b.txt\n@@ -0,0 +1 @@\n+hello\n";
        let files = parse_checkpoint_files_from_unified_diff(diff).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!((files[0].path.as_str(), files[0].kind.as_str(), files[0].additions, files[0].deletions), ("b.txt", "added", 1, 0));
        assert_eq!((files[1].path.as_str(), files[1].kind.as_str(), files[1].additions, files[1].deletions), ("src/a.rs", "modified", 2, 1));
    }

    #[test]
    fn decided_commands_for_an_unknown_thread_fail_cleanly() {
        let event: ProviderRuntimeEvent = serde_json::from_value(runtime("e1", T0, "turn.started", json!({}), json!({}))).unwrap();
        let (thread, _) = created_thread();
        let mut ingestion = ProviderRuntimeIngestion::new();
        let commands = ingestion.ingest(&thread, &event, 1);
        assert!(decide(&commands[0], None, &iso(T0)).is_err());
        assert!(project(None, &decide(&commands[0], Some(&thread), &iso(T0)).unwrap()[0]).is_none());
    }
}
