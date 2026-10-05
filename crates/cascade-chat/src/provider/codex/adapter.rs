//! Ported from Synara `apps/server/src/provider/Layers/CodexAdapter.ts`: the Codex
//! [`ProviderAdapter`], which runs a [`CodexAppServerManager`] per session and maps what it
//! reports ([`ProviderEvent`]) to canonical [`ProviderRuntimeEvent`]s (`mapToRuntimeEvents`).
//!
//! A session is one task: it starts the manager, then takes [`SessionCommand`]s and the
//! process's messages in turn. A second task maps the manager's events onto the sink, as
//! Synara's manager listener feeds the adapter's runtime queue.
//!
//! Left out, with Synara's names: generated images (`mapGeneratedImageEndEvent`), realtime
//! (`thread/realtime/*`, which fall through to `event.unmapped`), review, rollback, fork,
//! compaction, discovery (skills, plugins, model list, voice), the native event log, the turn
//! idle watchdog and the bounded callback ingress (the sink's own capacity bounds it here).

use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::{anyhow, Result};
use serde_json::{json, Map, Value};
use tokio::sync::mpsc;

use crate::contracts::{
    base::{now_iso, EventId, RuntimeItemId, RuntimeRequestId, RuntimeTaskId, ThreadId, TurnId},
    model::default_model_by_provider,
    orchestration::{
        AsyncUserInputQuestion, ChatAttachment, ModelSelection, ProviderApprovalDecision, ProviderKind,
        ProviderRequestKind,
    },
    provider::{ProviderEvent, ProviderEventKind, ProviderSendTurnInput, ProviderSessionStartInput},
    provider_runtime::*,
};
use crate::provider::{
    adapter::{
        EventSink, ProviderAdapter, ProviderAdapterCapabilities, ProviderConversationRollbackMode, ProviderModel,
        ProviderSessionHandle, ProviderSessionModelSwitchMode, SessionCommand,
        PROVIDER_ADAPTER_RUNTIME_EVENT_BUFFER_CAPACITY,
    },
    attachment_projection::{
        append_file_attachments_prompt_block, resolve_provider_attachment_path, ProjectedAttachments, StoredAttachment,
    },
    process::Spawner,
};

use super::app_server_manager::{
    is_non_fatal_codex_error_message, parse_codex_user_input_questions, CodexAppServerManager,
    CodexAppServerSendTurnInput, CodexAppServerStartSessionInput,
};
use super::turn_input::CodexImageInputItem;

const PROVIDER: ProviderKind = ProviderKind::Codex;

/// Synara `MAX_UNMAPPED_PROVIDER_DATA_JSON_CHARS` (unmappedProviderEvents.ts:5)
const MAX_UNMAPPED_PROVIDER_DATA_JSON_CHARS: usize = 16_000;
const MAX_UNMAPPED_PROVIDER_DETAIL_CHARS: usize = 500;
const MAX_UNMAPPED_PROVIDER_NATIVE_TYPE_CHARS: usize = 200;
const MAX_UNMAPPED_PROVIDER_PREVIEW_CHARS: usize = 2_000;
const MAX_UNMAPPED_TRACKED_BURSTS: usize = 128;
const REDACTED_VALUE: &str = "[REDACTED]";

/// Synara `DIAGNOSTIC_ONLY_CODEX_METHODS` (CodexAdapter.ts:1097): configuration and lifecycle
/// bookkeeping that belongs in native diagnostics, not the transcript.
const DIAGNOSTIC_ONLY_CODEX_METHODS: &[&str] =
    &["remoteControl/status/changed", "skills/changed", "session/threadOpenRequested"];

/// The Codex adapter. `attachments_dir` is where chat attachments are stored by id (Synara's
/// `serverConfig.attachmentsDir`); without one, a turn with attachments is refused.
#[derive(Clone, Debug, Default)]
pub struct CodexAdapter {
    attachments_dir: Option<PathBuf>,
}

impl CodexAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_attachments_dir(attachments_dir: impl Into<PathBuf>) -> Self {
        Self { attachments_dir: Some(attachments_dir.into()) }
    }
}

impl ProviderAdapter for CodexAdapter {
    fn provider(&self) -> ProviderKind {
        PROVIDER
    }

    /// Synara's Codex capabilities (CodexAdapter.ts:2647). Synara leaves `conversationRollback`
    /// unset, which its ProviderService treats as native (`thread/rollback`).
    fn capabilities(&self) -> ProviderAdapterCapabilities {
        ProviderAdapterCapabilities {
            session_model_switch: ProviderSessionModelSwitchMode::InSession,
            conversation_rollback: ProviderConversationRollbackMode::Native,
            supports_turn_steering: true,
            supports_native_slash_command_discovery: false,
            supports_live_turn_diff_patch: true,
        }
    }

    /// Synara asks a running app-server (`model/list`); without one, the default model is the
    /// one offered, and Codex accepts any slug the user's account has.
    fn models(&self) -> Vec<ProviderModel> {
        default_model_by_provider(PROVIDER)
            .map(|slug| ProviderModel { slug: slug.to_string(), name: slug.to_string(), is_default: true })
            .into_iter()
            .collect()
    }

    fn start_session(
        &self,
        input: ProviderSessionStartInput,
        events: EventSink,
        spawner: Arc<dyn Spawner>,
    ) -> ProviderSessionHandle {
        let (commands_tx, commands) = mpsc::unbounded_channel();
        let handle = ProviderSessionHandle::new(input.thread_id.clone(), commands_tx);
        let adapter = self.clone();
        tokio::spawn(async move { adapter.run_session(input, events, spawner, commands).await });
        handle
    }
}

impl CodexAdapter {
    async fn run_session(
        self,
        input: ProviderSessionStartInput,
        events: EventSink,
        spawner: Arc<dyn Spawner>,
        mut commands: mpsc::UnboundedReceiver<SessionCommand>,
    ) {
        let thread_id = input.thread_id.clone();
        if let Some(provider) = input.provider.as_ref().filter(|provider| provider.as_str() != PROVIDER.as_str()) {
            let message = format!("Expected provider '{}' but received '{provider}'.", PROVIDER.as_str());
            let _ = events.send(synthetic_event(&thread_id, None, runtime_error_body(message))).await;
            let body = ProviderRuntimeEventBody::SessionExited(SessionExitedPayload {
                exit_kind: Some(RuntimeSessionExitKind::Error),
                ..Default::default()
            });
            let _ = events.send(synthetic_event(&thread_id, None, body)).await;
            return;
        }

        let (manager_events, provider_events) = mpsc::channel(PROVIDER_ADAPTER_RUNTIME_EVENT_BUFFER_CAPACITY);
        let mapper = tokio::spawn(forward_runtime_events(provider_events, events.clone()));

        let manager_input = start_session_input(&input);
        let mut manager = CodexAppServerManager::new(&manager_input, manager_events);
        if manager.start_session(&manager_input, spawner).await.is_ok() {
            self.serve(&mut manager, &events, &mut commands).await;
        }
        drop(manager);
        let _ = mapper.await;
    }

    /// Takes commands and the process's messages in turn until the session ends.
    async fn serve(
        &self,
        manager: &mut CodexAppServerManager,
        events: &EventSink,
        commands: &mut mpsc::UnboundedReceiver<SessionCommand>,
    ) {
        loop {
            tokio::select! {
                incoming = manager.next_incoming() => {
                    if !manager.handle_incoming(incoming).await {
                        return;
                    }
                }
                command = commands.recv() => {
                    let Some(command) = command else {
                        manager.stop_session().await;
                        return;
                    };
                    if !self.handle_command(manager, events, command).await {
                        return;
                    }
                }
            }
        }
    }

    /// Handles one command. Returns false once the session has ended.
    async fn handle_command(
        &self,
        manager: &mut CodexAppServerManager,
        events: &EventSink,
        command: SessionCommand,
    ) -> bool {
        match command {
            SessionCommand::SendTurn { input, reply } => {
                let result = match self.prepare_codex_manager_turn_input(&input, "turn/start") {
                    Ok(turn) => manager.send_turn(turn).await.map_err(|cause| to_request_error("turn/start", cause)),
                    Err(error) => Err(error),
                };
                let _ = reply.send(result.map(|mut result| {
                    result.thread_id = input.thread_id.clone();
                    result
                }));
            }
            SessionCommand::SteerTurn { input, reply } => {
                let result = match self.prepare_codex_manager_turn_input(&input, "turn/steer") {
                    Ok(turn) => manager.steer_turn(turn).await.map_err(|cause| to_request_error("turn/steer", cause)),
                    Err(error) => Err(error),
                };
                // The `turn/steer` response carries no runtime event and the model only consumes
                // the input at its next boundary, so without this a landed steer looks dropped.
                if let (Ok(result), Some(message)) =
                    (&result, input.input.as_deref().map(str::trim).filter(|message| !message.is_empty()))
                {
                    let body = ProviderRuntimeEventBody::TurnSteered(TurnSteeredPayload {
                        message: message.to_string(),
                        target: Some(TurnSteeredTarget::Turn),
                    });
                    let _ = events.send(synthetic_event(&input.thread_id, Some(result.turn_id.clone()), body)).await;
                }
                let _ = reply.send(result.map(|mut result| {
                    result.thread_id = input.thread_id.clone();
                    result
                }));
            }
            SessionCommand::InterruptTurn { turn_id, reply } => {
                let result = manager.interrupt_turn(turn_id, None).await;
                let _ = reply.send(result.map_err(|cause| to_request_error("turn/interrupt", cause)));
            }
            SessionCommand::RespondToRequest { request_id, decision, reply } => {
                let result = manager.respond_to_request(&request_id, decision).await;
                let _ = reply.send(result.map_err(|cause| to_request_error("item/requestApproval/decision", cause)));
            }
            SessionCommand::RespondToUserInput { request_id, answers, reply } => {
                let result = manager.respond_to_user_input(&request_id, &answers).await;
                let _ = reply.send(result.map_err(|cause| to_request_error("item/tool/requestUserInput", cause)));
            }
            SessionCommand::SetRuntimeMode { mode, reply } => {
                let _ = reply.send(manager.set_runtime_mode(mode));
            }
            SessionCommand::Stop { reply } => {
                manager.stop_session().await;
                let _ = reply.send(Ok(()));
                return false;
            }
        }
        !manager.is_finished()
    }

