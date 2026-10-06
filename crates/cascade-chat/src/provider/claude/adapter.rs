//! Ported from Synara `apps/server/src/provider/Layers/ClaudeAdapter.ts`.
//!
//! Synara drives `claude` through the Agent SDK's `query()`; here the session task speaks the
//! SDK's wire itself ([`super::protocol`]). The names and the order of the TypeScript are kept:
//! the free functions first (ClaudeAdapter.ts:198-2058), then the session's handlers, which are
//! closures over `makeClaudeAdapter` there and methods of [`ClaudeSessionContext`] here.
//!
//! A session is one tokio task that owns the CLI process: it reads the CLI's stdout line by line,
//! writes its stdin, and serves the [`SessionCommand`]s of its handle, in a `select!`.
//!
//! A Task/Agent tool's subagent runs as a scoped context of its own (Synara `ensureSubagentRun`):
//! its messages, tagged with the tool's id, are projected by the same handlers, and every event
//! they make carries the subagent's `providerRefs`, which ingestion routes to the child thread.
//!
//! Left out on purpose (Synara-specific or not reachable without the SDK): the MCP gateway,
//! computer control, Claude cache observation, account isolation, messaging a running subagent
//! (`steerSubagent`, which needs the SDK's PreToolUse hook), per-task token meters
//! (`emitTaskUsageSnapshot`), the workflow runtime, compaction bookkeeping, tracked
//! TaskCreate/TaskUpdate tasks, context-usage probes, model refusal reroutes, VCS notices, thread
//! import and `readThread`.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Map, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader},
    sync::{mpsc, oneshot},
    time::Instant,
};
use uuid::Uuid;

use crate::contracts::{
    base::{
        now_iso, ApprovalRequestId, EventId, IsoDateTime, ProviderItemId,
        RuntimeItemId, RuntimeRequestId, ThreadId, TurnId,
    },
    model::ClaudeCodeEffort,
    orchestration::{
        ChatAttachment, ChatImageAttachment, ClaudeModelSelection, ModelSelection, ProviderApprovalDecision,
        ProviderInteractionMode, ProviderKind, ProviderUserInputAnswer, ProviderUserInputAnswers, RuntimeMode,
    },
    provider::{
        ProviderSendTurnInput, ProviderSession, ProviderSessionStartInput, ProviderSessionStatus,
        ProviderTurnStartResult,
    },
    provider_runtime::{
        CanonicalItemType, CanonicalRequestType, ContentDeltaPayload, ItemLifecyclePayload, ProviderRefs,
        ProviderRuntimeEvent, ProviderRuntimeEventBody, RequestOpenedPayload, RequestResolvedPayload,
        RuntimeContentStreamKind, RuntimeErrorClass, RuntimeErrorPayload, RuntimeEventRaw, RuntimeEventRawSource,
        RuntimeItemStatus, RuntimeSessionExitKind, RuntimeSessionState, RuntimeTaskListItem, RuntimeTaskStatus,
        RuntimeTurnState, RuntimeWarningPayload, SessionConfiguredPayload, SessionExitedPayload,
        SessionStartedPayload, SessionStateChangedPayload, ThreadStartedPayload, ThreadTokenUsageSnapshot,
        ThreadTokenUsageUpdatedPayload, TurnCompletedPayload, TurnProposedCompletedPayload, TurnStartedPayload,
        TurnSteeredPayload, TurnSteeredTarget, TurnTasksUpdatedPayload, UserInputQuestion,
        UserInputQuestionOption, UserInputRequestedPayload, UserInputResolvedPayload,
    },
};
use crate::provider::{
    adapter::{
        EventSink, ProviderAdapter, ProviderAdapterCapabilities, ProviderConversationRollbackMode,
        ProviderModel, ProviderSessionHandle, ProviderSessionModelSwitchMode, SessionCommand,
    },
    attachment_projection::{
        build_file_attachments_prompt_block, resolve_provider_attachment_path, ProjectedAttachments,
        StoredAttachment,
    },
    process::{ChildProcess, ExitFuture, SpawnSpec, Spawner},
};

use super::protocol::{
    self, launch_args, CanUseToolRequest, ClaudeLaunchOptions, CliLine, ControlRequest, PermissionResult,
};

const PROVIDER: ProviderKind = ProviderKind::ClaudeAgent;

/// Synara `ClaudeResumeState` (ClaudeAdapter.ts:214), without the cache and tracked tasks.
#[derive(Clone, Debug, Default, PartialEq)]
struct ClaudeResumeState {
    thread_id: Option<ThreadId>,
    resume: Option<String>,
    resume_session_at: Option<String>,
    turn_count: Option<u64>,
    processed_token_total: Option<u64>,
}

/// Synara `ClaudeTurnState` (ClaudeAdapter.ts:225)
struct ClaudeTurnState {
    turn_id: TurnId,
    interaction_mode: ProviderInteractionMode,
    /// Auto-started turns that wrap assistant output arriving without an active turn.
    synthetic: bool,
    /// Block index -> position in `assistant_text_block_order`, while not yet completed.
    assistant_text_blocks: HashMap<i64, usize>,
    /// Keyed blocks in insertion order (Synara's `Map` keeps it; reconciliation relies on it).
    reasoning_blocks: Vec<(String, ReasoningBlock)>,
    reasoning_message_id: Option<String>,
    assistant_text_block_order: Vec<AssistantTextBlockState>,
    captured_proposed_plan_keys: HashSet<String>,
    saw_file_change: bool,
    assistant_error: Option<(String, String)>,
    next_synthetic_assistant_block_index: i64,
    assistant_message_block_base: usize,
}

impl ClaudeTurnState {
    fn new(turn_id: TurnId, interaction_mode: ProviderInteractionMode, synthetic: bool) -> Self {
        Self {
            turn_id,
            interaction_mode,
            synthetic,
            assistant_text_blocks: HashMap::new(),
            reasoning_blocks: Vec::new(),
            reasoning_message_id: None,
            assistant_text_block_order: Vec::new(),
            captured_proposed_plan_keys: HashSet::new(),
            saw_file_change: false,
            assistant_error: None,
            next_synthetic_assistant_block_index: -1,
            assistant_message_block_base: 0,
        }
    }
}

struct ReasoningBlock {
    item_id: String,
    text: String,
    completed: bool,
    snapshot_received: bool,
}

/// Synara `AssistantTextBlockState` (ClaudeAdapter.ts:259)
struct AssistantTextBlockState {
    item_id: String,
    block_index: i64,
    emitted_text_delta: bool,
    fallback_text: String,
    stream_closed: bool,
    completion_emitted: bool,
}

/// Synara `PendingApproval` (ClaudeAdapter.ts:268). The SDK's deferred is the CLI's request id
/// here: answering it writes the `control_response`.
struct PendingApproval {
    cli_request_id: String,
    request_type: CanonicalRequestType,
    suggestions: Option<Vec<Value>>,
    tool_input: Value,
    turn_id: Option<TurnId>,
    provider_item_id: Option<String>,
    agent_id: Option<String>,
}

/// Synara `PendingUserInput` (ClaudeAdapter.ts:285)
struct PendingUserInput {
    cli_request_id: String,
    questions: Vec<UserInputQuestion>,
    tool_input: Value,
    turn_id: Option<TurnId>,
    provider_item_id: Option<String>,
    agent_id: Option<String>,
}

/// Synara `coerceClaudeAnswerValue` (ClaudeAdapter.ts:295)
fn coerce_claude_answer_value(value: &ProviderUserInputAnswer) -> String {
    match value {
        ProviderUserInputAnswer::Text(text) => text.clone(),
        ProviderUserInputAnswer::Many(values) => values.join(", "),
        ProviderUserInputAnswer::Null => String::new(),
    }
}

/// Synara `remapAnswersToClaudeQuestionText` (ClaudeAdapter.ts:304): Claude keys answers by
/// question text; the UI submits stable ids.
fn remap_answers_to_claude_question_text(
    questions: &[UserInputQuestion],
    answers: &ProviderUserInputAnswers,
) -> Map<String, Value> {
    let mut remapped: Map<String, Value> =
        answers.iter().map(|(key, value)| (key.clone(), json!(coerce_claude_answer_value(value)))).collect();
    for question in questions {
        if remapped.contains_key(&question.question) {
            continue;
        }
        if let Some(value) = remapped.remove(&question.id) {
            remapped.insert(question.question.clone(), value);
        }
    }
    remapped
}

/// Synara `ToolInFlight` (ClaudeAdapter.ts:327)
#[derive(Clone)]
struct ToolInFlight {
    item_id: String,
    item_type: CanonicalItemType,
    tool_name: String,
    title: String,
    detail: Option<String>,
    input: Map<String, Value>,
    partial_input_json: String,
    last_emitted_input_fingerprint: Option<String>,
}

/// Synara `isUuid` (ClaudeAdapter.ts:756)
fn is_uuid(value: &str) -> bool {
    let Ok(parsed) = Uuid::parse_str(value) else {
        return false;
    };
    value.len() == 36 && (1..=8).contains(&parsed.get_version_num()) && {
        let variant = value.as_bytes()[19].to_ascii_lowercase();
        matches!(variant, b'8' | b'9' | b'a' | b'b')
    }
}

/// Synara `isSyntheticClaudeThreadId` (ClaudeAdapter.ts:760)
fn is_synthetic_claude_thread_id(value: &str) -> bool {
    value.starts_with("claude-thread-")
}

/// Synara `hasDurableClaudeSessionId` (ClaudeAdapter.ts:766): hook messages can carry transient
/// session ids; only durable conversation messages advance the resume cursor.
fn has_durable_claude_session_id(message: &Value) -> bool {
    if message_type(message) != Some("system") {
        return true;
    }
    !matches!(message_subtype(message), Some("hook_started" | "hook_progress" | "hook_response"))
}

/// Synara `CLAUDE_BENIGN_TERMINATION_EXIT_CODES` (ClaudeAdapter.ts:879): SIGINT and SIGTERM are
/// graceful stop requests, not crashes.
const CLAUDE_BENIGN_TERMINATION_EXIT_CODES: &[i32] = &[130, 143];

/// Synara `CLAUDE_BENIGN_TERMINATION_MESSAGE` (ClaudeAdapter.ts:881)
const CLAUDE_BENIGN_TERMINATION_MESSAGE: &str = "Claude runtime stopped and will resume on your next message.";

/// Synara `resultErrorsText` (ClaudeAdapter.ts:903)
fn result_errors_text(result: &Value) -> String {
    result
        .get("errors")
        .and_then(Value::as_array)
        .map(|errors| errors.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ").to_lowercase())
        .unwrap_or_default()
}

/// Synara `isInterruptedResult` (ClaudeAdapter.ts:909)
fn is_interrupted_result(result: &Value) -> bool {
    let errors = result_errors_text(result);
    if errors.contains("interrupt") {
        return true;
    }
    message_subtype(result) == Some("error_during_execution")
        && result.get("is_error").and_then(Value::as_bool) == Some(false)
        && (errors.contains("request was aborted") || errors.contains("interrupted by user") || errors.contains("aborted"))
}

/// Synara `toPermissionMode` (ClaudeAdapter.ts:1040)
fn to_permission_mode(value: Option<&str>) -> Option<&'static str> {
    match value? {
        "default" => Some("default"),
        "acceptEdits" => Some("acceptEdits"),
        "bypassPermissions" => Some("bypassPermissions"),
        "plan" => Some("plan"),
        "dontAsk" => Some("dontAsk"),
        _ => None,
    }
}

/// The permission mode a session spawns in (ClaudeAdapter.ts:6119-6123): `auto` is Claude's own
/// classifier, full access bypasses permissions, and approval-required leaves the CLI in its
/// `default` mode (no flag). A configured `permissionMode` wins over the runtime mode except auto.
pub fn claude_permission_mode(runtime_mode: RuntimeMode, configured: Option<&str>) -> Option<&'static str> {
    if runtime_mode == RuntimeMode::Auto {
        return Some("auto");
    }
    to_permission_mode(configured).or(match runtime_mode {
        RuntimeMode::FullAccess => Some("bypassPermissions"),
        _ => None,
    })
}

/// Synara `readClaudeResumeState` (ClaudeAdapter.ts:1069)
fn read_claude_resume_state(resume_cursor: Option<&Value>) -> Option<ClaudeResumeState> {
    let cursor = resume_cursor?.as_object()?;
    let thread_id = cursor
        .get("threadId")
        .and_then(Value::as_str)
        .filter(|id| !is_synthetic_claude_thread_id(id))
        .map(ThreadId::new);
    let resume = cursor
        .get("resume")
        .and_then(Value::as_str)
        .or_else(|| cursor.get("sessionId").and_then(Value::as_str))
        .filter(|id| is_uuid(id))
        .map(str::to_owned);
    let resume_session_at = cursor.get("resumeSessionAt").and_then(Value::as_str).map(str::to_owned);
    let turn_count = cursor.get("turnCount").and_then(Value::as_u64);
    let processed_token_total = cursor
        .get("processedTokenTotal")
        .and_then(Value::as_u64)
        .filter(|_| cursor.get("tokenAccountingVersion").and_then(Value::as_u64) == Some(1));
    Some(ClaudeResumeState { thread_id, resume, resume_session_at, turn_count, processed_token_total })
}

/// Synara `classifyToolItemType` (ClaudeAdapter.ts:1173)
pub fn classify_tool_item_type(tool_name: &str) -> CanonicalItemType {
    let normalized = tool_name.to_lowercase();
    let n = normalized.as_str();
    if n == "todowrite" || n.contains("todo") || matches!(n, "taskcreate" | "taskupdate" | "taskget" | "tasklist") {
        return CanonicalItemType::Plan;
    }
    if n.contains("agent") {
        return CanonicalItemType::CollabAgentToolCall;
    }
    if n == "task" || n == "agent" || n.contains("subagent") || n.contains("sub-agent") {
        return CanonicalItemType::CollabAgentToolCall;
    }
    if n.contains("bash") || n.contains("command") || n.contains("shell") || n.contains("terminal") {
        return CanonicalItemType::CommandExecution;
    }
    if ["edit", "write", "file", "patch", "replace", "create", "delete"].iter().any(|word| n.contains(word)) {
        return CanonicalItemType::FileChange;
    }
    if n.contains("mcp") {
        return CanonicalItemType::McpToolCall;
    }
    if n.contains("websearch") || n.contains("web search") {
        return CanonicalItemType::WebSearch;
    }
    if n.contains("image") {
        return CanonicalItemType::ImageView;
    }
    CanonicalItemType::DynamicToolCall
}

/// Synara `isReadOnlyToolName` (ClaudeAdapter.ts:1227)
fn is_read_only_tool_name(tool_name: &str) -> bool {
    let n = tool_name.to_lowercase();
    n == "read" || n.contains("read file") || n.contains("view") || n.contains("grep") || n.contains("glob") || n.contains("search")
}

/// Synara `classifyRequestType` (ClaudeAdapter.ts:1239)
pub fn classify_request_type(tool_name: &str) -> CanonicalRequestType {
    // MCP tools are always generic tool approvals, whatever their names contain.
    if tool_name.starts_with("mcp__") {
        return CanonicalRequestType::ToolApproval;
    }
    if is_read_only_tool_name(tool_name) {
        return CanonicalRequestType::FileReadApproval;
    }
    match classify_tool_item_type(tool_name) {
        CanonicalItemType::CommandExecution => CanonicalRequestType::CommandExecutionApproval,
        CanonicalItemType::FileChange => CanonicalRequestType::FileChangeApproval,
        _ => CanonicalRequestType::ToolApproval,
    }
}

fn truncate_chars(value: &str, max: usize) -> &str {
    match value.char_indices().nth(max) {
        Some((index, _)) => &value[..index],
        None => value,
    }
}

/// Synara `summarizeToolRequest` (ClaudeAdapter.ts:1261)
fn summarize_tool_request(tool_name: &str, input: &Map<String, Value>, serialized_input: Option<&str>) -> String {
    let command = input.get("command").or_else(|| input.get("cmd")).and_then(Value::as_str);
    if let Some(command) = command.filter(|c| !c.trim().is_empty()) {
        return format!("{tool_name}: {}", truncate_chars(command.trim(), 400).trim_end());
    }
    let serialized = serialized_input.map(str::to_owned).unwrap_or_else(|| Value::Object(input.clone()).to_string());
    if serialized.chars().count() <= 400 {
        return format!("{tool_name}: {serialized}");
    }
    format!("{tool_name}: {}...", truncate_chars(&serialized, 397))
}

/// Synara `isClientSurfacedClaudeTool` (ClaudeAdapter.ts:1283): AskUserQuestion and ExitPlanMode
/// have their own runtime channels and no generic tool item.
fn is_client_surfaced_claude_tool(tool_name: &str) -> bool {
    tool_name == "AskUserQuestion" || tool_name == "ExitPlanMode"
}

/// Synara `toolLifecycleEventData` (ClaudeAdapter.ts:1290)
fn tool_lifecycle_event_data(tool: &ToolInFlight, extra: Option<Map<String, Value>>) -> Value {
    let mut data = Map::new();
    data.insert("toolCallId".into(), json!(tool.item_id));
    data.insert("callId".into(), json!(tool.item_id));
    data.insert("toolName".into(), json!(tool.tool_name));
    data.insert("input".into(), Value::Object(tool.input.clone()));
    if tool.tool_name == "Task" || tool.tool_name == "Agent" {
        data.extend(subagent_receiver_data(tool));
    }
    if let Some(extra) = extra {
        data.extend(extra);
    }
    Value::Object(data)
}

/// Synara `subagentReceiverData` (ClaudeAdapter.ts:1307), without the worker effort tiers.
fn subagent_receiver_data(tool: &ToolInFlight) -> Map<String, Value> {
    let mut data = Map::new();
    data.insert("receiverThreadId".into(), json!(tool.item_id));
    for (from, to) in [("subagent_type", "agentType"), ("description", "nickname"), ("prompt", "prompt"), ("model", "model")] {
        if let Some(value) = tool.input.get(from).and_then(Value::as_str) {
            data.insert(to.into(), json!(value));
        }
    }
    if tool.input.get("run_in_background").and_then(Value::as_bool) == Some(true) {
        data.insert("background".into(), json!(true));
    }
    data
}

/// Synara `titleForTool` (ClaudeAdapter.ts:1330)
fn title_for_tool(item_type: CanonicalItemType) -> &'static str {
    match item_type {
        CanonicalItemType::Plan => "Plan",
        CanonicalItemType::CommandExecution => "Command run",
        CanonicalItemType::FileChange => "File change",
        CanonicalItemType::McpToolCall => "MCP tool call",
        CanonicalItemType::CollabAgentToolCall => "Subagent task",
        CanonicalItemType::WebSearch => "Web search",
        CanonicalItemType::ImageView => "Image view",
        CanonicalItemType::DynamicToolCall => "Tool call",
        _ => "Item",
    }
}

/// Synara `SUPPORTED_CLAUDE_IMAGE_MIME_TYPES` (ClaudeAdapter.ts:1353)
const SUPPORTED_CLAUDE_IMAGE_MIME_TYPES: &[&str] = &["image/gif", "image/jpeg", "image/png", "image/webp"];

/// Synara `CLAUDE_INTERRUPT_TIMEOUT` (ClaudeAdapter.ts:1367)
const CLAUDE_INTERRUPT_TIMEOUT: Duration = Duration::from_secs(10);

/// Synara `buildEmbeddedClaudeSystemPromptAppend` (ClaudeAdapter.ts:1368), the host-neutral
/// lines; the harness policy and subagent tiers are Synara's own.
const EMBEDDED_CLAUDE_SYSTEM_PROMPT_APPEND: &str = "You are running inside Cascade, a coding app that embeds Claude Code.\n\
Do not present the host app as Claude Code unless the user is explicitly asking about Claude Code.\n\
Treat the current working directory as the active workspace for the task.\n\
When the user asks about the current project, codebase, or repository, proactively inspect files in the current working directory before asking the user where to look.";

/// Synara `PROVIDER_PLAN_MODE_PROMPT_PREFIX` (planMode.ts:11)
const PROVIDER_PLAN_MODE_PROMPT_PREFIX: &str = "Plan mode is active.\n\
Do not implement or mutate files in this turn. You may inspect or ask targeted questions as needed.\n\
When you are ready to present the final plan, wrap only the final plan markdown in these exact tags:\n\
<proposed_plan>\n\
plan content\n\
</proposed_plan>\n\
Use at most one proposed_plan block. Keep the tags in English exactly as shown.";

/// Synara `withProviderPlanModePrompt` (planMode.ts:23)
fn with_provider_plan_mode_prompt(text: &str, interaction_mode: Option<ProviderInteractionMode>) -> String {
    if interaction_mode != Some(ProviderInteractionMode::Plan) {
        return text.to_owned();
    }
    let text = text.trim();
    if text.is_empty() {
        PROVIDER_PLAN_MODE_PROMPT_PREFIX.to_owned()
    } else {
        format!("{PROVIDER_PLAN_MODE_PROMPT_PREFIX}\n\nUser request:\n{text}")
    }
}

/// Synara `extractProposedPlanMarkdown` (planMode.ts:36)
fn extract_proposed_plan_markdown(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase(); // length-preserving: offsets index `text`
    let start = lower.find("<proposed_plan>")? + "<proposed_plan>".len();
    let end = start + lower[start..].find("</proposed_plan>")?;
    let plan = text[start..end].trim();
    (!plan.is_empty()).then(|| plan.to_owned())
}

/// Synara `applyClaudePromptEffortPrefix` (packages/shared/src/model.ts:1052)
fn apply_claude_prompt_effort_prefix(text: &str, effort: Option<ClaudeCodeEffort>) -> String {
    let trimmed = text.trim();
    if trimmed.is_empty() || effort != Some(ClaudeCodeEffort::Ultrathink) || trimmed.starts_with("Ultrathink:") {
        return trimmed.to_owned();
    }
    format!("Ultrathink:\n{trimmed}")
}

/// Synara `isClaudeCompactionCommand` (ClaudeAdapter.ts:1435)
fn is_claude_compaction_command(text: Option<&str>) -> bool {
    let text = text.unwrap_or_default().trim();
    text == "/compact" || text.strip_prefix("/compact").is_some_and(|rest| rest.starts_with(char::is_whitespace))
}

/// Synara `isClaudeNativeSlashCommand` (ClaudeAdapter.ts:1443): `/name` then whitespace or end.
fn is_claude_native_slash_command(text: Option<&str>, native_command_names: Option<&HashSet<String>>) -> bool {
    let text = text.unwrap_or_default().trim();
    let Some(rest) = text.strip_prefix('/') else {
        return false;
    };
    let name_end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let name = &rest[..name_end];
    let mut chars = name.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_alphanumeric() || c == '_' || c == ':' || c == '-');
    if !valid {
        return false;
    }
    match native_command_names {
        Some(names) if !names.is_empty() => names.contains(name) || is_claude_compaction_command(Some(text)),
        _ => true,
    }
}

fn claude_selection(selection: Option<&ModelSelection>) -> Option<&ClaudeModelSelection> {
    match selection? {
        ModelSelection::ClaudeAgent(selection) => Some(selection),
        ModelSelection::Codex(_) => None,
    }
}

/// Synara `buildPromptText` (ClaudeAdapter.ts:1453). Model capabilities are not ported, so a
/// requested `ultrathink` is always honoured.
fn build_prompt_text(input: &ProviderSendTurnInput, native_command_names: Option<&HashSet<String>>) -> String {
    if is_claude_native_slash_command(input.input.as_deref(), native_command_names) {
        return input.input.as_deref().unwrap_or_default().trim().to_owned();
    }
    let base_prompt = input.input.as_deref().unwrap_or_default().trim();
    let effort = claude_selection(input.model_selection.as_ref()).and_then(|s| s.options.as_ref()?.effort);
    with_provider_plan_mode_prompt(&apply_claude_prompt_effort_prefix(base_prompt, effort), input.interaction_mode)
}

