//! Ported from Synara `apps/server/src/orchestration/providerRuntimeActivityProjection.ts`: which
//! thread activities (the timeline's tool, approval, task and warning rows) a provider runtime
//! event produces. Kinds, tones, summaries and payload keys are Synara's, so Synara's web client
//! (`workLog.ts`, `session-logic.ts`) reads them unchanged.
//!
//! Differences forced by Rust: a `serde_json::Value` is already what `Schema.Json` admits, so
//! `jsonSafeValue` is the identity; string limits count `char`s where JavaScript counts UTF-16
//! units; object keys come out in `serde_json`'s order, so `activityPayloadKeyRank` only decides
//! which keys a truncation keeps. `sensitiveKeys.ts` (`isSensitiveKey`) is ported at the bottom
//! without `isProviderCredentialKey`, and `unmappedProviderEvents.ts`'s sanitizers are reduced to
//! key redaction and the size cap.

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::contracts::base::{ApprovalRequestId, EventId, ThreadId, TurnId};
use crate::contracts::orchestration::{OrchestrationThreadActivity, OrchestrationThreadActivityTone};
use crate::contracts::provider_runtime::{
    is_tool_lifecycle_item_type, CanonicalItemType, CanonicalRequestType, ProviderRuntimeEvent,
    ProviderRuntimeEventBody, RequestOpenedPayload, RuntimeTurnState,
};

const MAX_ACTIVITY_DATA_JSON_CHARS: usize = 16_000;
pub(crate) const MAX_ACTIVITY_DATA_STRING_CHARS: usize = 2_000;
const MAX_REASONING_DETAIL_CHARS: usize = 8_000;
const MAX_ACTIVITY_DATA_ARRAY_ITEMS: usize = 24;
const MAX_ACTIVITY_DATA_OBJECT_KEYS: usize = 64;
const ACTIVITY_DATA_TRUNCATION_MARKER: &str = "__synaraTruncated";

type ActivityPayload = Value;

/// The `type` literal of a runtime event (Synara reads `event.type`).
pub fn runtime_event_type(event: &ProviderRuntimeEvent) -> &'static str {
    use ProviderRuntimeEventBody as B;
    match &event.body {
        B::SessionStarted(_) => "session.started",
        B::SessionConfigured(_) => "session.configured",
        B::SessionStateChanged(_) => "session.state.changed",
        B::SessionExited(_) => "session.exited",
        B::ThreadStarted(_) => "thread.started",
        B::ThreadStateChanged(_) => "thread.state.changed",
        B::ThreadMetadataUpdated(_) => "thread.metadata.updated",
        B::ThreadTokenUsageUpdated(_) => "thread.token-usage.updated",
        B::ThreadRealtimeStarted(_) => "thread.realtime.started",
        B::ThreadRealtimeItemAdded(_) => "thread.realtime.item-added",
        B::ThreadRealtimeAudioDelta(_) => "thread.realtime.audio.delta",
        B::ThreadRealtimeError(_) => "thread.realtime.error",
        B::ThreadRealtimeClosed(_) => "thread.realtime.closed",
        B::TurnStarted(_) => "turn.started",
        B::TurnCompleted(_) => "turn.completed",
        B::TurnAborted(_) => "turn.aborted",
        B::TurnTasksUpdated(_) => "turn.tasks.updated",
        B::TurnProposedDelta(_) => "turn.proposed.delta",
        B::TurnProposedCompleted(_) => "turn.proposed.completed",
        B::TurnDiffUpdated(_) => "turn.diff.updated",
        B::TurnSteered(_) => "turn.steered",
        B::ItemStarted(_) => "item.started",
        B::ItemUpdated(_) => "item.updated",
        B::ItemCompleted(_) => "item.completed",
        B::ContentDelta(_) => "content.delta",
        B::RequestOpened(_) => "request.opened",
        B::RequestResolved(_) => "request.resolved",
        B::UserInputRequested(_) => "user-input.requested",
        B::UserInputResolved(_) => "user-input.resolved",
        B::TaskStarted(_) => "task.started",
        B::TaskProgress(_) => "task.progress",
        B::TaskUpdated(_) => "task.updated",
        B::TaskCompleted(_) => "task.completed",
        B::HookStarted(_) => "hook.started",
        B::HookProgress(_) => "hook.progress",
        B::HookCompleted(_) => "hook.completed",
        B::ToolProgress(_) => "tool.progress",
        B::ToolSummary(_) => "tool.summary",
        B::AuthStatus(_) => "auth.status",
        B::AccountUpdated(_) => "account.updated",
        B::AccountRateLimitsUpdated(_) => "account.rate-limits.updated",
        B::McpStatusUpdated(_) => "mcp.status.updated",
        B::McpOauthCompleted(_) => "mcp.oauth.completed",
        B::ModelRerouted(_) => "model.rerouted",
        B::ConfigWarning(_) => "config.warning",
        B::DeprecationNotice(_) => "deprecation.notice",
        B::FilesPersisted(_) => "files.persisted",
        B::VcsStateChanged(_) => "vcs.state.changed",
        B::RuntimeWarning(_) => "runtime.warning",
        B::RuntimeError(_) => "runtime.error",
        B::EventUnmapped(_) => "event.unmapped",
    }
}

/// The serde literal of a wire enum (`"command_execution"`, `"inProgress"`, ...).
pub(crate) fn wire<T: Serialize>(value: &T) -> String {
    match serde_json::to_value(value) {
        Ok(Value::String(text)) => text,
        _ => String::new(),
    }
}

fn to_activity_payload(payload: Value) -> ActivityPayload {
    payload
}

/// Synara `toTurnId`: a blank runtime turn id means "no turn".
pub(crate) fn to_turn_id(value: Option<&TurnId>) -> Option<TurnId> {
    let trimmed = value?.as_str().trim();
    (!trimmed.is_empty()).then(|| TurnId::new(trimmed))
}

pub(crate) fn js_len(value: &str) -> usize {
    value.chars().count()
}

fn js_slice(value: &str, end: usize) -> String {
    value.chars().take(end).collect()
}

pub(crate) fn truncate_detail(value: &str, limit: usize) -> String {
    if js_len(value) > limit {
        format!("{}...", js_slice(value, limit.saturating_sub(3)))
    } else {
        value.to_string()
    }
}

fn stringify_json_like(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

fn truncate_json_string(value: &str, limit: usize) -> String {
    if js_len(value) > limit {
        format!("{}... [truncated]", js_slice(value, limit.saturating_sub(15)))
    } else {
        value.to_string()
    }
}

fn activity_payload_key_rank(key: &str) -> usize {
    match key {
        "itemType" => 0,
        "status" => 1,
        "title" => 2,
        "detail" => 3,
        "toolName" => 4,
        "tool" => 5,
        "toolCallId" => 6,
        "callID" => 7,
        "callId" => 8,
        "command" => 9,
        "cmd" => 10,
        "input" => 11,
        "rawInput" => 12,
        "arguments" => 13,
        "args" => 14,
        "params" => 15,
        "item" => 16,
        "result" => 17,
        "rawOutput" => 18,
        "output" => 19,
        "data" => 20,
        "commandActions" => 21,
        "files" => 22,
        "changes" => 23,
        "path" => 24,
        "file" => 25,
        "filePath" => 26,
        "stdout" => 27,
        "stderr" => 28,
        "content" => 29,
        "totalFiles" => 30,
        "truncated" => 31,
        _ => 100,
    }
}

#[derive(Clone, Copy)]
struct TruncateOptions {
    string_limit: usize,
    array_items: usize,
    object_keys: usize,
    depth: usize,
}

fn truncate_json_value(value: &Value, options: &TruncateOptions) -> Value {
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
        Value::String(text) => Value::String(truncate_json_string(text, options.string_limit)),
        Value::Array(_) | Value::Object(_) if options.depth == 0 => {
            json!({ ACTIVITY_DATA_TRUNCATION_MARKER: true })
        }
        Value::Array(items) => {
            let nested = TruncateOptions { depth: options.depth - 1, ..*options };
            let mut retained: Vec<Value> = items
                .iter()
                .take(options.array_items)
                .map(|entry| truncate_json_value(entry, &nested))
                .collect();
            if items.len() > options.array_items {
                retained.push(json!({
                    ACTIVITY_DATA_TRUNCATION_MARKER: true,
                    "omittedItems": items.len() - options.array_items,
                }));
            }
            Value::Array(retained)
        }
        Value::Object(entries) => {
            let nested = TruncateOptions { depth: options.depth - 1, ..*options };
            let retained = select_leading_activity_payload_entries(entries, options.object_keys);
            let mut result = Map::new();
            for (key, entry) in retained {
                result.insert(key.clone(), truncate_json_value(entry, &nested));
            }
            if entries.len() > options.object_keys {
                result.insert(ACTIVITY_DATA_TRUNCATION_MARKER.into(), Value::Bool(true));
                result.insert("omittedKeys".into(), json!(entries.len() - options.object_keys));
            }
            Value::Object(result)
        }
    }
}