    /// Synara `prepareCodexManagerTurnInput` (CodexAdapter.ts:2069): images go to Codex as local
    /// files, other files as a block of paths appended to the text.
    fn prepare_codex_manager_turn_input(
        &self,
        input: &ProviderSendTurnInput,
        method: &str,
    ) -> Result<CodexAppServerSendTurnInput> {
        let attachments = input.attachments.as_deref().unwrap_or_default();
        let mut native_codex_attachments = Vec::new();
        for attachment in attachments {
            let ChatAttachment::Image(image) = attachment else { continue };
            let path = self
                .attachments_dir
                .as_deref()
                .and_then(|dir| resolve_provider_attachment_path(dir, StoredAttachment::Image(image)))
                .ok_or_else(|| anyhow!("{method} failed: Invalid attachment id '{}'.", image.id))?;
            native_codex_attachments.push(CodexImageInputItem::LocalImage { path: path.to_string_lossy().into_owned() });
        }
        let composed_input = compose_codex_input_with_file_attachments(
            input.input.as_deref(),
            attachments,
            self.attachments_dir.as_deref(),
        );
        let overrides = codex_model_selection_overrides(input.model_selection.as_ref());
        Ok(CodexAppServerSendTurnInput {
            thread_id: Some(input.thread_id.clone()),
            input: composed_input,
            attachments: (!native_codex_attachments.is_empty()).then_some(native_codex_attachments),
            skills: input.skills.clone(),
            mentions: input.mentions.clone(),
            model: overrides.model,
            service_tier: overrides.service_tier,
            effort: overrides.effort,
            interaction_mode: input.interaction_mode,
        })
    }
}

/// Synara `composeCodexInputWithFileAttachments` (CodexAdapter.ts:183): every file attachment
/// as a block of paths after the text; images go to Codex natively.
fn compose_codex_input_with_file_attachments(
    text: Option<&str>,
    attachments: &[ChatAttachment],
    attachments_dir: Option<&Path>,
) -> Option<String> {
    let Some(attachments_dir) = attachments_dir else {
        return text.map(str::to_string);
    };
    append_file_attachments_prompt_block(text, Some(attachments), attachments_dir, ProjectedAttachments::AllFiles, None)
}

struct CodexModelSelectionOverrides {
    model: Option<String>,
    effort: Option<String>,
    service_tier: Option<String>,
}

/// Synara `codexModelSelectionOverrides` (CodexAdapter.ts:196), with `resolveCodexServiceTier`
/// (codexServiceTier.ts:3): Fast mode is the `fast` tier, its absence keeps Codex's own.
fn codex_model_selection_overrides(model_selection: Option<&ModelSelection>) -> CodexModelSelectionOverrides {
    let Some(ModelSelection::Codex(selection)) = model_selection else {
        return CodexModelSelectionOverrides { model: None, effort: None, service_tier: None };
    };
    let options = selection.options.as_ref();
    CodexModelSelectionOverrides {
        model: Some(selection.model.clone()),
        effort: options.and_then(|options| options.reasoning_effort.clone()),
        service_tier: options
            .and_then(|options| options.fast_mode)
            .map(|fast| if fast { "fast".to_string() } else { "default".to_string() }),
    }
}

fn start_session_input(input: &ProviderSessionStartInput) -> CodexAppServerStartSessionInput {
    let overrides = codex_model_selection_overrides(input.model_selection.as_ref());
    CodexAppServerStartSessionInput {
        thread_id: input.thread_id.clone(),
        provider_instance_id: input.provider_instance_id.clone(),
        lifecycle_generation: input.lifecycle_generation.clone(),
        cwd: input.cwd.clone(),
        model: overrides.model,
        service_tier: overrides.service_tier,
        resume_cursor: input.resume_cursor.clone(),
        fork_source_resume_cursor: input.fork_source_resume_cursor.clone(),
        provider_options: input.provider_options.clone(),
        runtime_mode: input.runtime_mode,
    }
}

/// Synara `toRequestError` / `toMessage` (CodexAdapter.ts:165-250): the first line of the cause.
fn to_request_error(method: &str, cause: anyhow::Error) -> anyhow::Error {
    let message = cause.to_string();
    let first_line = message.trim().lines().next().unwrap_or_default().trim().to_string();
    if first_line.is_empty() {
        anyhow!("{method} failed")
    } else {
        anyhow!(first_line)
    }
}

fn synthetic_event(thread_id: &ThreadId, turn_id: Option<TurnId>, body: ProviderRuntimeEventBody) -> ProviderRuntimeEvent {
    ProviderRuntimeEvent {
        event_id: EventId::new(uuid::Uuid::new_v4().to_string()),
        provider: PROVIDER.into(),
        provider_instance_id: None,
        thread_id: thread_id.clone(),
        created_at: now_iso(),
        turn_id,
        parent_turn_id: None,
        item_id: None,
        request_id: None,
        lifecycle_generation: None,
        provider_refs: None,
        raw: None,
        body,
    }
}

fn runtime_error_body(message: String) -> ProviderRuntimeEventBody {
    ProviderRuntimeEventBody::RuntimeError(RuntimeErrorPayload {
        message,
        class: Some(RuntimeErrorClass::ProviderError),
        detail: None,
    })
}

/// The manager listener of `makeCodexAdapter` (CodexAdapter.ts:2585): maps each event, drops
/// diagnostic-only and repeated burst `event.unmapped`, and forwards the rest in order.
async fn forward_runtime_events(mut provider_events: mpsc::Receiver<ProviderEvent>, sink: EventSink) {
    let mut should_surface_unmapped_event = UnmappedProviderEventGate::new(MAX_UNMAPPED_TRACKED_BURSTS);
    while let Some(event) = provider_events.recv().await {
        let runtime_events = assign_derived_provider_runtime_event_ids(map_to_runtime_events(&event, &event.thread_id));
        for runtime_event in runtime_events {
            let unmapped = matches!(runtime_event.body, ProviderRuntimeEventBody::EventUnmapped(_));
            if unmapped
                && (DIAGNOSTIC_ONLY_CODEX_METHODS.contains(&event.method.as_str())
                    || !should_surface_unmapped_event.check(&event))
            {
                continue;
            }
            if sink.send(runtime_event).await.is_err() {
                return;
            }
        }
    }
}

/// Synara `makeUnmappedProviderEventGate` (unmappedProviderEvents.ts:542): a burst-shaped
/// unmapped method (`...delta`, `...updated`) surfaces once per thread and generation.
struct UnmappedProviderEventGate {
    max_tracked_bursts: usize,
    surfaced: Vec<String>,
    lookup: HashSet<String>,
}

impl UnmappedProviderEventGate {
    fn new(max_tracked_bursts: usize) -> Self {
        Self { max_tracked_bursts: max_tracked_bursts.max(1), surfaced: Vec::new(), lookup: HashSet::new() }
    }

    fn check(&mut self, event: &ProviderEvent) -> bool {
        let method = event.method.to_lowercase();
        let burst = ["delta", "progress", "partial", "chunk", "update", "updated"]
            .iter()
            .any(|suffix| method.ends_with(suffix));
        if !burst {
            return true;
        }
        let generation: String = event.lifecycle_generation.as_deref().unwrap_or("session").chars().take(200).collect();
        let key = format!("{}\u{0}{generation}\u{0}{}", event.thread_id, truncate_text(&event.method, MAX_UNMAPPED_PROVIDER_NATIVE_TYPE_CHARS));
        if self.lookup.contains(&key) {
            return false;
        }
        if self.surfaced.len() >= self.max_tracked_bursts {
            let oldest = self.surfaced.remove(0);
            self.lookup.remove(&oldest);
        }
        self.surfaced.push(key.clone());
        self.lookup.insert(key);
        true
    }
}

/// Synara `assignDerivedProviderRuntimeEventIds` (providerRuntimeEventIdentity.ts:8): events
/// mapped from one native event share its id, so each gets `<id>:<type>:<ordinal>`.
fn assign_derived_provider_runtime_event_ids(mut events: Vec<ProviderRuntimeEvent>) -> Vec<ProviderRuntimeEvent> {
    if events.len() <= 1 {
        return events;
    }
    let mut occurrences = std::collections::HashMap::<String, usize>::new();
    for event in &events {
        *occurrences.entry(event.event_id.to_string()).or_default() += 1;
    }
    let mut ordinals = std::collections::HashMap::<String, usize>::new();
    for event in &mut events {
        let id = event.event_id.to_string();
        if occurrences[&id] <= 1 {
            continue;
        }
        let ordinal = ordinals.entry(id.clone()).or_default();
        let kind = serde_json::to_value(&event.body)
            .ok()
            .and_then(|body| body.get("type").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        event.event_id = EventId::new(format!("{id}:{kind}:{ordinal}"));
        *ordinal += 1;
    }
    events
}

fn as_object(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value?.as_object()
}

fn get<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    value?.get(key)
}