/// Synara `buildClaudeImageContentBlock` (ClaudeAdapter.ts:1494)
fn build_claude_image_content_block(mime_type: &str, bytes: &[u8]) -> Value {
    json!({
        "type": "image",
        "source": { "type": "base64", "media_type": mime_type, "data": base64_encode(bytes) },
    })
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

/// Synara `buildUserMessageEffect` (ClaudeAdapter.ts:1508): the prompt text, the supported
/// images as base64 blocks read from disk, and a path block for every other file.
fn build_user_message(
    input: &ProviderSendTurnInput,
    attachments_dir: &Path,
    native_command_names: Option<&HashSet<String>>,
) -> Result<Value> {
    let text = build_prompt_text(input, native_command_names);
    let mut sdk_content = Vec::new();
    if !text.is_empty() {
        sdk_content.push(json!({ "type": "text", "text": text }));
    }
    for attachment in input.attachments.as_deref().unwrap_or_default() {
        let ChatAttachment::Image(image) = attachment else {
            continue;
        };
        let mime_type = image.mime_type.to_lowercase();
        if !SUPPORTED_CLAUDE_IMAGE_MIME_TYPES.contains(&mime_type.as_str()) {
            continue;
        }
        let path = resolve_provider_attachment_path(attachments_dir, StoredAttachment::Image(image))
            .ok_or_else(|| anyhow!("Invalid attachment id '{}'.", image.id))?;
        let bytes = std::fs::read(&path)
            .map_err(|error| anyhow!("Failed to read attachment file {}: {error}", path.display()))?;
        sdk_content.push(build_claude_image_content_block(&mime_type, &bytes));
    }
    let include_image = |image: &ChatImageAttachment| {
        !SUPPORTED_CLAUDE_IMAGE_MIME_TYPES.contains(&image.mime_type.to_lowercase().as_str())
    };
    if let Some(block) = build_file_attachments_prompt_block(
        input.attachments.as_deref(),
        attachments_dir,
        ProjectedAttachments::AllFiles,
        Some(&include_image),
    ) {
        sdk_content.push(json!({ "type": "text", "text": block }));
    }
    Ok(protocol::user_message(sdk_content))
}

/// Synara `turnStatusFromResult` (ClaudeAdapter.ts:1580)
fn turn_status_from_result(result: &Value) -> RuntimeTurnState {
    if message_subtype(result) == Some("success") {
        return RuntimeTurnState::Completed;
    }
    if is_interrupted_result(result) {
        return RuntimeTurnState::Interrupted;
    }
    if result_errors_text(result).contains("cancel") {
        return RuntimeTurnState::Cancelled;
    }
    RuntimeTurnState::Failed
}

/// Synara `extractAssistantTextBlocks` (ClaudeAdapter.ts:1609)
fn extract_assistant_text_blocks(message: &Value) -> Vec<String> {
    if message_type(message) != Some("assistant") {
        return Vec::new();
    }
    let Some(content) = message.pointer("/message/content").and_then(Value::as_array) else {
        return Vec::new();
    };
    content
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .map(sanitize_claude_display_text)
        .filter(|text| !text.is_empty())
        .collect()
}

/// Synara `sanitizeClaudeDisplayText` (ClaudeAdapter.ts:1637): drops `[ede_diagnostic]` lines.
fn sanitize_claude_display_text(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let is_diagnostic = |line: &str| line.trim().to_lowercase().starts_with("[ede_diagnostic]");
    let lines: Vec<&str> = text.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line)).collect();
    let filtered: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|line| {
            let normalized = line.trim().to_lowercase();
            !(normalized.starts_with("[ede_diagnostic]")
                && normalized.contains("result_type=")
                && normalized.contains("stop_reason="))
        })
        .collect();
    if filtered.is_empty() && lines.iter().any(|line| is_diagnostic(line)) {
        return String::new();
    }
    filtered.join("\n")
}

/// Synara `normalizeClaudeUserVisibleErrorMessage` (ClaudeAdapter.ts:1662)
fn normalize_claude_user_visible_error_message(text: Option<&str>, status: RuntimeTurnState) -> Option<String> {
    let sanitized = sanitize_claude_display_text(text?).trim().to_owned();
    if sanitized.is_empty() {
        return None;
    }
    if sanitized == "User interrupted response." {
        return (status == RuntimeTurnState::Interrupted).then(|| "Claude runtime interrupted.".to_owned());
    }
    if sanitized.chars().all(|c| "]})\"'`.,;:!?_-".contains(c)) {
        return Some(if status == RuntimeTurnState::Interrupted {
            "Claude runtime interrupted.".to_owned()
        } else {
            "Claude turn failed.".to_owned()
        });
    }
    Some(sanitized)
}

/// Synara `claudeAssistantErrorMessage` (ClaudeAdapter.ts:1686)
fn claude_assistant_error_message(error: &str) -> &'static str {
    match error {
        "authentication_failed" => "Claude is not authenticated. Run `claude auth login --claudeai`, then retry.",
        "oauth_org_not_allowed" => "Claude authentication succeeded, but this organization does not allow Claude Code.",
        "account_on_hold" => "The active Claude account is on hold. Resolve the account issue, then retry.",
        "billing_error" => "Claude billing or subscription access failed. Check the active Claude account, then retry.",
        "rate_limit" => "Claude rate limit reached. Wait briefly, then retry.",
        "overloaded" => "Claude is temporarily overloaded. Retry in a moment.",
        "invalid_request" => "Claude rejected the request as invalid.",
        "model_not_found" => "The selected Claude model is unavailable for this account.",
        "server_error" => "Claude returned a server error. Retry in a moment.",
        "max_output_tokens" => "Claude reached the maximum output length before completing the turn.",
        _ => "Claude failed to complete the turn.",
    }
}

/// Synara `claudeAssistantErrorRequiresProcessRestart` (ClaudeAdapter.ts:1713)
fn claude_assistant_error_requires_process_restart(error: &str) -> bool {
    matches!(error, "authentication_failed" | "oauth_org_not_allowed" | "account_on_hold" | "billing_error")
}

/// Synara `extractContentBlockText` (ClaudeAdapter.ts:1722)
fn extract_content_block_text(block: &Value) -> String {
    match (block.get("type").and_then(Value::as_str), block.get("text").and_then(Value::as_str)) {
        (Some("text"), Some(text)) => sanitize_claude_display_text(text),
        _ => String::new(),
    }
}

/// Synara `extractTextContent` (ClaudeAdapter.ts:1733)
fn extract_text_content(value: &Value) -> String {
    match value {
        Value::String(text) => sanitize_claude_display_text(text),
        Value::Array(entries) => entries.iter().map(extract_text_content).collect(),
        Value::Object(record) => match record.get("text").and_then(Value::as_str) {
            Some(text) => sanitize_claude_display_text(text),
            None => record.get("content").map(extract_text_content).unwrap_or_default(),
        },
        _ => String::new(),
    }
}

/// Synara `extractExitPlanModePlan` (ClaudeAdapter.ts:1758)
fn extract_exit_plan_mode_plan(value: &Value) -> Option<String> {
    let plan = value.get("plan")?.as_str()?.trim();
    (!plan.is_empty()).then(|| plan.to_owned())
}

/// Synara `exitPlanCaptureKey` (ClaudeAdapter.ts:1771)
fn exit_plan_capture_key(tool_use_id: Option<&str>, plan_markdown: &str) -> String {
    match tool_use_id.filter(|id| !id.is_empty()) {
        Some(id) => format!("tool:{id}"),
        None => format!("plan:{plan_markdown}"),
    }
}

/// Synara `tryParseCompleteJsonRecord` (ClaudeAdapter.ts:1785)
fn try_parse_complete_json_record(value: &str) -> Option<(Map<String, Value>, String)> {
    if !value.trim_end().ends_with('}') {
        return None;
    }
    match serde_json::from_str::<Value>(value).ok()? {
        Value::Object(map) => {
            let serialized = Value::Object(map.clone()).to_string();
            Some((map, serialized))
        }
        _ => None,
    }
}

/// Synara `toolResultStreamKind` (ClaudeAdapter.ts:1811)
fn tool_result_stream_kind(item_type: CanonicalItemType) -> Option<RuntimeContentStreamKind> {
    match item_type {
        CanonicalItemType::CommandExecution => Some(RuntimeContentStreamKind::CommandOutput),
        CanonicalItemType::FileChange => Some(RuntimeContentStreamKind::FileChangeOutput),
        _ => None,
    }
}

struct ToolResultBlock {
    tool_use_id: String,
    block: Value,
    text: String,
    is_error: bool,
}

/// Synara `toolResultBlocksFromUserMessage` (ClaudeAdapter.ts:1822)
fn tool_result_blocks_from_user_message(message: &Value) -> Vec<ToolResultBlock> {
    if message_type(message) != Some("user") {
        return Vec::new();
    }
    let Some(content) = message.pointer("/message/content").and_then(Value::as_array) else {
        return Vec::new();
    };
    content
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_result"))
        .filter_map(|block| {
            Some(ToolResultBlock {
                tool_use_id: block.get("tool_use_id")?.as_str()?.to_owned(),
                block: block.clone(),
                text: block.get("content").map(extract_text_content).unwrap_or_default(),
                is_error: block.get("is_error").and_then(Value::as_bool) == Some(true),
            })
        })
        .collect()
}

/// Synara `sdkMessageType` (ClaudeAdapter.ts:1908)
fn message_type(value: &Value) -> Option<&str> {
    value.get("type").and_then(Value::as_str)
}

/// Synara `sdkMessageSubtype` (ClaudeAdapter.ts:1916)
fn message_subtype(value: &Value) -> Option<&str> {
    value.get("subtype").and_then(Value::as_str)
}

/// Synara `sdkNativeMethod` (ClaudeAdapter.ts:1924)
fn sdk_native_method(message: &Value) -> String {
    let kind = message_type(message).unwrap_or("unknown");
    if let Some(subtype) = message_subtype(message) {
        return format!("claude/{kind}/{subtype}");
    }
    if kind == "stream_event" {
        if let Some(stream_type) = message.get("event").and_then(message_type) {
            if stream_type == "content_block_delta" {
                if let Some(delta_type) = message.pointer("/event/delta").and_then(message_type) {
                    return format!("claude/{kind}/{stream_type}/{delta_type}");
                }
            }
            return format!("claude/{kind}/{stream_type}");
        }
    }
    format!("claude/{kind}")
}

/// Synara `parentToolUseId` (ClaudeAdapter.ts:1973)
fn parent_tool_use_id(message: &Value) -> Option<&str> {
    if !matches!(message_type(message), Some("assistant" | "user" | "stream_event" | "tool_progress")) {
        return None;
    }
    message.get("parent_tool_use_id").and_then(Value::as_str).filter(|id| !id.is_empty())
}

/// Synara `runtimeSessionStateFromClaudeTaskStatus` (ClaudeAdapter.ts:2020)
fn runtime_session_state_from_claude_task_status(status: &str) -> Option<RuntimeSessionState> {
    match status {
        "pending" => Some(RuntimeSessionState::Starting),
        "running" => Some(RuntimeSessionState::Running),
        "paused" => Some(RuntimeSessionState::Waiting),
        "completed" => Some(RuntimeSessionState::Ready),
        "failed" => Some(RuntimeSessionState::Error),
        "killed" => Some(RuntimeSessionState::Stopped),
        _ => None,
    }
}

/// Synara `normalizeClaudeTodoTasks` (claudeTaskTracker.ts:163)
fn normalize_claude_todo_tasks(input: &Map<String, Value>) -> Option<TurnTasksUpdatedPayload> {
    let todos = input.get("todos")?.as_array()?;
    let read = |todo: &Map<String, Value>, key: &str| {
        todo.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    let tasks: Vec<RuntimeTaskListItem> = todos
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|todo| {
            let status = match todo.get("status").and_then(Value::as_str) {
                Some("completed") => RuntimeTaskStatus::Completed,
                Some("in_progress" | "inProgress") => RuntimeTaskStatus::InProgress,
                _ => RuntimeTaskStatus::Pending,
            };
            let content = read(todo, "content");
            let active_form = read(todo, "activeForm");
            let task = if status == RuntimeTaskStatus::InProgress {
                active_form.or(content)
            } else {
                content.or(active_form)
            }?;
            Some(RuntimeTaskListItem { task, status })
        })
        .collect();
    (!tasks.is_empty()).then_some(TurnTasksUpdatedPayload { explanation: None, tasks })
}

fn empty_usage_snapshot(used_tokens: u64) -> ThreadTokenUsageSnapshot {
    ThreadTokenUsageSnapshot {
        cumulative_usage: None,
        used_tokens,
        used_percent: None,
        total_processed_tokens: None,
        token_accounting_version: None,
        max_tokens: None,
        input_tokens: None,
        cached_input_tokens: None,
        output_tokens: None,
        reasoning_output_tokens: None,
        last_used_tokens: None,
        last_input_tokens: None,
        last_cached_input_tokens: None,
        last_output_tokens: None,
        last_reasoning_output_tokens: None,
        tool_uses: None,
        duration_ms: None,
        compacts_automatically: None,
    }
}

fn token_count(usage: &Value, key: &str) -> u64 {
    usage.get(key).and_then(Value::as_f64).filter(|v| v.is_finite() && *v > 0.0).map(|v| v as u64).unwrap_or(0)
}

/// Synara `normalizeClaudeTokenUsage` (claudeTokenUsage.ts:90)
fn normalize_claude_token_usage(usage: &Value, context_window: Option<u64>) -> Option<ThreadTokenUsageSnapshot> {
    if !usage.is_object() {
        return None;
    }
    let input_tokens = token_count(usage, "input_tokens")
        + token_count(usage, "cache_creation_input_tokens")
        + token_count(usage, "cache_read_input_tokens");
    let output_tokens = token_count(usage, "output_tokens");
    let total_processed_tokens = usage
        .get("total_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(input_tokens + output_tokens);
    if total_processed_tokens == 0 {
        return None;
    }
    let max_tokens = context_window.filter(|w| *w > 0);
    let used_tokens = max_tokens.map_or(total_processed_tokens, |max| total_processed_tokens.min(max));
    let mut snapshot = empty_usage_snapshot(used_tokens);
    snapshot.last_used_tokens = Some(used_tokens);
    snapshot.total_processed_tokens = (total_processed_tokens > used_tokens).then_some(total_processed_tokens);
    snapshot.input_tokens = (input_tokens > 0).then_some(input_tokens);
    snapshot.output_tokens = (output_tokens > 0).then_some(output_tokens);
    snapshot.max_tokens = max_tokens;
    snapshot.tool_uses = usage.get("tool_uses").and_then(Value::as_u64);
    snapshot.duration_ms = usage.get("duration_ms").and_then(Value::as_u64);
    Some(snapshot)
}

/// Synara `mergeClaudeTokenUsageSnapshot` (claudeTokenUsage.ts:130)
fn merge_claude_token_usage_snapshot(
    previous: &ThreadTokenUsageSnapshot,
    accumulated: Option<&ThreadTokenUsageSnapshot>,
    context_window: Option<u64>,
) -> ThreadTokenUsageSnapshot {
    let max_tokens = context_window.filter(|w| *w > 0);
    let cap = |value: u64| max_tokens.map_or(value, |max| value.min(max));
    let used_tokens = cap(previous.used_tokens);
    let last_used_tokens = previous.last_used_tokens.map(cap).unwrap_or(used_tokens);
    let total = previous
        .total_processed_tokens
        .unwrap_or(previous.used_tokens)
        .max(accumulated.map_or(0, |a| a.total_processed_tokens.unwrap_or(a.used_tokens)))
        .max(used_tokens);
    let mut merged = previous.clone();
    merged.used_tokens = used_tokens;
    merged.last_used_tokens = Some(last_used_tokens);
    if max_tokens.is_some() {
        merged.max_tokens = max_tokens;
    }
    if total > used_tokens {
        merged.total_processed_tokens = Some(total);
    }
    merged
}

/// Synara `withoutProcessedTokenTotal` (ClaudeAdapter.ts:1126)
fn without_processed_token_total(snapshot: &ThreadTokenUsageSnapshot) -> ThreadTokenUsageSnapshot {
    ThreadTokenUsageSnapshot { total_processed_tokens: None, ..snapshot.clone() }
}

/// Synara `maxClaudeContextWindowFromModelUsage` (claudeTokenUsage.ts:45)
fn max_claude_context_window_from_model_usage(model_usage: Option<&Value>) -> Option<u64> {
    model_usage?
        .as_object()?
        .values()
        .filter_map(|usage| usage.get("contextWindow").and_then(Value::as_u64).filter(|w| *w > 0))
        .max()
}

/// Synara `resolveClaudeApiModelIdContextWindowMaxTokens` (claudeTokenUsage.ts:159), without the
/// capability table: only an explicit `[1m]`/`[200k]` qualifier is known before the first result.
fn resolve_claude_api_model_id_context_window_max_tokens(api_model_id: Option<&str>) -> Option<u64> {
    let id = api_model_id?.to_lowercase();
    if id.ends_with("[1m]") {
        Some(1_000_000)
    } else if id.ends_with("[200k]") {
        Some(200_000)
    } else {
        None
    }
}

/// Synara `stripClaudeContextWindowSuffix` (packages/shared/src/model.ts)
fn strip_claude_context_window_suffix(model: &str) -> &str {
    match model.rfind('[') {
        Some(index) if model.ends_with(']') => &model[..index],
        _ => model,
    }
}

/// Synara `resolveApiModelId` (packages/shared/src/model.ts:883)
fn resolve_api_model_id(selection: &ClaudeModelSelection) -> String {
    let window = selection
        .options
        .as_ref()
        .and_then(|o| o.auto_compact_window.as_deref().or(o.context_window.as_deref()));
    if window == Some("1m") && strip_claude_context_window_suffix(&selection.model) == selection.model {
        return format!("{}[1m]", selection.model);
    }
    selection.model.clone()
}

/// Synara `getEffectiveClaudeCodeEffort` (packages/shared/src/model.ts:900)
fn get_effective_claude_code_effort(effort: Option<ClaudeCodeEffort>) -> Option<&'static str> {
    Some(match effort? {
        ClaudeCodeEffort::Ultrathink => return None,
        ClaudeCodeEffort::Ultracode | ClaudeCodeEffort::Xhigh => "xhigh",
        ClaudeCodeEffort::Low => "low",
        ClaudeCodeEffort::Medium => "medium",
        ClaudeCodeEffort::High => "high",
        ClaudeCodeEffort::Max => "max",
    })
}

/// Synara `resolveSelectedClaudeAutoCompactWindow`: the token count of a window option.
fn auto_compact_window_tokens(selection: Option<&ClaudeModelSelection>) -> Option<u64> {
    match selection?.options.as_ref()?.auto_compact_window.as_deref()? {
        "200k" => Some(200_000),
        "1m" => Some(1_000_000),
        _ => None,
    }
}

/// Synara `ClaudeRequestUsage` (claudeRequestUsage.ts:3): per-API-response token counts, so the
/// several assistant snapshots of one response are counted once.
#[derive(Default)]
struct ClaudeRequestUsage {
    requests: HashMap<String, u64>,
    previous_requests: HashMap<String, u64>,
}

impl ClaudeRequestUsage {
    fn settle_turn(&mut self) {
        if self.requests.is_empty() {
            return;
        }
        self.previous_requests = std::mem::take(&mut self.requests);
    }

    fn add(&mut self, message_id: &str, tokens: u64) -> u64 {
        if self.previous_requests.contains_key(message_id) {
            return 0;
        }
        let previous = self.requests.get(message_id).copied().unwrap_or(0);
        if tokens <= previous {
            return 0;
        }
        self.requests.insert(message_id.to_owned(), tokens);
        tokens - previous
    }

    fn reset(&mut self) {
        self.requests.clear();
        self.previous_requests.clear();
    }
}

/// Synara `claudeTurnResultUsage` (claudeResultUsage.ts:10): the long-lived process reports
/// cumulative `modelUsage` and cost; a turn's share is the difference from the previous result.
fn claude_turn_result_usage(result: &Value, previous: Option<&Value>) -> (Map<String, Value>, Option<f64>) {
    fn delta(current: Option<f64>, before: Option<f64>) -> Option<f64> {
        let current = current?;
        Some(match before {
            Some(before) if current >= before => current - before,
            _ => current,
        })
    }
    let mut model_usage = Map::new();
    if let Some(models) = result.get("modelUsage").and_then(Value::as_object) {
        for (model, current) in models {
            let before = previous.and_then(|p| p.get("modelUsage")?.get(model));
            let mut entry = current.as_object().cloned().unwrap_or_default();
            for key in [
                "inputTokens",
                "outputTokens",
                "thinkingTokens",
                "cacheReadInputTokens",
                "cacheCreationInputTokens",
                "webSearchRequests",
                "costUSD",
            ] {
                let now = current.get(key).and_then(Value::as_f64);
                let then = before.and_then(|b| b.get(key)).and_then(Value::as_f64);
                if let Some(value) = delta(now, then) {
                    let value = if key == "costUSD" { json!(value) } else { json!(value as u64) };
                    entry.insert(key.into(), value);
                }
            }
            model_usage.insert(model.clone(), Value::Object(entry));
        }
    }
    let cost = delta(
        result.get("total_cost_usd").and_then(Value::as_f64),
        previous.and_then(|p| p.get("total_cost_usd")).and_then(Value::as_f64),
    );
    (model_usage, cost)
}

/// Synara `redactSensitiveJsonFields` (sensitiveKeys.ts:108), reduced to the obvious credential
/// names: the approval detail is persisted with the card.
fn redact_sensitive_json_fields(value: &Value) -> Value {
    fn sensitive(key: &str) -> bool {
        let k = key.to_lowercase().replace(['-', '_'], "");
        ["password", "passwd", "secret", "token", "apikey", "authorization", "credential", "privatekey", "cookie"]
            .iter()
            .any(|word| k.contains(word))
    }
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), if sensitive(k) { json!("[REDACTED]") } else { redact_sensitive_json_fields(v) }))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(redact_sensitive_json_fields).collect()),
        other => other.clone(),
    }
}

fn new_id() -> String {
    Uuid::new_v4().to_string()
}

fn body(kind: &str, payload: Value) -> Option<ProviderRuntimeEventBody> {
    serde_json::from_value(json!({ "type": kind, "payload": payload })).ok()
}

fn raw(source: RuntimeEventRawSource, method: impl Into<String>, payload: Value) -> RuntimeEventRaw {
    RuntimeEventRaw { source, method: Some(method.into()), message_type: None, payload }
}

/// Builder steps on an event, in place of Synara's object spreads.
trait EventExt {
    fn turn(self, turn_id: Option<TurnId>) -> Self;
    fn item(self, item_id: &str) -> Self;
    fn request(self, request_id: &str) -> Self;
    fn provider_item(self, item_id: Option<&str>) -> Self;
    fn raw(self, raw: RuntimeEventRaw) -> Self;
}

impl EventExt for ProviderRuntimeEvent {
    fn turn(mut self, turn_id: Option<TurnId>) -> Self {
        self.turn_id = turn_id;
        self
    }

    fn item(mut self, item_id: &str) -> Self {
        self.item_id = Some(RuntimeItemId::new(item_id));
        self
    }

    fn request(mut self, request_id: &str) -> Self {
        self.request_id = Some(RuntimeRequestId::new(request_id));
        self
    }

    fn provider_item(mut self, item_id: Option<&str>) -> Self {
        if let Some(id) = item_id {
            self.provider_refs.get_or_insert_with(ProviderRefs::default).provider_item_id = Some(ProviderItemId::new(id));
        }
        self
    }

    fn raw(mut self, raw: RuntimeEventRaw) -> Self {
        self.raw = Some(raw);
        self
    }
}

/// The models offered before a session has reported the account's own list.
fn default_claude_models() -> Vec<ProviderModel> {
    [("default", "Default (recommended)", true), ("opus", "Opus", false), ("sonnet", "Sonnet", false), ("haiku", "Haiku", false)]
        .into_iter()
        .map(|(slug, name, is_default)| ProviderModel { slug: slug.into(), name: name.into(), is_default })
        .collect()
}

/// Synara `makeClaudeAdapter` (ClaudeAdapter.ts:2059): drives `claude` over stream-json.
pub struct ClaudeAdapter {
    /// Where the app saves attachments, flat (`<dir>/<id><ext>`), read for images and named in
    /// the prompt for other files. Synara's `serverConfig.attachmentsDir`.
    attachments_dir: PathBuf,
    /// The CLI to run when the session's provider options name none.
    binary: String,
    /// The account's models, as the last session's `initialize` answer listed them.
    models: Arc<Mutex<Vec<ProviderModel>>>,
}

impl ClaudeAdapter {
    pub fn new(attachments_dir: impl Into<PathBuf>) -> Self {
        Self { attachments_dir: attachments_dir.into(), binary: "claude".into(), models: Arc::new(Mutex::new(default_claude_models())) }
    }

    pub fn with_binary(mut self, binary: impl Into<String>) -> Self {
        self.binary = binary.into();
        self
    }
}

impl ProviderAdapter for ClaudeAdapter {
    fn provider(&self) -> ProviderKind {
        PROVIDER
    }

    /// ClaudeAdapter.ts:7822
    fn capabilities(&self) -> ProviderAdapterCapabilities {
        ProviderAdapterCapabilities {
            session_model_switch: ProviderSessionModelSwitchMode::InSession,
            conversation_rollback: ProviderConversationRollbackMode::RestartSession,
            supports_turn_steering: true,
            supports_native_slash_command_discovery: true,
            supports_live_turn_diff_patch: false,
        }
    }