pub(crate) fn bound_activity_data(value: &Value) -> Value {
    let serialized = stringify_json_like(value);
    let original_chars = js_len(&serialized);
    if original_chars <= MAX_ACTIVITY_DATA_JSON_CHARS {
        return value.clone();
    }
    let with_truncation_metadata = |bounded: Value| -> Value {
        match bounded {
            Value::Object(mut map) => {
                map.insert(ACTIVITY_DATA_TRUNCATION_MARKER.into(), Value::Bool(true));
                map.insert("originalJsonChars".into(), json!(original_chars));
                Value::Object(map)
            }
            other => json!({
                ACTIVITY_DATA_TRUNCATION_MARKER: true,
                "originalJsonChars": original_chars,
                "value": other,
            }),
        }
    };
    let compact = truncate_json_value(
        value,
        &TruncateOptions {
            string_limit: MAX_ACTIVITY_DATA_STRING_CHARS,
            array_items: MAX_ACTIVITY_DATA_ARRAY_ITEMS,
            object_keys: MAX_ACTIVITY_DATA_OBJECT_KEYS,
            depth: 6,
        },
    );
    let compact_with_metadata = with_truncation_metadata(compact);
    if js_len(&stringify_json_like(&compact_with_metadata)) <= MAX_ACTIVITY_DATA_JSON_CHARS {
        return compact_with_metadata;
    }
    let bounded = with_truncation_metadata(truncate_json_value(
        value,
        &TruncateOptions { string_limit: 800, array_items: 12, object_keys: 32, depth: 4 },
    ));
    if js_len(&stringify_json_like(&bounded)) <= MAX_ACTIVITY_DATA_JSON_CHARS {
        bounded
    } else {
        json!({
            ACTIVITY_DATA_TRUNCATION_MARKER: true,
            "originalJsonChars": original_chars,
            "preview": truncate_json_string(&serialized, MAX_ACTIVITY_DATA_STRING_CHARS),
        })
    }
}

/// Tool payloads power the timeline, but they must stay small enough for snapshots.
fn activity_data_field(map: &mut Map<String, Value>, data: Option<&Value>) {
    if let Some(data) = data {
        map.insert("data".into(), bound_activity_data(data));
    }
}

fn build_tool_progress_activity_payload(
    payload: &crate::contracts::provider_runtime::ToolProgressPayload,
) -> ActivityPayload {
    let mut out = Map::new();
    out.insert("itemType".into(), json!("mcp_tool_call"));
    out.insert("title".into(), json!("MCP tool call"));
    if let Some(summary) = payload.summary.as_deref().filter(|s| !s.is_empty()) {
        out.insert(
            "detail".into(),
            json!(truncate_detail(summary, MAX_ACTIVITY_DATA_STRING_CHARS)),
        );
    }
    let mut data = Map::new();
    if let Some(id) = payload.tool_use_id.as_deref().filter(|s| !s.is_empty()) {
        data.insert("toolUseId".into(), json!(id));
    }
    if let Some(name) = payload.tool_name.as_deref().filter(|s| !s.is_empty()) {
        data.insert("toolName".into(), json!(name));
    }
    if let Some(summary) = payload.summary.as_deref().filter(|s| !s.is_empty()) {
        data.insert("summary".into(), json!(summary));
    }
    if let Some(elapsed) = payload.elapsed_seconds {
        data.insert("elapsedSeconds".into(), json!(elapsed));
    }
    out.insert("data".into(), Value::Object(data));
    to_activity_payload(Value::Object(out))
}