fn as_str<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a str> {
    get(value, key)?.as_str()
}

fn as_trimmed<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a str> {
    as_str(value, key).map(str::trim).filter(|text| !text.is_empty())
}

fn as_number(value: Option<&Value>, key: &str) -> Option<f64> {
    get(value, key)?.as_f64().filter(|number| number.is_finite())
}

fn as_count(value: Option<&Value>, key: &str) -> Option<u64> {
    as_number(value, key).filter(|number| *number >= 0.0).map(|number| number as u64)
}

/// Synara `normalizeCodexTokenUsage` (CodexAdapter.ts:288)
pub fn normalize_codex_token_usage(value: Option<&Value>) -> Option<ThreadTokenUsageSnapshot> {
    let usage = value.filter(|value| value.is_object());
    let total = get(usage, "total_token_usage").or_else(|| get(usage, "total")).filter(|value| value.is_object());
    let last = get(usage, "last_token_usage").or_else(|| get(usage, "last")).filter(|value| value.is_object());
    let pick = |source: Option<&Value>, snake: &str, camel: &str| as_count(source, snake).or_else(|| as_count(source, camel));

    let total_processed_tokens = pick(total, "total_tokens", "totalTokens");
    let used_tokens = pick(last, "total_tokens", "totalTokens").or(total_processed_tokens)?;
    if used_tokens == 0 {
        return None;
    }
    let max_tokens = pick(usage, "model_context_window", "modelContextWindow");
    let input_tokens = pick(last, "input_tokens", "inputTokens");
    let cached_input_tokens = pick(last, "cached_input_tokens", "cachedInputTokens");
    let output_tokens = pick(last, "output_tokens", "outputTokens");
    let reasoning_output_tokens = pick(last, "reasoning_output_tokens", "reasoningOutputTokens");
    let total_input = pick(total, "input_tokens", "inputTokens");
    let total_output = pick(total, "output_tokens", "outputTokens");
    let total_cached = pick(total, "cached_input_tokens", "cachedInputTokens");
    let total_writes = pick(total, "cache_write_input_tokens", "cacheWriteInputTokens");
    Some(ThreadTokenUsageSnapshot {
        cumulative_usage: match (total_input, total_output) {
            (Some(input_tokens), Some(output_tokens)) => Some(ThreadTokenCumulativeUsage {
                input_tokens,
                output_tokens,
                cached_input_tokens: total_cached,
                cache_creation_input_tokens: total_writes,
            }),
            _ => None,
        },
        used_tokens,
        used_percent: None,
        total_processed_tokens: total_processed_tokens.filter(|total| *total > used_tokens),
        token_accounting_version: None,
        max_tokens,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_output_tokens,
        last_used_tokens: Some(used_tokens),
        last_input_tokens: input_tokens,
        last_cached_input_tokens: cached_input_tokens,
        last_output_tokens: output_tokens,
        last_reasoning_output_tokens: reasoning_output_tokens,
        tool_uses: None,
        duration_ms: None,
        compacts_automatically: Some(true),
    })
}

/// Synara `toTurnStatus` (CodexAdapter.ts:354)
fn to_turn_status(value: Option<&str>) -> RuntimeTurnState {
    match value {
        Some("failed") => RuntimeTurnState::Failed,
        Some("cancelled") => RuntimeTurnState::Cancelled,
        Some("interrupted") => RuntimeTurnState::Interrupted,
        _ => RuntimeTurnState::Completed,
    }
}

/// Synara `normalizeItemType` (CodexAdapter.ts:366): `commandExecution` → `command execution`.
fn normalize_item_type(raw: Option<&str>) -> String {
    let Some(raw) = raw else { return "item".to_string() };
    let mut spaced = String::with_capacity(raw.len() + 8);
    let mut previous: Option<char> = None;
    for ch in raw.chars() {
        if ch.is_ascii_uppercase() && previous.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit()) {
            spaced.push(' ');
        }
        spaced.push(if matches!(ch, '.' | '_' | '/' | '-') { ' ' } else { ch });
        previous = Some(ch);
    }
    spaced.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Synara `toCanonicalItemType` (CodexAdapter.ts:377). Synara's generated-image check
/// (`isCodexGeneratedImageItemType`) is reduced to the `imageGeneration` item type.
pub fn to_canonical_item_type(raw: Option<&str>) -> CanonicalItemType {
    let kind = normalize_item_type(raw);
    if kind == "image generation" {
        return CanonicalItemType::ImageGeneration;
    }
    let has = |needle: &str| kind.contains(needle);
    if has("user") {
        CanonicalItemType::UserMessage
    } else if has("agent message") || has("assistant") {
        CanonicalItemType::AssistantMessage
    } else if has("reasoning") || has("thought") {
        CanonicalItemType::Reasoning
    } else if has("plan") || has("todo") {
        CanonicalItemType::Plan
    } else if has("command") {
        CanonicalItemType::CommandExecution
    } else if has("file change") || has("patch") || has("edit") {
        CanonicalItemType::FileChange
    } else if has("mcp") {
        CanonicalItemType::McpToolCall
    } else if has("dynamic tool") {
        CanonicalItemType::DynamicToolCall
    } else if has("collab") {
        CanonicalItemType::CollabAgentToolCall
    } else if has("web search") {
        CanonicalItemType::WebSearch
    } else if has("image") {
        CanonicalItemType::ImageView
    } else if has("review entered") || has("entered review") {
        CanonicalItemType::ReviewEntered
    } else if has("review exited") || has("exited review") {
        CanonicalItemType::ReviewExited
    } else if has("compact") {
        CanonicalItemType::ContextCompaction
    } else if has("error") {
        CanonicalItemType::Error
    } else {
        CanonicalItemType::Unknown
    }
}

/// Synara `toolItemTitle` (CodexAdapter.ts:399)
fn tool_item_title(item: Option<&Value>) -> Option<String> {
    let app_context = get(item, "appContext");
    let action = as_trimmed(app_context, "actionName")
        .or_else(|| as_trimmed(item, "title"))
        .or_else(|| as_trimmed(item, "tool"))
        .or_else(|| as_trimmed(item, "name"))?;
    match as_trimmed(app_context, "appName") {
        Some(app_name) if !action.to_lowercase().contains(&app_name.to_lowercase()) => {
            Some(format!("{action} in {app_name}"))
        }
        _ => Some(action.to_string()),
    }
}

/// Synara `itemTitle` (CodexAdapter.ts:416)
fn item_title(item_type: CanonicalItemType, item: Option<&Value>) -> Option<String> {
    let title = match item_type {
        CanonicalItemType::AssistantMessage => "Assistant message",
        CanonicalItemType::UserMessage => "User message",
        CanonicalItemType::Reasoning => "Reasoning",
        CanonicalItemType::Plan => "Plan",
        CanonicalItemType::CommandExecution => "Ran command",
        CanonicalItemType::FileChange => "File change",
        CanonicalItemType::McpToolCall => return Some(tool_item_title(item).unwrap_or_else(|| "MCP tool call".into())),
        CanonicalItemType::DynamicToolCall => return Some(tool_item_title(item).unwrap_or_else(|| "Tool call".into())),
        CanonicalItemType::WebSearch => "Web search",
        CanonicalItemType::ImageGeneration => "Generated image",
        CanonicalItemType::ImageView => "Image view",
        CanonicalItemType::Error => "Error",
        _ => return None,
    };
    Some(title.to_string())
}

/// Synara `joinedTextParts` (CodexAdapter.ts:450)
fn joined_text_parts(value: Option<&Value>) -> Option<String> {
    let parts: Vec<&str> = value?
        .as_array()?
        .iter()
        .filter_map(|entry| entry.as_str().or_else(|| as_str(Some(entry), "text")).or_else(|| as_str(Some(entry), "summary")))
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect();
    (!parts.is_empty()).then(|| parts.join("\n\n"))
}

/// Synara `reasoningSummaryDetail` (CodexAdapter.ts:464)
fn reasoning_summary_detail(item: &Value) -> Option<String> {
    as_str(Some(item), "summary")
        .map(str::trim)
        .filter(|summary| !summary.is_empty())
        .map(str::to_string)
        .or_else(|| joined_text_parts(item.get("summary")))
}