    fn models(&self) -> Vec<ProviderModel> {
        self.models.lock().unwrap().clone()
    }

    fn start_session(
        &self,
        input: ProviderSessionStartInput,
        events: EventSink,
        spawner: Arc<dyn Spawner>,
    ) -> ProviderSessionHandle {
        let (commands, inbox) = mpsc::unbounded_channel();
        let handle = ProviderSessionHandle::new(input.thread_id.clone(), commands);
        let attachments_dir = self.attachments_dir.clone();
        let binary = self.binary.clone();
        let models = self.models.clone();
        tokio::spawn(async move {
            run_session(input, events, spawner, inbox, attachments_dir, binary, models).await;
        });
        handle
    }
}

/// What the spawn needs, computed as `startSessionUnlocked` computes it (ClaudeAdapter.ts:5622).
struct ClaudeStartPlan {
    spec: SpawnSpec,
    permission_mode: Option<&'static str>,
    api_model_id: Option<String>,
    session_id: Option<String>,
    resume_state: Option<ClaudeResumeState>,
    effective_effort: Option<&'static str>,
    thinking: Option<bool>,
    fast_mode: bool,
    ultracode: bool,
    auto_compact_window: Option<u64>,
}

fn plan_claude_start(input: &ProviderSessionStartInput, binary: &str) -> ClaudeStartPlan {
    let mut resume_state = read_claude_resume_state(input.resume_cursor.as_ref());
    let existing_resume_session_id = resume_state.as_ref().and_then(|s| s.resume.clone());
    let new_session_id = existing_resume_session_id.is_none().then(new_id);
    // Synara `forkThread` (ClaudeAdapter.ts:7279) copies the source transcript with the SDK's
    // `forkSession` before the fork's first start. Without the SDK the CLI does the copy: the
    // fork's session resumes the source's with `--fork-session` under a new id of its own. The
    // SDK fork remaps every message uuid, so the source's resume pin does not carry over; the
    // turn count does, and token accounting starts again (the forked cursor of 7409-7418).
    let fork_source_session_id = match (&existing_resume_session_id, &input.fork_source_resume_cursor) {
        (None, Some(cursor)) => {
            let source = read_claude_resume_state(Some(cursor));
            let source_session_id = source.as_ref().and_then(|s| s.resume.clone());
            if source_session_id.is_some() {
                resume_state = Some(ClaudeResumeState {
                    thread_id: Some(input.thread_id.clone()),
                    resume: new_session_id.clone(),
                    resume_session_at: None,
                    turn_count: source.and_then(|s| s.turn_count),
                    processed_token_total: Some(0),
                });
            }
            source_session_id
        }
        _ => None,
    };
    let provider_options = input.provider_options.as_ref().and_then(|o| o.claude_agent.as_ref());
    let selection = claude_selection(input.model_selection.as_ref());
    let options = selection.and_then(|s| s.options.as_ref());
    let effort = options.and_then(|o| o.effort);
    let effective_effort = get_effective_claude_code_effort(effort);
    let ultracode = effort == Some(ClaudeCodeEffort::Ultracode);
    let fast_mode = options.and_then(|o| o.fast_mode) == Some(true);
    let thinking = options.and_then(|o| o.thinking);
    let auto_compact_window = auto_compact_window_tokens(selection);
    let api_model_id = selection.map(resolve_api_model_id);
    let permission_mode =
        claude_permission_mode(input.runtime_mode, provider_options.and_then(|o| o.permission_mode.as_deref()));

    let mut settings = Map::new();
    settings.insert("autoCompactEnabled".into(), json!(true));
    if let Some(window) = auto_compact_window {
        settings.insert("autoCompactWindow".into(), json!(window));
    }
    if let Some(thinking) = thinking {
        settings.insert("alwaysThinkingEnabled".into(), json!(thinking));
    }
    if let Some(effort) = effective_effort.filter(|e| *e != "max") {
        settings.insert("effortLevel".into(), json!(effort));
    }
    if fast_mode {
        settings.insert("fastMode".into(), json!(true));
    }
    if ultracode {
        settings.insert("ultracode".into(), json!(true));
    }

    let launch = ClaudeLaunchOptions {
        model: api_model_id.clone(),
        effort: (effective_effort == Some("max")).then(|| "max".to_owned()),
        max_thinking_tokens: provider_options.and_then(|o| o.max_thinking_tokens),
        permission_mode: permission_mode.map(str::to_owned),
        allow_dangerously_skip_permissions: permission_mode == Some("bypassPermissions"),
        resume: existing_resume_session_id.clone().or_else(|| fork_source_session_id.clone()),
        session_id: new_session_id.clone(),
        resume_session_at: None,
        fork_session: fork_source_session_id.is_some(),
        include_partial_messages: true,
        additional_directories: input.cwd.iter().cloned().collect(),
        settings: Some(settings),
    };
    let mut env = vec![("CLAUDE_CODE_ENTRYPOINT".to_owned(), "sdk-ts".to_owned())];
    if let Some(environment) = provider_options.and_then(|o| o.environment.as_ref()) {
        env.extend(environment.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    let spec = SpawnSpec {
        program: provider_options.and_then(|o| o.binary_path.clone()).unwrap_or_else(|| binary.to_owned()),
        args: launch_args(&launch),
        cwd: input.cwd.as_ref().map(PathBuf::from),
        env,
        env_remove: vec!["NODE_OPTIONS".to_owned()],
    };
    ClaudeStartPlan {
        spec,
        permission_mode,
        api_model_id,
        session_id: existing_resume_session_id.or(new_session_id),
        resume_state,
        effective_effort,
        thinking,
        fast_mode,
        ultracode,
        auto_compact_window,
    }
}

/// A control request of ours that is waiting for the CLI's answer.
enum PendingControl {
    Initialize,
    Interrupt { reply: oneshot::Sender<Result<()>>, deadline: Instant },
    /// Answered by nothing but a warning when it fails.
    Fire { subtype: &'static str },
}

/// Synara `ClaudeSubagentRun` (ClaudeAdapter.ts:341): one live Task tool spawn. Its traffic is
/// keyed by the Task tool's id (`parent_tool_use_id` on what the CLI forwards); the task id comes
/// later, with `task_started`, and is what `stop_task` takes.
struct ClaudeSubagentRun {
    tool_use_id: String,
    task_id: Option<String>,
    scope: ClaudeScope,
}

/// Synara `subagentRefs`: stamped on every event a subagent's scoped context makes.
#[derive(Clone, Debug)]
struct SubagentRefs {
    provider_thread_id: String,
    provider_parent_thread_id: String,
}

/// What a conversation of the session owns: the session's own, or one subagent run's. Synara
/// gives a run a `ClaudeSessionContext` of its own that shares the parent's session and query
/// (ClaudeAdapter.ts:3496). Here the session's context takes a run's scope in for as long as a
/// handler runs on it (`swap_scope`), so the same handlers project the subagent's messages.
struct ClaudeScope {
    session: ProviderSession,
    pending_approvals: HashMap<String, PendingApproval>,
    pending_user_inputs: HashMap<String, PendingUserInput>,
    turn_count: u64,
    in_flight_tools: Vec<(i64, ToolInFlight)>,
    turn_state: Option<ClaudeTurnState>,
    last_turn_id: Option<TurnId>,
    interrupt_requested_turn_id: Option<TurnId>,
    last_known_token_usage: Option<ThreadTokenUsageSnapshot>,
    processed_token_total: u64,
    processed_token_turn_baseline: u64,
    processed_token_result_baseline: u64,
    processed_token_baseline_known: bool,
    request_usage: ClaudeRequestUsage,
    result_usage_baseline: Option<Value>,
    last_result_uuid: Option<String>,
    last_assistant_uuid: Option<String>,
    last_thread_started_id: Option<String>,
    last_interaction_mode: Option<ProviderInteractionMode>,
    current_api_model_id: Option<String>,
    resume_session_id: Option<String>,
    first_turn_spawn_mode_authoritative: bool,
    known_background_task_ids: Vec<String>,
    terminal_task_ids: HashSet<String>,
    subagent_refs: Option<SubagentRefs>,
}

/// Synara `ClaudeSessionContext` (ClaudeAdapter.ts:349)
struct ClaudeSessionContext {
    session: ProviderSession,
    lifecycle_generation: Option<String>,
    events: EventSink,
    stdin: Option<Pin<Box<dyn AsyncWrite + Send>>>,
    terminate: Box<dyn FnMut() + Send>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    attachments_dir: PathBuf,
    models: Arc<Mutex<Vec<ProviderModel>>>,
    native_command_names: Option<HashSet<String>>,
    base_permission_mode: Option<&'static str>,
    spawn_permission_mode: &'static str,
    first_turn_spawn_mode_authoritative: bool,
    last_interaction_mode: Option<ProviderInteractionMode>,
    current_api_model_id: Option<String>,
    current_always_thinking_enabled: Option<bool>,
    current_effort: Option<&'static str>,
    current_ultracode: bool,
    current_fast_mode: bool,
    current_auto_compact_window: Option<u64>,
    resume_session_id: Option<String>,
    pending_approvals: HashMap<String, PendingApproval>,
    approvals_always_allowed_for_session: bool,
    pending_user_inputs: HashMap<String, PendingUserInput>,
    turn_count: u64,
    in_flight_tools: Vec<(i64, ToolInFlight)>,
    turn_state: Option<ClaudeTurnState>,
    last_turn_id: Option<TurnId>,
    interrupt_requested_turn_id: Option<TurnId>,
    last_known_context_window: Option<u64>,
    last_known_token_usage: Option<ThreadTokenUsageSnapshot>,
    processed_token_total: u64,
    processed_token_turn_baseline: u64,
    processed_token_result_baseline: u64,
    processed_token_baseline_known: bool,
    request_usage: ClaudeRequestUsage,
    result_usage_baseline: Option<Value>,
    last_result_uuid: Option<String>,
    last_assistant_uuid: Option<String>,
    last_thread_started_id: Option<String>,
    stopped: bool,
    warned_unhandled_sdk_kinds: HashSet<String>,
    known_background_task_ids: Vec<String>,
    terminal_task_ids: HashSet<String>,
    pending_controls: HashMap<String, PendingControl>,
    /// Set while a subagent run's scope is swapped in.
    subagent_refs: Option<SubagentRefs>,
    /// Live Task tool spawns by tool use id.
    subagent_runs: HashMap<String, ClaudeSubagentRun>,
    /// Stops asked for before `task_started` named the run's task; sent when it does.
    pending_subagent_stops: HashSet<String>,
    /// How each settled run ended. Late messages tagged with one are dropped, not let start a turn
    /// on its child thread that would never end.
    settled_subagent_tool_use_ids: HashMap<String, &'static str>,
}

/// The session task: spawn, then serve the CLI and the handle until one of them ends.
async fn run_session(
    input: ProviderSessionStartInput,
    events: EventSink,
    spawner: Arc<dyn Spawner>,
    inbox: mpsc::UnboundedReceiver<SessionCommand>,
    attachments_dir: PathBuf,
    binary: String,
    models: Arc<Mutex<Vec<ProviderModel>>>,
) {
    let plan = plan_claude_start(&input, &binary);
    let started_at = now_iso();
    let session = ProviderSession {
        provider: PROVIDER.into(),
        provider_instance_id: input
            .provider_instance_id
            .clone()
            .or_else(|| claude_selection(input.model_selection.as_ref()).and_then(|s| s.instance_id.clone())),
        status: ProviderSessionStatus::Ready,
        runtime_mode: input.runtime_mode,
        cwd: input.cwd.clone(),
        model: claude_selection(input.model_selection.as_ref()).map(|s| s.model.clone()),
        thread_id: input.thread_id.clone(),
        resume_cursor: None,
        active_turn_id: None,
        created_at: started_at.clone(),
        updated_at: started_at,
        last_error: None,
    };

    let child = match spawner.spawn(&plan.spec) {
        Ok(child) => child,
        Err(error) => {
            report_spawn_failure(&input, session, &events, &plan.spec.program, error).await;
            // Commands that arrive now find the inbox gone and fail with "session has ended".
            drop(inbox);
            return;
        }
    };
    let ChildProcess { stdin, stdout, stderr, exited, terminate } = child;
    let stderr_tail = Arc::new(Mutex::new(VecDeque::new()));
    if let Some(stderr) = stderr {
        tokio::spawn(collect_stderr(stderr, stderr_tail.clone()));
    }

    let resume_state = plan.resume_state.clone().unwrap_or_default();
    let processed_token_baseline_known =
        input.resume_cursor.is_none() || resume_state.processed_token_total.is_some();
    let mut context = ClaudeSessionContext {
        session,
        lifecycle_generation: input.lifecycle_generation.clone(),
        events,
        stdin: Some(stdin),
        terminate,
        stderr_tail,
        attachments_dir,
        models,
        native_command_names: None,
        base_permission_mode: plan.permission_mode,
        spawn_permission_mode: plan.permission_mode.unwrap_or("default"),
        first_turn_spawn_mode_authoritative: true,
        last_interaction_mode: None,
        current_api_model_id: plan.api_model_id.clone(),
        current_always_thinking_enabled: plan.thinking,
        current_effort: plan.effective_effort,
        current_ultracode: plan.ultracode,
        current_fast_mode: plan.fast_mode,
        current_auto_compact_window: plan.auto_compact_window,
        resume_session_id: plan.session_id.clone(),
        pending_approvals: HashMap::new(),
        approvals_always_allowed_for_session: false,
        pending_user_inputs: HashMap::new(),
        turn_count: resume_state.turn_count.unwrap_or(0),
        in_flight_tools: Vec::new(),
        turn_state: None,
        last_turn_id: None,
        interrupt_requested_turn_id: None,
        last_known_context_window: resolve_claude_api_model_id_context_window_max_tokens(plan.api_model_id.as_deref()),
        last_known_token_usage: None,
        processed_token_total: resume_state.processed_token_total.unwrap_or(0),
        processed_token_turn_baseline: resume_state.processed_token_total.unwrap_or(0),
        processed_token_result_baseline: resume_state.processed_token_total.unwrap_or(0),
        processed_token_baseline_known,
        request_usage: ClaudeRequestUsage::default(),
        result_usage_baseline: None,
        last_result_uuid: None,
        last_assistant_uuid: resume_state.resume_session_at.clone(),
        last_thread_started_id: None,
        stopped: false,
        warned_unhandled_sdk_kinds: HashSet::new(),
        known_background_task_ids: Vec::new(),
        terminal_task_ids: HashSet::new(),
        pending_controls: HashMap::new(),
        subagent_refs: None,
        subagent_runs: HashMap::new(),
        pending_subagent_stops: HashSet::new(),
        settled_subagent_tool_use_ids: HashMap::new(),
    };
    context.update_resume_cursor(None);
    context.start(&input, &plan).await;
    context.run(inbox, stdout, exited).await;
}

/// A launch that fails reports itself as a crash would: `runtime.error`, then `session.exited`.
async fn report_spawn_failure(
    input: &ProviderSessionStartInput,
    session: ProviderSession,
    events: &EventSink,
    program: &str,
    error: std::io::Error,
) {
    let context_events = events.clone();
    let stamp = |body| ProviderRuntimeEvent {
        event_id: EventId::new(new_id()),
        provider: PROVIDER.into(),
        provider_instance_id: session.provider_instance_id.clone(),
        thread_id: input.thread_id.clone(),
        created_at: now_iso(),
        turn_id: None,
        parent_turn_id: None,
        item_id: None,
        request_id: None,
        lifecycle_generation: input.lifecycle_generation.clone(),
        provider_refs: Some(ProviderRefs::default()),
        raw: None,
        body,
    };
    let message = format!("Failed to start Claude runtime session: could not run `{program}`: {error}");
    let _ = context_events
        .send(stamp(ProviderRuntimeEventBody::RuntimeError(RuntimeErrorPayload {
            message: message.clone(),
            class: Some(RuntimeErrorClass::TransportError),
            detail: None,
        })))
        .await;
    let _ = context_events
        .send(stamp(ProviderRuntimeEventBody::SessionExited(SessionExitedPayload {
            reason: Some(message),
            recoverable: Some(false),
            exit_kind: Some(RuntimeSessionExitKind::Error),
        })))
        .await;
}

async fn collect_stderr(stderr: Pin<Box<dyn AsyncRead + Send>>, tail: Arc<Mutex<VecDeque<String>>>) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let mut tail = tail.lock().unwrap();
        tail.push_back(line);
        while tail.len() > 40 {
            tail.pop_front();
        }
    }
}

enum Flow {
    Continue,
    Stop,
}

impl ClaudeSessionContext {
    // ---- plumbing ---------------------------------------------------------------------------

    fn event(&self, body: ProviderRuntimeEventBody) -> ProviderRuntimeEvent {
        ProviderRuntimeEvent {
            event_id: EventId::new(new_id()),
            provider: PROVIDER.into(),
            provider_instance_id: self.session.provider_instance_id.clone(),
            thread_id: self.session.thread_id.clone(),
            created_at: now_iso(),
            turn_id: None,
            parent_turn_id: None,
            item_id: None,
            request_id: None,
            lifecycle_generation: self.lifecycle_generation.clone(),
            // Synara `nativeProviderRefs` (ClaudeAdapter.ts:1597): a subagent's events name it.
            provider_refs: Some(ProviderRefs {
                provider_thread_id: self.subagent_refs.as_ref().map(|r| r.provider_thread_id.clone()),
                provider_parent_thread_id: self.subagent_refs.as_ref().map(|r| r.provider_parent_thread_id.clone()),
                ..ProviderRefs::default()
            }),
            raw: None,
            body,
        }
    }

    // ---- subagent runs ----------------------------------------------------------------------

    /// Exchanges the conversation state on the context with `scope`'s: once to enter a run's
    /// scope, again to leave it.
    fn swap_scope(&mut self, scope: &mut ClaudeScope) {
        macro_rules! swap {
            ($($field:ident),* $(,)?) => { $(std::mem::swap(&mut self.$field, &mut scope.$field);)* };
        }
        swap!(
            session,
            pending_approvals,
            pending_user_inputs,
            turn_count,
            in_flight_tools,
            turn_state,
            last_turn_id,
            interrupt_requested_turn_id,
            last_known_token_usage,
            processed_token_total,
            processed_token_turn_baseline,
            processed_token_result_baseline,
            processed_token_baseline_known,
            request_usage,
            result_usage_baseline,
            last_result_uuid,
            last_assistant_uuid,
            last_thread_started_id,
            last_interaction_mode,
            current_api_model_id,
            resume_session_id,
            first_turn_spawn_mode_authoritative,
            known_background_task_ids,
            terminal_task_ids,
            subagent_refs,
        );
    }

    /// Synara `ensureSubagentRun` (ClaudeAdapter.ts:3496): the run for a Task tool, made the first
    /// time it is heard of. Taken out of the map; [`Self::put_subagent_run`] gives it back.
    fn take_subagent_run(&mut self, tool_use_id: &str) -> ClaudeSubagentRun {
        if let Some(run) = self.subagent_runs.remove(tool_use_id) {
            return run;
        }
        ClaudeSubagentRun {
            tool_use_id: tool_use_id.to_owned(),
            task_id: None,
            scope: ClaudeScope {
                session: self.session.clone(),
                pending_approvals: HashMap::new(),
                pending_user_inputs: HashMap::new(),
                turn_count: 0,
                in_flight_tools: Vec::new(),
                turn_state: None,
                last_turn_id: None,
                interrupt_requested_turn_id: None,
                last_known_token_usage: None,
                processed_token_total: 0,
                processed_token_turn_baseline: 0,
                processed_token_result_baseline: 0,
                processed_token_baseline_known: true,
                request_usage: ClaudeRequestUsage::default(),
                result_usage_baseline: None,
                last_result_uuid: None,
                last_assistant_uuid: None,
                last_thread_started_id: None,
                last_interaction_mode: None,
                current_api_model_id: None,
                resume_session_id: None,
                // A run only projects events of a CLI already running; it never sends the first prompt.
                first_turn_spawn_mode_authoritative: false,
                known_background_task_ids: Vec::new(),
                terminal_task_ids: HashSet::new(),
                subagent_refs: Some(SubagentRefs {
                    provider_thread_id: tool_use_id.to_owned(),
                    provider_parent_thread_id: self.session.thread_id.to_string(),
                }),
            },
        }
    }

    fn put_subagent_run(&mut self, run: ClaudeSubagentRun) {
        self.subagent_runs.insert(run.tool_use_id.clone(), run);
    }

    /// Synara `isRecognizedSubagentToolUseId` (ClaudeAdapter.ts:1987)
    fn is_recognized_subagent_tool_use_id(&self, tool_use_id: &str) -> bool {
        self.subagent_runs.contains_key(tool_use_id)
            || self.settled_subagent_tool_use_ids.contains_key(tool_use_id)
            || self
                .in_flight_tools
                .iter()
                .any(|(_, tool)| tool.item_id == tool_use_id && tool.item_type == CanonicalItemType::CollabAgentToolCall)
    }

    /// Synara `recognizedSubagentParentToolUseId` (ClaudeAdapter.ts:1999). Claude also tags async
    /// Bash progress with a parent tool use id, so only a known Task/Agent tool's id routes.
    fn recognized_subagent_parent_tool_use_id(&self, message: &Value) -> Option<String> {
        parent_tool_use_id(message).filter(|id| self.is_recognized_subagent_tool_use_id(id)).map(str::to_owned)
    }

    /// Synara `subagentRunForTask` (ClaudeAdapter.ts:2041): the run's tool use id.
    fn subagent_run_for_task(&mut self, tool_use_id: Option<&str>, task_id: &str) -> Option<String> {
        if let Some(run) = tool_use_id.and_then(|id| self.subagent_runs.get_mut(id)) {
            run.task_id.get_or_insert_with(|| task_id.to_owned());
            return Some(run.tool_use_id.clone());
        }
        self.subagent_runs.values().find(|run| run.task_id.as_deref() == Some(task_id)).map(|run| run.tool_use_id.clone())
    }

    /// A settled run leaves: later messages tagged with it are dropped, and its turn, if one is
    /// open, ends as the task did.
    async fn settle_subagent_run(&mut self, tool_use_id: &str, settled: &'static str, turn_status: RuntimeTurnState) {
        let Some(mut run) = self.subagent_runs.remove(tool_use_id) else { return };
        self.pending_subagent_stops.remove(tool_use_id);
        self.settled_subagent_tool_use_ids.insert(tool_use_id.to_owned(), settled);
        if run.scope.turn_state.is_some() {
            self.swap_scope(&mut run.scope);
            self.complete_turn(turn_status, None, None).await;
            self.swap_scope(&mut run.scope);
        }
    }

    /// Synara `offerRuntimeEvent` (ClaudeAdapter.ts:2271)
    async fn offer(&mut self, event: ProviderRuntimeEvent) {
        let _ = self.events.send(event).await;
    }

    fn current_turn_id(&self) -> Option<TurnId> {
        self.turn_state.as_ref().map(|t| t.turn_id.clone())
    }

    async fn write(&mut self, value: &Value) -> Result<()> {
        let stdin = self.stdin.as_mut().ok_or_else(|| anyhow!("the Claude runtime's input is closed"))?;
        stdin.write_all(&protocol::encode_line(value)).await?;
        stdin.flush().await?;
        Ok(())
    }

    async fn send_control(&mut self, request: ControlRequest, pending: PendingControl) -> Result<()> {
        let request_id = new_id();
        self.write(&protocol::control_request(&request_id, &request)).await?;
        self.pending_controls.insert(request_id, pending);
        Ok(())
    }

    async fn answer_permission(&mut self, cli_request_id: &str, result: PermissionResult, tool_use_id: Option<&str>) {
        let response = protocol::control_response_success(cli_request_id, result.to_response(tool_use_id));
        if let Err(error) = self.write(&response).await {
            tracing::debug!("claude: could not answer {cli_request_id}: {error}");
        }
    }

    /// Synara `updateResumeCursor` (ClaudeAdapter.ts:2351)
    fn update_resume_cursor(&mut self, updated_at: Option<IsoDateTime>) {
        let mut cursor = Map::new();
        cursor.insert("threadId".into(), json!(self.session.thread_id));
        if let Some(resume) = &self.resume_session_id {
            cursor.insert("resume".into(), json!(resume));
        }
        if let Some(at) = &self.last_assistant_uuid {
            cursor.insert("resumeSessionAt".into(), json!(at));
        }
        cursor.insert("turnCount".into(), json!(self.turn_count));
        if self.processed_token_baseline_known {
            cursor.insert("processedTokenTotal".into(), json!(self.processed_token_total));
            cursor.insert("tokenAccountingVersion".into(), json!(1));
        }
        self.session.resume_cursor = Some(Value::Object(cursor));
        self.session.updated_at = updated_at.unwrap_or_else(now_iso);
    }

    fn budget(&self) -> Option<u64> {
        match (self.current_auto_compact_window, self.last_known_context_window) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    // ---- start and the loop -----------------------------------------------------------------

    /// The tail of `startSessionUnlocked` (ClaudeAdapter.ts:6413-6461), plus the SDK's
    /// `initialize` handshake.
    async fn start(&mut self, input: &ProviderSessionStartInput, plan: &ClaudeStartPlan) {
        let started = self.event(ProviderRuntimeEventBody::SessionStarted(SessionStartedPayload {
            message: None,
            resume: input.resume_cursor.clone(),
        }));
        self.offer(started).await;

        let mut config = Map::new();
        if let Some(model) = &self.session.model {
            config.insert("model".into(), json!(model));
        }
        if let Some(api_model_id) = &plan.api_model_id {
            config.insert("apiModelId".into(), json!(api_model_id));
        }
        config.insert("autoCompactWindow".into(), json!(plan.auto_compact_window));
        if let Some(cwd) = &input.cwd {
            config.insert("cwd".into(), json!(cwd));
        }
        if let Some(effort) = plan.effective_effort {
            config.insert("effort".into(), json!(effort));
        }
        if let Some(mode) = plan.permission_mode {
            config.insert("permissionMode".into(), json!(mode));
        }
        if plan.fast_mode {
            config.insert("fastMode".into(), json!(true));
        }
        if plan.ultracode {
            config.insert("ultracode".into(), json!(true));
        }
        let configured = self.event(ProviderRuntimeEventBody::SessionConfigured(SessionConfiguredPayload { config }));
        self.offer(configured).await;

        let initialize = ControlRequest::Initialize {
            append_system_prompt: Some(EMBEDDED_CLAUDE_SYSTEM_PROMPT_APPEND.to_owned()),
        };
        if let Err(error) = self.send_control(initialize, PendingControl::Initialize).await {
            self.emit_runtime_error(&format!("Failed to initialize the Claude runtime: {error}"), None).await;
        }

        let ready = self.event(ProviderRuntimeEventBody::SessionStateChanged(SessionStateChangedPayload {
            state: RuntimeSessionState::Ready,
            reason: None,
            detail: None,
        }));
        self.offer(ready).await;
    }

    async fn run(
        mut self,
        mut inbox: mpsc::UnboundedReceiver<SessionCommand>,
        stdout: Pin<Box<dyn AsyncRead + Send>>,
        mut exited: ExitFuture,
    ) {
        let mut lines = BufReader::new(stdout).lines();
        let mut exit_code: Option<Option<i32>> = None;
        loop {
            let deadline = self
                .pending_controls
                .values()
                .filter_map(|p| match p {
                    PendingControl::Interrupt { deadline, .. } => Some(*deadline),
                    _ => None,
                })
                .min();
            tokio::select! {
                command = inbox.recv() => match command {
                    Some(command) => {
                        if let Flow::Stop = self.handle_command(command).await {
                            break;
                        }
                    }
                    None => {
                        self.stop_session_internal(true, None).await;
                        break;
                    }
                },
                line = lines.next_line() => match line {
                    Ok(Some(line)) => {
                        self.handle_line(&line).await;
                        if self.stopped {
                            break;
                        }
                    }
                    Ok(None) | Err(_) => {
                        // The CLI closed its output: wait briefly for its exit status.
                        let code = match exit_code {
                            Some(code) => code,
                            None => tokio::time::timeout(Duration::from_secs(3), &mut exited).await.unwrap_or(None),
                        };
                        exit_code = Some(code);
                        self.handle_stream_exit(code).await;
                        break;
                    }
                },
                code = &mut exited, if exit_code.is_none() => {
                    // Exited while stdout may still hold lines: keep reading until it closes.
                    exit_code = Some(code);
                }
                _ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => {
                    self.expire_controls();
                }
            }
        }
        if exit_code.is_none() {
            let _ = tokio::time::timeout(Duration::from_secs(3), &mut exited).await;
        }
    }

    fn expire_controls(&mut self) {
        let now = Instant::now();
        let expired: Vec<String> = self
            .pending_controls
            .iter()
            .filter(|(_, p)| matches!(p, PendingControl::Interrupt { deadline, .. } if *deadline <= now))
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            if let Some(PendingControl::Interrupt { reply, .. }) = self.pending_controls.remove(&id) {
                let _ = reply.send(Err(anyhow!(
                    "The Claude CLI did not acknowledge the interrupt within {}ms.",
                    CLAUDE_INTERRUPT_TIMEOUT.as_millis()
                )));
            }
        }
    }

    async fn handle_command(&mut self, command: SessionCommand) -> Flow {
        match command {
            SessionCommand::SendTurn { input, reply } => {
                let _ = reply.send(self.send_turn(input).await);
            }
            SessionCommand::SteerTurn { input, reply } => {
                let _ = reply.send(self.steer_turn(input).await);
            }
            SessionCommand::StartReview { reply, .. } => {
                // Synara's ClaudeAdapter has no `startReview` (ProviderService.startReview).
                let _ = reply.send(Err(anyhow!("Provider 'claudeAgent' does not support native review.")));
            }
            SessionCommand::InterruptTurn { turn_id: _, provider_thread_id: Some(provider_thread_id), reply } => {
                let _ = reply.send(self.interrupt_subagent(&provider_thread_id).await);
            }
            SessionCommand::InterruptTurn { turn_id, provider_thread_id: None, reply } => self.interrupt_turn(turn_id, reply).await,
            SessionCommand::RespondToRequest { request_id, decision, reply } => {
                let _ = reply.send(self.respond_to_request(&request_id, decision).await);
            }
            SessionCommand::RespondToUserInput { request_id, answers, reply } => {
                let _ = reply.send(self.respond_to_user_input(&request_id, answers).await);
            }
            SessionCommand::SetRuntimeMode { mode, reply } => {
                let _ = reply.send(self.set_runtime_mode(mode).await);
            }
            SessionCommand::Stop { reply } => {
                self.stop_session_internal(true, None).await;
                let _ = reply.send(Ok(()));
                return Flow::Stop;
            }
        }
        Flow::Continue
    }

    async fn handle_line(&mut self, line: &str) {
        let parsed = match protocol::parse_line(line) {
            Ok(Some(parsed)) => parsed,
            Ok(None) => return,
            Err(error) => {
                tracing::debug!("claude: {error}: {}", truncate_chars(line, 200));
                return;
            }
        };
        match parsed {
            CliLine::Message(message) => self.handle_sdk_message(message).await,
            CliLine::ControlResponse { request_id, result } => self.handle_control_response(&request_id, result).await,
            CliLine::ControlRequest { request_id, request } => self.handle_control_request(request_id, request).await,
            CliLine::ControlCancelRequest { request_id } => self.handle_control_cancel_request(&request_id).await,
            CliLine::KeepAlive => {}
        }
    }

    async fn handle_control_response(&mut self, request_id: &str, result: std::result::Result<Value, String>) {
        match self.pending_controls.remove(request_id) {
            Some(PendingControl::Initialize) => match result {
                Ok(response) => self.apply_initialize_response(&response),
                Err(error) => {
                    self.emit_runtime_warning(&format!("Claude initialization failed: {error}"), None).await;
                }
            },
            Some(PendingControl::Interrupt { reply, .. }) => {
                let _ = reply.send(result.map(|_| ()).map_err(|error| anyhow!("turn/interrupt failed: {error}")));
            }
            Some(PendingControl::Fire { subtype }) => {
                if let Err(error) = result {
                    self.emit_runtime_warning(&format!("Claude {subtype} failed: {error}"), None).await;
                }
            }
            None => {}
        }
    }

    /// The `initialize` answer lists the account's models and the native commands.
    fn apply_initialize_response(&mut self, response: &Value) {
        if let Some(models) = response.get("models").and_then(Value::as_array) {
            let models: Vec<ProviderModel> = models
                .iter()
                .filter_map(|model| {
                    let slug = model.get("value")?.as_str()?.to_owned();
                    let name = model.get("displayName").and_then(Value::as_str).unwrap_or(&slug).to_owned();
                    Some(ProviderModel { is_default: slug == "default", slug, name })
                })
                .collect();
            if !models.is_empty() {
                *self.models.lock().unwrap() = models;
            }
        }
        if let Some(commands) = response.get("commands").and_then(Value::as_array) {
            let mut names = HashSet::new();
            for command in commands {
                if let Some(name) = command.get("name").and_then(Value::as_str) {
                    names.insert(name.to_owned());
                }
                for alias in command.get("aliases").and_then(Value::as_array).into_iter().flatten() {
                    if let Some(alias) = alias.as_str() {
                        names.insert(alias.to_owned());
                    }
                }
            }
            self.native_command_names = Some(names);
        }
    }

    // ---- the free-standing emitters of makeClaudeAdapter ------------------------------------

    /// Synara `ensureAssistantTextBlock` (ClaudeAdapter.ts:2381): the block's position in the
    /// turn's order.
    fn ensure_assistant_text_block(&mut self, block_index: i64, fallback_text: Option<&str>, stream_closed: bool) -> Option<usize> {
        let turn = self.turn_state.as_mut()?;
        if let Some(&position) = turn.assistant_text_blocks.get(&block_index) {
            let existing = &mut turn.assistant_text_block_order[position];
            if !existing.completion_emitted {
                if existing.fallback_text.is_empty() {
                    if let Some(text) = fallback_text.filter(|t| !t.is_empty()) {
                        existing.fallback_text = text.to_owned();
                    }
                }
                if stream_closed {
                    existing.stream_closed = true;
                }
                return Some(position);
            }
        }
        turn.assistant_text_block_order.push(AssistantTextBlockState {
            item_id: new_id(),
            block_index,
            emitted_text_delta: false,
            fallback_text: fallback_text.unwrap_or_default().to_owned(),
            stream_closed,
            completion_emitted: false,
        });
        let position = turn.assistant_text_block_order.len() - 1;
        turn.assistant_text_blocks.insert(block_index, position);
        Some(position)
    }

    /// Synara `createSyntheticAssistantTextBlock` (ClaudeAdapter.ts:2425)
    fn create_synthetic_assistant_text_block(&mut self, fallback_text: &str) -> Option<usize> {
        let turn = self.turn_state.as_mut()?;
        let block_index = turn.next_synthetic_assistant_block_index;
        turn.next_synthetic_assistant_block_index -= 1;
        self.ensure_assistant_text_block(block_index, Some(fallback_text), true)
    }

    /// Synara `completeAssistantTextBlock` (ClaudeAdapter.ts:2449)
    async fn complete_assistant_text_block(&mut self, position: usize, force: bool, raw_method: &str, raw_payload: Option<Value>) {
        let Some(turn) = self.turn_state.as_mut() else {
            return;
        };
        let turn_id = turn.turn_id.clone();
        let block = &mut turn.assistant_text_block_order[position];
        if block.completion_emitted || (!force && !block.stream_closed) {
            return;
        }
        let needs_fallback_delta = !block.emitted_text_delta && !block.fallback_text.is_empty();
        block.completion_emitted = true;
        let item_id = block.item_id.clone();
        let fallback_text = block.fallback_text.clone();
        let block_index = block.block_index;
        if turn.assistant_text_blocks.get(&block_index) == Some(&position) {
            turn.assistant_text_blocks.remove(&block_index);
        }

        if needs_fallback_delta {
            let delta = self
                .event(ProviderRuntimeEventBody::ContentDelta(ContentDeltaPayload {
                    stream_kind: RuntimeContentStreamKind::AssistantText,
                    delta: fallback_text.clone(),
                    content_index: None,
                    summary_index: None,
                }))
                .turn(Some(turn_id.clone()))
                .item(&item_id)
                .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, raw_method, json!({})));
            self.offer(delta).await;
        }
        let completed = self
            .event(ProviderRuntimeEventBody::ItemCompleted(ItemLifecyclePayload {
                async_questions: None,
                item_type: CanonicalItemType::AssistantMessage,
                status: Some(RuntimeItemStatus::Completed),
                title: Some("Assistant message".into()),
                detail: (!fallback_text.is_empty()).then_some(fallback_text),
                data: None,
            }))
            .item(&item_id)
            .turn(Some(turn_id))
            .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, raw_method, raw_payload.unwrap_or(Value::Null)));
        self.offer(completed).await;
    }

    /// Synara `backfillAssistantTextBlocksFromSnapshot` (ClaudeAdapter.ts:2528)
    async fn backfill_assistant_text_blocks_from_snapshot(&mut self, message: &Value) {
        let snapshot_text_blocks = extract_assistant_text_blocks(message);
        let Some(turn) = self.turn_state.as_ref() else {
            return;
        };
        if snapshot_text_blocks.is_empty() {
            return;
        }
        let mut ordered: Vec<usize> = (turn.assistant_message_block_base..turn.assistant_text_block_order.len()).collect();
        for (position, text) in snapshot_text_blocks.iter().enumerate() {
            let entry = match ordered.get(position) {
                Some(&entry) => Some(entry),
                None => self.create_synthetic_assistant_text_block(text).inspect(|&created| ordered.push(created)),
            };
            let Some(entry) = entry else {
                continue;
            };
            let Some(turn) = self.turn_state.as_mut() else {
                return;
            };
            let block = &mut turn.assistant_text_block_order[entry];
            if block.fallback_text.is_empty() {
                block.fallback_text = text.clone();
            }
            if block.stream_closed && !block.completion_emitted {
                self.complete_assistant_text_block(entry, false, "claude/assistant", Some(message.clone())).await;
            }
        }
        if let Some(turn) = self.turn_state.as_mut() {
            turn.assistant_message_block_base = turn.assistant_text_block_order.len();
        }
    }

    /// Synara `ensureThreadId` (ClaudeAdapter.ts:2588)
    async fn ensure_thread_id(&mut self, message: &Value) {
        let Some(session_id) = message.get("session_id").and_then(Value::as_str).filter(|s| !s.is_empty()) else {
            return;
        };
        if !has_durable_claude_session_id(message) {
            return;
        }
        let next = session_id.to_owned();
        self.resume_session_id = Some(next.clone());
        self.update_resume_cursor(None);
        if self.last_thread_started_id.as_deref() != Some(next.as_str()) {
            self.result_usage_baseline = None;
            self.last_thread_started_id = Some(next.clone());
            let started = self
                .event(ProviderRuntimeEventBody::ThreadStarted(ThreadStartedPayload { provider_thread_id: Some(next.clone()) }))
                .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/thread/started", json!({ "session_id": next })));
            self.offer(started).await;
        }
    }

    /// Synara `emitRuntimeError` (ClaudeAdapter.ts:2633)
    async fn emit_runtime_error(&mut self, message: &str, detail: Option<Value>) {
        let event = self
            .event(ProviderRuntimeEventBody::RuntimeError(RuntimeErrorPayload {
                message: message.to_owned(),
                class: Some(RuntimeErrorClass::ProviderError),
                detail,
            }))
            .turn(self.current_turn_id());
        self.offer(event).await;
    }

    /// Synara `emitRuntimeWarning` (ClaudeAdapter.ts:2660)
    async fn emit_runtime_warning(&mut self, message: &str, detail: Option<Value>) {
        let event = self
            .event(ProviderRuntimeEventBody::RuntimeWarning(RuntimeWarningPayload { message: message.to_owned(), detail }))
            .turn(self.current_turn_id());
        self.offer(event).await;
    }

    /// Synara `warnUnhandledSdkKind` (ClaudeAdapter.ts:2859)
    async fn warn_unhandled_sdk_kind(&mut self, kind: String, message: String, detail: Value) {
        if !self.warned_unhandled_sdk_kinds.insert(kind) {
            return;
        }
        self.emit_runtime_warning(&message, Some(detail)).await;
    }

    /// Synara `emitProposedPlanCompleted` (ClaudeAdapter.ts:2873)
    async fn emit_proposed_plan_completed(
        &mut self,
        plan_markdown: &str,
        tool_use_id: Option<&str>,
        raw_source: RuntimeEventRawSource,
        raw_method: &str,
        raw_payload: Value,
    ) {
        let plan_markdown = plan_markdown.trim();
        let Some(turn) = self.turn_state.as_mut() else {
            return;
        };
        if plan_markdown.is_empty() {
            return;
        }
        if !turn.captured_proposed_plan_keys.insert(exit_plan_capture_key(tool_use_id, plan_markdown)) {
            return;
        }
        let turn_id = turn.turn_id.clone();
        let event = self
            .event(ProviderRuntimeEventBody::TurnProposedCompleted(TurnProposedCompletedPayload {
                plan_markdown: plan_markdown.to_owned(),
            }))
            .turn(Some(turn_id))
            .provider_item(tool_use_id)
            .raw(raw(raw_source, raw_method, raw_payload));
        self.offer(event).await;
    }

    /// Synara `emitTodoTasksUpdated` (ClaudeAdapter.ts:2922)
    async fn emit_todo_tasks_updated(&mut self, tool_input: &Map<String, Value>, tool_use_id: &str, raw_method: &str, raw_payload: Value) {
        let Some(turn_id) = self.current_turn_id() else {
            return;
        };
        let Some(payload) = normalize_claude_todo_tasks(tool_input) else {
            return;
        };
        let event = self
            .event(ProviderRuntimeEventBody::TurnTasksUpdated(payload))
            .turn(Some(turn_id))
            .provider_item(Some(tool_use_id))
            .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, raw_method, raw_payload));
        self.offer(event).await;
    }

    /// Synara `settlePendingApproval` (ClaudeAdapter.ts:2995): publishes the resolution and
    /// answers the CLI's `can_use_tool`.
    async fn settle_pending_approval(&mut self, request_id: &str, decision: ProviderApprovalDecision) -> bool {
        let Some(pending) = self.pending_approvals.remove(request_id) else {
            return false;
        };
        let decision_name = serde_json::to_value(decision).ok().and_then(|v| v.as_str().map(str::to_owned));
        let resolved = self
            .event(ProviderRuntimeEventBody::RequestResolved(RequestResolvedPayload {
                request_type: pending.request_type,
                decision: decision_name.clone(),
                resolution: None,
            }))
            .turn(pending.turn_id.clone())
            .request(request_id)
            .provider_item(pending.provider_item_id.as_deref())
            .raw(raw(RuntimeEventRawSource::ClaudeSdkPermission, "canUseTool/decision", json!({ "decision": decision_name })));
        self.offer(resolved).await;

        let result = match decision {
            ProviderApprovalDecision::Accept | ProviderApprovalDecision::AcceptForSession => {
                // Only command and file prompts widen the whole session; a tool grant stays
                // scoped to that tool through the CLI's permission suggestions.
                let widens = matches!(
                    pending.request_type,
                    CanonicalRequestType::CommandExecutionApproval
                        | CanonicalRequestType::FileReadApproval
                        | CanonicalRequestType::FileChangeApproval
                );
                if decision == ProviderApprovalDecision::AcceptForSession && self.session.runtime_mode != RuntimeMode::Auto && widens {
                    self.approvals_always_allowed_for_session = true;
                }
                PermissionResult::Allow {
                    updated_input: pending.tool_input.clone(),
                    updated_permissions: if decision == ProviderApprovalDecision::AcceptForSession {
                        pending.suggestions.clone()
                    } else {
                        None
                    },
                }
            }
            ProviderApprovalDecision::Decline => PermissionResult::Deny { message: "User declined tool execution.".into() },
            ProviderApprovalDecision::Cancel => PermissionResult::Deny { message: "User cancelled tool execution.".into() },
        };
        self.answer_permission(&pending.cli_request_id, result, pending.provider_item_id.as_deref()).await;
        true
    }

    /// Synara `settlePendingUserInput` (ClaudeAdapter.ts:3046)
    async fn settle_pending_user_input(&mut self, request_id: &str, answers: ProviderUserInputAnswers, cancelled: bool) -> bool {
        let Some(pending) = self.pending_user_inputs.remove(request_id) else {
            return false;
        };
        let remapped = remap_answers_to_claude_question_text(&pending.questions, &answers);
        let resolved = self
            .event(ProviderRuntimeEventBody::UserInputResolved(UserInputResolvedPayload { answers: remapped.clone() }))
            .turn(pending.turn_id.clone())
            .request(request_id)
            .provider_item(pending.provider_item_id.as_deref())
            .raw(raw(
                RuntimeEventRawSource::ClaudeSdkPermission,
                "canUseTool/AskUserQuestion/resolved",
                json!({ "answers": remapped, "cancelled": cancelled }),
            ));
        self.offer(resolved).await;
        let result = if cancelled {
            PermissionResult::Deny { message: "User cancelled tool execution.".into() }
        } else {
            PermissionResult::Allow {
                updated_input: json!({
                    "questions": pending.tool_input.get("questions").cloned().unwrap_or(Value::Null),
                    "answers": remapped,
                }),
                updated_permissions: None,
            }
        };
        self.answer_permission(&pending.cli_request_id, result, pending.provider_item_id.as_deref()).await;
        true
    }

    /// Synara `settlePendingHumanInteractions` (ClaudeAdapter.ts:3108): `None` settles the whole
    /// session, a turn id its foreground callbacks.
    async fn settle_pending_human_interactions(&mut self, turn_scope: Option<&TurnId>) {
        let in_scope = |turn_id: &Option<TurnId>, agent_id: &Option<String>, terminal: &HashSet<String>| match turn_scope {
            None => true,
            Some(scope) => turn_id.as_ref() == Some(scope) && agent_id.as_ref().is_none_or(|a| terminal.contains(a)),
        };
        let approvals: Vec<String> = self
            .pending_approvals
            .iter()
            .filter(|(_, p)| in_scope(&p.turn_id, &p.agent_id, &self.terminal_task_ids))
            .map(|(id, _)| id.clone())
            .collect();
        for id in approvals {
            self.settle_pending_approval(&id, ProviderApprovalDecision::Cancel).await;
        }
        let inputs: Vec<String> = self
            .pending_user_inputs
            .iter()
            .filter(|(_, p)| in_scope(&p.turn_id, &p.agent_id, &self.terminal_task_ids))
            .map(|(id, _)| id.clone())
            .collect();
        for id in inputs {
            self.settle_pending_user_input(&id, ProviderUserInputAnswers::new(), true).await;
        }
    }

    /// Synara `settlePendingHumanInteractionsForAgent` (ClaudeAdapter.ts:3130)
    async fn settle_pending_human_interactions_for_agent(&mut self, agent_id: &str) {
        let approvals: Vec<String> = self
            .pending_approvals
            .iter()
            .filter(|(_, p)| p.agent_id.as_deref() == Some(agent_id))
            .map(|(id, _)| id.clone())
            .collect();
        for id in approvals {
            self.settle_pending_approval(&id, ProviderApprovalDecision::Cancel).await;
        }
        let inputs: Vec<String> = self
            .pending_user_inputs
            .iter()
            .filter(|(_, p)| p.agent_id.as_deref() == Some(agent_id))
            .map(|(id, _)| id.clone())
            .collect();
        for id in inputs {
            self.settle_pending_user_input(&id, ProviderUserInputAnswers::new(), true).await;
        }
    }

    /// Synara `completeTurn` (ClaudeAdapter.ts:3150), with the token accounting reduced to the
    /// per-call snapshots and the result's totals (no live context-usage probe).
    async fn complete_turn(&mut self, status: RuntimeTurnState, error_message: Option<String>, result: Option<&Value>) {
        if let Some(turn_id) = self.current_turn_id() {
            self.settle_pending_human_interactions(Some(&turn_id)).await;
        }

        let turn_result_usage = result.map(|r| claude_turn_result_usage(r, self.result_usage_baseline.as_ref()));
        if let Some(result) = result {
            self.result_usage_baseline = Some(result.clone());
        }
        if let Some(window) = max_claude_context_window_from_model_usage(result.and_then(|r| r.get("modelUsage"))) {
            self.last_known_context_window = Some(window);
        }

        let accumulated = result.and_then(|r| r.get("usage")).and_then(|u| normalize_claude_token_usage(u, self.budget()));
        let reported_zero_usage = result.and_then(|r| r.get("usage")).is_some_and(|u| {
            ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .iter()
                .all(|key| token_count(u, key) == 0)
        });
        let result_processed_tokens = accumulated
            .as_ref()
            .map(|a| a.total_processed_tokens.unwrap_or(a.used_tokens))
            .or(reported_zero_usage.then_some(0));
        if let Some(processed) = result_processed_tokens {
            let reconciled = self.processed_token_result_baseline + processed;
            self.processed_token_total = if status == RuntimeTurnState::Completed {
                reconciled
            } else {
                self.processed_token_total.max(reconciled)
            };
        }
        let total_processed_tokens =
            if self.processed_token_total > 0 { Some(self.processed_token_total) } else { result_processed_tokens };
        let accounted_accumulated = accumulated.as_ref().map(|a| match total_processed_tokens {
            Some(total) if self.processed_token_baseline_known => ThreadTokenUsageSnapshot { total_processed_tokens: Some(total), ..a.clone() },
            _ => without_processed_token_total(a),
        });
        let merged = match &self.last_known_token_usage {
            Some(last) if self.processed_token_baseline_known => {
                Some(merge_claude_token_usage_snapshot(last, accounted_accumulated.as_ref(), self.budget()))
            }
            Some(last) => Some(last.clone()),
            None => accounted_accumulated,
        };
        let usage_snapshot = merged.map(|merged| {
            let mut snapshot = without_processed_token_total(&merged);
            snapshot.token_accounting_version = Some(1);
            if self.processed_token_baseline_known {
                snapshot.total_processed_tokens = total_processed_tokens;
            }
            snapshot
        });
        let baseline = if result.is_some() { self.processed_token_result_baseline } else { self.processed_token_turn_baseline };
        let main_loop_tokens = self.processed_token_total.saturating_sub(baseline);
        self.processed_token_result_baseline = self.processed_token_total;
        self.request_usage.settle_turn();

        let stop_reason = result.and_then(|r| r.get("stop_reason")).map(|v| v.as_str().map(str::to_owned));
        let usage = result.and_then(|r| r.get("usage")).cloned();
        let (model_usage, total_cost_usd) = match turn_result_usage {
            Some((model_usage, cost)) => (Some(model_usage), cost),
            None => (None, None),
        };
        let completed_payload = |state| TurnCompletedPayload {
            state,
            context_compacted: None,
            stop_reason: stop_reason.clone(),
            usage: usage.clone(),
            model_usage: model_usage.clone(),
            token_accounting_version: Some(1),
            main_loop_tokens: Some(main_loop_tokens),
            total_cost_usd: result.and_then(|r| r.get("total_cost_usd")).and_then(Value::as_f64).and(total_cost_usd),
            cumulative_cost_usd: None,
            error_message: error_message.clone(),
        };

        let Some(turn_state) = self.turn_state.take() else {
            if let Some(usage) = usage_snapshot {
                let event = self.event(ProviderRuntimeEventBody::ThreadTokenUsageUpdated(ThreadTokenUsageUpdatedPayload { usage }));
                self.offer(event).await;
            }
            // Ingestion drops a terminal event it cannot attribute; the last turn is the only one
            // a result with no live turn can settle.
            if self.last_turn_id.is_none() {
                tracing::warn!("claude turn result arrived with no attributable turn");
            }
            let event = self
                .event(ProviderRuntimeEventBody::TurnCompleted(completed_payload(status)))
                .turn(self.last_turn_id.clone());
            self.offer(event).await;
            return;
        };
        self.turn_state = Some(turn_state);
        let turn_id = self.current_turn_id().expect("turn state was just restored");

        let tools = std::mem::take(&mut self.in_flight_tools);
        let raw_result = result.cloned().unwrap_or_else(|| json!({ "status": status }));
        for (_, tool) in tools {
            let completed = self
                .event(ProviderRuntimeEventBody::ItemCompleted(ItemLifecyclePayload {
                    async_questions: None,
                    item_type: tool.item_type,
                    status: Some(if status == RuntimeTurnState::Completed { RuntimeItemStatus::Completed } else { RuntimeItemStatus::Failed }),
                    title: Some(tool.title.clone()),
                    detail: tool.detail.clone(),
                    data: Some(tool_lifecycle_event_data(&tool, None)),
                }))
                .turn(Some(turn_id.clone()))
                .item(&tool.item_id)
                .provider_item(Some(&tool.item_id))
                .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/result", raw_result.clone()));
            self.offer(completed).await;
            if tool.item_type == CanonicalItemType::FileChange {
                if let Some(turn) = self.turn_state.as_mut() {
                    turn.saw_file_change = true;
                }
            }
        }

        let block_count = self.turn_state.as_ref().map_or(0, |t| t.assistant_text_block_order.len());
        for position in 0..block_count {
            self.complete_assistant_text_block(position, true, "claude/result", Some(raw_result.clone())).await;
        }
        self.turn_count += 1;

        if let Some(usage) = usage_snapshot {
            let event = self
                .event(ProviderRuntimeEventBody::ThreadTokenUsageUpdated(ThreadTokenUsageUpdatedPayload { usage }))
                .turn(Some(turn_id.clone()));
            self.offer(event).await;
        }

        let turn_state = self.turn_state.take().expect("turn state is live until completion");
        if status == RuntimeTurnState::Completed && turn_state.saw_file_change {
            let diff = self
                .event(ProviderRuntimeEventBody::TurnDiffUpdated(
                    crate::contracts::provider_runtime::TurnDiffUpdatedPayload { unified_diff: String::new() },
                ))
                .turn(Some(turn_id.clone()))
                .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/result", raw_result.clone()));
            self.offer(diff).await;
        }

        // Terminal consumers can dispatch another turn at once: settle the session and cursor
        // first.
        let completed_at = now_iso();
        if self.interrupt_requested_turn_id.as_ref() == Some(&turn_id) {
            self.interrupt_requested_turn_id = None;
        }
        self.last_interaction_mode = Some(turn_state.interaction_mode);
        self.session.status = ProviderSessionStatus::Ready;
        self.session.active_turn_id = None;
        if status == RuntimeTurnState::Failed {
            if let Some(message) = &error_message {
                self.session.last_error = Some(message.clone());
            }
        }
        self.update_resume_cursor(Some(completed_at.clone()));

        let mut event = self.event(ProviderRuntimeEventBody::TurnCompleted(completed_payload(status))).turn(Some(turn_id));
        event.created_at = completed_at;
        self.offer(event).await;
    }

    /// Synara `openInFlightTool` (ClaudeAdapter.ts:3591)
    async fn open_in_flight_tool(&mut self, block_index: i64, tool_name: &str, item_id: &str, tool_input: Map<String, Value>, raw_method: &str, raw_payload: Value) {
        let item_type = classify_tool_item_type(tool_name);
        let serialized = Value::Object(tool_input.clone()).to_string();
        let fingerprint = (!tool_input.is_empty()).then(|| serialized.clone());
        let tool = ToolInFlight {
            item_id: item_id.to_owned(),
            item_type,
            tool_name: tool_name.to_owned(),
            title: title_for_tool(item_type).to_owned(),
            detail: Some(summarize_tool_request(tool_name, &tool_input, Some(&serialized))),
            input: tool_input,
            partial_input_json: String::new(),
            last_emitted_input_fingerprint: fingerprint,
        };
        self.in_flight_tools.retain(|(index, _)| *index != block_index);
        self.in_flight_tools.push((block_index, tool.clone()));

        let started = self
            .event(ProviderRuntimeEventBody::ItemStarted(ItemLifecyclePayload {
                async_questions: None,
                item_type,
                status: Some(RuntimeItemStatus::InProgress),
                title: Some(tool.title.clone()),
                detail: tool.detail.clone(),
                data: Some(tool_lifecycle_event_data(&tool, None)),
            }))
            .turn(self.current_turn_id())
            .item(&tool.item_id)
            .provider_item(Some(&tool.item_id))
            .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, raw_method, raw_payload.clone()));
        self.offer(started).await;
        if tool.tool_name == "TodoWrite" {
            self.emit_todo_tasks_updated(&tool.input, &tool.item_id, raw_method, raw_payload).await;
        }
    }

    /// Synara `emitReasoning` (ClaudeAdapter.ts:3659): a turn holds several API messages, each
    /// reusing block indices, so blocks are keyed by message and index.
    async fn emit_reasoning(&mut self, index: i64, text: &str, complete: bool, snapshot_key: Option<String>) {
        const LIMIT: usize = 8_000;
        let Some(turn) = self.turn_state.as_mut() else {
            return;
        };
        let turn_id = turn.turn_id.clone();
        let is_snapshot = snapshot_key.is_some();
        let key = snapshot_key.unwrap_or_else(|| {
            format!("{}:{index}", turn.reasoning_message_id.as_deref().unwrap_or("partial"))
        });
        let mut position = turn.reasoning_blocks.iter().position(|(k, _)| *k == key);
        match position {
            Some(p) if !is_snapshot && turn.reasoning_blocks[p].1.completed => return,
            None if text.is_empty() => return,
            _ => {}
        }
        let snapshot_text = is_snapshot.then(|| truncate_chars(text, LIMIT).to_owned());
        if let (Some(p), Some(snapshot_text)) = (position, &snapshot_text) {
            let block = &mut turn.reasoning_blocks[p].1;
            block.snapshot_received = true;
            if block.completed && block.text == *snapshot_text {
                return;
            }
        }
        let mut started_item = None;
        if position.is_none() {
            let item_id = new_id();
            turn.reasoning_blocks.push((key, ReasoningBlock { item_id: item_id.clone(), text: String::new(), completed: false, snapshot_received: false }));
            position = Some(turn.reasoning_blocks.len() - 1);
            started_item = Some(item_id);
        }
        let block = &mut turn.reasoning_blocks[position.expect("reasoning block exists")].1;
        let delta = match &snapshot_text {
            Some(snapshot) => snapshot.strip_prefix(block.text.as_str()).unwrap_or_default().to_owned(),
            None => truncate_chars(text, LIMIT.saturating_sub(block.text.chars().count())).to_owned(),
        };
        match snapshot_text {
            Some(snapshot) => {
                block.text = snapshot;
                block.snapshot_received = true;
            }
            None => block.text.push_str(&delta),
        }
        if complete {
            block.completed = true;
        }
        let item_id = block.item_id.clone();
        let final_text = block.text.clone();

        if let Some(item_id) = started_item {
            let started = self
                .event(ProviderRuntimeEventBody::ItemStarted(ItemLifecyclePayload {
                    async_questions: None,
                    item_type: CanonicalItemType::Reasoning,
                    status: Some(RuntimeItemStatus::InProgress),
                    title: Some("Thinking".into()),
                    detail: None,
                    data: None,
                }))
                .turn(Some(turn_id.clone()))
                .item(&item_id);
            self.offer(started).await;
        }
        if !delta.is_empty() {
            let event = self
                .event(ProviderRuntimeEventBody::ContentDelta(ContentDeltaPayload {
                    stream_kind: RuntimeContentStreamKind::ReasoningText,
                    delta,
                    content_index: None,
                    summary_index: None,
                }))
                .turn(Some(turn_id.clone()))
                .item(&item_id);
            self.offer(event).await;
        }
        if complete {
            let event = self
                .event(ProviderRuntimeEventBody::ItemCompleted(ItemLifecyclePayload {
                    async_questions: None,
                    item_type: CanonicalItemType::Reasoning,
                    status: Some(RuntimeItemStatus::Completed),
                    title: Some("Thinking".into()),
                    detail: Some(final_text),
                    data: None,
                }))
                .turn(Some(turn_id))
                .item(&item_id);
            self.offer(event).await;
        }
    }

    // ---- SDK messages -----------------------------------------------------------------------

    /// Synara `handleStreamEvent` (ClaudeAdapter.ts:3738)
    async fn handle_stream_event(&mut self, message: &Value) {
        let Some(event) = message.get("event") else {
            return;
        };
        let event_type = message_type(event).unwrap_or_default();
        let index = event.get("index").and_then(Value::as_i64).unwrap_or(0);
        if event_type == "message_start" {
            if let Some(turn) = self.turn_state.as_mut() {
                turn.reasoning_message_id = event.pointer("/message/id").and_then(Value::as_str).map(str::to_owned);
            }
        }
        let block_type = event.pointer("/content_block/type").and_then(Value::as_str);
        let delta_type = event.pointer("/delta/type").and_then(Value::as_str);
        if event_type == "content_block_start" && block_type == Some("thinking") {
            let text = event.pointer("/content_block/thinking").and_then(Value::as_str).unwrap_or_default().to_owned();
            self.emit_reasoning(index, &text, false, None).await;
            return;
        }
        if event_type == "content_block_delta" && delta_type == Some("thinking_delta") {
            let text = event.pointer("/delta/thinking").and_then(Value::as_str).unwrap_or_default().to_owned();
            self.emit_reasoning(index, &text, false, None).await;
            return;
        }
        if event_type == "content_block_stop" {
            self.emit_reasoning(index, "", true, None).await;
        }

        if event_type == "content_block_delta" {
            if delta_type == Some("text_delta") && self.turn_state.is_some() {
                let delta_text = event.pointer("/delta/text").and_then(Value::as_str).unwrap_or_default().to_owned();
                if delta_text.is_empty() {
                    return;
                }
                let position = self.ensure_assistant_text_block(index, None, false);
                let item_id = position.and_then(|p| {
                    let block = &mut self.turn_state.as_mut()?.assistant_text_block_order[p];
                    block.emitted_text_delta = true;
                    Some(block.item_id.clone())
                });
                let mut delta = self
                    .event(ProviderRuntimeEventBody::ContentDelta(ContentDeltaPayload {
                        stream_kind: RuntimeContentStreamKind::AssistantText,
                        delta: delta_text,
                        content_index: None,
                        summary_index: None,
                    }))
                    .turn(self.current_turn_id())
                    .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/stream_event/content_block_delta", json!({})));
                if let Some(item_id) = item_id {
                    delta = delta.item(&item_id);
                }
                self.offer(delta).await;
                return;
            }
            if delta_type == Some("input_json_delta") {
                let Some(partial) = event.pointer("/delta/partial_json").and_then(Value::as_str) else {
                    return;
                };
                let Some(slot) = self.in_flight_tools.iter().position(|(i, _)| *i == index) else {
                    return;
                };
                let tool = &mut self.in_flight_tools[slot].1;
                tool.partial_input_json.push_str(partial);
                let parsed = try_parse_complete_json_record(&tool.partial_input_json);
                if let Some((input, serialized)) = &parsed {
                    tool.input = input.clone();
                    tool.detail = Some(summarize_tool_request(&tool.tool_name, input, Some(serialized)));
                }
                let next_fingerprint = parsed.as_ref().filter(|(input, _)| !input.is_empty()).map(|(_, s)| s.clone());
                let Some(next_fingerprint) = next_fingerprint else {
                    return;
                };
                if tool.last_emitted_input_fingerprint.as_deref() == Some(next_fingerprint.as_str()) {
                    return;
                }
                tool.last_emitted_input_fingerprint = Some(next_fingerprint);
                let tool = tool.clone();
                let updated = self
                    .event(ProviderRuntimeEventBody::ItemUpdated(ItemLifecyclePayload {
                        async_questions: None,
                        item_type: tool.item_type,
                        status: Some(RuntimeItemStatus::InProgress),
                        title: Some(tool.title.clone()),
                        detail: tool.detail.clone(),
                        data: Some(tool_lifecycle_event_data(&tool, None)),
                    }))
                    .turn(self.current_turn_id())
                    .item(&tool.item_id)
                    .provider_item(Some(&tool.item_id))
                    .raw(raw(
                        RuntimeEventRawSource::ClaudeSdkMessage,
                        "claude/stream_event/content_block_delta/input_json_delta",
                        json!({}),
                    ));
                self.offer(updated).await;
                if tool.tool_name == "TodoWrite" {
                    self.emit_todo_tasks_updated(
                        &tool.input,
                        &tool.item_id,
                        "claude/stream_event/content_block_delta/input_json_delta",
                        message.clone(),
                    )
                    .await;
                }
            }
            return;
        }

        if event_type == "content_block_start" {
            let Some(block) = event.get("content_block") else {
                return;
            };
            if block_type == Some("text") {
                let fallback = extract_content_block_text(block);
                self.ensure_assistant_text_block(index, Some(&fallback), false);
                return;
            }
            if !matches!(block_type, Some("tool_use" | "server_tool_use" | "mcp_tool_use")) {
                return;
            }
            let tool_name = block.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
            if is_client_surfaced_claude_tool(&tool_name) {
                return;
            }
            let item_id = block.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
            let input = block.get("input").and_then(Value::as_object).cloned().unwrap_or_default();
            self.open_in_flight_tool(index, &tool_name, &item_id, input, "claude/stream_event/content_block_start", message.clone())
                .await;
            return;
        }

        if event_type == "content_block_stop" {
            let position = self.turn_state.as_ref().and_then(|t| t.assistant_text_blocks.get(&index).copied());
            if let Some(position) = position {
                if let Some(turn) = self.turn_state.as_mut() {
                    turn.assistant_text_block_order[position].stream_closed = true;
                }
                self.complete_assistant_text_block(position, false, "claude/stream_event/content_block_stop", Some(message.clone()))
                    .await;
            }
        }
    }

    /// Synara `handleUserMessage` (ClaudeAdapter.ts:3927): a tool result closes its item.
    async fn handle_user_message(&mut self, message: &Value) {
        for tool_result in tool_result_blocks_from_user_message(message) {
            let Some(slot) = self.in_flight_tools.iter().position(|(_, tool)| tool.item_id == tool_result.tool_use_id) else {
                continue;
            };
            let (_, tool) = self.in_flight_tools.remove(slot);
            let mut extra = Map::new();
            extra.insert("result".into(), tool_result.block.clone());
            // A stopped task answers with an error-shaped result: the agent's state says stopped,
            // so its row does not read "Failed".
            let settled = matches!(tool.tool_name.as_str(), "Task" | "Agent")
                .then(|| self.settled_subagent_tool_use_ids.get(&tool.item_id).copied())
                .flatten();
            if settled == Some("stopped") {
                extra.insert("agentStates".into(), json!({ tool.item_id.clone(): { "status": "stopped" } }));
            }
            let tool_data = tool_lifecycle_event_data(&tool, Some(extra));

            let updated = self
                .event(ProviderRuntimeEventBody::ItemUpdated(ItemLifecyclePayload {
                    async_questions: None,
                    item_type: tool.item_type,
                    status: Some(if tool_result.is_error { RuntimeItemStatus::Failed } else { RuntimeItemStatus::InProgress }),
                    title: Some(tool.title.clone()),
                    detail: tool.detail.clone(),
                    data: Some(tool_data.clone()),
                }))
                .turn(self.current_turn_id())
                .item(&tool.item_id)
                .provider_item(Some(&tool.item_id))
                .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/user", message.clone()));
            self.offer(updated).await;

            if let (Some(stream_kind), Some(turn_id)) = (tool_result_stream_kind(tool.item_type), self.current_turn_id()) {
                if !tool_result.text.is_empty() {
                    let delta = self
                        .event(ProviderRuntimeEventBody::ContentDelta(ContentDeltaPayload {
                            stream_kind,
                            delta: tool_result.text.clone(),
                            content_index: None,
                            summary_index: None,
                        }))
                        .turn(Some(turn_id))
                        .item(&tool.item_id)
                        .provider_item(Some(&tool.item_id))
                        .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/user", json!({})));
                    self.offer(delta).await;
                }
            }

            let completed = self
                .event(ProviderRuntimeEventBody::ItemCompleted(ItemLifecyclePayload {
                    async_questions: None,
                    item_type: tool.item_type,
                    status: Some(if tool_result.is_error { RuntimeItemStatus::Failed } else { RuntimeItemStatus::Completed }),
                    title: Some(tool.title.clone()),
                    detail: tool.detail.clone(),
                    data: Some(tool_data),
                }))
                .turn(self.current_turn_id())
                .item(&tool.item_id)
                .provider_item(Some(&tool.item_id))
                .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/user", message.clone()));
            self.offer(completed).await;

            if tool.item_type == CanonicalItemType::FileChange {
                if let Some(turn) = self.turn_state.as_mut() {
                    turn.saw_file_change = true;
                }
            }
        }
    }

    /// Synara `ensureSyntheticTurn` (ClaudeAdapter.ts:4111): output that arrives with no active
    /// turn (background agents between prompts) gets a turn of its own.
    async fn ensure_synthetic_turn(&mut self) {
        if self.turn_state.is_some() {
            return;
        }
        let turn_id = TurnId::new(new_id());
        self.turn_state = Some(ClaudeTurnState::new(turn_id.clone(), ProviderInteractionMode::Default, true));
        self.processed_token_turn_baseline = self.processed_token_total;
        self.last_turn_id = Some(turn_id.clone());
        self.session.status = ProviderSessionStatus::Running;
        self.session.active_turn_id = Some(turn_id.clone());
        self.session.updated_at = now_iso();
        let mut started = self
            .event(ProviderRuntimeEventBody::TurnStarted(TurnStartedPayload::default()))
            .turn(Some(turn_id.clone()))
            .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/synthetic-turn-start", json!({})));
        started.provider_refs.get_or_insert_with(ProviderRefs::default).provider_turn_id = Some(turn_id.to_string());
        self.offer(started).await;
    }

    /// Synara `handleAssistantMessage` (ClaudeAdapter.ts:4195)
    async fn handle_assistant_message(&mut self, message: &Value) {
        self.ensure_synthetic_turn().await;
        if let Some(error) = message.get("error").and_then(Value::as_str) {
            if let Some(turn) = self.turn_state.as_mut() {
                turn.assistant_error = Some((error.to_owned(), claude_assistant_error_message(error).to_owned()));
            }
        }
        let content = message.pointer("/message/content").and_then(Value::as_array).cloned();
        if let Some(content) = &content {
            for block in content {
                // A subagent's conversation comes as whole messages, never streamed, so this is the
                // one chance to open its tools. The parent's are opened from the stream (whose
                // `content_block_start` may come after this snapshot), so only a subagent's are.
                let tool_use_block = matches!(block.get("type").and_then(Value::as_str), Some("tool_use" | "server_tool_use" | "mcp_tool_use"));
                if let (true, true, Some(id), Some(name)) = (
                    tool_use_block,
                    self.subagent_refs.is_some(),
                    block.get("id").and_then(Value::as_str),
                    block.get("name").and_then(Value::as_str),
                ) {
                    if !is_client_surfaced_claude_tool(name) && !self.in_flight_tools.iter().any(|(_, tool)| tool.item_id == id) {
                        let synthetic_index = self.in_flight_tools.iter().map(|(index, _)| *index).filter(|i| *i <= -1).min().map_or(-1, |i| i - 1);
                        let input = block.get("input").and_then(Value::as_object).cloned().unwrap_or_default();
                        self.open_in_flight_tool(synthetic_index, name, id, input, "claude/assistant", message.clone()).await;
                    }
                }
                if block.get("type").and_then(Value::as_str) != Some("tool_use")
                    || block.get("name").and_then(Value::as_str) != Some("ExitPlanMode")
                {
                    continue;
                }
                let Some(plan) = block.get("input").and_then(extract_exit_plan_mode_plan) else {
                    continue;
                };
                let tool_use_id = block.get("id").and_then(Value::as_str).map(str::to_owned);
                self.emit_proposed_plan_completed(
                    &plan,
                    tool_use_id.as_deref(),
                    RuntimeEventRawSource::ClaudeSdkMessage,
                    "claude/assistant",
                    message.clone(),
                )
                .await;
            }
            let in_plan_mode = self.turn_state.as_ref().is_some_and(|t| t.interaction_mode == ProviderInteractionMode::Plan);
            if in_plan_mode {
                if let Some(plan) = extract_proposed_plan_markdown(&extract_text_content(&Value::Array(content.clone()))) {
                    self.emit_proposed_plan_completed(
                        &plan,
                        None,
                        RuntimeEventRawSource::ClaudeSdkMessage,
                        "claude/assistant/proposed-plan-block",
                        message.clone(),
                    )
                    .await;
                }
            }
        }

        if self.turn_state.is_some() {
            if let Some(content) = &content {
                let message_id = message
                    .pointer("/message/id")
                    .and_then(Value::as_str)
                    .or_else(|| message.get("uuid").and_then(Value::as_str))
                    .unwrap_or_default()
                    .to_owned();
                let uuid = message.get("uuid").and_then(Value::as_str).unwrap_or_default().to_owned();
                for (index, block) in content.iter().enumerate() {
                    if block.get("type").and_then(Value::as_str) != Some("thinking") {
                        continue;
                    }
                    let Some(thinking) = block.get("thinking").and_then(Value::as_str) else {
                        continue;
                    };
                    let key = if content.len() > 1 {
                        format!("{message_id}:{index}")
                    } else {
                        let turn = self.turn_state.as_ref().expect("turn checked above");
                        let prefix = format!("{message_id}:");
                        let truncated = truncate_chars(thinking, 8_000);
                        let candidates: Vec<&(String, ReasoningBlock)> =
                            turn.reasoning_blocks.iter().filter(|(k, _)| k.starts_with(&prefix)).collect();
                        let exact = candidates
                            .iter()
                            .find(|(_, b)| !b.snapshot_received && b.text == truncated)
                            .or_else(|| candidates.iter().find(|(_, b)| b.text == truncated));
                        let streamed = candidates.iter().find(|(_, b)| !b.snapshot_received);
                        exact
                            .or(streamed)
                            .map(|(k, _)| k.clone())
                            .unwrap_or_else(|| format!("{message_id}:snapshot:{uuid}:{index}"))
                    };
                    self.emit_reasoning(index as i64, thinking, true, Some(key)).await;
                }
            }
            self.backfill_assistant_text_blocks_from_snapshot(message).await;
        }

        // Per-API-call usage: the prompt plus output of this one call, which is the context size.
        if let Some(per_call_usage) = message.pointer("/message/usage") {
            let message_id = message
                .pointer("/message/id")
                .or_else(|| message.get("request_id"))
                .or_else(|| message.get("uuid"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if let Some(normalized) = normalize_claude_token_usage(per_call_usage, self.budget()) {
                let added = self
                    .request_usage
                    .add(&message_id, normalized.total_processed_tokens.unwrap_or(normalized.used_tokens));
                self.processed_token_total += added;
                let mut current = without_processed_token_total(&normalized);
                current.token_accounting_version = Some(1);
                if self.processed_token_baseline_known {
                    current.total_processed_tokens = Some(self.processed_token_total);
                }
                self.last_known_token_usage = Some(current.clone());
                let event = self
                    .event(ProviderRuntimeEventBody::ThreadTokenUsageUpdated(ThreadTokenUsageUpdatedPayload { usage: current }))
                    .turn(self.current_turn_id())
                    .raw(raw(RuntimeEventRawSource::ClaudeSdkMessage, "claude/assistant-usage", per_call_usage.clone()));
                self.offer(event).await;
            }
        }

        if let Some(uuid) = message.get("uuid").and_then(Value::as_str) {
            self.last_assistant_uuid = Some(uuid.to_owned());
        }
        self.update_resume_cursor(None);
    }

    fn has_pending_user_interrupt(&self) -> bool {
        self.interrupt_requested_turn_id.is_some() && self.interrupt_requested_turn_id == self.current_turn_id()
    }

    /// Synara `handleResultMessage` (ClaudeAdapter.ts:4405)
    async fn handle_result_message(&mut self, message: &Value) {
        let uuid = message.get("uuid").and_then(Value::as_str).map(str::to_owned);
        if uuid.is_some() && self.last_result_uuid == uuid {
            return;
        }
        self.last_result_uuid = uuid;

        let assistant_error = self.turn_state.as_ref().and_then(|t| t.assistant_error.clone());
        let status = if self.has_pending_user_interrupt() && message_subtype(message) == Some("error_during_execution") {
            RuntimeTurnState::Interrupted
        } else if assistant_error.is_some() {
            RuntimeTurnState::Failed
        } else {
            turn_status_from_result(message)
        };
        let error_message = match &assistant_error {
            Some((_, text)) => Some(text.clone()),
            None if message_subtype(message) != Some("success") => normalize_claude_user_visible_error_message(
                message.get("errors").and_then(|e| e.get(0)).and_then(Value::as_str),
                status,
            ),
            None => None,
        };
        if status == RuntimeTurnState::Failed {
            self.emit_runtime_error(error_message.as_deref().unwrap_or("Claude turn failed."), None).await;
        }
        self.complete_turn(status, error_message, Some(message)).await;

        // An auth/account failure cannot be recovered by the live process: retire it after the
        // failed turn; the next message starts a fresh one from the resume cursor.
        if assistant_error.is_some_and(|(code, _)| claude_assistant_error_requires_process_restart(&code)) {
            self.stop_session_internal(true, None).await;
        }
    }

    /// Synara `handleSystemMessage` (ClaudeAdapter.ts:4605), less the subagent, workflow and
    /// compaction bookkeeping.
    async fn handle_system_message(&mut self, message: &Value) {
        let subtype = message_subtype(message).unwrap_or_default().to_owned();
        if subtype == "thinking_tokens" {
            return;
        }
        let base_raw = RuntimeEventRaw {
            source: RuntimeEventRawSource::ClaudeSdkMessage,
            method: Some(sdk_native_method(message)),
            message_type: Some(format!("system:{subtype}")),
            payload: message.clone(),
        };
        let field = |key: &str| message.get(key).cloned().unwrap_or(Value::Null);
        let text = |key: &str| message.get(key).and_then(Value::as_str).map(str::to_owned);

        if subtype == "task_updated" {
            let patch = message.get("patch");
            let status = patch.and_then(|p| p.get("status")).and_then(Value::as_str).map(str::to_owned);
            let is_backgrounded = patch.and_then(|p| p.get("is_backgrounded")).and_then(Value::as_bool);
            if status.is_none() && is_backgrounded.is_none() {
                return;
            }
            let task_id = text("task_id").unwrap_or_default();
            let terminal = matches!(status.as_deref(), Some("completed" | "failed" | "killed"));
            if terminal {
                self.terminal_task_ids.insert(task_id.clone());
                self.settle_pending_human_interactions_for_agent(&task_id).await;
            }
            if terminal || is_backgrounded == Some(false) {
                self.known_background_task_ids.retain(|id| *id != task_id);
            }
            let mut payload = json!({ "taskId": task_id });
            if let Some(status) = &status {
                payload["status"] = json!(status);
            }
            if let Some(error) = patch.and_then(|p| p.get("error")).and_then(Value::as_str) {
                payload["error"] = json!(error);
            }
            if let Some(backgrounded) = is_backgrounded {
                payload["isBackgrounded"] = json!(backgrounded);
            }
            let run = self.subagent_run_for_task(None, &task_id);
            if let Some(run) = &run {
                payload["toolUseId"] = json!(run);
            }
            self.offer_body("task.updated", payload, base_raw.clone()).await;
            // A tracked subagent's child thread follows its task's state.
            let (Some(tool_use_id), Some(state)) = (run, status.as_deref().and_then(runtime_session_state_from_claude_task_status))
            else {
                return;
            };
            if let Some(mut run) = self.subagent_runs.remove(&tool_use_id) {
                self.swap_scope(&mut run.scope);
                let changed = self
                    .event(ProviderRuntimeEventBody::SessionStateChanged(SessionStateChangedPayload {
                        state,
                        reason: Some(format!("task:{}", status.as_deref().unwrap_or_default())),
                        detail: Some(message.clone()),
                    }))
                    .turn(self.current_turn_id())
                    .raw(base_raw);
                self.offer(changed).await;
                self.swap_scope(&mut run.scope);
                self.put_subagent_run(run);
            }
            if terminal {
                let (settled, turn_status) = match status.as_deref() {
                    Some("completed") => ("completed", RuntimeTurnState::Completed),
                    Some("failed") => ("failed", RuntimeTurnState::Failed),
                    _ => ("stopped", RuntimeTurnState::Interrupted),
                };
                self.settle_subagent_run(&tool_use_id, settled, turn_status).await;
            }
            return;
        }

        let (kind, payload) = match subtype.as_str() {
            "init" => ("session.configured", json!({ "config": message })),
            "api_retry" => {
                let delay = message.get("retry_delay_ms").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
                let reason = match message.get("error_status") {
                    Some(Value::Null) | None => "connection error".to_owned(),
                    Some(status) => format!("HTTP {status}"),
                };
                let attempt = field("attempt");
                let max = field("max_retries");
                self.emit_runtime_warning(&format!("Request retry {attempt}/{max} in {}s ({reason}).", delay.ceil()), Some(message.clone()))
                    .await;
                return;
            }
            "permission_denied" => {
                let reason = text("decision_reason")
                    .filter(|r| !r.trim().is_empty())
                    .or_else(|| text("message").filter(|m| !m.trim().is_empty()))
                    .unwrap_or_else(|| "Claude's automatic permission reviewer denied this action.".into());
                let tool = text("tool_name").unwrap_or_default();
                self.emit_runtime_warning(&format!("{tool} was denied: {}", reason.trim()), Some(message.clone())).await;
                return;
            }
            "status" => {
                let status = text("status");
                let state = if status.as_deref() == Some("compacting") { "waiting" } else { "running" };
                (
                    "session.state.changed",
                    json!({ "state": state, "reason": format!("status:{}", status.as_deref().unwrap_or("active")), "detail": message }),
                )
            }
            "compact_boundary" => {
                self.last_known_token_usage = None;
                self.update_resume_cursor(None);
                ("thread.state.changed", json!({ "state": "compacted", "detail": message }))
            }
            "hook_started" => (
                "hook.started",
                json!({ "hookId": field("hook_id"), "hookName": field("hook_name"), "hookEvent": field("hook_event") }),
            ),
            "hook_progress" => (
                "hook.progress",
                json!({ "hookId": field("hook_id"), "output": field("output"), "stdout": field("stdout"), "stderr": field("stderr") }),
            ),
            "hook_response" => {
                let mut payload = json!({
                    "hookId": field("hook_id"),
                    "outcome": field("outcome"),
                    "output": field("output"),
                    "stdout": field("stdout"),
                    "stderr": field("stderr"),
                });
                if let Some(code) = message.get("exit_code").and_then(Value::as_i64) {
                    payload["exitCode"] = json!(code);
                }
                ("hook.completed", payload)
            }
            "task_started" => {
                let task_id = text("task_id").unwrap_or_default();
                self.terminal_task_ids.remove(&task_id);
                // A subagent task gets its run, so later progress, its end and a stop find it by
                // the Task tool's id, which ingestion routes on.
                if let Some(tool_use_id) = text("tool_use_id")
                    .filter(|id| message.get("subagent_type").is_some_and(|t| !t.is_null()) || self.subagent_runs.contains_key(id))
                {
                    let mut run = self.take_subagent_run(&tool_use_id);
                    run.task_id = Some(task_id.clone());
                    self.put_subagent_run(run);
                    // A stop that raced the spawn goes now that the task has an id.
                    if self.pending_subagent_stops.remove(&tool_use_id) {
                        self.stop_subagent_task(&task_id).await;
                    }
                }
                let mut payload = json!({ "taskId": task_id, "description": field("description") });
                for (from, to) in [("task_type", "taskType"), ("subagent_type", "subagentType"), ("workflow_name", "workflowName"), ("tool_use_id", "toolUseId")] {
                    if let Some(value) = text(from) {
                        payload[to] = json!(value);
                    }
                }
                ("task.started", payload)
            }
            "task_progress" => {
                let mut payload = json!({ "taskId": field("task_id"), "description": field("description") });
                for (from, to) in [("summary", "summary"), ("last_tool_name", "lastToolName")] {
                    if let Some(value) = text(from).filter(|v| !v.is_empty()) {
                        payload[to] = json!(value);
                    }
                }
                if let Some(usage) = message.get("usage").filter(|u| !u.is_null()) {
                    payload["usage"] = usage.clone();
                }
                ("task.progress", payload)
            }
            "task_notification" => {
                let task_id = text("task_id").unwrap_or_default();
                self.terminal_task_ids.insert(task_id.clone());
                self.settle_pending_human_interactions_for_agent(&task_id).await;
                self.known_background_task_ids.retain(|id| *id != task_id);
                let mut payload = json!({ "taskId": task_id, "status": field("status") });
                if let Some(summary) = text("summary").filter(|v| !v.is_empty()) {
                    payload["summary"] = json!(summary);
                }
                if let Some(usage) = message.get("usage").filter(|u| !u.is_null()) {
                    payload["usage"] = usage.clone();
                }
                let tool_use_id = text("tool_use_id");
                let status = text("status");
                self.offer_body("task.completed", payload, base_raw).await;
                if let Some(run) = self.subagent_run_for_task(tool_use_id.as_deref(), &task_id) {
                    let (settled, turn_status) = match status.as_deref() {
                        Some("completed") => ("completed", RuntimeTurnState::Completed),
                        Some("failed") => ("failed", RuntimeTurnState::Failed),
                        _ => ("stopped", RuntimeTurnState::Interrupted),
                    };
                    self.settle_subagent_run(&run, settled, turn_status).await;
                }
                return;
            }
            "files_persisted" => {
                let files: Vec<Value> = message
                    .get("files")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(|f| json!({ "filename": f.get("filename"), "fileId": f.get("file_id") }))
                    .collect();
                let mut payload = json!({ "files": files });
                if let Some(failed) = message.get("failed").and_then(Value::as_array) {
                    payload["failed"] = Value::Array(
                        failed.iter().map(|f| json!({ "filename": f.get("filename"), "error": f.get("error") })).collect(),
                    );
                }
                ("files.persisted", payload)
            }
            "background_tasks_changed" => {
                // REPLACE semantics: the payload is the whole live background set.
                let tasks = message.get("tasks").and_then(Value::as_array).cloned().unwrap_or_default();
                let added: Vec<&Value> = tasks
                    .iter()
                    .filter(|t| {
                        let id = t.get("task_id").and_then(Value::as_str).unwrap_or_default();
                        !self.known_background_task_ids.iter().any(|known| known == id)
                    })
                    .collect();
                let labels: Vec<String> = added
                    .iter()
                    .map(|t| {
                        let description = t.get("description").and_then(Value::as_str).unwrap_or_default().trim();
                        if description.is_empty() {
                            t.get("task_type").and_then(Value::as_str).unwrap_or_default().to_owned()
                        } else {
                            description.to_owned()
                        }
                    })
                    .collect();
                let notice = match labels.len() {
                    0 => None,
                    1 => Some(labels[0].clone()),
                    n => Some(truncate_chars(&format!("{n} tasks: {}", labels.join(", ")), 200).to_owned()),
                };
                self.known_background_task_ids =
                    tasks.iter().filter_map(|t| t.get("task_id").and_then(Value::as_str).map(str::to_owned)).collect();
                if let Some(notice) = notice {
                    self.emit_runtime_warning(&notice, Some(message.clone())).await;
                }
                return;
            }
            _ => {
                self.warn_unhandled_sdk_kind(
                    format!("system:{subtype}"),
                    format!("Unhandled Claude system message subtype '{subtype}'."),
                    message.clone(),
                )
                .await;
                return;
            }
        };
        self.offer_body(kind, payload, base_raw).await;
    }

    /// Publishes a payload built as JSON; one the contract rejects is reported, not dropped.
    async fn offer_body(&mut self, kind: &str, payload: Value, raw_event: RuntimeEventRaw) {
        match body(kind, payload) {
            Some(body) => {
                let event = self.event(body).turn(self.current_turn_id()).raw(raw_event);
                self.offer(event).await;
            }
            None => {
                let native = raw_event.message_type.clone().unwrap_or_else(|| kind.to_owned());
                self.warn_unhandled_sdk_kind(
                    format!("invalid:{native}"),
                    format!("Claude sent a '{native}' message this app could not read."),
                    raw_event.payload,
                )
                .await;
            }
        }
    }

    /// Synara `handleSdkTelemetryMessage` (ClaudeAdapter.ts:5112)
    async fn handle_sdk_telemetry_message(&mut self, message: &Value) {
        let kind = message_type(message).unwrap_or_default().to_owned();
        let base_raw = RuntimeEventRaw {
            source: RuntimeEventRawSource::ClaudeSdkMessage,
            method: Some(sdk_native_method(message)),
            message_type: Some(kind.clone()),
            payload: message.clone(),
        };
        let field = |key: &str| message.get(key).cloned().unwrap_or(Value::Null);
        let (event_kind, payload) = match kind.as_str() {
            "tool_progress" => {
                let mut payload = json!({
                    "toolUseId": field("tool_use_id"),
                    "toolName": field("tool_name"),
                    "elapsedSeconds": field("elapsed_time_seconds"),
                });
                if let Some(task_id) = message.get("task_id").and_then(Value::as_str) {
                    payload["summary"] = json!(format!("task:{task_id}"));
                }
                ("tool.progress", payload)
            }
            "tool_use_summary" => {
                let summary = message.get("summary").and_then(Value::as_str).unwrap_or_default().trim().to_owned();
                if summary.is_empty() {
                    return;
                }
                let mut payload = json!({ "summary": summary });
                if let Some(ids) = message.get("preceding_tool_use_ids").and_then(Value::as_array).filter(|ids| !ids.is_empty()) {
                    payload["precedingToolUseIds"] = Value::Array(ids.clone());
                }
                ("tool.summary", payload)
            }
            "auth_status" => {
                let mut payload = json!({ "isAuthenticating": field("isAuthenticating"), "output": field("output") });
                if let Some(error) = message.get("error").and_then(Value::as_str) {
                    payload["error"] = json!(error);
                }
                ("auth.status", payload)
            }
            "rate_limit_event" => ("account.rate-limits.updated", json!({ "rateLimits": message })),
            _ => return,
        };
        self.offer_body(event_kind, payload, base_raw).await;
    }

    /// Synara `handleSdkMessage` (ClaudeAdapter.ts:5188)
    async fn handle_sdk_message(&mut self, message: Value) {
        // Claude tags a subagent's own traffic with its Task tool's id: the run's scope projects
        // it, and its events go to the subagent's child thread.
        if let Some(tool_use_id) = self.recognized_subagent_parent_tool_use_id(&message) {
            // A settled task's tail (messages in flight when it stopped) is dropped, not projected
            // onto the settled child.
            if self.settled_subagent_tool_use_ids.contains_key(&tool_use_id) {
                return;
            }
            let mut run = self.take_subagent_run(&tool_use_id);
            self.swap_scope(&mut run.scope);
            self.ensure_synthetic_turn().await;
            match message_type(&message).unwrap_or_default() {
                "stream_event" => self.handle_stream_event(&message).await,
                "user" => self.handle_user_message(&message).await,
                "assistant" => self.handle_assistant_message(&message).await,
                _ => self.handle_sdk_telemetry_message(&message).await,
            }
            self.swap_scope(&mut run.scope);
            self.put_subagent_run(run);
            return;
        }

        self.ensure_thread_id(&message).await;
        match message_type(&message).unwrap_or_default() {
            "stream_event" => self.handle_stream_event(&message).await,
            "user" => self.handle_user_message(&message).await,
            "assistant" => self.handle_assistant_message(&message).await,
            "conversation_reset" => {
                self.result_usage_baseline = None;
                self.request_usage.reset();
                self.processed_token_turn_baseline = self.processed_token_total;
                self.processed_token_result_baseline = self.processed_token_total;
                self.update_resume_cursor(None);
            }
            "result" => self.handle_result_message(&message).await,
            "system" => self.handle_system_message(&message).await,
            "tool_progress" | "tool_use_summary" | "auth_status" | "rate_limit_event" => {
                self.handle_sdk_telemetry_message(&message).await;
            }
            other => {
                let other = other.to_owned();
                self.warn_unhandled_sdk_kind(
                    format!("type:{other}"),
                    format!("Unhandled Claude SDK message type '{other}'."),
                    message.clone(),
                )
                .await;
            }
        }
    }

    // ---- the CLI's requests ---------------------------------------------------------------

    async fn handle_control_request(&mut self, request_id: String, request: Value) {
        if message_subtype(&request) != Some("can_use_tool") {
            let subtype = message_subtype(&request).unwrap_or("unknown").to_owned();
            let error = protocol::control_response_error(&request_id, &format!("Unsupported control request: {subtype}"));
            let _ = self.write(&error).await;
            return;
        }
        match CanUseToolRequest::parse(&request) {
            Ok(parsed) => self.can_use_tool(request_id, parsed).await,
            Err(error) => {
                let response = protocol::control_response_error(&request_id, &error.to_string());
                let _ = self.write(&response).await;
            }
        }
    }

    /// Synara `canUseTool` (ClaudeAdapter.ts:5869)
    async fn can_use_tool(&mut self, cli_request_id: String, request: CanUseToolRequest) {
        if request.tool_name == "AskUserQuestion" {
            self.handle_ask_user_question(cli_request_id, request).await;
            return;
        }
        let tool_use_id = request.tool_use_id.clone();
        let tool_input = Value::Object(request.input.clone());

        if request.tool_name == "ExitPlanMode" {
            if let Some(plan) = extract_exit_plan_mode_plan(&tool_input) {
                self.emit_proposed_plan_completed(
                    &plan,
                    tool_use_id.as_deref(),
                    RuntimeEventRawSource::ClaudeSdkPermission,
                    "canUseTool/ExitPlanMode",
                    json!({ "toolName": request.tool_name, "input": tool_input }),
                )
                .await;
            }
            let deny = PermissionResult::Deny {
                message: "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn.".into(),
            };
            self.answer_permission(&cli_request_id, deny, tool_use_id.as_deref()).await;
            return;
        }

        let runtime_mode = self.session.runtime_mode;
        if runtime_mode == RuntimeMode::FullAccess || self.approvals_always_allowed_for_session {
            let allow = PermissionResult::Allow { updated_input: tool_input, updated_permissions: None };
            self.answer_permission(&cli_request_id, allow, tool_use_id.as_deref()).await;
            return;
        }

        // In Auto mode the CLI asks only for the classifier's "ask" outcome: it still reaches the user.
        let interaction_turn_id = self
            .current_turn_id()
            .or_else(|| request.agent_id.as_ref().and(self.last_turn_id.clone()));
        let request_id = new_id();
        let request_type = classify_request_type(&request.tool_name);
        let redacted = redact_sensitive_json_fields(&tool_input).to_string();
        let detail = summarize_tool_request(&request.tool_name, &request.input, Some(&redacted));
        let mut args = json!({
            "toolName": request.tool_name,
            "input": tool_input,
            "sessionApprovalAvailable": request.permission_suggestions.is_some(),
        });
        if let Some(id) = &tool_use_id {
            args["toolUseId"] = json!(id);
        }
        let opened = self
            .event(ProviderRuntimeEventBody::RequestOpened(RequestOpenedPayload {
                request_type,
                detail: Some(detail),
                args: Some(args),
            }))
            .turn(interaction_turn_id.clone())
            .request(&request_id)
            .provider_item(tool_use_id.as_deref())
            .raw(raw(
                RuntimeEventRawSource::ClaudeSdkPermission,
                "canUseTool/request",
                json!({ "toolName": request.tool_name, "input": tool_input }),
            ));
        self.offer(opened).await;

        let agent_id = request.agent_id.clone();
        self.pending_approvals.insert(
            request_id.clone(),
            PendingApproval {
                cli_request_id,
                request_type,
                suggestions: request.permission_suggestions,
                tool_input,
                turn_id: interaction_turn_id,
                provider_item_id: tool_use_id,
                agent_id: agent_id.clone(),
            },
        );
        if agent_id.is_some_and(|agent| self.terminal_task_ids.contains(&agent)) {
            self.settle_pending_approval(&request_id, ProviderApprovalDecision::Cancel).await;
        }
    }

    /// Synara `handleAskUserQuestion` (ClaudeAdapter.ts:5700)
    async fn handle_ask_user_question(&mut self, cli_request_id: String, request: CanUseToolRequest) {
        let tool_use_id = request.tool_use_id.clone();
        if self.stopped || request.agent_id.as_ref().is_some_and(|a| self.terminal_task_ids.contains(a)) {
            let deny = PermissionResult::Deny { message: "User cancelled tool execution.".into() };
            self.answer_permission(&cli_request_id, deny, tool_use_id.as_deref()).await;
            return;
        }
        let request_id = new_id();
        let interaction_turn_id = self
            .current_turn_id()
            .or_else(|| request.agent_id.as_ref().and(self.last_turn_id.clone()));
        let questions: Vec<UserInputQuestion> = request
            .input
            .get("questions")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .enumerate()
            .map(|(idx, q)| {
                let header = q.get("header").and_then(Value::as_str);
                UserInputQuestion {
                    id: header.map(str::to_owned).unwrap_or_else(|| format!("q-{idx}")),
                    header: header.map(str::to_owned).unwrap_or_else(|| format!("Question {}", idx + 1)),
                    question: q.get("question").and_then(Value::as_str).unwrap_or_default().to_owned(),
                    options: q
                        .get("options")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .map(|opt| UserInputQuestionOption {
                            label: opt.get("label").and_then(Value::as_str).unwrap_or_default().to_owned(),
                            description: opt.get("description").and_then(Value::as_str).unwrap_or_default().to_owned(),
                        })
                        .collect(),
                    multi_select: Some(q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false)),
                }
            })
            .collect();
        let tool_input = Value::Object(request.input.clone());
        let requested = self
            .event(ProviderRuntimeEventBody::UserInputRequested(UserInputRequestedPayload { questions: questions.clone() }))
            .turn(interaction_turn_id.clone())
            .request(&request_id)
            .provider_item(tool_use_id.as_deref())
            .raw(raw(
                RuntimeEventRawSource::ClaudeSdkPermission,
                "canUseTool/AskUserQuestion",
                json!({ "toolName": "AskUserQuestion", "input": tool_input }),
            ));
        self.offer(requested).await;
        self.pending_user_inputs.insert(
            request_id,
            PendingUserInput {
                cli_request_id,
                questions,
                tool_input,
                turn_id: interaction_turn_id,
                provider_item_id: tool_use_id,
                agent_id: request.agent_id,
            },
        );
    }

    /// The SDK aborts the callback's signal; Synara settles the request as cancelled.
    async fn handle_control_cancel_request(&mut self, cli_request_id: &str) {
        let approval = self
            .pending_approvals
            .iter()
            .find(|(_, p)| p.cli_request_id == cli_request_id)
            .map(|(id, _)| id.clone());
        if let Some(id) = approval {
            self.settle_pending_approval(&id, ProviderApprovalDecision::Cancel).await;
            return;
        }
        let input = self
            .pending_user_inputs
            .iter()
            .find(|(_, p)| p.cli_request_id == cli_request_id)
            .map(|(id, _)| id.clone());
        if let Some(id) = input {
            self.settle_pending_user_input(&id, ProviderUserInputAnswers::new(), true).await;
        }
    }

    // ---- the end of the stream and of the session ------------------------------------------

    fn stderr_message(&self) -> Option<String> {
        let tail = self.stderr_tail.lock().unwrap();
        let text: Vec<&str> = tail.iter().map(String::as_str).filter(|l| !l.trim().is_empty()).collect();
        (!text.is_empty()).then(|| text[text.len().saturating_sub(5)..].join("\n"))
    }

    /// Synara `handleStreamExit` (ClaudeAdapter.ts:5275): the CLI's output ended.
    async fn handle_stream_exit(&mut self, exit_code: Option<i32>) {
        if self.stopped {
            return;
        }
        let failed = exit_code != Some(0);
        let mut exit_error = None;
        if failed {
            let stderr = self.stderr_message();
            let message = match (exit_code, &stderr) {
                (Some(code), Some(stderr)) => format!("Claude Code process exited with code {code}: {stderr}"),
                (Some(code), None) => format!("Claude Code process exited with code {code}"),
                (None, Some(stderr)) => format!("Claude Code process was terminated: {stderr}"),
                (None, None) => "Claude Code process was terminated.".to_owned(),
            };
            let benign = exit_code.is_some_and(|code| CLAUDE_BENIGN_TERMINATION_EXIT_CODES.contains(&code));
            if self.has_pending_user_interrupt() {
                if self.turn_state.is_some() {
                    self.complete_turn(RuntimeTurnState::Interrupted, Some("Claude runtime interrupted.".into()), None).await;
                }
            } else if benign {
                if self.turn_state.is_some() {
                    self.complete_turn(RuntimeTurnState::Interrupted, Some(CLAUDE_BENIGN_TERMINATION_MESSAGE.into()), None)
                        .await;
                }
            } else {
                if message.to_lowercase().contains("no conversation found with session id") {
                    // A dead native conversation: drop its ids so the cursor carries no `resume`.
                    self.resume_session_id = None;
                    self.last_assistant_uuid = None;
                }
                self.emit_runtime_error(&message, stderr.map(Value::String)).await;
                self.complete_turn(RuntimeTurnState::Failed, Some(message.clone()), None).await;
                exit_error = Some(message);
            }
        } else if self.turn_state.is_some() {
            self.complete_turn(RuntimeTurnState::Interrupted, Some("Claude runtime stream ended.".into()), None).await;
        }
        self.stop_session_internal(true, exit_error).await;
    }

    /// Synara `performStopSessionInternal` (ClaudeAdapter.ts:5350). `exit_error` marks a crash:
    /// its `session.exited` says so (Synara reports every exit as graceful).
    async fn stop_session_internal(&mut self, emit_exit_event: bool, exit_error: Option<String>) {
        if self.stopped {
            return;
        }
        self.settle_pending_human_interactions(None).await;
        let runs: Vec<String> = self.subagent_runs.keys().cloned().collect();
        for tool_use_id in runs {
            let Some(mut run) = self.subagent_runs.remove(&tool_use_id) else { continue };
            if run.scope.turn_state.is_some() {
                self.swap_scope(&mut run.scope);
                self.complete_turn(RuntimeTurnState::Interrupted, Some("Session stopped.".into()), None).await;
                self.swap_scope(&mut run.scope);
            }
        }
        self.pending_subagent_stops.clear();
        if self.turn_state.is_some() {
            self.complete_turn(RuntimeTurnState::Interrupted, Some("Session stopped.".into()), None).await;
        }
        self.stopped = true;
        if let Some(mut stdin) = self.stdin.take() {
            let _ = stdin.shutdown().await;
        }
        (self.terminate)();
        for (_, pending) in self.pending_controls.drain() {
            if let PendingControl::Interrupt { reply, .. } = pending {
                let _ = reply.send(Err(anyhow!("the Claude session stopped")));
            }
        }

        // Retired background tasks cannot report their own end.
        for task_id in std::mem::take(&mut self.known_background_task_ids) {
            if let Some(body) = body("task.completed", json!({ "taskId": task_id, "status": "stopped" })) {
                let event = self.event(body);
                self.offer(event).await;
            }
        }

        self.session.status = ProviderSessionStatus::Closed;
        self.session.active_turn_id = None;
        self.session.updated_at = now_iso();
        if emit_exit_event {
            let payload = match exit_error {
                Some(message) => SessionExitedPayload {
                    reason: Some(message),
                    recoverable: Some(true),
                    exit_kind: Some(RuntimeSessionExitKind::Error),
                },
                None => SessionExitedPayload {
                    reason: Some("Session stopped".into()),
                    recoverable: None,
                    exit_kind: Some(RuntimeSessionExitKind::Graceful),
                },
            };
            let event = self.event(ProviderRuntimeEventBody::SessionExited(payload));
            self.offer(event).await;
        }
    }

    // ---- the handle's commands ------------------------------------------------------------

    /// Synara `applyInteractionModePermission` (ClaudeAdapter.ts:6559): applied on every turn
    /// so a sticky plan mode cannot leak, skipped only on the first turn when the CLI provably
    /// still runs in the mode it spawned in.
    async fn apply_interaction_mode_permission(&mut self, interaction_mode: Option<ProviderInteractionMode>) -> Result<ProviderInteractionMode> {
        let effective = interaction_mode.unwrap_or_default();
        let desired = if effective == ProviderInteractionMode::Plan {
            Some("plan")
        } else if self.base_permission_mode.is_some() || self.last_interaction_mode == Some(ProviderInteractionMode::Plan) {
            Some(self.base_permission_mode.unwrap_or("default"))
        } else {
            None
        };
        let skip = self.first_turn_spawn_mode_authoritative && desired == Some(self.spawn_permission_mode);
        if let Some(mode) = desired.filter(|_| !skip) {
            self.send_control(ControlRequest::SetPermissionMode { mode: mode.into() }, PendingControl::Fire { subtype: "set_permission_mode" })
                .await?;
        }
        Ok(effective)
    }

    /// Model, thinking, effort and fast-mode changes ride live controls (ClaudeAdapter.ts:6708-6818).
    async fn apply_model_selection(&mut self, selection: &ClaudeModelSelection) -> Result<()> {
        let api_model_id = resolve_api_model_id(selection);
        let changed = self.current_api_model_id.as_deref() != Some(api_model_id.as_str());
        if changed {
            self.send_control(ControlRequest::SetModel { model: Some(api_model_id.clone()) }, PendingControl::Fire { subtype: "set_model" })
                .await?;
            self.last_known_context_window = resolve_claude_api_model_id_context_window_max_tokens(Some(&api_model_id));
            self.current_auto_compact_window = auto_compact_window_tokens(Some(selection));
        }
        self.current_api_model_id = Some(api_model_id.clone());
        self.session.model = Some(selection.model.clone());
        self.update_resume_cursor(None);
        if changed {
            let mut config = Map::new();
            config.insert("autoCompactWindow".into(), json!(auto_compact_window_tokens(Some(selection))));
            config.insert("model".into(), json!(selection.model));
            config.insert("apiModelId".into(), json!(api_model_id));
            let event = self.event(ProviderRuntimeEventBody::SessionConfigured(SessionConfiguredPayload { config }));
            self.offer(event).await;
        }

        let options = selection.options.as_ref();
        let thinking = options.and_then(|o| o.thinking);
        let mut flags = Map::new();
        if thinking != self.current_always_thinking_enabled {
            flags.insert("alwaysThinkingEnabled".into(), json!(thinking));
            self.current_always_thinking_enabled = thinking;
        }
        let effort = options.and_then(|o| o.effort);
        let requested_effort = get_effective_claude_code_effort(effort);
        let requested_ultracode = effort == Some(ClaudeCodeEffort::Ultracode);
        let requested_fast_mode = options.and_then(|o| o.fast_mode) == Some(true);
        if requested_effort != self.current_effort && requested_effort != Some("max") && self.current_effort != Some("max") {
            flags.insert("effortLevel".into(), json!(requested_effort));
            self.current_effort = requested_effort;
        }
        if requested_ultracode != self.current_ultracode {
            flags.insert("ultracode".into(), if requested_ultracode { json!(true) } else { Value::Null });
            self.current_ultracode = requested_ultracode;
        }
        if requested_fast_mode != self.current_fast_mode {
            flags.insert("fastMode".into(), if requested_fast_mode { json!(true) } else { Value::Null });
            self.current_fast_mode = requested_fast_mode;
        }
        if !flags.is_empty() {
            self.send_control(ControlRequest::ApplyFlagSettings { settings: flags }, PendingControl::Fire { subtype: "apply_flag_settings" })
                .await?;
        }
        Ok(())
    }

    fn turn_start_result(&self, turn_id: TurnId) -> ProviderTurnStartResult {
        ProviderTurnStartResult { thread_id: self.session.thread_id.clone(), turn_id, resume_cursor: self.session.resume_cursor.clone() }
    }

    /// Synara `sendTurnCore` (ClaudeAdapter.ts:6584), without native compaction admission: a
    /// `/compact` goes to the CLI as the slash command it is.
    async fn send_turn(&mut self, input: ProviderSendTurnInput) -> Result<ProviderTurnStartResult> {
        if self.stopped {
            bail!("the Claude session has stopped");
        }
        // Read the attachments before the turn exists, so a missing file fails the send rather
        // than leaving a started turn behind.
        let message = build_user_message(&input, &self.attachments_dir, self.native_command_names.as_ref())?;

        if self.turn_state.is_some() {
            // Auto-close a stale synthetic turn so it does not block the user's.
            self.complete_turn(RuntimeTurnState::Completed, None, None).await;
        }
        if let Some(selection) = claude_selection(input.model_selection.as_ref()) {
            self.apply_model_selection(selection).await?;
        }
        let interaction_mode = self.apply_interaction_mode_permission(input.interaction_mode).await?;

        let turn_id = TurnId::new(new_id());
        self.processed_token_turn_baseline = self.processed_token_total;
        self.turn_state = Some(ClaudeTurnState::new(turn_id.clone(), interaction_mode, false));
        self.last_turn_id = Some(turn_id.clone());
        self.session.status = ProviderSessionStatus::Running;
        self.session.active_turn_id = Some(turn_id.clone());
        self.session.updated_at = now_iso();

        let model = self
            .current_api_model_id
            .as_deref()
            .map(|m| strip_claude_context_window_suffix(m).to_owned())
            .or_else(|| claude_selection(input.model_selection.as_ref()).map(|s| s.model.clone()));
        let started = self
            .event(ProviderRuntimeEventBody::TurnStarted(TurnStartedPayload { model, effort: None }))
            .turn(Some(turn_id.clone()));
        self.offer(started).await;

        if let Err(error) = self.write(&message).await {
            self.complete_turn(RuntimeTurnState::Failed, Some(format!("turn/start failed: {error}")), None).await;
            return Err(anyhow!("turn/start failed: {error}"));
        }
        // The first prompt is out: the spawn mode is no longer provably the CLI's mode.
        self.first_turn_spawn_mode_authoritative = false;
        Ok(self.turn_start_result(turn_id))
    }

    /// Synara `steerTurn` (ClaudeAdapter.ts:7072): the message joins the live turn.
    async fn steer_turn(&mut self, input: ProviderSendTurnInput) -> Result<ProviderTurnStartResult> {
        if is_claude_compaction_command(input.input.as_deref()) {
            return self.send_turn(input).await;
        }
        let live = self.turn_state.as_ref().filter(|t| !t.synthetic).map(|t| (t.turn_id.clone(), t.interaction_mode));
        let Some((turn_id, live_mode)) = live else {
            return self.send_turn(input).await;
        };
        let message = build_user_message(&input, &self.attachments_dir, self.native_command_names.as_ref())?;
        let effective = self.apply_interaction_mode_permission(input.interaction_mode).await?;
        if effective != live_mode {
            if let Some(turn) = self.turn_state.as_mut() {
                turn.interaction_mode = effective;
            }
        }
        self.write(&message).await.map_err(|error| anyhow!("turn/steer failed: {error}"))?;
        if let Some(text) = input.input.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
            let steered = self
                .event(ProviderRuntimeEventBody::TurnSteered(TurnSteeredPayload {
                    message: text.to_owned(),
                    target: Some(TurnSteeredTarget::Turn),
                }))
                .turn(Some(turn_id.clone()));
            self.offer(steered).await;
        }
        Ok(self.turn_start_result(turn_id))
    }

    /// Synara `interruptTurn` (ClaudeAdapter.ts:7133): answered when the CLI acknowledges.
    /// Synara `interruptTurn` with a provider thread id (ClaudeAdapter.ts:7140): a subagent's
    /// Task tool spawn is stopped, not the whole turn. Before `task_started` names its task there
    /// is nothing to stop yet, so the stop waits for it. An id that names no run, settled or live,
    /// and no open Task/Agent tool is an error: nothing would ever end the child's turn, so the
    /// caller settles it.
    async fn interrupt_subagent(&mut self, tool_use_id: &str) -> Result<()> {
        // Already settled: nothing to stop, and a queued stop could hit an unrelated later task.
        if self.settled_subagent_tool_use_ids.contains_key(tool_use_id) {
            return Ok(());
        }
        if !self.is_recognized_subagent_tool_use_id(tool_use_id) {
            return Err(anyhow!("No running subagent '{tool_use_id}' in this Claude session."));
        }
        match self.subagent_runs.get(tool_use_id).and_then(|run| run.task_id.clone()) {
            Some(task_id) => self.stop_subagent_task(&task_id).await,
            None => {
                self.pending_subagent_stops.insert(tool_use_id.to_owned());
            }
        }
        Ok(())
    }

    /// `Query.stopTask`
    async fn stop_subagent_task(&mut self, task_id: &str) {
        let request = ControlRequest::StopTask { task_id: task_id.to_owned() };
        if let Err(error) = self.send_control(request, PendingControl::Fire { subtype: "stop_task" }).await {
            self.emit_runtime_error(&format!("Failed to stop subagent task '{task_id}': {error}"), None).await;
        }
    }

    async fn interrupt_turn(&mut self, turn_id: Option<TurnId>, reply: oneshot::Sender<Result<()>>) {
        if turn_id.is_some() && turn_id != self.current_turn_id() {
            tracing::warn!("claude.stale_interrupt_ignored");
            let _ = reply.send(Ok(()));
            return;
        }
        if let Some(active) = turn_id.or_else(|| self.current_turn_id()) {
            self.interrupt_requested_turn_id = Some(active);
        }
        let request_id = new_id();
        match self.write(&protocol::control_request(&request_id, &ControlRequest::Interrupt)).await {
            Ok(()) => {
                let deadline = Instant::now() + CLAUDE_INTERRUPT_TIMEOUT;
                self.pending_controls.insert(request_id, PendingControl::Interrupt { reply, deadline });
            }
            Err(error) => {
                let _ = reply.send(Err(anyhow!("turn/interrupt failed: {error}")));
            }
        }
    }

    /// Synara `respondToRequest` (ClaudeAdapter.ts:7422)
    async fn respond_to_request(&mut self, request_id: &ApprovalRequestId, decision: ProviderApprovalDecision) -> Result<()> {
        if !self.settle_pending_approval(request_id.as_str(), decision).await {
            bail!("Unknown pending approval request: {request_id}");
        }
        Ok(())
    }

    /// Synara `respondToUserInput` (ClaudeAdapter.ts:7449)
    async fn respond_to_user_input(&mut self, request_id: &ApprovalRequestId, answers: ProviderUserInputAnswers) -> Result<()> {
        if !self.settle_pending_user_input(request_id.as_str(), answers, false).await {
            bail!("Unknown pending user-input request: {request_id}");
        }
        Ok(())
    }

    /// Not in Synara, which restarts a Claude session to change its runtime mode: the mode
    /// decides how `can_use_tool` is answered, and the CLI is moved to the matching permission
    /// mode. Bypass needs a CLI launched with `--allow-dangerously-skip-permissions`; when the
    /// CLI refuses, full access still holds because every `can_use_tool` is allowed.
    async fn set_runtime_mode(&mut self, mode: RuntimeMode) -> Result<()> {
        self.session.runtime_mode = mode;
        let permission_mode = claude_permission_mode(mode, None);
        self.base_permission_mode = permission_mode;
        if mode != RuntimeMode::FullAccess {
            self.approvals_always_allowed_for_session = false;
        }
        let in_plan = self.turn_state.as_ref().is_some_and(|t| t.interaction_mode == ProviderInteractionMode::Plan);
        if !in_plan {
            let mode = permission_mode.unwrap_or("default");
            self.send_control(ControlRequest::SetPermissionMode { mode: mode.into() }, PendingControl::Fire { subtype: "set_permission_mode" })
                .await?;
            self.first_turn_spawn_mode_authoritative = false;
        }
        if mode == RuntimeMode::FullAccess {
            let pending: Vec<String> = self.pending_approvals.keys().cloned().collect();
            for id in pending {
                self.settle_pending_approval(&id, ProviderApprovalDecision::Accept).await;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    use super::*;
    use crate::contracts::{model::ClaudeModelOptions, provider::ProviderSessionStartInput};
    use crate::provider::process::ScriptedSpawner;

    #[test]
    fn maps_runtime_modes_to_permission_modes() {
        assert_eq!(claude_permission_mode(RuntimeMode::Auto, None), Some("auto"));
        assert_eq!(claude_permission_mode(RuntimeMode::Auto, Some("plan")), Some("auto"));
        assert_eq!(claude_permission_mode(RuntimeMode::FullAccess, None), Some("bypassPermissions"));
        assert_eq!(claude_permission_mode(RuntimeMode::ApprovalRequired, None), None);
        assert_eq!(claude_permission_mode(RuntimeMode::ApprovalRequired, Some("acceptEdits")), Some("acceptEdits"));
        assert_eq!(claude_permission_mode(RuntimeMode::FullAccess, Some("bogus")), Some("bypassPermissions"));
    }

    #[test]
    fn full_access_launches_with_bypass() {
        let input = start_input(RuntimeMode::FullAccess);
        let plan = plan_claude_start(&input, "claude");
        let args = &plan.spec.args;
        let at = args.iter().position(|a| a == "--permission-mode").unwrap();
        assert_eq!(args[at + 1], "bypassPermissions");
        assert!(args.contains(&"--allow-dangerously-skip-permissions".to_owned()));
        let approval = plan_claude_start(&start_input(RuntimeMode::ApprovalRequired), "claude");
        assert!(!approval.spec.args.contains(&"--permission-mode".to_owned()));
        assert_eq!(approval.permission_mode.unwrap_or("default"), "default");
    }

    #[test]
    fn classifies_tools_as_synara_does() {
        assert_eq!(classify_tool_item_type("Bash"), CanonicalItemType::CommandExecution);
        assert_eq!(classify_tool_item_type("Edit"), CanonicalItemType::FileChange);
        assert_eq!(classify_tool_item_type("Write"), CanonicalItemType::FileChange);
        assert_eq!(classify_tool_item_type("TodoWrite"), CanonicalItemType::Plan);
        assert_eq!(classify_tool_item_type("Task"), CanonicalItemType::CollabAgentToolCall);
        assert_eq!(classify_tool_item_type("Agent"), CanonicalItemType::CollabAgentToolCall);
        assert_eq!(classify_tool_item_type("WebSearch"), CanonicalItemType::WebSearch);
        assert_eq!(classify_tool_item_type("mcp__server__lookup"), CanonicalItemType::McpToolCall);
        assert_eq!(classify_tool_item_type("Read"), CanonicalItemType::DynamicToolCall);

        assert_eq!(classify_request_type("Bash"), CanonicalRequestType::CommandExecutionApproval);
        assert_eq!(classify_request_type("Edit"), CanonicalRequestType::FileChangeApproval);
        assert_eq!(classify_request_type("Read"), CanonicalRequestType::FileReadApproval);
        assert_eq!(classify_request_type("Grep"), CanonicalRequestType::FileReadApproval);
        assert_eq!(classify_request_type("mcp__fs__write_file"), CanonicalRequestType::ToolApproval);
        assert_eq!(classify_request_type("WebFetch"), CanonicalRequestType::ToolApproval);
    }

    #[test]
    fn reads_resume_cursors() {
        let id = "f17ee499-d743-47c0-965c-a383d97a0b55";
        let state = read_claude_resume_state(Some(&json!({
            "threadId": "t", "resume": id, "resumeSessionAt": "u", "turnCount": 3,
            "processedTokenTotal": 10, "tokenAccountingVersion": 1,
        })))
        .unwrap();
        assert_eq!(state.resume.as_deref(), Some(id));
        assert_eq!(state.turn_count, Some(3));
        assert_eq!(state.processed_token_total, Some(10));
        let legacy = read_claude_resume_state(Some(&json!({ "sessionId": "not-a-uuid" }))).unwrap();
        assert_eq!(legacy.resume, None);
    }

    #[test]
    fn summarizes_and_remaps() {
        let mut input = Map::new();
        input.insert("command".into(), json!("  ls -la  "));
        assert_eq!(summarize_tool_request("Bash", &input, None), "Bash: ls -la");
        let questions = vec![UserInputQuestion {
            id: "Color".into(),
            header: "Color".into(),
            question: "Which color?".into(),
            options: vec![],
            multi_select: Some(false),
        }];
        let mut answers = BTreeMap::new();
        answers.insert("Color".to_owned(), ProviderUserInputAnswer::Many(vec!["red".into(), "blue".into()]));
        assert_eq!(remap_answers_to_claude_question_text(&questions, &answers), json!({ "Which color?": "red, blue" }).as_object().unwrap().clone());
        assert_eq!(base64_encode(b"hello"), "aGVsbG8=");
        assert!(is_claude_native_slash_command(Some("/compact now"), None));
        assert!(!is_claude_native_slash_command(Some("/Users/me/x"), None));
        assert_eq!(extract_proposed_plan_markdown("a <proposed_plan>\n# Plan\n</proposed_plan>").as_deref(), Some("# Plan"));
    }

    #[test]
    fn proposed_plan_survives_text_whose_lowercase_changes_length() {
        // "İ" lowercases to two chars and the Kelvin sign to a shorter one; offsets must still index the original.
        assert_eq!(
            extract_proposed_plan_markdown("İİ <proposed_plan>\nşu plan</proposed_plan>").as_deref(),
            Some("şu plan")
        );
        assert_eq!(extract_proposed_plan_markdown("\u{212A}\u{212A} <PROPOSED_PLAN>ok</Proposed_Plan>").as_deref(), Some("ok"));
    }

    fn start_input(runtime_mode: RuntimeMode) -> ProviderSessionStartInput {
        ProviderSessionStartInput {
            thread_id: ThreadId::new("thread-1"),
            provider: None,
            lifecycle_generation: None,
            provider_instance_id: None,
            cwd: Some("/tmp/probe".into()),
            model_selection: Some(ModelSelection::ClaudeAgent(ClaudeModelSelection {
                instance_id: None,
                model: "haiku".into(),
                options: Some(ClaudeModelOptions::default()),
                supports_auto_mode: None,
            })),
            resume_cursor: None,
            fork_source_resume_cursor: None,
            approval_policy: None,
            sandbox_mode: None,
            provider_options: None,
            auto_approve_synara_tools: None,
            runtime_mode,
        }
    }

    fn kind(event: &ProviderRuntimeEvent) -> String {
        serde_json::to_value(event).unwrap()["type"].as_str().unwrap().to_owned()
    }

    async fn next_until(
        events: &mut mpsc::Receiver<ProviderRuntimeEvent>,
        seen: &mut Vec<ProviderRuntimeEvent>,
        wanted: &str,
    ) -> ProviderRuntimeEvent {
        loop {
            let event = tokio::time::timeout(Duration::from_secs(5), events.recv())
                .await
                .unwrap_or_else(|_| panic!("timed out waiting for {wanted}"))
                .expect("event stream ended");
            seen.push(event.clone());
            if kind(&event) == wanted {
                return event;
            }
        }
    }

    async fn read_json_line(reader: &mut tokio::io::Lines<BufReader<tokio::io::DuplexStream>>) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(5), reader.next_line()).await.unwrap().unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    #[tokio::test]
    async fn replays_a_recorded_turn_with_an_approval() {
        let fixture = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/claude-turn-with-approval.jsonl")).unwrap();
        let lines: Vec<&str> = fixture.lines().collect();
        let approval_line = lines.iter().position(|l| l.contains("\"can_use_tool\"")).unwrap();

        let spawner = ScriptedSpawner::new();
        let adapter = ClaudeAdapter::new("/tmp/attachments");
        let (sink, mut events) = mpsc::channel(1024);
        let handle = adapter.start_session(start_input(RuntimeMode::ApprovalRequired), sink, Arc::new(spawner.clone()));
        let mut child = spawner.next().await;

        // The launch: stream-json both ways, permissions over stdio, the model, a new session id.
        let args = &child.spec.args;
        assert_eq!(child.spec.program, "claude");
        assert_eq!(&args[..5], ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]);
        for expected in ["--include-partial-messages", "--setting-sources=user,project,local"] {
            assert!(args.contains(&expected.to_owned()), "missing {expected} in {args:?}");
        }
        let pair = |flag: &str| args.iter().position(|a| a == flag).map(|i| args[i + 1].clone());
        assert_eq!(pair("--model").as_deref(), Some("haiku"));
        assert_eq!(pair("--permission-prompt-tool").as_deref(), Some("stdio"));
        assert_eq!(pair("--add-dir").as_deref(), Some("/tmp/probe"));
        assert_eq!(pair("--permission-mode"), None);
        let session_flag = args.iter().find(|a| a.starts_with("--session-id=")).unwrap();
        assert!(is_uuid(&session_flag["--session-id=".len()..]));
        assert_eq!(child.spec.cwd.as_deref(), Some(Path::new("/tmp/probe")));

        let mut stdin = BufReader::new(child.stdin).lines();
        let initialize = read_json_line(&mut stdin).await;
        assert_eq!(initialize["type"], "control_request");
        assert_eq!(initialize["request"]["subtype"], "initialize");

        let turn = handle
            .send_turn(ProviderSendTurnInput {
                thread_id: ThreadId::new("thread-1"),
                input: Some("Run the shell command `echo hi > probe.txt` with Bash, then reply with one word.".into()),
                attachments: None,
                skills: None,
                mentions: None,
                model_selection: None,
                interaction_mode: None,
            })
            .await
            .unwrap();
        let user = read_json_line(&mut stdin).await;
        assert_eq!(user["type"], "user");
        assert_eq!(user["parent_tool_use_id"], Value::Null);
        assert_eq!(user["message"]["content"][0]["type"], "text");
        assert!(user["message"]["content"][0]["text"].as_str().unwrap().starts_with("Run the shell command"));

        for line in &lines[..=approval_line] {
            child.stdout.write_all(line.as_bytes()).await.unwrap();
            child.stdout.write_all(b"\n").await.unwrap();
        }
        let mut seen = Vec::new();
        let opened = next_until(&mut events, &mut seen, "request.opened").await;
        assert_eq!(opened.turn_id.as_ref(), Some(&turn.turn_id));
        let ProviderRuntimeEventBody::RequestOpened(payload) = &opened.body else { unreachable!() };
        assert_eq!(payload.request_type, CanonicalRequestType::CommandExecutionApproval);
        assert_eq!(payload.detail.as_deref(), Some("Bash: echo hi > probe.txt"));
        let request_id = ApprovalRequestId::new(opened.request_id.as_ref().unwrap().as_str());

        handle.respond_to_request(request_id, ProviderApprovalDecision::Accept).await.unwrap();
        let response = read_json_line(&mut stdin).await;
        assert_eq!(
            response,
            json!({
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": "2150f4bb-2695-4107-89a1-ae3189518752",
                    "response": {
                        "behavior": "allow",
                        "updatedInput": { "command": "echo hi > probe.txt", "description": "Write \"hi\" to probe.txt" },
                        "toolUseID": "toolu_011XF8vFptD8bLpupaPJKjkX",
                    },
                },
            })
        );

        for line in &lines[approval_line + 1..] {
            child.stdout.write_all(line.as_bytes()).await.unwrap();
            child.stdout.write_all(b"\n").await.unwrap();
        }
        let completed = next_until(&mut events, &mut seen, "turn.completed").await;
        let ProviderRuntimeEventBody::TurnCompleted(payload) = &completed.body else { unreachable!() };
        assert_eq!(payload.state, RuntimeTurnState::Completed);
        assert_eq!(completed.turn_id.as_ref(), Some(&turn.turn_id));
        assert!(payload.total_cost_usd.is_some_and(|c| c > 0.0));

        let kinds: Vec<String> = seen.iter().map(kind).collect();
        let expected_order = [
            "session.started",
            "session.configured",
            "session.state.changed",
            "turn.started",
            "hook.started",
            "hook.completed",
            "thread.started",
            "session.configured",
            "account.rate-limits.updated",
            "thread.token-usage.updated",
            "item.started",
            "item.updated",
            "request.opened",
            "request.resolved",
            "item.completed",
            "content.delta",
            "item.completed",
            "thread.token-usage.updated",
            "turn.completed",
        ];
        let mut cursor = kinds.iter();
        for wanted in expected_order {
            assert!(cursor.any(|k| k == wanted), "{wanted} missing or out of order in {kinds:?}");
        }
        assert!(!kinds.iter().any(|k| k == "runtime.error" || k == "runtime.warning"), "{kinds:?}");

        // The assistant's text streams and its item completes with the whole message.
        let text: String = seen
            .iter()
            .filter_map(|e| match &e.body {
                ProviderRuntimeEventBody::ContentDelta(d) if d.stream_kind == RuntimeContentStreamKind::AssistantText => Some(d.delta.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "Done.");
        let assistant = seen.iter().find_map(|e| match &e.body {
            ProviderRuntimeEventBody::ItemCompleted(p) if p.item_type == CanonicalItemType::AssistantMessage => Some(p.clone()),
            _ => None,
        });
        assert_eq!(assistant.and_then(|p| p.detail).as_deref(), Some("Done."));

        // The command item completes from its tool result, with the result on its data.
        let command = seen
            .iter()
            .find_map(|e| match &e.body {
                ProviderRuntimeEventBody::ItemCompleted(p) if p.item_type == CanonicalItemType::CommandExecution => Some(p.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(command.status, Some(RuntimeItemStatus::Completed));
        assert_eq!(command.data.unwrap()["toolCallId"], "toolu_011XF8vFptD8bLpupaPJKjkX");

        // The resume cursor names the CLI's session and its last assistant message.
        let cursor_after = handle.send_turn(ProviderSendTurnInput {
            thread_id: ThreadId::new("thread-1"),
            input: Some("again".into()),
            attachments: None,
            skills: None,
            mentions: None,
            model_selection: None,
            interaction_mode: None,
        });
        let next_turn = cursor_after.await.unwrap();
        let cursor = next_turn.resume_cursor.unwrap();
        assert_eq!(cursor["resume"], "f17ee499-d743-47c0-965c-a383d97a0b55");
        assert_eq!(cursor["turnCount"], 1);
        assert!(cursor["resumeSessionAt"].is_string());
        let _second_user = read_json_line(&mut stdin).await;

        // Interrupt writes the control request and is answered by the CLI's acknowledgement.
        let interrupting = {
            let handle = handle.clone();
            tokio::spawn(async move { handle.interrupt_turn(None).await })
        };
        let interrupt = read_json_line(&mut stdin).await;
        assert_eq!(interrupt["request"]["subtype"], "interrupt");
        let ack = json!({
            "type": "control_response",
            "response": { "subtype": "success", "request_id": interrupt["request_id"], "response": {} },
        });
        child.stdout.write_all(format!("{ack}\n").as_bytes()).await.unwrap();
        interrupting.await.unwrap().unwrap();

        handle.stop().await.unwrap();
        let exited = next_until(&mut events, &mut seen, "session.exited").await;
        let ProviderRuntimeEventBody::SessionExited(payload) = &exited.body else { unreachable!() };
        assert_eq!(payload.exit_kind, Some(RuntimeSessionExitKind::Graceful));
        let _ = child.exit.send(Some(0));
        // The second turn was still open: stopping settles it as interrupted before the exit.
        let interrupted = seen.iter().rev().find(|e| kind(e) == "turn.completed").unwrap();
        let ProviderRuntimeEventBody::TurnCompleted(payload) = &interrupted.body else { unreachable!() };
        assert_eq!(payload.state, RuntimeTurnState::Interrupted);
        assert!(!handle.is_alive() || tokio::time::timeout(Duration::from_secs(1), async {
            while handle.is_alive() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .is_ok());
    }

    /// The subagent fixture, fed to a session up to the line `until` matches (all of it for "").
    async fn start_subagent_replay() -> (
        ProviderSessionHandle,
        mpsc::Receiver<ProviderRuntimeEvent>,
        tokio::io::Lines<BufReader<tokio::io::DuplexStream>>,
        tokio::io::DuplexStream,
        Vec<String>,
        TurnId,
    ) {
        let fixture = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/claude-turn-with-subagent.jsonl")).unwrap();
        let lines: Vec<String> = fixture.lines().map(str::to_owned).collect();
        let spawner = ScriptedSpawner::new();
        let adapter = ClaudeAdapter::new("/tmp/attachments");
        let (sink, events) = mpsc::channel(1024);
        let handle = adapter.start_session(start_input(RuntimeMode::ApprovalRequired), sink, Arc::new(spawner.clone()));
        let child = spawner.next().await;
        let mut stdin = BufReader::new(child.stdin).lines();
        let initialize = read_json_line(&mut stdin).await;
        // Synara's `forwardSubagentText`: the subagent's text comes, not only its tool calls.
        assert_eq!(initialize["request"]["forwardSubagentText"], true);
        let turn = handle
            .send_turn(ProviderSendTurnInput {
                thread_id: ThreadId::new("thread-1"),
                input: Some("Use the Agent tool".into()),
                attachments: None,
                skills: None,
                mentions: None,
                model_selection: None,
                interaction_mode: None,
            })
            .await
            .unwrap();
        let _user = read_json_line(&mut stdin).await;
        (handle, events, stdin, child.stdout, lines, turn.turn_id)
    }

    fn subagent_of(event: &ProviderRuntimeEvent) -> Option<(&str, &str)> {
        let refs = event.provider_refs.as_ref()?;
        Some((refs.provider_thread_id.as_deref()?, refs.provider_parent_thread_id.as_deref()?))
    }

    #[tokio::test]
    async fn a_subagents_traffic_runs_in_its_own_scope() {
        const AGENT: &str = "toolu_01UURA7ASnZqors4Psep6oL5";
        let (handle, mut events, mut stdin, mut stdout, lines, parent_turn) = start_subagent_replay().await;
        let approval_line = lines.iter().position(|l| l.contains("\"can_use_tool\"")).unwrap();
        for line in &lines[..=approval_line] {
            stdout.write_all(line.as_bytes()).await.unwrap();
            stdout.write_all(b"\n").await.unwrap();
        }
        let mut seen = Vec::new();
        // The subagent's Bash approval is asked on the parent's turn, as Synara asks it.
        let opened = next_until(&mut events, &mut seen, "request.opened").await;
        assert_eq!(opened.turn_id.as_ref(), Some(&parent_turn));
        assert_eq!(subagent_of(&opened), None);
        handle
            .respond_to_request(ApprovalRequestId::new(opened.request_id.as_ref().unwrap().as_str()), ProviderApprovalDecision::Accept)
            .await
            .unwrap();
        let _response = read_json_line(&mut stdin).await;
        for line in &lines[approval_line + 1..] {
            stdout.write_all(line.as_bytes()).await.unwrap();
            stdout.write_all(b"\n").await.unwrap();
        }
        loop {
            let event = next_until(&mut events, &mut seen, "turn.completed").await;
            if subagent_of(&event).is_none() {
                break;
            }
        }
        let kinds: Vec<String> = seen.iter().map(kind).collect();
        assert!(!kinds.iter().any(|k| k == "runtime.error" || k == "runtime.warning"), "{kinds:?}");

        // The Task tool is one collab item on the parent, naming its child.
        let collab = seen
            .iter()
            .find(|e| matches!(&e.body, ProviderRuntimeEventBody::ItemStarted(p) if p.item_type == CanonicalItemType::CollabAgentToolCall))
            .unwrap();
        assert_eq!(subagent_of(collab), None);
        assert_eq!(collab.turn_id.as_ref(), Some(&parent_turn));
        let collab_done = seen
            .iter()
            .find_map(|e| match &e.body {
                ProviderRuntimeEventBody::ItemCompleted(p) if p.item_type == CanonicalItemType::CollabAgentToolCall => Some(p.clone()),
                _ => None,
            })
            .unwrap();
        let data = collab_done.data.unwrap();
        assert_eq!(data["receiverThreadId"], AGENT);
        assert_eq!(data["agentType"], "general-purpose");
        assert_eq!(data["nickname"], "List files in current directory");

        // Everything the subagent did is tagged with it and has a turn of its own.
        let child: Vec<&ProviderRuntimeEvent> = seen.iter().filter(|e| subagent_of(e) == Some((AGENT, "thread-1"))).collect();
        let child_kinds: Vec<String> = child.iter().map(|e| kind(e)).collect();
        let child_turn = child.first().and_then(|e| e.turn_id.clone()).unwrap();
        assert_ne!(child_turn, parent_turn);
        assert_eq!(child_kinds.first().map(String::as_str), Some("turn.started"));
        assert!(child.iter().all(|e| e.turn_id.as_ref() == Some(&child_turn) || e.turn_id.is_none()), "{child_kinds:?}");
        let mut cursor = child_kinds.iter();
        for wanted in ["turn.started", "item.started", "item.completed", "session.state.changed", "turn.completed"] {
            assert!(cursor.any(|k| k == wanted), "{wanted} missing or out of order in {child_kinds:?}");
        }
        let bash = child
            .iter()
            .find_map(|e| match &e.body {
                ProviderRuntimeEventBody::ItemCompleted(p) if p.item_type == CanonicalItemType::CommandExecution => Some(p.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(bash.status, Some(RuntimeItemStatus::Completed));
        assert_eq!(bash.data.unwrap()["toolCallId"], "toolu_01QMhVgLsf7JiXxjLCkoJn8u");
        let text = child
            .iter()
            .find_map(|e| match &e.body {
                ProviderRuntimeEventBody::ItemCompleted(p) if p.item_type == CanonicalItemType::AssistantMessage => p.detail.clone(),
                _ => None,
            })
            .unwrap();
        assert!(text.contains("a.txt"), "{text}");
        let ProviderRuntimeEventBody::TurnCompleted(done) = &child.last().unwrap().body else { panic!("{child_kinds:?}") };
        assert_eq!(done.state, RuntimeTurnState::Completed);

        // Nothing of the subagent's reached the parent's turn: its text is the parent's own.
        let parent_text: String = seen
            .iter()
            .filter(|e| subagent_of(e).is_none())
            .filter_map(|e| match &e.body {
                ProviderRuntimeEventBody::ContentDelta(d) if d.stream_kind == RuntimeContentStreamKind::AssistantText => Some(d.delta.clone()),
                _ => None,
            })
            .collect();
        assert!(parent_text.starts_with("The directory contains five files"), "{parent_text}");
        handle.stop().await.unwrap();
    }

    #[tokio::test]
    async fn stopping_a_subagent_stops_its_task_once_it_has_one() {
        const AGENT: &str = "toolu_01UURA7ASnZqors4Psep6oL5";
        let (handle, mut events, mut stdin, mut stdout, lines, _) = start_subagent_replay().await;
        // The Task tool is open but its task is not started yet: the stop waits.
        let started = lines.iter().position(|l| l.contains("\"subtype\":\"task_started\"")).unwrap();
        for line in &lines[..started] {
            stdout.write_all(line.as_bytes()).await.unwrap();
            stdout.write_all(b"\n").await.unwrap();
        }
        let mut seen = Vec::new();
        next_until(&mut events, &mut seen, "item.started").await;
        handle.interrupt_subagent(None, AGENT.into()).await.unwrap();
        stdout.write_all(lines[started].as_bytes()).await.unwrap();
        stdout.write_all(b"\n").await.unwrap();
        let stop = read_json_line(&mut stdin).await;
        assert_eq!(stop["request"], json!({ "subtype": "stop_task", "task_id": "a38b7bd2324a4a267" }));
        // Once its task ends, a stop for it is not sent again.
        let notification = lines.iter().position(|l| l.contains("\"subtype\":\"task_notification\"")).unwrap();
        for line in &lines[started + 1..=notification] {
            if line.contains("\"can_use_tool\"") {
                continue;
            }
            stdout.write_all(line.as_bytes()).await.unwrap();
            stdout.write_all(b"\n").await.unwrap();
        }
        next_until(&mut events, &mut seen, "task.completed").await;
        handle.interrupt_subagent(None, AGENT.into()).await.unwrap();
        // An id that names no Task tool is refused, not parked for a task that never comes.
        let unknown = handle.interrupt_subagent(None, "toolu_unknown".into()).await;
        assert!(unknown.is_err(), "{unknown:?}");
        handle.stop().await.unwrap();
        let after = tokio::time::timeout(Duration::from_millis(200), stdin.next_line()).await;
        assert!(!matches!(after, Ok(Ok(Some(line))) if line.contains("stop_task")));
    }

    #[tokio::test]
    async fn a_failed_launch_reports_and_exits() {
        struct Failing;
        impl Spawner for Failing {
            fn spawn(&self, _: &SpawnSpec) -> std::io::Result<ChildProcess> {
                Err(std::io::Error::new(std::io::ErrorKind::NotFound, "no such file"))
            }
        }
        let (sink, mut events) = mpsc::channel(16);
        let handle = ClaudeAdapter::new("/tmp").start_session(start_input(RuntimeMode::FullAccess), sink, Arc::new(Failing));
        let mut seen = Vec::new();
        next_until(&mut events, &mut seen, "session.exited").await;
        assert_eq!(seen.iter().map(kind).collect::<Vec<_>>(), ["runtime.error", "session.exited"]);
        assert!(handle.send_turn(ProviderSendTurnInput {
            thread_id: ThreadId::new("thread-1"),
            input: Some("hi".into()),
            attachments: None,
            skills: None,
            mentions: None,
            model_selection: None,
            interaction_mode: None,
        })
        .await
        .is_err());
    }

    #[tokio::test]
    async fn ask_user_question_and_exit_plan_mode_use_their_own_channels() {
        let spawner = ScriptedSpawner::new();
        let (sink, mut events) = mpsc::channel(256);
        let handle = ClaudeAdapter::new("/tmp").start_session(start_input(RuntimeMode::FullAccess), sink, Arc::new(spawner.clone()));
        let mut child = spawner.next().await;
        let mut stdin = BufReader::new(child.stdin).lines();
        let _initialize = read_json_line(&mut stdin).await;
        handle
            .send_turn(ProviderSendTurnInput {
                thread_id: ThreadId::new("thread-1"),
                input: Some("plan it".into()),
                attachments: None,
                skills: None,
                mentions: None,
                model_selection: None,
                interaction_mode: Some(ProviderInteractionMode::Plan),
            })
            .await
            .unwrap();
        // Plan mode moves the CLI to its plan permission mode before the prompt.
        let mode = read_json_line(&mut stdin).await;
        assert_eq!(mode["request"], json!({ "subtype": "set_permission_mode", "mode": "plan" }));
        let user = read_json_line(&mut stdin).await;
        assert!(user["message"]["content"][0]["text"].as_str().unwrap().starts_with("Plan mode is active."));

        let ask = json!({
            "type": "control_request", "request_id": "ask-1",
            "request": { "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "toolu_q",
                "input": { "questions": [{ "header": "Color", "question": "Which color?", "options": [{ "label": "red", "description": "" }] }] } },
        });
        child.stdout.write_all(format!("{ask}\n").as_bytes()).await.unwrap();
        let mut seen = Vec::new();
        let requested = next_until(&mut events, &mut seen, "user-input.requested").await;
        let request_id = ApprovalRequestId::new(requested.request_id.unwrap().as_str());
        let mut answers = BTreeMap::new();
        answers.insert("Color".to_owned(), ProviderUserInputAnswer::Text("red".into()));
        handle.respond_to_user_input(request_id, answers).await.unwrap();
        let response = read_json_line(&mut stdin).await;
        assert_eq!(response["response"]["request_id"], "ask-1");
        assert_eq!(response["response"]["response"]["behavior"], "allow");
        assert_eq!(response["response"]["response"]["updatedInput"]["answers"], json!({ "Which color?": "red" }));

        let exit_plan = json!({
            "type": "control_request", "request_id": "plan-1",
            "request": { "subtype": "can_use_tool", "tool_name": "ExitPlanMode", "tool_use_id": "toolu_p", "input": { "plan": "# Do it" } },
        });
        child.stdout.write_all(format!("{exit_plan}\n").as_bytes()).await.unwrap();
        let proposed = next_until(&mut events, &mut seen, "turn.proposed.completed").await;
        let ProviderRuntimeEventBody::TurnProposedCompleted(payload) = &proposed.body else { unreachable!() };
        assert_eq!(payload.plan_markdown, "# Do it");
        let response = read_json_line(&mut stdin).await;
        assert_eq!(response["response"]["response"]["behavior"], "deny");

        // A cancelled request resolves as cancelled.
        let bash = json!({
            "type": "control_request", "request_id": "bash-1",
            "request": { "subtype": "can_use_tool", "tool_name": "Bash", "input": { "command": "ls" } },
        });
        // Inside a plan turn the CLI stays in plan mode; only the answers to `can_use_tool` change.
        handle.set_runtime_mode(RuntimeMode::ApprovalRequired).await.unwrap();
        child.stdout.write_all(format!("{bash}\n").as_bytes()).await.unwrap();
        next_until(&mut events, &mut seen, "request.opened").await;
        child.stdout.write_all(b"{\"type\":\"control_cancel_request\",\"request_id\":\"bash-1\"}\n").await.unwrap();
        let resolved = next_until(&mut events, &mut seen, "request.resolved").await;
        let ProviderRuntimeEventBody::RequestResolved(payload) = &resolved.body else { unreachable!() };
        assert_eq!(payload.decision.as_deref(), Some("cancel"));

        // The CLI ending its output mid-turn interrupts the turn and exits the session.
        let _ = child.exit.send(Some(0));
        drop(child.stdout);
        next_until(&mut events, &mut seen, "session.exited").await;
        let completed = seen.iter().rev().find(|e| kind(e) == "turn.completed").unwrap();
        let ProviderRuntimeEventBody::TurnCompleted(payload) = &completed.body else { unreachable!() };
        assert_eq!(payload.state, RuntimeTurnState::Interrupted);
    }

    /// One real turn against the installed `claude`, in the folder `CASCADE_CHAT_LIVE_DIR` names:
    /// `CASCADE_CHAT_LIVE_DIR=/some/tmp cargo test live_claude_turn -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn live_claude_turn() {
        let Ok(dir) = std::env::var("CASCADE_CHAT_LIVE_DIR") else {
            return;
        };
        let mut input = start_input(RuntimeMode::ApprovalRequired);
        input.cwd = Some(dir);
        let (sink, mut events) = mpsc::channel(4096);
        let handle = ClaudeAdapter::new("/tmp").start_session(input, sink, Arc::new(crate::provider::process::ProcessSpawner));
        handle
            .send_turn(ProviderSendTurnInput {
                thread_id: ThreadId::new("thread-1"),
                input: Some("Run the shell command `echo hi > live.txt` with Bash, then reply with one word.".into()),
                attachments: None,
                skills: None,
                mentions: None,
                model_selection: None,
                interaction_mode: None,
            })
            .await
            .unwrap();
        let mut seen = Vec::new();
        loop {
            let event = tokio::time::timeout(Duration::from_secs(120), events.recv()).await.unwrap().unwrap();
            seen.push(kind(&event));
            match &event.body {
                ProviderRuntimeEventBody::RequestOpened(_) => {
                    let id = ApprovalRequestId::new(event.request_id.unwrap().as_str());
                    handle.respond_to_request(id, ProviderApprovalDecision::Accept).await.unwrap();
                }
                ProviderRuntimeEventBody::TurnCompleted(payload) => {
                    println!("turn.completed: {}", serde_json::to_string(payload).unwrap());
                    break;
                }
                ProviderRuntimeEventBody::RuntimeError(payload) => println!("runtime.error: {}", payload.message),
                ProviderRuntimeEventBody::RuntimeWarning(payload) => println!("runtime.warning: {}", payload.message),
                _ => {}
            }
        }
        println!("events: {seen:?}");
        handle.stop().await.unwrap();
    }
}