/// Synara `readableReasoningDetail`: the trimmed text, unless it is empty once HTML comments
/// (Claude's encrypted-thinking markers) are removed.
pub fn readable_reasoning_detail(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    let mut stripped = String::new();
    let mut rest = trimmed;
    while let Some(start) = rest.find("<!--") {
        stripped.push_str(&rest[..start]);
        match rest[start + 4..].find("-->") {
            Some(end) => rest = &rest[start + 4 + end + 3..],
            None => {
                stripped.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    stripped.push_str(rest);
    (!stripped.trim().is_empty()).then(|| trimmed.to_string())
}

fn as_str(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

fn as_object(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value.and_then(Value::as_object)
}

fn build_context_window_activity_payload(event: &ProviderRuntimeEvent) -> Option<ActivityPayload> {
    let ProviderRuntimeEventBody::ThreadTokenUsageUpdated(payload) = &event.body else {
        return None;
    };
    let usage = &payload.usage;
    let has_token_usage = usage.used_tokens > 0;
    let has_percent_usage = usage.used_percent.is_some_and(f64::is_finite);
    let has_known_window = usage.max_tokens.is_some();
    let has_processed_tokens = usage.total_processed_tokens.is_some_and(|t| t > 0);
    if !has_token_usage && !has_percent_usage && !has_known_window && !has_processed_tokens {
        return None;
    }
    let mut out = match serde_json::to_value(usage) {
        Ok(Value::Object(map)) => map,
        _ => Map::new(),
    };
    out.insert("provider".into(), json!(event.provider.as_str()));
    if let Some(provider_thread_id) = event
        .provider_refs
        .as_ref()
        .and_then(|refs| refs.provider_thread_id.as_deref())
        .filter(|id| !id.is_empty())
    {
        let generation = event
            .lifecycle_generation
            .as_deref()
            .filter(|g| !g.is_empty())
            .map(|g| format!(":{g}"))
            .unwrap_or_default();
        out.insert("usageSessionId".into(), json!(format!("{provider_thread_id}{generation}")));
    }
    Some(to_activity_payload(Value::Object(out)))
}

fn as_positive_finite_number(value: Option<&Value>) -> Option<f64> {
    value.and_then(Value::as_f64).filter(|n| n.is_finite() && *n > 0.0)
}

/// Claude reports a per-model token breakdown on the turn result; keep a compact copy.
fn compact_turn_model_usage(model_usage: Option<&Map<String, Value>>) -> Option<Value> {
    let model_usage = model_usage?;
    let mut compact = Map::new();
    for (model, value) in model_usage {
        let Some(usage) = value.as_object() else { continue };
        let input_tokens = as_positive_finite_number(usage.get("inputTokens")).unwrap_or(0.0)
            + as_positive_finite_number(usage.get("cacheReadInputTokens")).unwrap_or(0.0)
            + as_positive_finite_number(usage.get("cacheCreationInputTokens")).unwrap_or(0.0);
        let output_tokens = as_positive_finite_number(usage.get("outputTokens")).unwrap_or(0.0);
        let total_tokens = input_tokens + output_tokens;
        if total_tokens <= 0.0 {
            continue;
        }
        let mut entry = Map::new();
        entry.insert("inputTokens".into(), number(input_tokens));
        entry.insert("outputTokens".into(), number(output_tokens));
        entry.insert("totalTokens".into(), number(total_tokens));
        for key in ["cacheReadInputTokens", "cacheCreationInputTokens"] {
            if let Some(n) = usage.get(key).and_then(Value::as_f64).filter(|n| n.is_finite() && *n >= 0.0) {
                entry.insert(key.into(), number(n));
            }
        }
        compact.insert(model.clone(), Value::Object(entry));
    }
    (!compact.is_empty()).then_some(Value::Object(compact))
}

fn number(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9.0e15 {
        json!(value as i64)
    } else {
        json!(value)
    }
}

/// Convert session-configured Claude window labels into the max-token shape the web meter uses.
fn build_configured_context_window_payload(event: &ProviderRuntimeEvent) -> Option<ActivityPayload> {
    let ProviderRuntimeEventBody::SessionConfigured(payload) = &event.body else {
        return None;
    };
    let config = &payload.config;
    let auto_compact_window = config.get("autoCompactWindow");
    let legacy_context_window = config.get("contextWindow");
    let configured_window_value = auto_compact_window.or(legacy_context_window);
    let configured_window = as_str(configured_window_value).map(|s| s.trim().to_lowercase());
    let max_tokens = as_positive_finite_number(configured_window_value).or(match configured_window.as_deref() {
        Some("1m") => Some(1_000_000.0),
        Some("200k") => Some(200_000.0),
        _ => None,
    });
    let Some(max_tokens) = max_tokens else {
        let is_null = |v: Option<&Value>| matches!(v, Some(Value::Null));
        let explicitly_cleared = (is_null(auto_compact_window)
            && (legacy_context_window.is_none() || is_null(legacy_context_window)))
            || (auto_compact_window.is_none() && is_null(legacy_context_window));
        return explicitly_cleared.then(|| json!({ "cleared": true }));
    };
    let mut out = Map::new();
    out.insert("maxTokens".into(), number(max_tokens));
    if let Some(window) = configured_window.filter(|w| !w.is_empty()) {
        out.insert("contextWindow".into(), json!(window));
    }
    Some(Value::Object(out))
}

/// Synara `runtimePayloadRecord`: the event's payload as a JSON object.
pub fn runtime_payload_record(event: &ProviderRuntimeEvent) -> Option<Map<String, Value>> {
    match serde_json::to_value(&event.body) {
        Ok(Value::Object(mut map)) => match map.remove("payload") {
            Some(Value::Object(payload)) => Some(payload),
            _ => None,
        },
        _ => None,
    }
}

/// Synara `runtimeTurnState`: `completed` unless the payload says failed, interrupted or cancelled.
pub fn runtime_turn_state(event: &ProviderRuntimeEvent) -> RuntimeTurnState {
    match &event.body {
        ProviderRuntimeEventBody::TurnCompleted(payload) => payload.state,
        _ => match runtime_payload_record(event).as_ref().and_then(|p| p.get("state")).and_then(Value::as_str) {
            Some("failed") => RuntimeTurnState::Failed,
            Some("interrupted") => RuntimeTurnState::Interrupted,
            Some("cancelled") => RuntimeTurnState::Cancelled,
            _ => RuntimeTurnState::Completed,
        },
    }
}

fn request_kind_from_canonical_request_type(request_type: CanonicalRequestType) -> Option<&'static str> {
    use CanonicalRequestType as R;
    match request_type {
        R::CommandExecutionApproval | R::ExecCommandApproval => Some("command"),
        R::FileReadApproval => Some("file-read"),
        R::PermissionsApproval => Some("permissions"),
        R::ToolApproval => Some("tool"),
        // Legacy Claude classification: generic/MCP tool approvals were labelled with the
        // item type instead of the canonical "tool_approval".
        R::DynamicToolCall => Some("tool"),
        R::FileChangeApproval | R::ApplyPatchApproval => Some("file-change"),
        _ => None,
    }
}

fn requested_permission_profile(payload: &RequestOpenedPayload) -> Option<Value> {
    if payload.request_type != CanonicalRequestType::PermissionsApproval {
        return None;
    }
    let permissions = as_object(payload.args.as_ref())
        .and_then(|args| args.get("permissions"))
        .and_then(Value::as_object)?;
    (!permissions.is_empty()).then(|| bound_activity_data(&Value::Object(permissions.clone())))
}

fn session_approval_available(payload: &RequestOpenedPayload) -> Option<bool> {
    as_object(payload.args.as_ref())
        .and_then(|args| args.get("sessionApprovalAvailable"))
        .and_then(Value::as_bool)
}

/// Approval cards render `toolParamsDisplay` entries as name/value rows.
fn tool_params_display_from_tool_input(input: Option<&Map<String, Value>>) -> Option<Vec<Value>> {
    let input = input?;
    let entries: Vec<Value> = input
        .iter()
        .map(|(name, value)| json!({ "name": name, "value": value }))
        .collect();
    (!entries.is_empty()).then_some(entries)
}

fn tool_param_display_value(names: &[Option<&str>], value: Option<&Value>) -> String {
    if names.iter().any(|name| name.is_some_and(is_sensitive_key)) {
        return REDACTED_SENSITIVE_VALUE.to_string();
    }
    match value {
        Some(Value::String(text)) => redact_structured_tool_param_string(text),
        Some(other) => safe_stringify_tool_param_value(other),
        None => "undefined".to_string(),
    }
}

fn redact_structured_tool_param_string(value: &str) -> String {
    let trimmed = value.trim();
    if !trimmed.starts_with('{') && !trimmed.starts_with('[') {
        return value.to_string();
    }
    match serde_json::from_str::<Value>(value) {
        Ok(parsed @ (Value::Object(_) | Value::Array(_))) => {
            let mut redacted = false;
            let cleaned = redact_sensitive_json_fields(&parsed, &mut redacted);
            if redacted {
                stringify_json_like(&cleaned)
            } else {
                value.to_string()
            }
        }
        _ => value.to_string(),
    }
}

fn safe_stringify_tool_param_value(value: &Value) -> String {
    let mut redacted = false;
    stringify_json_like(&redact_sensitive_json_fields(value, &mut redacted))
}

fn requested_mcp_tool_call_presentation(payload: &RequestOpenedPayload) -> Map<String, Value> {
    let mut out = Map::new();
    if payload.request_type != CanonicalRequestType::ToolApproval
        && payload.request_type != CanonicalRequestType::DynamicToolCall
    {
        return out;
    }
    let args = as_object(payload.args.as_ref());
    let metadata = args.and_then(|a| a.get("_meta")).and_then(Value::as_object);
    let title = as_str(metadata.and_then(|m| m.get("tool_title")));
    let tool_name = as_str(metadata.and_then(|m| m.get("tool_name")))
        .or_else(|| as_str(args.and_then(|a| a.get("toolName"))));
    let raw_params: Option<Vec<Value>> = match metadata.and_then(|m| m.get("tool_params_display")) {
        Some(Value::Array(items)) => Some(items.clone()),
        _ => tool_params_display_from_tool_input(args.and_then(|a| a.get("input")).and_then(Value::as_object)),
    };
    let tool_params_display = raw_params.map(|params| {
        params
            .iter()
            .take(12)
            .map(|entry| {
                let row = entry.as_object();
                let name = as_str(row.and_then(|r| r.get("name")));
                let display_name = as_str(row.and_then(|r| r.get("display_name")));
                let mut out = Map::new();
                if let Some(display_name) = display_name.filter(|d| !d.is_empty()) {
                    out.insert("display_name".into(), json!(truncate_json_string(display_name, 128)));
                }
                out.insert("name".into(), json!(truncate_json_string(name.unwrap_or("argument"), 128)));
                out.insert(
                    "value".into(),
                    json!(truncate_json_string(
                        &tool_param_display_value(&[name, display_name], row.and_then(|r| r.get("value"))),
                        900
                    )),
                );
                Value::Object(out)
            })
            .collect::<Vec<_>>()
    });
    if let Some(title) = title.filter(|t| !t.is_empty()) {
        out.insert("title".into(), json!(truncate_json_string(title, 128)));
    }
    if let Some(tool_name) = tool_name.filter(|t| !t.is_empty()) {
        out.insert("toolName".into(), json!(tool_name));
    }
    if let Some(display) = tool_params_display {
        out.insert("toolParamsDisplay".into(), Value::Array(display));
    }
    out
}

fn non_empty_trimmed(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn activity(
    event: &ProviderRuntimeEvent,
    id: EventId,
    tone: OrchestrationThreadActivityTone,
    kind: &str,
    summary: impl Into<String>,
    payload: Value,
    sequence: Option<u64>,
) -> OrchestrationThreadActivity {
    OrchestrationThreadActivity {
        id,
        tone,
        kind: kind.to_string(),
        summary: summary.into(),
        payload: to_activity_payload(payload),
        turn_id: to_turn_id(event.turn_id.as_ref()),
        sequence,
        created_at: event.created_at.clone(),
    }
}

/// Synara `projectProviderRuntimeActivities`.
pub fn project_provider_runtime_activities(
    event: &ProviderRuntimeEvent,
    session_sequence: Option<u64>,
) -> Vec<OrchestrationThreadActivity> {
    use OrchestrationThreadActivityTone as Tone;
    use ProviderRuntimeEventBody as B;
    let provider = event.provider.as_str();
    let maybe_sequence = session_sequence;

    // Claude previews are coalesced by ingestion; other providers publish their readable
    // reasoning only at completion. Empty/encrypted boundaries stay hidden.
    let reasoning_item = match &event.body {
        B::ItemCompleted(p) if provider == "codex" || provider == "antigravity" => Some(p),
        B::ItemUpdated(p) | B::ItemCompleted(p) if provider == "claudeAgent" => Some(p),
        _ => None,
    };
    if let (Some(payload), Some(item_id)) = (reasoning_item, event.item_id.as_ref()) {
        if payload.item_type == CanonicalItemType::Reasoning {
            if let Some(reasoning_detail) = readable_reasoning_detail(payload.detail.as_deref()) {
                let mut out = Map::new();
                if let Some(status) = payload.status {
                    out.insert("status".into(), json!(wire(&status)));
                }
                out.insert(
                    "detail".into(),
                    json!(truncate_detail(
                        &reasoning_detail,
                        if provider == "claudeAgent" {
                            MAX_REASONING_DETAIL_CHARS
                        } else {
                            MAX_ACTIVITY_DATA_STRING_CHARS
                        }
                    )),
                );
                out.insert("data".into(), json!({ "toolCallId": item_id.as_str() }));
                return vec![activity(
                    event,
                    EventId::new(format!("provider-reasoning:{}:{}", event.thread_id, item_id)),
                    Tone::Tool,
                    "task.progress",
                    "Reasoning trace",
                    Value::Object(out),
                    maybe_sequence,
                )];
            }
        }
    }

    let id = event.event_id.clone();
    match &event.body {
        B::SessionConfigured(_) => match build_configured_context_window_payload(event) {
            Some(payload) => vec![activity(
                event,
                id,
                Tone::Info,
                "context-window.configured",
                "Context window configured",
                payload,
                maybe_sequence,
            )],
            None => vec![],
        },

        B::RequestOpened(_) | B::RequestResolved(_) => {
            let (request_type, opened) = match &event.body {
                B::RequestOpened(p) => (p.request_type, Some(p)),
                B::RequestResolved(p) => (p.request_type, None),
                _ => unreachable!(),
            };
            if request_type == CanonicalRequestType::ToolUserInput {
                return vec![];
            }
            let request_kind = request_kind_from_canonical_request_type(request_type);
            let request_id = non_empty_trimmed(event.request_id.as_ref().map(|r| r.as_str()));
            let summary = if opened.is_none() {
                "Approval resolved"
            } else {
                match request_kind {
                    Some("command") => "Command approval requested",
                    Some("file-read") => "File-read approval requested",
                    Some("file-change") => "File-change approval requested",
                    Some("permissions") => "Permission approval requested",
                    Some("tool") => "Tool approval requested",
                    _ => "Approval requested",
                }
            };
            let mut out = Map::new();
            if let Some(request_id) = request_id {
                out.insert("requestId".into(), json!(ApprovalRequestId::new(request_id)));
            }
            if let Some(generation) = &event.lifecycle_generation {
                out.insert("lifecycleGeneration".into(), json!(generation));
            }
            if let Some(kind) = request_kind {
                out.insert("requestKind".into(), json!(kind));
            }
            out.insert("requestType".into(), json!(wire(&request_type)));
            if let Some(opened) = opened {
                if let Some(detail) = opened.detail.as_deref().filter(|d| !d.is_empty()) {
                    out.insert("detail".into(), json!(truncate_detail(detail, MAX_ACTIVITY_DATA_STRING_CHARS)));
                }
                if let Some(profile) = requested_permission_profile(opened) {
                    out.insert("permissionProfile".into(), profile);
                }
                out.extend(requested_mcp_tool_call_presentation(opened));
                if let Some(available) = session_approval_available(opened) {
                    out.insert("sessionApprovalAvailable".into(), json!(available));
                }
            }
            if let B::RequestResolved(resolved) = &event.body {
                if let Some(decision) = resolved.decision.as_deref().filter(|d| !d.is_empty()) {
                    out.insert("decision".into(), json!(decision));
                }
            }
            vec![activity(
                event,
                id,
                Tone::Approval,
                if opened.is_some() { "approval.requested" } else { "approval.resolved" },
                summary,
                Value::Object(out),
                maybe_sequence,
            )]
        }

        B::RuntimeError(payload) => {
            if payload.message.is_empty() {
                return vec![];
            }
            let mut out = Map::new();
            out.insert("message".into(), json!(truncate_detail(&payload.message, 500)));
            if let Some(class) = payload.class {
                out.insert("class".into(), json!(wire(&class)));
            }
            vec![activity(event, id, Tone::Error, "runtime.error", "Provider runtime error", Value::Object(out), maybe_sequence)]
        }

        B::RuntimeWarning(payload) => {
            let raw_payload = event.raw.as_ref().map(|raw| &raw.payload);
            let native_type = as_str(as_object(raw_payload).and_then(|p| p.get("type")));
            let detail_subtype = as_str(as_object(payload.detail.as_ref()).and_then(|d| d.get("subtype")));
            let is_background_move = detail_subtype == Some("background_tasks_changed");
            let is_claude_retry = provider == "claudeAgent" && detail_subtype == Some("api_retry");
            let is_pi_info_notification = provider == "pi"
                && event.raw.as_ref().and_then(|raw| raw.method.as_deref()) == Some("extension/ui/notify")
                && as_str(as_object(payload.detail.as_ref()).and_then(|d| d.get("type"))) == Some("info");
            let message = truncate_detail(&payload.message, MAX_ACTIVITY_DATA_STRING_CHARS);
            let summary = if is_pi_info_notification {
                "Pi extension".to_string()
            } else if is_claude_retry {
                message.clone()
            } else if is_background_move {
                "Moved to background".to_string()
            } else if provider == "opencode"
                && matches!(native_type, Some("session.next.retried") | Some("session.status"))
            {
                "OpenCode retrying".to_string()
            } else {
                "Runtime warning".to_string()
            };
            let mut out = Map::new();
            out.insert("message".into(), json!(message));
            out.insert("detail".into(), json!(message));
            if is_background_move || is_claude_retry {
                if let Some(subtype) = detail_subtype {
                    out.insert("nativeEventType".into(), json!(subtype));
                }
            } else if let Some(native_type) = native_type.filter(|t| !t.is_empty()) {
                out.insert("nativeEventType".into(), json!(native_type));
            }
            activity_data_field(&mut out, payload.detail.as_ref());
            vec![activity(event, id, Tone::Info, "runtime.warning", summary, Value::Object(out), maybe_sequence)]
        }

        B::ModelRerouted(payload) => vec![activity(
            event,
            id,
            Tone::Info,
            "model.rerouted",
            format!("Model switched: {} -> {}", payload.from_model, payload.to_model),
            json!({
                "fromModel": payload.from_model,
                "toModel": payload.to_model,
                "detail": truncate_detail(&payload.reason, 500),
            }),
            maybe_sequence,
        )],

        B::TurnTasksUpdated(payload) => {
            let mut out = Map::new();
            out.insert("tasks".into(), serde_json::to_value(&payload.tasks).unwrap_or(Value::Null));
            if let Some(explanation) = &payload.explanation {
                out.insert("explanation".into(), json!(explanation));
            }
            vec![activity(event, id, Tone::Info, "turn.tasks.updated", "Tasks updated", Value::Object(out), maybe_sequence)]
        }

        B::UserInputRequested(_) | B::UserInputResolved(_) => {
            let requested = matches!(event.body, B::UserInputRequested(_));
            let mut out = Map::new();
            if let Some(request_id) = event.request_id.as_ref().filter(|r| !r.as_str().is_empty()) {
                out.insert("requestId".into(), json!(request_id));
            }
            if let Some(generation) = &event.lifecycle_generation {
                out.insert("lifecycleGeneration".into(), json!(generation));
            }
            match &event.body {
                B::UserInputRequested(p) => {
                    out.insert("questions".into(), serde_json::to_value(&p.questions).unwrap_or(Value::Null));
                }
                B::UserInputResolved(p) => {
                    out.insert("answers".into(), Value::Object(p.answers.clone()));
                }
                _ => {}
            }
            vec![activity(
                event,
                id,
                Tone::Info,
                if requested { "user-input.requested" } else { "user-input.resolved" },
                if requested { "User input requested" } else { "User input submitted" },
                Value::Object(out),
                maybe_sequence,
            )]
        }

        B::TaskStarted(payload) => {
            let summary = match payload.task_type.as_deref() {
                Some("plan") => "Plan task started".to_string(),
                Some(task_type) if !task_type.is_empty() => format!("{task_type} task started"),
                _ => "Task started".to_string(),
            };
            let mut out = Map::new();
            out.insert("taskId".into(), json!(payload.task_id));
            insert_non_empty(&mut out, "taskType", payload.task_type.as_deref());
            insert_non_empty(&mut out, "subagentType", payload.subagent_type.as_deref());
            insert_non_empty(&mut out, "workflowName", payload.workflow_name.as_deref());
            insert_non_empty(&mut out, "workflowTaskId", payload.workflow_task_id.as_ref().map(|t| t.as_str()));
            if let Some(phases) = &payload.workflow_phases {
                out.insert("workflowPhases".into(), serde_json::to_value(phases).unwrap_or(Value::Null));
            }
            if let Some(phases) = &payload.workflow_agent_phases {
                out.insert("workflowAgentPhases".into(), serde_json::to_value(phases).unwrap_or(Value::Null));
            }
            if let Some(plans) = &payload.workflow_agent_plans {
                out.insert("workflowAgentPlans".into(), serde_json::to_value(plans).unwrap_or(Value::Null));
            }
            insert_non_empty(&mut out, "toolUseId", payload.tool_use_id.as_deref());
            if let Some(description) = payload.description.as_deref().filter(|d| !d.is_empty()) {
                out.insert("detail".into(), json!(truncate_detail(description, 180)));
            }
            vec![activity(event, id, Tone::Info, "task.started", summary, Value::Object(out), maybe_sequence)]
        }

        B::TaskProgress(payload) => {
            let mut out = Map::new();
            out.insert("taskId".into(), json!(payload.task_id));
            out.insert(
                "detail".into(),
                json!(truncate_detail(payload.summary.as_deref().unwrap_or(&payload.description), 180)),
            );
            out.insert("description".into(), json!(truncate_detail(&payload.description, 180)));
            if let Some(summary) = payload.summary.as_deref().filter(|s| !s.is_empty()) {
                out.insert("summary".into(), json!(truncate_detail(summary, 180)));
            }
            insert_non_empty(&mut out, "lastToolName", payload.last_tool_name.as_deref());
            if let Some(usage) = &payload.usage {
                out.insert("usage".into(), usage.clone());
            }
            insert_non_empty(&mut out, "workflowTaskId", payload.workflow_task_id.as_ref().map(|t| t.as_str()));
            if let Some(agents) = &payload.workflow_agents {
                out.insert("workflowAgents".into(), serde_json::to_value(agents).unwrap_or(Value::Null));
            }
            vec![activity(event, id, Tone::Info, "task.progress", "Reasoning update", Value::Object(out), maybe_sequence)]
        }

        B::TaskCompleted(payload) => {
            use crate::contracts::provider_runtime::TaskCompletedStatus as S;
            let failed = payload.status == S::Failed;
            let summary = match payload.status {
                S::Failed => "Task failed",
                S::Stopped => "Task stopped",
                S::Completed => "Task completed",
            };
            let mut out = Map::new();
            out.insert("taskId".into(), json!(payload.task_id));
            out.insert("status".into(), json!(wire(&payload.status)));
            if let Some(summary) = payload.summary.as_deref().filter(|s| !s.is_empty()) {
                out.insert("detail".into(), json!(truncate_detail(summary, MAX_ACTIVITY_DATA_STRING_CHARS)));
            }
            if let Some(usage) = &payload.usage {
                out.insert("usage".into(), usage.clone());
            }
            insert_non_empty(&mut out, "workflowTaskId", payload.workflow_task_id.as_ref().map(|t| t.as_str()));
            if let Some(agents) = &payload.workflow_agents {
                out.insert("workflowAgents".into(), serde_json::to_value(agents).unwrap_or(Value::Null));
            }
            vec![activity(
                event,
                id,
                if failed { Tone::Error } else { Tone::Info },
                "task.completed",
                summary,
                Value::Object(out),
                maybe_sequence,
            )]
        }

        B::TaskUpdated(payload) => {
            use crate::contracts::provider_runtime::TaskUpdatedStatus as S;
            let summary = match payload.status {
                Some(S::Paused) => "Task paused",
                Some(S::Killed) => "Task killed",
                _ if payload.is_backgrounded == Some(true) => "Task moved to background",
                _ => "Task updated",
            };
            let mut out = Map::new();
            out.insert("taskId".into(), json!(payload.task_id));
            if let Some(status) = payload.status {
                out.insert("status".into(), json!(wire(&status)));
            }
            if let Some(backgrounded) = payload.is_backgrounded {
                out.insert("isBackgrounded".into(), json!(backgrounded));
            }
            insert_non_empty(&mut out, "toolUseId", payload.tool_use_id.as_deref());
            if let Some(error) = payload.error.as_deref().filter(|e| !e.is_empty()) {
                out.insert("detail".into(), json!(truncate_detail(error, MAX_ACTIVITY_DATA_STRING_CHARS)));
            }
            insert_non_empty(&mut out, "workflowTaskId", payload.workflow_task_id.as_ref().map(|t| t.as_str()));
            insert_non_empty(&mut out, "workflowRunId", payload.workflow_run_id.as_deref());
            insert_non_empty(&mut out, "workflowScriptPath", payload.workflow_script_path.as_deref());
            vec![activity(
                event,
                id,
                if payload.status == Some(S::Failed) { Tone::Error } else { Tone::Info },
                "task.updated",
                summary,
                Value::Object(out),
                maybe_sequence,
            )]
        }

        B::TurnSteered(payload) => {
            // A steer of the thread's own turn is already visible as the sent user message.
            if payload.target == Some(crate::contracts::provider_runtime::TurnSteeredTarget::Turn) {
                return vec![];
            }
            vec![activity(
                event,
                id,
                Tone::Info,
                "turn.steered",
                "User message delivered",
                json!({ "detail": truncate_detail(&payload.message, 180) }),
                maybe_sequence,
            )]
        }

        B::ThreadStateChanged(payload) => {
            if payload.state != crate::contracts::provider_runtime::RuntimeThreadState::Compacted {
                return vec![];
            }
            let mut out = Map::new();
            out.insert("state".into(), json!(wire(&payload.state)));
            if let Some(detail) = &payload.detail {
                out.insert("detail".into(), detail.clone());
            }
            vec![activity(event, id, Tone::Info, "context-compaction", "Context compacted manually", Value::Object(out), maybe_sequence)]
        }

        B::ThreadTokenUsageUpdated(_) => match build_context_window_activity_payload(event) {
            Some(payload) => vec![activity(
                event,
                id,
                Tone::Info,
                "context-window.updated",
                "Context window updated",
                payload,
                maybe_sequence,
            )],
            None => vec![],
        },

        B::ItemUpdated(payload) | B::ItemCompleted(payload) | B::ItemStarted(payload) => {
            let event_type = runtime_event_type(event);
            let item_type = wire(&payload.item_type);
            if payload.item_type == CanonicalItemType::ContextCompaction {
                let failed = event_type == "item.completed"
                    && payload.status == Some(crate::contracts::provider_runtime::RuntimeItemStatus::Failed);
                let mut out = Map::new();
                out.insert("itemType".into(), json!(item_type));
                if let Some(status) = payload.status {
                    out.insert("status".into(), json!(wire(&status)));
                }
                if let Some(detail) = payload.detail.as_deref().filter(|d| !d.is_empty()) {
                    out.insert("detail".into(), json!(truncate_detail(detail, 180)));
                }
                activity_data_field(&mut out, payload.data.as_ref());
                return vec![activity(
                    event,
                    id,
                    if failed { Tone::Error } else { Tone::Info },
                    "context-compaction",
                    if event_type != "item.completed" {
                        "Compacting context"
                    } else if failed {
                        "Context compaction failed"
                    } else {
                        "Context compacted"
                    },
                    Value::Object(out),
                    maybe_sequence,
                )];
            }
            if !is_tool_lifecycle_item_type(&item_type) {
                return vec![];
            }
            let item_title = non_empty_trimmed(payload.title.as_deref());
            let kind = match event_type {
                "item.started" => "tool.started",
                "item.completed" => "tool.completed",
                _ => "tool.updated",
            };
            let summary = if event_type == "item.started" {
                format!("{} started", item_title.as_deref().unwrap_or("Tool"))
            } else {
                item_title.clone().unwrap_or_else(|| {
                    if event_type == "item.completed" { "Tool" } else { "Tool updated" }.to_string()
                })
            };
            let mut out = Map::new();
            out.insert("itemType".into(), json!(item_type));
            if let Some(status) = payload.status {
                out.insert("status".into(), json!(wire(&status)));
            }
            if let Some(title) = &item_title {
                out.insert("title".into(), json!(title));
            }
            if let Some(detail) = payload.detail.as_deref().filter(|d| !d.is_empty()) {
                out.insert("detail".into(), json!(truncate_detail(detail, 180)));
            }
            activity_data_field(&mut out, payload.data.as_ref());
            vec![activity(event, id, Tone::Tool, kind, summary, Value::Object(out), maybe_sequence)]
        }

        B::ToolSummary(payload) => {
            if provider != "claudeAgent" {
                return vec![];
            }
            let Some(summary) = non_empty_trimmed(Some(&payload.summary)) else {
                return vec![];
            };
            let preceding = payload.preceding_tool_use_ids.as_ref();
            let activity_id = match preceding.and_then(|ids| ids.last()) {
                Some(last) => EventId::new(format!(
                    "provider-tool-summary:{}:{}:{}:{}",
                    provider,
                    event.thread_id,
                    event.turn_id.as_ref().map(|t| t.as_str()).unwrap_or("session"),
                    last
                )),
                None => id,
            };
            let mut out = Map::new();
            out.insert("detail".into(), json!(truncate_detail(&summary, MAX_REASONING_DETAIL_CHARS)));
            if let Some(ids) = preceding {
                out.insert("data".into(), json!({ "precedingToolUseIds": ids }));
            }
            vec![activity(event, activity_id, Tone::Info, "tool.summary", "Tool summary", Value::Object(out), maybe_sequence)]
        }

        B::AuthStatus(payload) => {
            if provider != "claudeAgent" {
                return vec![];
            }
            let failed = non_empty_trimmed(payload.error.as_deref()).is_some();
            if !failed && payload.is_authenticating.is_none() {
                return vec![];
            }
            let summary = if failed {
                "Claude authentication needs attention."
            } else if payload.is_authenticating == Some(true) {
                "Claude authentication started"
            } else {
                "Claude authentication finished"
            };
            let mut out = Map::new();
            out.insert("provider".into(), json!(provider));
            if failed {
                out.insert("detail".into(), json!("Check your Claude account in Settings."));
            }
            vec![activity(
                event,
                id,
                if failed { Tone::Error } else { Tone::Info },
                "auth.status",
                summary,
                Value::Object(out),
                maybe_sequence,
            )]
        }

        B::ToolProgress(payload) => {
            let summary = non_empty_trimmed(payload.tool_name.as_deref())
                .or_else(|| non_empty_trimmed(payload.summary.as_deref()))
                .unwrap_or_else(|| "MCP tool call".to_string());
            vec![activity(
                event,
                id,
                Tone::Tool,
                "tool.updated",
                summary,
                build_tool_progress_activity_payload(payload),
                maybe_sequence,
            )]
        }

        B::TurnCompleted(payload) => {
            let state = runtime_turn_state(event);
            let model_usage = compact_turn_model_usage(payload.model_usage.as_ref());
            let error_message = payload.error_message.as_deref().filter(|m| !m.is_empty());
            let interrupted = matches!(state, RuntimeTurnState::Interrupted | RuntimeTurnState::Cancelled);
            let summary = if state == RuntimeTurnState::Failed {
                "Turn failed"
            } else if interrupted {
                "Turn interrupted"
            } else {
                "Turn completed"
            };
            let mut out = Map::new();
            out.insert("state".into(), json!(wire(&state)));
            if provider == "claudeAgent" {
                out.insert("provider".into(), json!(provider));
            }
            if payload.token_accounting_version == Some(1) {
                out.insert("tokenAccountingVersion".into(), json!(1));
                if let Some(tokens) = payload.main_loop_tokens {
                    out.insert("mainLoopTokens".into(), json!(tokens));
                }
            }
            if let Some(model_usage) = model_usage {
                out.insert("modelUsage".into(), model_usage);
            }
            if let Some(cost) = payload.total_cost_usd {
                out.insert("totalCostUsd".into(), json!(cost));
            }
            if let Some(cost) = payload.cumulative_cost_usd {
                out.insert("cumulativeCostUsd".into(), json!(cost));
            }
            if let Some(message) = error_message {
                out.insert("errorMessage".into(), json!(message));
            }
            vec![activity(
                event,
                id,
                if state == RuntimeTurnState::Failed { Tone::Error } else { Tone::Info },
                "turn.completed",
                summary,
                Value::Object(out),
                maybe_sequence,
            )]
        }

        // Hook lifecycle is operational evidence, not transcript content.
        B::HookStarted(_) | B::HookProgress(_) => vec![],

        B::HookCompleted(payload) => {
            use crate::contracts::provider_runtime::{HookCompletedStatus as S, HookOutcome as O};
            let status = payload.status;
            if payload.outcome == O::Success || (payload.outcome == O::Cancelled && status.is_none()) {
                return vec![];
            }
            let hook_label = payload.hook_event.as_deref().unwrap_or("Lifecycle");
            let summary = match status {
                Some(S::Blocked) => format!("{hook_label} hook blocked an action"),
                Some(S::Stopped) => format!("{hook_label} hook stopped execution"),
                _ => format!("{hook_label} hook failed"),
            };
            let message = truncate_detail(
                payload
                    .status_message
                    .as_deref()
                    .or(payload.stderr.as_deref())
                    .or(payload.output.as_deref())
                    .or(payload.stdout.as_deref())
                    .unwrap_or(&summary),
                500,
            );
            let mut out = Map::new();
            out.insert("message".into(), json!(message));
            out.insert("detail".into(), json!(message));
            out.insert("hookId".into(), json!(payload.hook_id));
            insert_non_empty(&mut out, "hookName", payload.hook_name.as_deref());
            insert_non_empty(&mut out, "hookEvent", payload.hook_event.as_deref());
            out.insert("outcome".into(), json!(wire(&payload.outcome)));
            if let Some(status) = status {
                out.insert("status".into(), json!(wire(&status)));
            }
            if let Some(duration) = payload.duration_ms {
                out.insert("durationMs".into(), json!(duration));
            }
            vec![activity(
                event,
                id,
                if status == Some(S::Failed) || payload.outcome == O::Error { Tone::Error } else { Tone::Info },
                "runtime.warning",
                summary,
                Value::Object(out),
                maybe_sequence,
            )]
        }

        B::AccountRateLimitsUpdated(payload) => {
            let Some(rl) = payload.rate_limits.as_object() else {
                return vec![];
            };
            if rl.is_empty() {
                return vec![];
            }
            let status = rl.get("status").and_then(Value::as_str).map(str::to_string);
            let resets_at = normalize_resets_at(rl.get("resetsAt"));
            let limits: Option<Vec<Value>> = rl.get("limits").and_then(Value::as_array).map(|raw| {
                raw.iter()
                    .filter_map(Value::as_object)
                    .filter(|l| l.get("window").is_some_and(Value::is_string))
                    .map(|l| {
                        let mut limit = Map::new();
                        limit.insert("window".into(), l["window"].clone());
                        if let Some(u) = l.get("utilization").filter(|u| u.is_number()) {
                            limit.insert("utilization".into(), u.clone());
                        }
                        if let Some(r) = normalize_resets_at(l.get("resetsAt")) {
                            limit.insert("resetsAt".into(), json!(r));
                        }
                        Value::Object(limit)
                    })
                    .collect()
            });
            let mut normalized = Map::new();
            normalized.insert("provider".into(), json!(provider));
            normalized.extend(rl.clone());
            if let Some(resets_at) = resets_at {
                normalized.insert("resetsAt".into(), json!(resets_at));
            }
            if let Some(limits) = limits.filter(|l| !l.is_empty()) {
                normalized.insert("limits".into(), Value::Array(limits));
            }
            let mut activities = vec![activity(
                event,
                id.clone(),
                Tone::Info,
                "account.rate-limits.updated",
                "Rate limits updated",
                Value::Object(normalized.clone()),
                maybe_sequence,
            )];
            match status.as_deref() {
                Some(status @ ("rejected" | "allowed_warning")) => {
                    let mut limited = normalized;
                    limited.insert("status".into(), json!(status));
                    activities.push(activity(
                        event,
                        id,
                        if status == "rejected" { Tone::Error } else { Tone::Info },
                        "account.rate-limited",
                        if status == "rejected" { "Rate limited" } else { "Approaching rate limit" },
                        Value::Object(limited),
                        maybe_sequence,
                    ));
                    activities
                }
                _ => activities,
            }
        }

        B::EventUnmapped(payload) => {
            if payload.native_type.is_empty() {
                return vec![];
            }
            let mut out = Map::new();
            out.insert("nativeEventType".into(), json!(payload.native_type));
            if let Some(detail) = payload.detail.as_deref().filter(|d| !d.is_empty()) {
                out.insert("detail".into(), json!(truncate_detail(detail, MAX_UNMAPPED_PROVIDER_DETAIL_CHARS)));
            }
            if let Some(data) = &payload.data {
                out.insert("data".into(), sanitize_unmapped_provider_data(data));
            }
            vec![activity(event, id, Tone::Info, "provider.event.unmapped", payload.native_type.clone(), Value::Object(out), maybe_sequence)]
        }

        _ => vec![],
    }
}

fn insert_non_empty(out: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|v| !v.is_empty()) {
        out.insert(key.into(), json!(value));
    }
}

/// Claude sends Unix seconds, Codex may send an ISO string.
fn normalize_resets_at(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::Number(n) => {
            let millis = (n.as_f64()? * 1000.0) as i64;
            chrono::DateTime::from_timestamp_millis(millis)
                .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        }
        Value::String(s) => Some(s.clone()),
        _ => None,
    }
}

/// Synara `providerActivityUpdateDedupeKey`: the key under which a repeated update row (context
/// window, rate limits, task progress, tool progress) replaces its previous value.
pub fn provider_activity_update_dedupe_key(
    event: &ProviderRuntimeEvent,
    thread_id: &ThreadId,
    activity: &OrchestrationThreadActivity,
) -> Option<String> {
    let prefix = format!("{}:{}:{}", thread_id, event.provider, activity.kind);
    if activity.kind == "context-window.updated" || activity.kind == "account.rate-limits.updated" {
        return Some(prefix);
    }
    let payload = activity.payload.as_object();
    if activity.kind == "task.progress" {
        if let ProviderRuntimeEventBody::ItemUpdated(p) | ProviderRuntimeEventBody::ItemCompleted(p) = &event.body {
            if p.item_type == CanonicalItemType::Reasoning {
                if let Some(item_id) = &event.item_id {
                    return Some(format!("{prefix}:reasoning:{item_id}"));
                }
            }
        }
        return as_str(payload.and_then(|p| p.get("taskId"))).map(|task_id| format!("{prefix}:{task_id}"));
    }
    if activity.kind != "tool.updated" {
        return None;
    }
    let data = payload.and_then(|p| p.get("data")).and_then(Value::as_object);
    let tool_update_id = event.item_id.as_ref().map(|i| i.as_str().to_string()).or_else(|| {
        ["toolUseId", "toolCallId", "callId", "callID"]
            .iter()
            .find_map(|key| as_str(data.and_then(|d| d.get(*key))).map(str::to_string))
    });
    tool_update_id.map(|id| format!("{prefix}:{id}"))
}

/// Synara `providerActivityUpdateFingerprint`.
pub fn provider_activity_update_fingerprint(activity: &OrchestrationThreadActivity) -> String {
    stringify_json_like(&json!({
        "kind": activity.kind,
        "summary": activity.summary,
        "payload": activity.payload,
        "turnId": activity.turn_id,
    }))
}

/// The first `limit` entries in rank/name order (Synara `selectLeadingActivityPayloadEntries`).
fn select_leading_activity_payload_entries(
    entries: &Map<String, Value>,
    limit: usize,
) -> Vec<(&String, &Value)> {
    let mut sorted: Vec<(&String, &Value)> = entries.iter().collect();
    sorted.sort_by(|left, right| {
        activity_payload_key_rank(left.0)
            .cmp(&activity_payload_key_rank(right.0))
            .then_with(|| left.0.cmp(right.0))
    });
    sorted.truncate(limit);
    sorted
}

// --- Synara `apps/server/src/sensitiveKeys.ts` (without `isProviderCredentialKey`) ---

const EXACT_SENSITIVE_KEYS: &[&str] = &[
    "accesskey", "accesskeyid", "apikey", "authtoken", "authorization", "clientsecret", "cookie",
    "cookies", "credential", "credentials", "idtoken", "passphrase", "passwd", "password",
    "privatekey", "proxyauthorization", "pwd", "refreshtoken", "secret", "secretkey",
    "sessiontoken", "setcookie", "token",
];
const SECRET_TERMINAL_WORDS: &[&str] = &[
    "authorization", "cookie", "cookies", "credential", "credentials", "passphrase", "passwd",
    "password", "pwd", "secret", "secrets",
];
const SECRET_TOKEN_QUALIFIERS: &[&str] = &[
    "access", "api", "auth", "bearer", "bot", "client", "gateway", "id", "jwt", "machine", "oauth",
    "personal", "refresh", "secret", "service", "session", "sso", "user", "webhook",
];

fn key_tokens(key: &str) -> Vec<String> {
    // camelCase and ACRONYMCase boundaries become word boundaries, then split on non-alnum.
    let chars: Vec<char> = key.chars().collect();
    let mut spaced = String::new();
    for (index, &c) in chars.iter().enumerate() {
        if index > 0 && c.is_ascii_uppercase() {
            let previous = chars[index - 1];
            let next = chars.get(index + 1).copied();
            if previous.is_ascii_lowercase() || previous.is_ascii_digit() {
                spaced.push(' ');
            } else if previous.is_ascii_uppercase() && next.is_some_and(|n| n.is_ascii_lowercase()) {
                spaced.push(' ');
            }
        }
        spaced.push(c);
    }
    spaced
        .to_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .collect()
}

/// True when a JSON object key names a credential rather than benign metadata.
pub(crate) fn is_sensitive_key(key: &str) -> bool {
    let normalized: String = key.chars().filter(char::is_ascii_alphanumeric).collect::<String>().to_lowercase();
    if EXACT_SENSITIVE_KEYS.contains(&normalized.as_str()) {
        return true;
    }
    let tokens = key_tokens(key);
    let Some(terminal) = tokens.last() else {
        return false;
    };
    if SECRET_TERMINAL_WORDS.contains(&terminal.as_str()) {
        return true;
    }
    if terminal == "token" || terminal == "tokens" {
        return match tokens.len().checked_sub(2).map(|i| tokens[i].as_str()) {
            None => true,
            Some(qualifier) => SECRET_TOKEN_QUALIFIERS.contains(&qualifier),
        };
    }
    terminal == "key"
        && tokens[..tokens.len() - 1]
            .iter()
            .any(|t| ["api", "private", "proxy", "secret"].contains(&t.as_str()))
}

const REDACTED_SENSITIVE_VALUE: &str = "[redacted]";

fn redact_sensitive_json_fields(value: &Value, redacted: &mut bool) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, entry)| {
                    if is_sensitive_key(key) {
                        *redacted = true;
                        (key.clone(), json!(REDACTED_SENSITIVE_VALUE))
                    } else {
                        (key.clone(), redact_sensitive_json_fields(entry, redacted))
                    }
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(|v| redact_sensitive_json_fields(v, redacted)).collect()),
        other => other.clone(),
    }
}