/// Synara `itemDetail` (CodexAdapter.ts:468)
fn item_detail(item: &Value, payload: Option<&Value>) -> Option<String> {
    let item = Some(item);
    let nested_result = get(item, "result");
    let candidates = [
        as_str(item, "command").map(str::to_string),
        as_str(item, "title").map(str::to_string),
        as_str(item, "summary").map(str::to_string),
        joined_text_parts(get(item, "summary")),
        joined_text_parts(get(item, "content")),
        as_str(item, "review").map(str::to_string),
        as_str(item, "text").map(str::to_string),
        as_str(item, "saved_path").map(str::to_string),
        as_str(item, "savedPath").map(str::to_string),
        as_str(item, "path").map(str::to_string),
        as_str(item, "file_path").map(str::to_string),
        as_str(item, "prompt").map(str::to_string),
        as_str(nested_result, "command").map(str::to_string),
        as_str(payload, "command").map(str::to_string),
        as_str(payload, "message").map(str::to_string),
        as_str(payload, "prompt").map(str::to_string),
    ];
    candidates.into_iter().flatten().map(|candidate| candidate.trim().to_string()).find(|candidate| !candidate.is_empty())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ItemLifecycle {
    Started,
    Updated,
    Completed,
}

/// Synara `itemStatus` (CodexAdapter.ts:500)
fn item_status(lifecycle: ItemLifecycle, raw_status: Option<&str>) -> Option<RuntimeItemStatus> {
    match lifecycle {
        ItemLifecycle::Started => Some(RuntimeItemStatus::InProgress),
        ItemLifecycle::Updated => None,
        ItemLifecycle::Completed => Some(match raw_status {
            Some("failed") => RuntimeItemStatus::Failed,
            Some("declined") => RuntimeItemStatus::Declined,
            _ => RuntimeItemStatus::Completed,
        }),
    }
}

/// Synara `toRequestTypeFromMethod` (CodexAdapter.ts:513)
pub fn to_request_type_from_method(method: &str) -> CanonicalRequestType {
    match method {
        "item/commandExecution/requestApproval" => CanonicalRequestType::CommandExecutionApproval,
        "item/fileRead/requestApproval" => CanonicalRequestType::FileReadApproval,
        "item/fileChange/requestApproval" => CanonicalRequestType::FileChangeApproval,
        "item/permissions/requestApproval" => CanonicalRequestType::PermissionsApproval,
        "mcpServer/elicitation/request" => CanonicalRequestType::ToolApproval,
        "applyPatchApproval" => CanonicalRequestType::ApplyPatchApproval,
        "execCommandApproval" => CanonicalRequestType::ExecCommandApproval,
        "item/tool/requestUserInput" => CanonicalRequestType::ToolUserInput,
        "item/tool/call" => CanonicalRequestType::DynamicToolCall,
        "account/chatgptAuthTokens/refresh" => CanonicalRequestType::AuthTokensRefresh,
        _ => CanonicalRequestType::Unknown,
    }
}

/// Synara `toRequestTypeFromKind` (CodexAdapter.ts:540)
fn to_request_type_from_kind(kind: Option<&str>) -> CanonicalRequestType {
    match kind {
        Some("command") => CanonicalRequestType::CommandExecutionApproval,
        Some("file-read") => CanonicalRequestType::FileReadApproval,
        Some("file-change") => CanonicalRequestType::FileChangeApproval,
        Some("permissions") => CanonicalRequestType::PermissionsApproval,
        Some("tool") => CanonicalRequestType::ToolApproval,
        _ => CanonicalRequestType::Unknown,
    }
}

fn request_kind_str(kind: ProviderRequestKind) -> &'static str {
    match kind {
        ProviderRequestKind::Command => "command",
        ProviderRequestKind::FileRead => "file-read",
        ProviderRequestKind::FileChange => "file-change",
        ProviderRequestKind::Permissions => "permissions",
        ProviderRequestKind::Tool => "tool",
    }
}

/// Synara `toRequestTypeFromResolvedPayload` (CodexAdapter.ts:557)
fn to_request_type_from_resolved_payload(payload: Option<&Value>) -> CanonicalRequestType {
    let request = get(payload, "request");
    if let Some(method) = as_str(request, "method").or_else(|| as_str(payload, "method")) {
        return to_request_type_from_method(method);
    }
    if let Some(kind) = as_str(request, "kind").or_else(|| as_str(payload, "requestKind")) {
        return to_request_type_from_kind(Some(kind));
    }
    CanonicalRequestType::Unknown
}

/// Synara `toCanonicalUserInputAnswers` (CodexAdapter.ts:572): Codex's `{ answers: [...] }` per
/// question as a string, or a list when there are several.
fn to_canonical_user_input_answers(answers: Option<&Value>) -> Map<String, Value> {
    let mut result = Map::new();
    let Some(answers) = answers.and_then(Value::as_object) else { return result };
    for (question_id, value) in answers {
        let list = match value {
            Value::String(text) => {
                result.insert(question_id.clone(), json!(text));
                continue;
            }
            Value::Array(values) => values,
            other => match other.get("answers").and_then(Value::as_array) {
                Some(values) => values,
                None => continue,
            },
        };
        let strings: Vec<&str> = list.iter().filter_map(Value::as_str).collect();
        result.insert(question_id.clone(), if strings.len() == 1 { json!(strings[0]) } else { json!(strings) });
    }
    result
}

/// Synara `toThreadState` (CodexAdapter.ts:604)
fn to_thread_state(value: Option<&str>) -> RuntimeThreadState {
    match value {
        Some("idle") | Some("notLoaded") => RuntimeThreadState::Idle,
        Some("archived") => RuntimeThreadState::Archived,
        Some("closed") => RuntimeThreadState::Closed,
        Some("compacted") => RuntimeThreadState::Compacted,
        Some("error") | Some("failed") | Some("systemError") => RuntimeThreadState::Error,
        _ => RuntimeThreadState::Active,
    }
}

/// Synara `contentStreamKindFromMethod` (CodexAdapter.ts:624)
pub fn content_stream_kind_from_method(method: &str) -> RuntimeContentStreamKind {
    match method {
        "item/reasoning/textDelta" => RuntimeContentStreamKind::ReasoningText,
        "item/reasoning/summaryTextDelta" => RuntimeContentStreamKind::ReasoningSummaryText,
        "item/commandExecution/outputDelta" => RuntimeContentStreamKind::CommandOutput,
        "item/fileChange/outputDelta" => RuntimeContentStreamKind::FileChangeOutput,
        _ => RuntimeContentStreamKind::AssistantText,
    }
}

/// Synara `normalizeRuntimeTaskStatus` (runtimeTaskList.ts:3)
fn normalize_runtime_task_status(value: Option<&str>) -> RuntimeTaskStatus {
    match value {
        Some("completed") => RuntimeTaskStatus::Completed,
        Some("in_progress") | Some("inProgress") => RuntimeTaskStatus::InProgress,
        _ => RuntimeTaskStatus::Pending,
    }
}

/// Synara `extractProposedPlanMarkdown` (planMode.ts:36)
fn extract_proposed_plan_markdown(text: Option<&str>) -> Option<String> {
    let text = text?;
    let lower = text.to_ascii_lowercase(); // length-preserving: offsets index `text`
    let open = lower.find("<proposed_plan>")?;
    let body_start = open + "<proposed_plan>".len();
    let close = lower[body_start..].find("</proposed_plan>")? + body_start;
    Some(text[body_start..close].trim().to_string()).filter(|plan| !plan.is_empty())
}

/// The base fields of a runtime event before its type and payload.
struct RuntimeEventBase {
    event: ProviderRuntimeEvent,
}

impl RuntimeEventBase {
    fn with(mut self, body: ProviderRuntimeEventBody) -> ProviderRuntimeEvent {
        self.event.body = body;
        self.event
    }

    /// Synara `withMinimalRawPayload` (CodexAdapter.ts:896): deltas keep no raw payload.
    fn minimal_raw(mut self) -> Self {
        if let Some(raw) = self.event.raw.as_mut() {
            raw.payload = json!({});
        }
        self
    }

    /// Synara `withSanitizedHookRaw` / the raw of `mapUnmappedCodexEvent`.
    fn sanitized_raw(mut self, method: String) -> Self {
        if let Some(raw) = self.event.raw.as_mut() {
            raw.method = Some(method);
            raw.payload = json!({ "synaraSanitized": true });
        }
        self
    }
}

/// Synara `eventRawSource` (CodexAdapter.ts:837)
fn event_raw_source(event: &ProviderEvent) -> RuntimeEventRawSource {
    if event.kind == ProviderEventKind::Request {
        RuntimeEventRawSource::CodexAppServerRequest
    } else {
        RuntimeEventRawSource::CodexAppServerNotification
    }
}

/// Synara `providerRefsFromEvent` (CodexAdapter.ts:841)
fn provider_refs_from_event(event: &ProviderEvent) -> Option<ProviderRefs> {
    let refs = ProviderRefs {
        provider_thread_id: event.provider_thread_id.clone(),
        provider_parent_thread_id: event.provider_parent_thread_id.clone(),
        provider_turn_id: event.turn_id.as_ref().map(ToString::to_string),
        parent_provider_turn_id: event.parent_turn_id.as_ref().map(ToString::to_string),
        provider_item_id: event.item_id.clone(),
        provider_request_id: event.request_id.as_ref().map(ToString::to_string),
    };
    (refs != ProviderRefs::default()).then_some(refs)
}

/// Synara `runtimeEventBase` (CodexAdapter.ts:855)
fn runtime_event_base(event: &ProviderEvent, canonical_thread_id: &ThreadId) -> RuntimeEventBase {
    RuntimeEventBase {
        event: ProviderRuntimeEvent {
            event_id: event.id.clone(),
            provider: event.provider.clone(),
            provider_instance_id: event.provider_instance_id.clone(),
            thread_id: canonical_thread_id.clone(),
            created_at: event.created_at.clone(),
            turn_id: event.turn_id.clone(),
            parent_turn_id: event.parent_turn_id.clone(),
            item_id: event.item_id.as_ref().map(|id| RuntimeItemId::new(id.as_str())),
            request_id: event.request_id.as_ref().map(|id| RuntimeRequestId::new(id.as_str())),
            lifecycle_generation: event.lifecycle_generation.clone(),
            provider_refs: provider_refs_from_event(event),
            raw: Some(RuntimeEventRaw {
                source: event_raw_source(event),
                method: Some(event.method.clone()),
                message_type: None,
                payload: event.payload.clone().unwrap_or_else(|| json!({})),
            }),
            body: ProviderRuntimeEventBody::SessionConfigured(SessionConfiguredPayload::default()),
        },
    }
}

/// Synara `codexEventBase` (CodexAdapter.ts:667): ids from a legacy `codex/event/*` message.
fn codex_event_base(event: &ProviderEvent, canonical_thread_id: &ThreadId) -> RuntimeEventBase {
    let message = get(event.payload.as_ref(), "msg");
    let turn_id = event
        .turn_id
        .clone()
        .or_else(|| as_trimmed(message, "turn_id").or_else(|| as_trimmed(message, "turnId")).map(TurnId::new));
    let item_id = event
        .item_id
        .as_ref()
        .map(|id| id.as_str().to_string())
        .or_else(|| as_trimmed(message, "item_id").or_else(|| as_trimmed(message, "itemId")).map(str::to_string));
    let request_id = as_str(message, "request_id").or_else(|| as_str(message, "requestId")).map(str::to_string);
    let mut base = runtime_event_base(event, canonical_thread_id);
    let mut refs = base.event.provider_refs.take().unwrap_or_default();
    if let Some(turn_id) = &turn_id {
        refs.provider_turn_id = Some(turn_id.to_string());
        base.event.turn_id = Some(turn_id.clone());
    }
    if let Some(item_id) = &item_id {
        refs.provider_item_id = Some(crate::contracts::base::ProviderItemId::new(item_id));
        base.event.item_id = Some(RuntimeItemId::new(item_id));
    }
    if let Some(request_id) = &request_id {
        refs.provider_request_id = Some(request_id.clone());
        base.event.request_id = Some(RuntimeRequestId::new(request_id));
    }
    base.event.provider_refs = (refs != ProviderRefs::default()).then_some(refs);
    base
}

/// Synara `mapItemLifecycle` (CodexAdapter.ts:911), without generated images.
fn map_item_lifecycle(
    event: &ProviderEvent,
    canonical_thread_id: &ThreadId,
    lifecycle: ItemLifecycle,
) -> Option<ProviderRuntimeEvent> {
    let payload = event.payload.as_ref();
    let source = get(payload, "item").filter(|item| item.is_object()).or(payload.filter(|p| p.is_object()))?;
    let item_type = to_canonical_item_type(as_str(Some(source), "type").or_else(|| as_str(Some(source), "kind")));
    if item_type == CanonicalItemType::Unknown && lifecycle != ItemLifecycle::Updated {
        return None;
    }
    // Synara keeps a completed generated image only when it can find the file it wrote.
    if lifecycle == ItemLifecycle::Completed && item_type == CanonicalItemType::ImageGeneration {
        return None;
    }
    let canonical_item_type = if lifecycle == ItemLifecycle::Completed && item_type == CanonicalItemType::ReviewExited {
        CanonicalItemType::AssistantMessage
    } else {
        item_type
    };
    // Only the provider-authored summary is user-visible reasoning.
    let detail = if item_type == CanonicalItemType::Reasoning {
        reasoning_summary_detail(source)
    } else {
        item_detail(source, payload)
    };
    let async_questions = if item_type == CanonicalItemType::AssistantMessage {
        source.get("questions").and_then(Value::as_array).and_then(|questions| {
            questions
                .iter()
                .map(|question| {
                    let title = question.get("title")?.as_str()?.to_string();
                    let options = match question.get("options") {
                        None | Some(Value::Null) => None,
                        Some(Value::Array(options)) => {
                            Some(options.iter().map(|option| option.as_str().map(str::to_string)).collect::<Option<Vec<_>>>()?)
                        }
                        Some(_) => return None,
                    };
                    Some(AsyncUserInputQuestion { title, options })
                })
                .collect::<Option<Vec<_>>>()
        })
    } else {
        None
    };
    let payload_body = ItemLifecyclePayload {
        async_questions,
        item_type: canonical_item_type,
        status: item_status(lifecycle, as_str(Some(source), "status")),
        title: item_title(canonical_item_type, Some(source)),
        detail,
        data: event.payload.clone(),
    };
    let body = match lifecycle {
        ItemLifecycle::Started => ProviderRuntimeEventBody::ItemStarted(payload_body),
        ItemLifecycle::Updated => ProviderRuntimeEventBody::ItemUpdated(payload_body),
        ItemLifecycle::Completed => ProviderRuntimeEventBody::ItemCompleted(payload_body),
    };
    Some(runtime_event_base(event, canonical_thread_id).with(body))
}

/// Synara `mapCodexHookEvent` (CodexAdapter.ts:1040)
fn map_codex_hook_event(event: &ProviderEvent, canonical_thread_id: &ThreadId) -> Option<ProviderRuntimeEvent> {
    if event.method != "hook/started" && event.method != "hook/completed" {
        return None;
    }
    let run = get(event.payload.as_ref(), "run").filter(|run| run.is_object())?;
    let hook_id = as_trimmed(Some(run), "id")?.to_string();
    let hook_event = as_trimmed(Some(run), "eventName")?.to_string();
    let hook_name = as_trimmed(Some(run), "sourcePath")
        .or_else(|| as_trimmed(Some(run), "handlerType"))
        .unwrap_or(&hook_event)
        .to_string();
    let status_message = as_trimmed(Some(run), "statusMessage").map(sanitize_unmapped_provider_detail);
    let data = Some(sanitize_unmapped_provider_data(run));
    let base = runtime_event_base(event, canonical_thread_id).sanitized_raw(event.method.clone());
    if event.method == "hook/started" {
        return Some(base.with(ProviderRuntimeEventBody::HookStarted(HookStartedPayload {
            hook_id,
            hook_name,
            hook_event,
            status_message,
            data,
        })));
    }
    let status = match as_str(Some(run), "status") {
        Some("completed") => Some(HookCompletedStatus::Completed),
        Some("failed") => Some(HookCompletedStatus::Failed),
        Some("blocked") => Some(HookCompletedStatus::Blocked),
        Some("stopped") => Some(HookCompletedStatus::Stopped),
        _ => None,
    };
    let outcome = match status {
        Some(HookCompletedStatus::Completed) => HookOutcome::Success,
        Some(HookCompletedStatus::Blocked | HookCompletedStatus::Stopped) => HookOutcome::Cancelled,
        _ => HookOutcome::Error,
    };
    let duration_ms = run.get("durationMs").and_then(Value::as_u64);
    let output = run.get("entries").and_then(Value::as_array).and_then(|entries| {
        let text = entries
            .iter()
            .filter_map(|entry| {
                let text = as_trimmed(Some(entry), "text")?;
                Some(match as_trimmed(Some(entry), "kind") {
                    Some(kind) => format!("{kind}: {text}"),
                    None => text.to_string(),
                })
            })
            .collect::<Vec<_>>()
            .join("\n");
        (!text.is_empty()).then(|| sanitize_unmapped_provider_detail(&text))
    });
    Some(base.with(ProviderRuntimeEventBody::HookCompleted(HookCompletedPayload {
        hook_id,
        hook_name: Some(hook_name),
        hook_event: Some(hook_event),
        outcome,
        status,
        status_message,
        duration_ms,
        output,
        stdout: None,
        stderr: None,
        exit_code: None,
        data,
    })))
}

/// Synara `mapUnmappedCodexEvent` (CodexAdapter.ts:1103)
fn map_unmapped_codex_event(event: &ProviderEvent, canonical_thread_id: &ThreadId) -> ProviderRuntimeEvent {
    let payload = event.payload.as_ref();
    let message = get(payload, "msg");
    let native_type = truncate_text(&event.method, MAX_UNMAPPED_PROVIDER_NATIVE_TYPE_CHARS);
    let detail = as_trimmed(payload, "message")
        .or_else(|| as_trimmed(message, "summary"))
        .or_else(|| as_trimmed(payload, "reason"))
        .or_else(|| as_trimmed(payload, "summary"))
        .or_else(|| as_trimmed(message, "status"))
        .or_else(|| as_trimmed(payload, "detail"))
        .or_else(|| as_trimmed(payload, "status"))
        .map(sanitize_unmapped_provider_detail);
    runtime_event_base(event, canonical_thread_id).sanitized_raw(native_type.clone()).with(
        ProviderRuntimeEventBody::EventUnmapped(EventUnmappedPayload {
            native_type,
            detail,
            data: payload.map(sanitize_unmapped_provider_data),
        }),
    )
}