// --- reduced Synara `apps/server/src/provider/unmappedProviderEvents.ts` sanitizers ---

const MAX_UNMAPPED_PROVIDER_DETAIL_CHARS: usize = 2_000;
const MAX_UNMAPPED_PROVIDER_DATA_JSON_CHARS: usize = 8_000;
const MAX_UNMAPPED_PROVIDER_PREVIEW_CHARS: usize = 2_000;

fn sanitize_unmapped_provider_data(value: &Value) -> Value {
    let mut redacted_any = false;
    let redacted = redact_sensitive_json_fields(value, &mut redacted_any);
    let serialized = stringify_json_like(&redacted);
    if js_len(&serialized) <= MAX_UNMAPPED_PROVIDER_DATA_JSON_CHARS {
        return redacted;
    }
    json!({
        ACTIVITY_DATA_TRUNCATION_MARKER: true,
        "originalJsonChars": js_len(&serialized),
        "preview": format!("{}...", js_slice(&serialized, MAX_UNMAPPED_PROVIDER_PREVIEW_CHARS - 3)),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn event(sample: Value) -> ProviderRuntimeEvent {
        serde_json::from_value(sample).unwrap()
    }

    fn base(kind: &str, payload: Value) -> Value {
        json!({
            "eventId": "evt-1",
            "provider": "codex",
            "threadId": "thread-1",
            "createdAt": "2026-10-05T10:00:00.000Z",
            "turnId": "turn-1",
            "itemId": "item-1",
            "type": kind,
            "payload": payload,
        })
    }

    #[test]
    fn command_execution_lifecycle_becomes_tool_rows() {
        let started = event(base(
            "item.started",
            json!({ "itemType": "command_execution", "status": "inProgress", "title": "Ran command", "data": { "command": "ls" } }),
        ));
        let rows = project_provider_runtime_activities(&started, Some(4));
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!(row.kind, "tool.started");
        assert_eq!(row.tone, OrchestrationThreadActivityTone::Tool);
        assert_eq!(row.summary, "Ran command started");
        assert_eq!(row.sequence, Some(4));
        assert_eq!(row.turn_id, Some(TurnId::new("turn-1")));
        assert_eq!(
            row.payload,
            json!({ "itemType": "command_execution", "status": "inProgress", "title": "Ran command", "data": { "command": "ls" } })
        );

        let completed = event(base(
            "item.completed",
            json!({ "itemType": "command_execution", "status": "completed", "title": "  " }),
        ));
        let rows = project_provider_runtime_activities(&completed, None);
        assert_eq!(rows[0].kind, "tool.completed");
        assert_eq!(rows[0].summary, "Tool");
        assert_eq!(rows[0].sequence, None);
    }

    #[test]
    fn approvals_carry_request_kind_and_id() {
        let mut opened = base(
            "request.opened",
            json!({ "requestType": "command_execution_approval", "detail": "rm -rf build" }),
        );
        opened["requestId"] = json!("req-1");
        let rows = project_provider_runtime_activities(&event(opened), None);
        assert_eq!(rows[0].kind, "approval.requested");
        assert_eq!(rows[0].tone, OrchestrationThreadActivityTone::Approval);
        assert_eq!(rows[0].summary, "Command approval requested");
        assert_eq!(
            rows[0].payload,
            json!({ "requestId": "req-1", "requestKind": "command", "requestType": "command_execution_approval", "detail": "rm -rf build" })
        );

        let mut resolved = base("request.resolved", json!({ "requestType": "command_execution_approval", "decision": "accept" }));
        resolved["requestId"] = json!("req-1");
        let rows = project_provider_runtime_activities(&event(resolved), None);
        assert_eq!(rows[0].kind, "approval.resolved");
        assert_eq!(rows[0].summary, "Approval resolved");
        assert_eq!(rows[0].payload["decision"], json!("accept"));

        let user_input = base("request.opened", json!({ "requestType": "tool_user_input" }));
        assert!(project_provider_runtime_activities(&event(user_input), None).is_empty());
    }

    #[test]
    fn claude_tool_approval_flattens_input_into_params_and_redacts_secrets() {
        let mut sample = base(
            "request.opened",
            json!({ "requestType": "tool_approval", "args": { "toolName": "Bash", "input": { "command": "ls", "apiKey": "sk-1" } } }),
        );
        sample["provider"] = json!("claudeAgent");
        let rows = project_provider_runtime_activities(&event(sample), None);
        let payload = &rows[0].payload;
        assert_eq!(payload["toolName"], json!("Bash"));
        let params = payload["toolParamsDisplay"].as_array().unwrap();
        let api_key = params.iter().find(|p| p["name"] == "apiKey").unwrap();
        assert_eq!(api_key["value"], json!("[redacted]"));
        let command = params.iter().find(|p| p["name"] == "command").unwrap();
        assert_eq!(command["value"], json!("ls"));
    }

    #[test]
    fn reasoning_trace_uses_a_stable_id_and_hides_encrypted_blocks() {
        let readable = event(base(
            "item.completed",
            json!({ "itemType": "reasoning", "status": "completed", "detail": "Thinking about it" }),
        ));
        let rows = project_provider_runtime_activities(&readable, None);
        assert_eq!(rows[0].id, EventId::new("provider-reasoning:thread-1:item-1"));
        assert_eq!(rows[0].kind, "task.progress");
        assert_eq!(rows[0].summary, "Reasoning trace");
        assert_eq!(rows[0].payload["data"], json!({ "toolCallId": "item-1" }));

        let encrypted = event(base("item.completed", json!({ "itemType": "reasoning", "detail": "<!-- sig -->" })));
        assert!(project_provider_runtime_activities(&encrypted, None).is_empty());
    }

    #[test]
    fn turn_completed_states_map_to_summaries() {
        let failed = event(base("turn.completed", json!({ "state": "failed", "errorMessage": "boom" })));
        let rows = project_provider_runtime_activities(&failed, None);
        assert_eq!(rows[0].summary, "Turn failed");
        assert_eq!(rows[0].tone, OrchestrationThreadActivityTone::Error);
        assert_eq!(rows[0].payload, json!({ "state": "failed", "errorMessage": "boom" }));
        let interrupted = event(base("turn.completed", json!({ "state": "cancelled" })));
        assert_eq!(project_provider_runtime_activities(&interrupted, None)[0].summary, "Turn interrupted");
    }

    #[test]
    fn oversized_tool_data_is_bounded() {
        let big = "x".repeat(40_000);
        let sample = event(base(
            "item.updated",
            json!({ "itemType": "command_execution", "data": { "rawOutput": { "output": big } } }),
        ));
        let rows = project_provider_runtime_activities(&sample, None);
        let data = &rows[0].payload["data"];
        assert_eq!(data[ACTIVITY_DATA_TRUNCATION_MARKER], json!(true));
        assert!(stringify_json_like(data).len() <= MAX_ACTIVITY_DATA_JSON_CHARS);
    }

    #[test]
    fn tool_progress_dedupes_by_tool_id() {
        let sample = event(json!({
            "eventId": "evt-9", "provider": "claudeAgent", "threadId": "thread-1",
            "createdAt": "2026-10-05T10:00:00.000Z",
            "type": "tool.progress",
            "payload": { "toolUseId": "toolu_1", "toolName": "mcp__x", "elapsedSeconds": 2.5 }
        }));
        let rows = project_provider_runtime_activities(&sample, None);
        assert_eq!(rows[0].kind, "tool.updated");
        let key = provider_activity_update_dedupe_key(&sample, &ThreadId::new("thread-1"), &rows[0]);
        assert_eq!(key.as_deref(), Some("thread-1:claudeAgent:tool.updated:toolu_1"));
    }

    #[test]
    fn sensitive_keys_follow_synara() {
        assert!(is_sensitive_key("apiKey"));
        assert!(is_sensitive_key("OPENAI_API_KEY"));
        assert!(is_sensitive_key("refresh_token"));
        assert!(!is_sensitive_key("total_tokens"));
        assert!(!is_sensitive_key("command"));
    }
}