/// Synara `mapToRuntimeEvents` (CodexAdapter.ts:1135): one manager event as zero or more
/// canonical runtime events.
pub fn map_to_runtime_events(event: &ProviderEvent, canonical_thread_id: &ThreadId) -> Vec<ProviderRuntimeEvent> {
    let payload = event.payload.as_ref();
    let turn = get(payload, "turn");
    let base = || runtime_event_base(event, canonical_thread_id);
    let one = |body: ProviderRuntimeEventBody| vec![base().with(body)];

    if let Some(hook_event) = map_codex_hook_event(event, canonical_thread_id) {
        return vec![hook_event];
    }

    if event.kind == ProviderEventKind::Error {
        let Some(message) = event.message.clone() else { return Vec::new() };
        // Keep manager-emitted stderr lines visible without escalating them into a fatal error.
        let treat_as_warning = event.method == "process/stderr"
            || event.method == "mcpServer/elicitation/request/unrenderable"
            || (event.method == "error" && is_non_fatal_codex_error_message(&message));
        return one(if treat_as_warning {
            ProviderRuntimeEventBody::RuntimeWarning(RuntimeWarningPayload { message, detail: event.payload.clone() })
        } else {
            ProviderRuntimeEventBody::RuntimeError(RuntimeErrorPayload {
                message,
                class: Some(RuntimeErrorClass::ProviderError),
                detail: event.payload.clone(),
            })
        });
    }

    if event.kind == ProviderEventKind::Request {
        if event.method == "item/tool/requestUserInput" {
            // The manager refuses (and answers) unrenderable requests.
            let Some(questions) = parse_codex_user_input_questions(payload) else { return Vec::new() };
            return one(ProviderRuntimeEventBody::UserInputRequested(UserInputRequestedPayload { questions }));
        }
        let detail = as_str(payload, "command")
            .or_else(|| as_str(payload, "reason"))
            .or_else(|| as_str(payload, "prompt"))
            .or_else(|| as_str(payload, "message"))
            .map(str::to_string);
        return one(ProviderRuntimeEventBody::RequestOpened(RequestOpenedPayload {
            request_type: to_request_type_from_method(&event.method),
            detail,
            args: event.payload.clone(),
        }));
    }

    match event.method.as_str() {
        "item/requestApproval/decision" if event.request_id.is_some() => {
            let decision = get(payload, "decision")
                .and_then(|decision| serde_json::from_value::<ProviderApprovalDecision>(decision.clone()).ok())
                .and_then(|decision| serde_json::to_value(decision).ok())
                .and_then(|decision| decision.as_str().map(str::to_string));
            let request_type = match event.request_kind {
                Some(kind) => to_request_type_from_kind(Some(request_kind_str(kind))),
                None => to_request_type_from_method(&event.method),
            };
            one(ProviderRuntimeEventBody::RequestResolved(RequestResolvedPayload {
                request_type,
                decision,
                resolution: event.payload.clone(),
            }))
        }
        "item/autoApprovalReview/completed" => {
            let review = get(payload, "review").filter(|review| review.is_object()).or(payload);
            let status = as_str(review, "status");
            if status != Some("denied") && status != Some("aborted") {
                return Vec::new();
            }
            let message = as_str(review, "rationale")
                .or_else(|| as_str(review, "reason"))
                .map(str::to_string)
                .unwrap_or_else(|| format!("Automatic approval review {} this action.", status.unwrap_or_default()));
            one(ProviderRuntimeEventBody::RuntimeWarning(RuntimeWarningPayload { message, detail: event.payload.clone() }))
        }
        "session/connecting" | "session/ready" => one(ProviderRuntimeEventBody::SessionStateChanged(SessionStateChangedPayload {
            state: if event.method == "session/ready" { RuntimeSessionState::Ready } else { RuntimeSessionState::Starting },
            reason: event.message.clone(),
            detail: None,
        })),
        "session/started" => one(ProviderRuntimeEventBody::SessionStarted(SessionStartedPayload {
            message: event.message.clone(),
            resume: event.payload.clone(),
        })),
        "session/exited" | "session/closed" => one(ProviderRuntimeEventBody::SessionExited(SessionExitedPayload {
            reason: event.message.clone(),
            recoverable: None,
            exit_kind: (event.method == "session/closed").then_some(RuntimeSessionExitKind::Graceful),
        })),
        "thread/started" => {
            let provider_thread_id = as_str(get(payload, "thread"), "id").or_else(|| as_str(payload, "threadId"));
            match provider_thread_id {
                Some(provider_thread_id) => one(ProviderRuntimeEventBody::ThreadStarted(ThreadStartedPayload {
                    provider_thread_id: Some(provider_thread_id.to_string()),
                })),
                None => Vec::new(),
            }
        }
        "thread/compacting" => one(ProviderRuntimeEventBody::ItemUpdated(ItemLifecyclePayload {
            async_questions: None,
            item_type: CanonicalItemType::ContextCompaction,
            status: Some(RuntimeItemStatus::InProgress),
            title: Some("Context compaction".into()),
            detail: Some(event.message.clone().unwrap_or_else(|| "Compacting context".into())),
            data: event.payload.clone(),
        })),
        "thread/status/changed" | "thread/archived" | "thread/unarchived" | "thread/closed" | "thread/compacted" => {
            let state = match event.method.as_str() {
                "thread/archived" => RuntimeThreadState::Archived,
                "thread/closed" => RuntimeThreadState::Closed,
                "thread/compacted" => RuntimeThreadState::Compacted,
                // Synara reads `thread.state` or `state`; codex-cli 0.160.0 sends `status.type`.
                _ => to_thread_state(
                    as_str(get(payload, "thread"), "state")
                        .or_else(|| as_str(payload, "state"))
                        .or_else(|| as_str(get(payload, "status"), "type")),
                ),
            };
            one(ProviderRuntimeEventBody::ThreadStateChanged(ThreadStateChangedPayload {
                state,
                detail: event.payload.clone(),
            }))
        }
        "thread/name/updated" => one(ProviderRuntimeEventBody::ThreadMetadataUpdated(ThreadMetadataUpdatedPayload {
            name: as_str(payload, "threadName").map(str::to_string),
            metadata: as_object(payload).cloned(),
        })),
        "thread/tokenUsage/updated" => {
            let token_usage = get(payload, "tokenUsage").filter(|usage| usage.is_object()).or(payload);
            match normalize_codex_token_usage(token_usage) {
                Some(usage) => one(ProviderRuntimeEventBody::ThreadTokenUsageUpdated(ThreadTokenUsageUpdatedPayload { usage })),
                None => Vec::new(),
            }
        }
        "turn/started" => {
            let Some(turn_id) = event.turn_id.clone() else { return Vec::new() };
            let mut started = base();
            started.event.turn_id = Some(turn_id);
            vec![started.with(ProviderRuntimeEventBody::TurnStarted(TurnStartedPayload {
                model: as_str(turn, "model").map(str::to_string),
                effort: as_str(turn, "effort").map(str::to_string),
            }))]
        }
        "turn/completed" => one(ProviderRuntimeEventBody::TurnCompleted(TurnCompletedPayload {
            state: to_turn_status(as_str(turn, "status")),
            context_compacted: None,
            stop_reason: as_str(turn, "stopReason").map(|reason| Some(reason.to_string())),
            usage: get(turn, "usage").cloned(),
            model_usage: as_object(get(turn, "modelUsage")).cloned(),
            token_accounting_version: None,
            main_loop_tokens: None,
            total_cost_usd: as_number(turn, "totalCostUsd"),
            cumulative_cost_usd: None,
            error_message: as_str(get(turn, "error"), "message").map(str::to_string),
        })),
        "turn/aborted" => one(ProviderRuntimeEventBody::TurnAborted(TurnAbortedPayload {
            reason: event.message.clone().unwrap_or_else(|| "Turn aborted".into()),
        })),
        "turn/plan/updated" => {
            let tasks = get(payload, "plan")
                .and_then(Value::as_array)
                .map(|steps| {
                    steps
                        .iter()
                        .filter(|step| step.is_object())
                        .filter_map(|step| {
                            let task = as_str(Some(step), "step").unwrap_or("task").trim();
                            (!task.is_empty()).then(|| RuntimeTaskListItem {
                                task: task.to_string(),
                                status: normalize_runtime_task_status(as_str(Some(step), "status")),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            one(ProviderRuntimeEventBody::TurnTasksUpdated(TurnTasksUpdatedPayload {
                explanation: as_str(payload, "explanation").filter(|text| !text.is_empty()).map(|text| Some(text.to_string())),
                tasks,
            }))
        }
        "turn/diff/updated" => one(ProviderRuntimeEventBody::TurnDiffUpdated(TurnDiffUpdatedPayload {
            unified_diff: as_str(payload, "unifiedDiff")
                .or_else(|| as_str(payload, "diff"))
                .or_else(|| as_str(payload, "patch"))
                .unwrap_or_default()
                .to_string(),
        })),
        "item/started" => map_item_lifecycle(event, canonical_thread_id, ItemLifecycle::Started).into_iter().collect(),
        "item/completed" => {
            let Some(source) = get(payload, "item").filter(|item| item.is_object()).or(payload) else {
                return Vec::new();
            };
            let item_type = to_canonical_item_type(as_str(Some(source), "type").or_else(|| as_str(Some(source), "kind")));
            if item_type == CanonicalItemType::Plan {
                return match item_detail(source, payload) {
                    Some(plan_markdown) => {
                        one(ProviderRuntimeEventBody::TurnProposedCompleted(TurnProposedCompletedPayload { plan_markdown }))
                    }
                    None => Vec::new(),
                };
            }
            map_item_lifecycle(event, canonical_thread_id, ItemLifecycle::Completed).into_iter().collect()
        }
        "item/reasoning/summaryPartAdded" | "item/commandExecution/terminalInteraction" => {
            map_item_lifecycle(event, canonical_thread_id, ItemLifecycle::Updated).into_iter().collect()
        }
        "item/plan/delta" => match delta_text(event) {
            Some(delta) => vec![base().minimal_raw().with(ProviderRuntimeEventBody::TurnProposedDelta(TurnProposedDeltaPayload { delta }))],
            None => Vec::new(),
        },
        "item/agentMessage/delta"
        | "item/commandExecution/outputDelta"
        | "item/fileChange/outputDelta"
        | "item/reasoning/summaryTextDelta"
        | "item/reasoning/textDelta" => match delta_text(event) {
            Some(delta) => vec![base().minimal_raw().with(ProviderRuntimeEventBody::ContentDelta(ContentDeltaPayload {
                stream_kind: content_stream_kind_from_method(&event.method),
                delta,
                content_index: get(payload, "contentIndex").and_then(Value::as_i64),
                summary_index: get(payload, "summaryIndex").and_then(Value::as_i64),
            }))],
            None => Vec::new(),
        },
        "item/mcpToolCall/progress" => one(ProviderRuntimeEventBody::ToolProgress(ToolProgressPayload {
            tool_use_id: as_str(payload, "toolUseId").or_else(|| as_str(payload, "itemId")).map(str::to_string),
            tool_name: as_str(payload, "toolName").map(str::to_string),
            summary: as_str(payload, "summary").or_else(|| as_str(payload, "message")).map(str::to_string),
            elapsed_seconds: as_number(payload, "elapsedSeconds"),
        })),
        "serverRequest/resolved" => {
            let from_payload = to_request_type_from_resolved_payload(payload);
            let request_type = match (from_payload, &event.request_id, event.request_kind) {
                (CanonicalRequestType::Unknown, Some(_), Some(kind)) => to_request_type_from_kind(Some(request_kind_str(kind))),
                (request_type, _, _) => request_type,
            };
            one(ProviderRuntimeEventBody::RequestResolved(RequestResolvedPayload {
                request_type,
                decision: None,
                resolution: event.payload.clone(),
            }))
        }
        "item/tool/requestUserInput/answered" => one(ProviderRuntimeEventBody::UserInputResolved(UserInputResolvedPayload {
            answers: to_canonical_user_input_answers(get(payload, "answers")),
        })),
        "codex/event/task_started" => {
            let message = get(payload, "msg");
            let Some(task_id) = as_str(payload, "id").or_else(|| as_str(message, "turn_id")) else { return Vec::new() };
            vec![codex_event_base(event, canonical_thread_id).with(ProviderRuntimeEventBody::TaskStarted(TaskStartedPayload {
                task_id: RuntimeTaskId::new(task_id),
                description: None,
                task_type: as_str(message, "collaboration_mode_kind").map(str::to_string),
                subagent_type: None,
                workflow_name: None,
                workflow_task_id: None,
                workflow_phases: None,
                workflow_agent_phases: None,
                workflow_agent_plans: None,
                tool_use_id: None,
            }))]
        }
        "codex/event/task_complete" => {
            let message = get(payload, "msg");
            let last_agent_message = as_str(message, "last_agent_message");
            let proposed_plan = extract_proposed_plan_markdown(last_agent_message);
            let mut events = Vec::new();
            if let Some(task_id) = as_str(payload, "id").or_else(|| as_str(message, "turn_id")) {
                events.push(codex_event_base(event, canonical_thread_id).with(ProviderRuntimeEventBody::TaskCompleted(
                    TaskCompletedPayload {
                        task_id: RuntimeTaskId::new(task_id),
                        status: TaskCompletedStatus::Completed,
                        summary: last_agent_message.map(str::to_string),
                        usage: None,
                        workflow_task_id: None,
                        workflow_agents: None,
                    },
                )));
            }
            if let Some(plan_markdown) = proposed_plan {
                events.push(
                    codex_event_base(event, canonical_thread_id)
                        .with(ProviderRuntimeEventBody::TurnProposedCompleted(TurnProposedCompletedPayload { plan_markdown })),
                );
            }
            events
        }
        "codex/event/agent_reasoning" => {
            let (Some(task_id), Some(description)) = (as_str(payload, "id"), as_str(get(payload, "msg"), "text")) else {
                return Vec::new();
            };
            vec![codex_event_base(event, canonical_thread_id).with(ProviderRuntimeEventBody::TaskProgress(TaskProgressPayload {
                task_id: RuntimeTaskId::new(task_id),
                description: description.to_string(),
                summary: None,
                usage: None,
                last_tool_name: None,
                workflow_task_id: None,
                workflow_agents: None,
            }))]
        }
        "codex/event/reasoning_content_delta" => {
            let message = get(payload, "msg");
            let Some(delta) = as_str(message, "delta").filter(|delta| !delta.is_empty()) else { return Vec::new() };
            let summary_index = get(message, "summary_index").and_then(Value::as_i64);
            vec![codex_event_base(event, canonical_thread_id).minimal_raw().with(ProviderRuntimeEventBody::ContentDelta(
                ContentDeltaPayload {
                    stream_kind: if summary_index.is_some() {
                        RuntimeContentStreamKind::ReasoningSummaryText
                    } else {
                        RuntimeContentStreamKind::ReasoningText
                    },
                    delta: delta.to_string(),
                    content_index: None,
                    summary_index,
                },
            ))]
        }
        "model/rerouted" => one(ProviderRuntimeEventBody::ModelRerouted(ModelReroutedPayload {
            from_model: as_str(payload, "fromModel").unwrap_or("unknown").to_string(),
            to_model: as_str(payload, "toModel").unwrap_or("unknown").to_string(),
            reason: as_str(payload, "reason").unwrap_or("unknown").to_string(),
        })),
        "deprecationNotice" => one(ProviderRuntimeEventBody::DeprecationNotice(DeprecationNoticePayload {
            summary: as_trimmed(payload, "summary").unwrap_or("Deprecation notice").to_string(),
            details: as_trimmed(payload, "details").map(str::to_string),
        })),
        "configWarning" => one(ProviderRuntimeEventBody::ConfigWarning(ConfigWarningPayload {
            summary: as_trimmed(payload, "summary").unwrap_or("Configuration warning").to_string(),
            details: as_trimmed(payload, "details").map(str::to_string),
            path: as_trimmed(payload, "path").map(str::to_string),
            range: get(payload, "range").cloned(),
        })),
        "account/updated" => one(ProviderRuntimeEventBody::AccountUpdated(AccountUpdatedPayload {
            account: event.payload.clone().unwrap_or_else(|| json!({})),
        })),
        "account/rateLimits/updated" => one(ProviderRuntimeEventBody::AccountRateLimitsUpdated(AccountRateLimitsUpdatedPayload {
            rate_limits: event.payload.clone().unwrap_or_else(|| json!({})),
        })),
        "mcpServer/oauthLogin/completed" => one(ProviderRuntimeEventBody::McpOauthCompleted(McpOauthCompletedPayload {
            success: get(payload, "success") == Some(&Value::Bool(true)),
            name: as_str(payload, "name").map(str::to_string),
            error: as_str(payload, "error").map(str::to_string),
        })),
        "error" => {
            let message = as_str(get(payload, "error"), "message")
                .map(str::to_string)
                .or_else(|| event.message.clone())
                .unwrap_or_else(|| "Provider runtime error".into());
            let treat_as_warning = get(payload, "willRetry") == Some(&Value::Bool(true)) || is_non_fatal_codex_error_message(&message);
            one(if treat_as_warning {
                ProviderRuntimeEventBody::RuntimeWarning(RuntimeWarningPayload { message, detail: event.payload.clone() })
            } else {
                ProviderRuntimeEventBody::RuntimeError(RuntimeErrorPayload {
                    message,
                    class: Some(RuntimeErrorClass::ProviderError),
                    detail: event.payload.clone(),
                })
            })
        }
        "windows/worldWritableWarning" => one(ProviderRuntimeEventBody::RuntimeWarning(RuntimeWarningPayload {
            message: event.message.clone().unwrap_or_else(|| "Windows world-writable warning".into()),
            detail: event.payload.clone(),
        })),
        // No explicit mapping: keep the event visible as a readable row rather than silence.
        _ => vec![map_unmapped_codex_event(event, canonical_thread_id)],
    }
}

fn delta_text(event: &ProviderEvent) -> Option<String> {
    let payload = event.payload.as_ref();
    event
        .text_delta
        .clone()
        .or_else(|| as_str(payload, "delta").map(str::to_string))
        .or_else(|| as_str(payload, "text").map(str::to_string))
        .or_else(|| as_str(get(payload, "content"), "text").map(str::to_string))
        .filter(|delta| !delta.is_empty())
}

fn truncate_text(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let kept: String = value.chars().take(max_chars.saturating_sub(3)).collect();
    format!("{kept}...")
}

/// Synara `sanitizeUnmappedProviderDetail` (unmappedProviderEvents.ts:518), bounded but without
/// Synara's in-text credential patterns.
fn sanitize_unmapped_provider_detail(value: &str) -> String {
    truncate_text(value, MAX_UNMAPPED_PROVIDER_DETAIL_CHARS)
}

/// Synara `sanitizeUnmappedProviderData` (unmappedProviderEvents.ts:505): sensitive keys are
/// redacted (Synara's key rules, without its in-text patterns) and an oversized value becomes a
/// bounded preview.
fn sanitize_unmapped_provider_data(value: &Value) -> Value {
    let redacted = redact_value(value, 0);
    let serialized = serde_json::to_string(&redacted).unwrap_or_else(|_| "null".into());
    let length = serialized.chars().count();
    if length <= MAX_UNMAPPED_PROVIDER_DATA_JSON_CHARS {
        return redacted;
    }
    json!({
        "__synaraTruncated": true,
        "originalJsonChars": length,
        "preview": truncate_text(&serialized, MAX_UNMAPPED_PROVIDER_PREVIEW_CHARS),
    })
}

fn redact_value(value: &Value, depth: usize) -> Value {
    if depth > 64 {
        return json!("[Truncated]");
    }
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, entry)| {
                    let redacted = if is_sensitive_key(key) { json!(REDACTED_VALUE) } else { redact_value(entry, depth + 1) };
                    (key.clone(), redacted)
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.iter().map(|entry| redact_value(entry, depth + 1)).collect()),
        other => other.clone(),
    }
}

/// Synara `isSensitiveKey` (unmappedProviderEvents.ts:348), without the provider credential
/// environment list.
fn is_sensitive_key(key: &str) -> bool {
    const EXACT: &[&str] = &[
        "authorization", "proxyauthorization", "apikey", "awsaccesskeyid", "password", "passphrase",
        "cookie", "setcookie", "credential", "credentials", "privatekey",
    ];
    const TERMINAL: &[&str] = &["authorization", "cookie", "credential", "credentials", "passphrase", "password", "secret", "token"];
    let normalized: String = key.chars().filter(char::is_ascii_alphanumeric).collect::<String>().to_lowercase();
    if EXACT.contains(&normalized.as_str()) {
        return true;
    }
    let last_token = normalize_item_type(Some(key)).split(' ').next_back().unwrap_or_default().to_string();
    TERMINAL.contains(&last_token.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::base::ProviderDriverKind;

    fn notification(method: &str, payload: Value) -> ProviderEvent {
        ProviderEvent {
            id: EventId::new("evt"),
            kind: ProviderEventKind::Notification,
            provider: ProviderDriverKind::new("codex"),
            provider_instance_id: None,
            thread_id: ThreadId::new("thread"),
            created_at: now_iso(),
            method: method.into(),
            message: None,
            turn_id: Some(TurnId::new("turn")),
            parent_turn_id: None,
            item_id: None,
            request_id: None,
            request_kind: None,
            lifecycle_generation: None,
            provider_thread_id: None,
            provider_parent_thread_id: None,
            text_delta: None,
            payload: Some(payload),
        }
    }

    fn kind(event: &ProviderRuntimeEvent) -> String {
        serde_json::to_value(event).unwrap()["type"].as_str().unwrap().to_string()
    }

    #[test]
    fn item_types_map_to_canonical_types() {
        let cases = [
            ("userMessage", CanonicalItemType::UserMessage),
            ("agentMessage", CanonicalItemType::AssistantMessage),
            ("reasoning", CanonicalItemType::Reasoning),
            ("plan", CanonicalItemType::Plan),
            ("commandExecution", CanonicalItemType::CommandExecution),
            ("fileChange", CanonicalItemType::FileChange),
            ("mcpToolCall", CanonicalItemType::McpToolCall),
            ("dynamicToolCall", CanonicalItemType::DynamicToolCall),
            ("collabAgentToolCall", CanonicalItemType::CollabAgentToolCall),
            ("webSearch", CanonicalItemType::WebSearch),
            ("imageView", CanonicalItemType::ImageView),
            ("imageGeneration", CanonicalItemType::ImageGeneration),
            ("enteredReviewMode", CanonicalItemType::ReviewEntered),
            ("exitedReviewMode", CanonicalItemType::ReviewExited),
            ("contextCompaction", CanonicalItemType::ContextCompaction),
            ("hookPrompt", CanonicalItemType::Unknown),
        ];
        for (raw, expected) in cases {
            assert_eq!(to_canonical_item_type(Some(raw)), expected, "{raw}");
        }
        assert_eq!(normalize_item_type(Some("item/commandExecution.outputDelta")), "item command execution output delta");
    }

    #[test]
    fn stream_kinds_follow_the_delta_method() {
        assert_eq!(content_stream_kind_from_method("item/agentMessage/delta"), RuntimeContentStreamKind::AssistantText);
        assert_eq!(content_stream_kind_from_method("item/reasoning/textDelta"), RuntimeContentStreamKind::ReasoningText);
        assert_eq!(
            content_stream_kind_from_method("item/reasoning/summaryTextDelta"),
            RuntimeContentStreamKind::ReasoningSummaryText
        );
        assert_eq!(content_stream_kind_from_method("item/commandExecution/outputDelta"), RuntimeContentStreamKind::CommandOutput);
        assert_eq!(content_stream_kind_from_method("item/fileChange/outputDelta"), RuntimeContentStreamKind::FileChangeOutput);
    }

    #[test]
    fn token_usage_plan_and_diff_are_mapped() {
        let usage = map_to_runtime_events(
            &notification(
                "thread/tokenUsage/updated",
                json!({ "tokenUsage": {
                    "total": { "totalTokens": 300, "inputTokens": 250, "cachedInputTokens": 100, "outputTokens": 50 },
                    "last": { "totalTokens": 120, "inputTokens": 100, "outputTokens": 20 },
                    "modelContextWindow": 1000
                }}),
            ),
            &ThreadId::new("thread"),
        );
        let ProviderRuntimeEventBody::ThreadTokenUsageUpdated(payload) = &usage[0].body else { panic!("{usage:?}") };
        assert_eq!(payload.usage.used_tokens, 120);
        assert_eq!(payload.usage.total_processed_tokens, Some(300));
        assert_eq!(payload.usage.max_tokens, Some(1000));
        assert_eq!(payload.usage.cumulative_usage.as_ref().unwrap().cached_input_tokens, Some(100));

        let plan = map_to_runtime_events(
            &notification(
                "turn/plan/updated",
                json!({ "explanation": "why", "plan": [{ "step": "a", "status": "completed" }, { "step": "b", "status": "inProgress" }] }),
            ),
            &ThreadId::new("thread"),
        );
        let ProviderRuntimeEventBody::TurnTasksUpdated(payload) = &plan[0].body else { panic!() };
        assert_eq!(payload.tasks[1].status, RuntimeTaskStatus::InProgress);

        let diff = map_to_runtime_events(&notification("turn/diff/updated", json!({ "diff": "--- a" })), &ThreadId::new("thread"));
        assert_eq!(kind(&diff[0]), "turn.diff.updated");

        let limits = map_to_runtime_events(
            &notification("account/rateLimits/updated", json!({ "rateLimits": { "primary": {} } })),
            &ThreadId::new("thread"),
        );
        assert_eq!(kind(&limits[0]), "account.rate-limits.updated");
    }

    #[test]
    fn thread_status_reads_the_schema_shape() {
        let events = map_to_runtime_events(
            &notification("thread/status/changed", json!({ "status": { "type": "idle" } })),
            &ThreadId::new("thread"),
        );
        let ProviderRuntimeEventBody::ThreadStateChanged(payload) = &events[0].body else { panic!() };
        assert_eq!(payload.state, RuntimeThreadState::Idle);
    }

    #[test]
    fn a_completed_plan_item_is_a_proposed_plan() {
        let events = map_to_runtime_events(
            &notification("item/completed", json!({ "item": { "type": "plan", "id": "p", "text": "# Plan" } })),
            &ThreadId::new("thread"),
        );
        let ProviderRuntimeEventBody::TurnProposedCompleted(payload) = &events[0].body else { panic!() };
        assert_eq!(payload.plan_markdown, "# Plan");
        assert_eq!(extract_proposed_plan_markdown(Some("x <proposed_plan>\n do it \n</proposed_plan>")), Some("do it".into()));
    }

    #[test]
    fn proposed_plan_survives_text_whose_lowercase_changes_length() {
        assert_eq!(
            extract_proposed_plan_markdown(Some("İİ <proposed_plan>\nşu plan</proposed_plan>")),
            Some("şu plan".into())
        );
    }

    #[test]
    fn unmapped_data_is_redacted_and_bounded() {
        let data = sanitize_unmapped_provider_data(&json!({ "apiKey": "k", "nested": { "accessToken": "t", "ok": 1 } }));
        assert_eq!(data, json!({ "apiKey": REDACTED_VALUE, "nested": { "accessToken": REDACTED_VALUE, "ok": 1 } }));
        let big = sanitize_unmapped_provider_data(&json!({ "text": "x".repeat(20_000) }));
        assert_eq!(big["__synaraTruncated"], true);
    }

    #[test]
    fn file_attachments_become_a_path_block() {
        let attachments = [ChatAttachment::File(crate::contracts::orchestration::ChatFileAttachment {
            id: "att-1".into(),
            name: "notes.txt".into(),
            mime_type: "text/plain".into(),
            size_bytes: 2048,
        })];
        let composed = compose_codex_input_with_file_attachments(Some("read this"), &attachments, Some(Path::new("/a"))).unwrap();
        assert!(composed.starts_with("read this\n\n<attached_files>\n"));
        assert!(composed.contains("- \"notes.txt\" - text/plain - 2 KB - /a/att-1.txt"));
    }
}
