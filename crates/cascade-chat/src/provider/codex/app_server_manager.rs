//! Ported from Synara `apps/server/src/codexAppServerManager.ts`: one `codex app-server` process
//! driven over JSON-RPC on stdio, from the handshake through thread open, turns, steering,
//! interrupts and the server's own requests (approvals and questions), reported as
//! [`ProviderEvent`]s that the adapter maps.
//!
//! Synara's manager keeps a map of sessions; here a manager is one session, owned by the task the
//! adapter starts for it, so its `CodexSessionContext` fields are the manager's own. A task reads
//! stdout and settles requests as their responses arrive (so a request awaited here can never
//! wait on the session that awaits it); everything else it reads is queued for the session as a
//! [`CodexIncoming`], in order.
//!
//! Left out on purpose, with Synara's names so a later port can find them: the agent gateway
//! (`gatewaySessionLease`, Synara MCP auto-approval, computer control), review mode
//! (`startReview`, `reviewTurnIds`, `settleTrackedReview`), discovery sessions, skills, plugins,
//! models, voice, import, fork/rollback/compact of an open thread, the legacy
//! `codex/event/task_complete` fallback timer, the CLI version gate and the `CODEX_HOME`
//! overlays of `codexProcessEnv.ts`. The user's own codex home is used as it is.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{anyhow, Result};
use serde_json::{json, Map, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, BufReader},
    sync::mpsc,
};
use uuid::Uuid;

use crate::contracts::{
    base::{now_iso, ApprovalRequestId, EventId, ProviderDriverKind, ProviderInstanceId, ProviderItemId, ThreadId, TurnId},
    model::default_model_by_provider,
    orchestration::{
        ProviderApprovalDecision, ProviderInteractionMode, ProviderKind, ProviderRequestKind,
        ProviderStartOptions, ProviderUserInputAnswer, ProviderUserInputAnswers, RuntimeMode,
    },
    provider::{
        ProviderEvent, ProviderEventKind, ProviderMentionReference, ProviderSession, ProviderSessionStatus,
        ProviderSkillReference, ProviderTurnStartResult,
    },
    provider_runtime::{UserInputQuestion, UserInputQuestionOption},
};
use crate::provider::process::{ExitFuture, SpawnSpec, Spawner};

use super::transport::{
    json_rpc_request, request_timeout_message, CodexAppServerTransportError, CodexAppServerTransportErrorReason,
    CodexJsonlFramer, CodexJsonlWriter, JsonRpcError, JsonRpcStdioRequestRegistry, JSONRPC_STDIO_REQUEST_TIMEOUT_MS,
};
use super::turn_input::{build_codex_turn_input, CodexImageInputItem, CodexTurnInputParts};

const MCP_SERVER_ELICITATION_REQUEST_METHOD: &str = "mcpServer/elicitation/request";
const MCP_TOOL_CALL_APPROVAL_KIND: &str = "mcp_tool_call";

/// Synara `CODEX_PENDING_SETTLE_DEADLINE_MS` (codexAppServerManager.ts:430): bounds the answers
/// written to parked server requests, so a child that stopped draining stdin cannot hold
/// teardown hostage.
const CODEX_PENDING_SETTLE_DEADLINE_MS: u64 = 2_000;
/// How long a stop waits for the process to leave after it was asked to. The process spawner
/// escalates to SIGKILL after two seconds, so this only bounds a process that ignores both.
const CODEX_TEARDOWN_EXIT_DEADLINE_MS: u64 = 5_000;
/// How long an exited session keeps reading what the process wrote before it left.
const CODEX_EXIT_DRAIN_DEADLINE_MS: u64 = 1_000;

const ANSI_ESCAPE_CHAR: char = '\u{1b}';
const BENIGN_ERROR_LOG_SNIPPETS: &[&str] = &[
    "state db missing rollout path for thread",
    "state db record_discrepancy: find_thread_path_by_id_str_in_subdir, falling_back",
];
const RECOVERABLE_THREAD_RESUME_ERROR_SNIPPETS: &[&str] =
    &["not found", "missing thread", "no such thread", "unknown thread", "does not exist"];
const CODEX_SPARK_MODEL: &str = "gpt-5.3-codex-spark";
const CODEX_SPARK_DISABLED_PLAN_TYPES: &[&str] = &["free", "go", "plus"];
/// Synara's fallback for a collaboration mode when no model is known
/// (`buildCodexCollaborationMode`, codexAppServerManager.ts:913).
const CODEX_COLLABORATION_FALLBACK_MODEL: &str = "gpt-5.3-codex";

/// Synara `NON_FATAL_CODEX_ERROR_SNIPPETS` (codexErrorClassification.ts:10)
const NON_FATAL_CODEX_ERROR_SNIPPETS: &[&str] = &["write_stdin failed: stdin is closed for this session"];

/// Synara `isNonFatalCodexErrorMessage` (codexErrorClassification.ts:14)
pub fn is_non_fatal_codex_error_message(message: &str) -> bool {
    let normalized = message.trim().to_lowercase();
    NON_FATAL_CODEX_ERROR_SNIPPETS.iter().any(|snippet| normalized.contains(snippet))
}

/// Synara `approvalSessionGrantWidensSessionPolicy` (packages/shared/src/approvalSessionGrant.ts:15):
/// whether "always allow this session" on a request of this kind widens the whole session.
pub fn approval_session_grant_widens_session_policy(request_kind: Option<ProviderRequestKind>) -> bool {
    match request_kind {
        Some(ProviderRequestKind::Command | ProviderRequestKind::FileRead | ProviderRequestKind::FileChange) => true,
        Some(ProviderRequestKind::Permissions | ProviderRequestKind::Tool) => false,
        None => true,
    }
}

/// Synara `PendingApprovalRequest` (codexAppServerManager.ts:128)
#[derive(Clone, Debug)]
struct PendingApprovalRequest {
    request_id: ApprovalRequestId,
    json_rpc_id: Value,
    method: String,
    request_kind: ProviderRequestKind,
    turn_id: Option<TurnId>,
    parent_turn_id: Option<TurnId>,
    item_id: Option<ProviderItemId>,
    provider_thread_id: Option<String>,
    provider_parent_thread_id: Option<String>,
    requested_permissions: Option<Map<String, Value>>,
    mcp_session_persistence_advertised: Option<bool>,
}

fn is_permission_approval_request(request: &PendingApprovalRequest) -> bool {
    request.method == "item/permissions/requestApproval"
}

/// Synara `PendingUserInputRequest` (codexAppServerManager.ts:153)
#[derive(Clone, Debug)]
struct PendingUserInputRequest {
    request_id: ApprovalRequestId,
    json_rpc_id: Value,
    turn_id: Option<TurnId>,
    parent_turn_id: Option<TurnId>,
    item_id: Option<ProviderItemId>,
    provider_thread_id: Option<String>,
    provider_parent_thread_id: Option<String>,
}

/// Synara `ResolvedCollaborationRoute` (codexAppServerManager.ts:176)
#[derive(Clone, Debug, Default)]
struct ResolvedCollaborationRoute {
    parent_turn_id: Option<TurnId>,
    provider_thread_id: Option<String>,
    provider_parent_thread_id: Option<String>,
    is_child_conversation: bool,
}

#[derive(Clone, Debug, Default)]
struct RouteFields {
    turn_id: Option<TurnId>,
    item_id: Option<ProviderItemId>,
}

/// Synara `CodexApprovalPolicy` (codexAppServerManager.ts:187). The 0.160.0 schema
/// (`AskForApproval`) no longer offers `on-failure`; no runtime mode maps to it.
pub type CodexApprovalPolicy = &'static str;
/// Synara `CodexApprovalsReviewer` (codexAppServerManager.ts:188)
pub type CodexApprovalsReviewer = &'static str;
/// Synara `CodexSandboxMode` (codexAppServerManager.ts:189)
pub type CodexSandboxMode = &'static str;

/// The thread-level permission overrides of `mapCodexRuntimeMode` (codexAppServerManager.ts:686).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CodexThreadModeOverrides {
    pub approval_policy: CodexApprovalPolicy,
    pub approvals_reviewer: CodexApprovalsReviewer,
    pub sandbox: CodexSandboxMode,
}

/// The turn-level overrides of `mapCodexRuntimeModeToTurnOverrides` (codexAppServerManager.ts:791):
/// `turn/start` takes a `sandboxPolicy` object rather than a sandbox mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CodexTurnOverrides {
    pub approval_policy: CodexApprovalPolicy,
    pub approvals_reviewer: CodexApprovalsReviewer,
    pub sandbox_policy_type: &'static str,
}

impl CodexTurnOverrides {
    fn write_into(&self, params: &mut Map<String, Value>) {
        params.insert("approvalPolicy".into(), json!(self.approval_policy));
        params.insert("approvalsReviewer".into(), json!(self.approvals_reviewer));
        params.insert("sandboxPolicy".into(), json!({ "type": self.sandbox_policy_type }));
    }
}

/// Synara `CodexAccountSnapshot` (codexAppServerManager.ts:338)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexAccountSnapshot {
    pub kind: &'static str,
    pub plan_type: Option<String>,
    pub spark_enabled: bool,
}

impl Default for CodexAccountSnapshot {
    fn default() -> Self {
        Self { kind: "unknown", plan_type: None, spark_enabled: true }
    }
}

/// Synara `CodexAppServerSendTurnInput` (codexAppServerManager.ts:344)
#[derive(Clone, Debug, Default)]
pub struct CodexAppServerSendTurnInput {
    pub thread_id: Option<ThreadId>,
    pub input: Option<String>,
    pub attachments: Option<Vec<CodexImageInputItem>>,
    pub skills: Option<Vec<ProviderSkillReference>>,
    pub mentions: Option<Vec<ProviderMentionReference>>,
    pub model: Option<String>,
    pub service_tier: Option<String>,
    pub effort: Option<String>,
    pub interaction_mode: Option<ProviderInteractionMode>,
}

/// Synara `CodexAppServerStartSessionInput` (codexAppServerManager.ts:358), without the gateway.
#[derive(Clone, Debug)]
pub struct CodexAppServerStartSessionInput {
    pub thread_id: ThreadId,
    pub provider_instance_id: Option<ProviderInstanceId>,
    pub lifecycle_generation: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<String>,
    pub service_tier: Option<String>,
    pub resume_cursor: Option<Value>,
    pub fork_source_resume_cursor: Option<Value>,
    pub provider_options: Option<ProviderStartOptions>,
    pub runtime_mode: RuntimeMode,
}

/// What the session hears from its process, in the order it happened.
#[derive(Debug)]
pub enum CodexIncoming {
    /// A protocol message that is not a response: a notification or a server request.
    Message(Value),
    /// A stderr line worth showing (see [`classify_codex_stderr_line`]).
    Stderr(String),
    /// The pipes failed; the process cannot be talked to any more.
    TransportFailure { message: String, reason: Option<CodexAppServerTransportErrorReason> },
    /// The process ended with this exit code (`None` for a signal).
    Exited(Option<i32>),
}

fn normalize_codex_process_line(raw_line: &str) -> String {
    if !raw_line.contains(ANSI_ESCAPE_CHAR) {
        return raw_line.trim().to_string();
    }
    // Synara `ANSI_ESCAPE_REGEX`: ESC [ [0-9;]* m
    let mut out = String::with_capacity(raw_line.len());
    let mut chars = raw_line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == ANSI_ESCAPE_CHAR && chars.peek() == Some(&'[') {
            let rest: String = chars.clone().skip(1).take_while(|c| c.is_ascii_digit() || *c == ';').collect();
            let after: Vec<char> = chars.clone().skip(1 + rest.chars().count()).take(1).collect();
            if after.first() == Some(&'m') {
                for _ in 0..(2 + rest.chars().count()) {
                    chars.next();
                }
                continue;
            }
        }
        out.push(ch);
    }
    out.trim().to_string()
}

fn is_ignorable_codex_process_line(line: &str) -> bool {
    if line.is_empty() {
        return true;
    }
    // Synara `BENIGN_PROCESS_OUTPUT_REGEXES`: /^(?:\^C)?Token usage:/i
    let lower = line.to_lowercase();
    lower.strip_prefix("^c").unwrap_or(&lower).starts_with("token usage:")
}

fn is_codex_protocol_envelope(value: &Map<String, Value>) -> bool {
    if value.get("method").is_some_and(Value::is_string) {
        return true;
    }
    value.contains_key("id") && (value.contains_key("result") || value.contains_key("error"))
}

fn normalize_codex_user_visible_error_message(raw_message: &str) -> String {
    let message = normalize_codex_process_line(raw_message);
    let marker = "failed to parse function arguments: duplicate field `";
    if let Some(at) = message.to_ascii_lowercase().find(marker) {
        let rest = &message[at + marker.len()..];
        let field = rest.split('`').next().filter(|field| !field.is_empty());
        return match field {
            Some(field) => format!("Tool call failed because the same argument was sent twice ({field})."),
            None => "Tool call failed because the same argument was sent twice.".to_string(),
        };
    }
    message
}

/// Synara `readCodexAccountSnapshot` (codexAppServerManager.ts:501)
pub fn read_codex_account_snapshot(response: &Value) -> CodexAccountSnapshot {
    let account = response.get("account").filter(|value| value.is_object()).unwrap_or(response);
    match account.get("type").and_then(Value::as_str) {
        Some("apiKey") => CodexAccountSnapshot { kind: "apiKey", plan_type: None, spark_enabled: true },
        Some("chatgpt") => {
            let plan_type = account.get("planType").and_then(Value::as_str).unwrap_or("unknown").to_string();
            let spark_enabled = !CODEX_SPARK_DISABLED_PLAN_TYPES.contains(&plan_type.as_str());
            CodexAccountSnapshot { kind: "chatgpt", plan_type: Some(plan_type), spark_enabled }
        }
        _ => CodexAccountSnapshot::default(),
    }
}

/// Synara `CODEX_PLAN_MODE_DEVELOPER_INSTRUCTIONS` (codexAppServerManager.ts:550), without
/// Synara's browser-tool routing and gateway harness policy, which name tools this app does not
/// give the agent.
pub const CODEX_PLAN_MODE_DEVELOPER_INSTRUCTIONS: &str = r#"<collaboration_mode># Plan Mode (Conversational)

You work in 3 phases, and you should *chat your way* to a great plan before finalizing it. A great plan is very detailed-intent- and implementation-wise-so that it can be handed to another engineer or agent to be implemented right away. It must be **decision complete**, where the implementer does not need to make any decisions.

## Mode rules (strict)

You are in **Plan Mode** until a developer message explicitly ends it.

Plan Mode is not changed by user intent, tone, or imperative language. If a user asks for execution while still in Plan Mode, treat it as a request to **plan the execution**, not perform it.

## Plan Mode vs update_plan tool

Plan Mode is a collaboration mode that can involve requesting user input and eventually issuing a `<proposed_plan>` block.

Separately, `update_plan` is a checklist/progress/TODOs tool; it does not enter or exit Plan Mode. Do not confuse it with Plan mode or try to use it while in Plan mode. If you try to use `update_plan` in Plan mode, it will return an error.

## Execution vs. mutation in Plan Mode

You may explore and execute **non-mutating** actions that improve the plan. You must not perform **mutating** actions.

### Allowed (non-mutating, plan-improving)

Actions that gather truth, reduce ambiguity, or validate feasibility without changing repo-tracked state. Examples:

* Reading or searching files, configs, schemas, types, manifests, and docs
* Static analysis, inspection, and repo exploration
* Dry-run style commands when they do not edit repo-tracked files
* Tests, builds, or checks that may write to caches or build artifacts (for example, `target/`, `.cache/`, or snapshots) so long as they do not edit repo-tracked files

### Not allowed (mutating, plan-executing)

Actions that implement the plan or change repo-tracked state. Examples:

* Editing or writing files
* Running formatters or linters that rewrite files
* Applying patches, migrations, or codegen that updates repo-tracked files
* Side-effectful commands whose purpose is to carry out the plan rather than refine it

When in doubt: if the action would reasonably be described as "doing the work" rather than "planning the work," do not do it.

## PHASE 1 - Ground in the environment (explore first, ask second)

Begin by grounding yourself in the actual environment. Eliminate unknowns in the prompt by discovering facts, not by asking the user. Resolve all questions that can be answered through exploration or inspection. Identify missing or ambiguous details only if they cannot be derived from the environment. Silent exploration between turns is allowed and encouraged.

Before asking the user any question, perform at least one targeted non-mutating exploration pass (for example: search relevant files, inspect likely entrypoints/configs, confirm current implementation shape), unless no local environment/repo is available.

Exception: you may ask clarifying questions about the user's prompt before exploring, ONLY if there are obvious ambiguities or contradictions in the prompt itself. However, if ambiguity might be resolved by exploring, always prefer exploring first.

Do not ask questions that can be answered from the repo or system (for example, "where is this struct?" or "which UI component should we use?" when exploration can make it clear). Only ask once you have exhausted reasonable non-mutating exploration.

## PHASE 2 - Intent chat (what they actually want)

* Keep asking until you can clearly state: goal + success criteria, audience, in/out of scope, constraints, current state, and the key preferences/tradeoffs.
* Bias toward questions over guessing: if any high-impact ambiguity remains, do NOT plan yet-ask.

## PHASE 3 - Implementation chat (what/how we'll build)

* Once intent is stable, keep asking until the spec is decision complete: approach, interfaces (APIs/schemas/I/O), data flow, edge cases/failure modes, testing + acceptance criteria, rollout/monitoring, and any migrations/compat constraints.

## Asking questions

Critical rules:

* Strongly prefer using the `request_user_input` tool to ask any questions.
* Offer only meaningful multiple-choice options; don't include filler choices that are obviously wrong or irrelevant.
* In rare cases where an unavoidable, important question can't be expressed with reasonable multiple-choice options (due to extreme ambiguity), you may ask it directly without the tool.

You SHOULD ask many questions, but each question must:

* materially change the spec/plan, OR
* confirm/lock an assumption, OR
* choose between meaningful tradeoffs.
* not be answerable by non-mutating commands.

Use the `request_user_input` tool only for decisions that materially change the plan, for confirming important assumptions, or for information that cannot be discovered via non-mutating exploration.

## Two kinds of unknowns (treat differently)

1. **Discoverable facts** (repo/system truth): explore first.

   * Before asking, run targeted searches and check likely sources of truth (configs/manifests/entrypoints/schemas/types/constants).
   * Ask only if: multiple plausible candidates; nothing found but you need a missing identifier/context; or ambiguity is actually product intent.
   * If asking, present concrete candidates (paths/service names) + recommend one.
   * Never ask questions you can answer from your environment (e.g., "where is this struct").

2. **Preferences/tradeoffs** (not discoverable): ask early.

   * These are intent or implementation preferences that cannot be derived from exploration.
   * Provide 2-4 mutually exclusive options + a recommended default.
   * If unanswered, proceed with the recommended option and record it as an assumption in the final plan.

## Finalization rule

Only output the final plan when it is decision complete and leaves no decisions to the implementer.

When you present the official plan, wrap it in a `<proposed_plan>` block so the client can render it specially:

1) The opening tag must be on its own line.
2) Start the plan content on the next line (no text on the same line as the tag).
3) The closing tag must be on its own line.
4) Use Markdown inside the block.
5) Keep the tags exactly as `<proposed_plan>` and `</proposed_plan>` (do not translate or rename them), even if the plan content is in another language.

Example:

<proposed_plan>
plan content
</proposed_plan>

plan content should be human and agent digestible. The final plan must be plan-only and include:

* A clear title
* A brief summary section
* Important changes or additions to public APIs/interfaces/types
* Test cases and scenarios
* Explicit assumptions and defaults chosen where needed

Do not ask "should I proceed?" in the final output. The user can easily switch out of Plan mode and request implementation if you have included a `<proposed_plan>` block in your response. Alternatively, they can decide to stay in Plan mode and continue refining the plan.

Only produce at most one `<proposed_plan>` block per turn, and only when you are presenting a complete spec.
</collaboration_mode>"#;

/// Synara `CODEX_DEFAULT_MODE_DEVELOPER_INSTRUCTIONS` (codexAppServerManager.ts:672), without the
/// browser-tool routing and gateway policy.
pub const CODEX_DEFAULT_MODE_DEVELOPER_INSTRUCTIONS: &str = r#"<collaboration_mode># Collaboration Mode: Default

You are now in Default mode. Any previous instructions for other modes (e.g. Plan mode) are no longer active.

Your active mode changes only when new developer instructions with a different `<collaboration_mode>...</collaboration_mode>` change it; user requests or tool descriptions do not change mode by themselves. Known mode names are Default and Plan.

## request_user_input availability

The `request_user_input` tool is unavailable in Default mode. If you call it while in Default mode, it will return an error.

In Default mode, strongly prefer making reasonable assumptions and executing the user's request rather than stopping to ask questions. If you absolutely must ask a question because the answer cannot be discovered from local context and a reasonable assumption would be risky, ask the user directly with a concise plain-text question. Never write a multiple choice question as a textual assistant message.
</collaboration_mode>"#;

/// Synara `mapCodexRuntimeMode` (codexAppServerManager.ts:686): the runtime mode as Codex
/// thread-level permission overrides. Field names and values checked against the
/// `ThreadStartParams` schema of codex-cli 0.160.0.
pub fn map_codex_runtime_mode(runtime_mode: RuntimeMode) -> CodexThreadModeOverrides {
    match runtime_mode {
        RuntimeMode::ApprovalRequired => CodexThreadModeOverrides {
            approval_policy: "untrusted",
            approvals_reviewer: "user",
            sandbox: "read-only",
        },
        RuntimeMode::Auto => CodexThreadModeOverrides {
            approval_policy: "on-request",
            approvals_reviewer: "auto_review",
            sandbox: "workspace-write",
        },
        RuntimeMode::FullAccess => CodexThreadModeOverrides {
            approval_policy: "never",
            approvals_reviewer: "user",
            sandbox: "danger-full-access",
        },
    }
}

/// Synara `CodexThreadSessionOverrides` (codexAppServerManager.ts:716)
#[derive(Clone, Debug, PartialEq)]
pub struct CodexThreadSessionOverrides {
    pub model: Option<String>,
    pub service_tier: Option<String>,
    pub cwd: String,
    pub mode: CodexThreadModeOverrides,
}

impl CodexThreadSessionOverrides {
    fn to_params(&self) -> Map<String, Value> {
        let mut params = Map::new();
        params.insert("model".into(), self.model.clone().map(Value::String).unwrap_or(Value::Null));
        if let Some(service_tier) = &self.service_tier {
            params.insert("serviceTier".into(), json!(service_tier));
        }
        params.insert("cwd".into(), json!(self.cwd));
        params.insert("approvalPolicy".into(), json!(self.mode.approval_policy));
        params.insert("approvalsReviewer".into(), json!(self.mode.approvals_reviewer));
        params.insert("sandbox".into(), json!(self.mode.sandbox));
        params
    }
}

/// Synara `CodexThreadOpenRequest` (codexAppServerManager.ts:725)
#[derive(Clone, Debug, PartialEq)]
pub struct CodexThreadOpenRequest {
    pub method: &'static str,
    pub params: Value,
}

/// Synara `buildCodexThreadOpenRequest` (codexAppServerManager.ts:736)
pub fn build_codex_thread_open_request(
    fork_source_thread_id: Option<&str>,
    resume_thread_id: Option<&str>,
    session_overrides: &CodexThreadSessionOverrides,
) -> Result<CodexThreadOpenRequest> {
    if fork_source_thread_id.is_some() && resume_thread_id.is_some() {
        return Err(anyhow!("A Codex session cannot resume and fork at the same time."));
    }
    let mut params = session_overrides.to_params();
    if let Some(thread_id) = fork_source_thread_id {
        params.insert("threadId".into(), json!(thread_id));
        params.insert("excludeTurns".into(), json!(true));
        return Ok(CodexThreadOpenRequest { method: "thread/fork", params: Value::Object(params) });
    }
    if let Some(thread_id) = resume_thread_id {
        params.insert("threadId".into(), json!(thread_id));
        params.insert("excludeTurns".into(), json!(true));
        return Ok(CodexThreadOpenRequest { method: "thread/resume", params: Value::Object(params) });
    }
    params.insert("experimentalRawEvents".into(), json!(false));
    Ok(CodexThreadOpenRequest { method: "thread/start", params: Value::Object(params) })
}

/// Synara `mapCodexRuntimeModeToTurnOverrides` (codexAppServerManager.ts:791)
pub fn map_codex_runtime_mode_to_turn_overrides(runtime_mode: RuntimeMode) -> CodexTurnOverrides {
    let mode = map_codex_runtime_mode(runtime_mode);
    CodexTurnOverrides {
        approval_policy: mode.approval_policy,
        approvals_reviewer: mode.approvals_reviewer,
        sandbox_policy_type: match runtime_mode {
            RuntimeMode::ApprovalRequired => "readOnly",
            RuntimeMode::Auto => "workspaceWrite",
            RuntimeMode::FullAccess => "dangerFullAccess",
        },
    }
}

/// Synara `CODEX_ALWAYS_ALLOW_SESSION_TURN_OVERRIDES` (codexAppServerManager.ts:819)
pub const CODEX_ALWAYS_ALLOW_SESSION_TURN_OVERRIDES: CodexTurnOverrides = CodexTurnOverrides {
    approval_policy: "never",
    approvals_reviewer: "user",
    sandbox_policy_type: "dangerFullAccess",
};

/// Synara `resolveCodexModelForAccount` (codexAppServerManager.ts:838)
pub fn resolve_codex_model_for_account(model: Option<String>, account: &CodexAccountSnapshot) -> Option<String> {
    if model.as_deref() != Some(CODEX_SPARK_MODEL) || account.spark_enabled {
        return model;
    }
    default_model_by_provider(ProviderKind::Codex).map(str::to_string)
}

/// Synara `normalizeCodexModelSlug` (codexAppServerManager.ts:866), without the shared alias
/// table: a trimmed, non-empty slug.
pub fn normalize_codex_model_slug(model: Option<&str>) -> Option<String> {
    model.map(str::trim).filter(|model| !model.is_empty()).map(str::to_string)
}

/// Synara `buildCodexInitializeParams` (codexAppServerManager.ts:882)
fn build_codex_initialize_params() -> Value {
    json!({
        "clientInfo": {
            "name": "cascade",
            "title": "Cascade",
            "version": env!("CARGO_PKG_VERSION"),
        },
        "capabilities": { "experimentalApi": true },
    })
}

/// Synara `buildCodexCollaborationMode` (codexAppServerManager.ts:895). Codex's `turn/start`
/// takes `collaborationMode` only under `experimentalApi`, which the handshake turns on.
pub fn build_codex_collaboration_mode(
    interaction_mode: Option<ProviderInteractionMode>,
    model: Option<&str>,
    effort: Option<&str>,
) -> Option<Value> {
    let interaction_mode = interaction_mode?;
    let model = normalize_codex_model_slug(model).unwrap_or_else(|| CODEX_COLLABORATION_FALLBACK_MODEL.to_string());
    let (native_mode, instructions) = if interaction_mode == ProviderInteractionMode::Plan {
        ("plan", CODEX_PLAN_MODE_DEVELOPER_INSTRUCTIONS)
    } else {
        ("default", CODEX_DEFAULT_MODE_DEVELOPER_INSTRUCTIONS)
    };
    Some(json!({
        "mode": native_mode,
        "settings": {
            "model": model,
            "reasoning_effort": effort.unwrap_or("medium"),
            "developer_instructions": instructions,
        },
    }))
}

/// Synara `toCodexUserInputAnswer` (codexAppServerManager.ts:938)
fn to_codex_user_input_answer(value: &ProviderUserInputAnswer) -> Result<Value> {
    match value {
        ProviderUserInputAnswer::Text(text) => Ok(json!({ "answers": [text] })),
        ProviderUserInputAnswer::Many(values) => Ok(json!({ "answers": values })),
        ProviderUserInputAnswer::Null => Err(anyhow!("User input answers must be strings or arrays of strings.")),
    }
}

/// Synara `toCodexUserInputAnswers` (codexAppServerManager.ts:959)
fn to_codex_user_input_answers(answers: &ProviderUserInputAnswers) -> Result<Map<String, Value>> {
    answers
        .iter()
        .map(|(question_id, value)| Ok((question_id.clone(), to_codex_user_input_answer(value)?)))
        .collect()
}

/// Synara `parseCodexUserInputQuestions` (codexAppServerManager.ts:981): the questions of an
/// `item/tool/requestUserInput`, or `None` when none can be shown. Shared with the adapter, so a
/// request the manager parks is always one the adapter can surface.
pub fn parse_codex_user_input_questions(payload: Option<&Value>) -> Option<Vec<UserInputQuestion>> {
    let questions = payload?.get("questions")?.as_array()?;
    let parsed: Vec<UserInputQuestion> = questions
        .iter()
        .filter_map(|entry| {
            let question = entry.as_object()?;
            let trimmed = |key: &str| {
                question.get(key).and_then(Value::as_str).map(str::trim).filter(|value| !value.is_empty())
            };
            let id = trimmed("id")?;
            let header = trimmed("header")?;
            let prompt = trimmed("question")?;
            let options = question
                .get("options")
                .and_then(Value::as_array)
                .map(|options| {
                    options
                        .iter()
                        .filter_map(|option| {
                            let label = option.get("label").and_then(Value::as_str).map(str::trim)?;
                            if label.is_empty() {
                                return None;
                            }
                            let description = option
                                .get("description")
                                .and_then(Value::as_str)
                                .map(str::trim)
                                .filter(|description| !description.is_empty())
                                .unwrap_or(label);
                            Some(UserInputQuestionOption { label: label.into(), description: description.into() })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(UserInputQuestion {
                id: id.into(),
                header: header.into(),
                question: prompt.into(),
                options,
                multi_select: (question.get("multiSelect") == Some(&Value::Bool(true))).then_some(true),
            })
        })
        .collect();
    (!parsed.is_empty()).then_some(parsed)
}

/// Synara `classifyCodexStderrLine` (codexAppServerManager.ts:1025): a stderr line worth
/// showing, or `None` for log noise below ERROR and known-benign errors.
pub fn classify_codex_stderr_line(raw_line: &str) -> Option<String> {
    let line = normalize_codex_process_line(raw_line);
    if is_ignorable_codex_process_line(&line) {
        return None;
    }
    if let Some(level) = codex_stderr_log_level(&line) {
        if level != "ERROR" {
            return None;
        }
        if BENIGN_ERROR_LOG_SNIPPETS.iter().any(|snippet| line.contains(snippet)) {
            return None;
        }
    }
    Some(normalize_codex_user_visible_error_message(&line))
}

/// The level of a line shaped like Synara `CODEX_STDERR_LOG_REGEX`:
/// `^\d{4}-\d{2}-\d{2}T\S+\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+\S+:\s+(.*)$`.
fn codex_stderr_log_level(line: &str) -> Option<&str> {
    let mut parts = line.split_whitespace();
    let timestamp = parts.next()?.as_bytes();
    let dated = timestamp.len() > 11
        && timestamp[..4].iter().all(u8::is_ascii_digit)
        && timestamp[4] == b'-'
        && timestamp[5..7].iter().all(u8::is_ascii_digit)
        && timestamp[7] == b'-'
        && timestamp[8..10].iter().all(u8::is_ascii_digit)
        && timestamp[10] == b'T';
    let level = parts.next()?;
    let target = parts.next()?;
    let has_message = parts.next().is_some();
    (dated && ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"].contains(&level) && target.ends_with(':') && has_message)
        .then_some(level)
}

/// Synara `isRecoverableThreadResumeError` (codexAppServerManager.ts:1047)
pub fn is_recoverable_thread_resume_error(message: &str) -> bool {
    let message = message.to_lowercase();
    message.contains("thread/resume")
        && RECOVERABLE_THREAD_RESUME_ERROR_SNIPPETS.iter().any(|snippet| message.contains(snippet))
}

/// Synara `formatCodexThreadResumeError` (codexAppServerManager.ts:1056)
pub fn format_codex_thread_resume_error(message: &str, provider_thread_id: &str) -> String {
    if !message.to_lowercase().contains("already has an active writer") {
        return message.to_string();
    }
    format!(
        "Codex thread {provider_thread_id} is open in another Codex client. Close that client before continuing the original thread, or import it as a copy instead."
    )
}

/// Synara `decodeSubagentReceiverThreadIds` (packages/shared/src/subagents.ts:147)
fn decode_subagent_receiver_thread_ids(item: &Map<String, Value>) -> Vec<String> {
    for key in ["receiverThreadIds", "receiver_thread_ids", "threadIds", "thread_ids"] {
        let Some(values) = item.get(key).and_then(Value::as_array) else { continue };
        let ids: Vec<String> = values
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_string)
            .collect();
        if !ids.is_empty() {
            return ids;
        }
    }
    for key in ["receiverThreadId", "receiver_thread_id", "threadId", "thread_id", "newThreadId", "new_thread_id"] {
        if let Some(id) = item.get(key).and_then(Value::as_str).map(str::trim).filter(|id| !id.is_empty()) {
            return vec![id.to_string()];
        }
    }
    Vec::new()
}

/// Synara `readResumeCursorThreadId` (codexAppServerManager.ts:5521): the resume cursor is
/// `{ "threadId": <provider thread id> }`.
pub fn read_resume_cursor_thread_id(resume_cursor: Option<&Value>) -> Option<String> {
    normalize_provider_thread_id(resume_cursor?.as_object()?.get("threadId")?.as_str())
}

fn normalize_provider_thread_id(value: Option<&str>) -> Option<String> {
    value.map(str::trim).filter(|value| !value.is_empty()).map(str::to_string)
}

fn to_turn_id(value: Option<&str>) -> Option<TurnId> {
    value.map(str::trim).filter(|value| !value.is_empty()).map(TurnId::new)
}

fn to_provider_item_id(value: Option<&str>) -> Option<ProviderItemId> {
    value.map(str::trim).filter(|value| !value.is_empty()).map(ProviderItemId::new)
}

fn read_object<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    value?.get(key).filter(|value| value.is_object())
}

fn read_string<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a str> {
    value?.get(key)?.as_str()
}

fn read_boolean(value: Option<&Value>, key: &str) -> Option<bool> {
    value?.get(key)?.as_bool()
}

/// Synara `CodexAppServerManager` (codexAppServerManager.ts:1193), holding the one
/// `CodexSessionContext` (codexAppServerManager.ts:196) it drives.
pub struct CodexAppServerManager {
    session: ProviderSession,
    lifecycle_generation: Option<String>,
    account: CodexAccountSnapshot,
    events: mpsc::Sender<ProviderEvent>,
    writer: Option<CodexJsonlWriter>,
    requests: JsonRpcStdioRequestRegistry,
    incoming: Option<mpsc::UnboundedReceiver<CodexIncoming>>,
    // Behind mutexes only so the manager is `Sync` (its `&self` futures are held across
    // awaits); the manager reaches them through `get_mut`, never by locking.
    exited: Mutex<Option<ExitFuture>>,
    terminate: Mutex<Option<Box<dyn FnMut() + Send>>>,
    pending_approvals: Vec<PendingApprovalRequest>,
    pending_user_inputs: Vec<PendingUserInputRequest>,
    session_approval_override: Option<CodexTurnOverrides>,
    collab_receiver_turns: HashMap<String, TurnId>,
    collab_receiver_parents: HashMap<String, String>,
    active_interaction_mode: Option<ProviderInteractionMode>,
    next_request_id: u64,
    stopping: bool,
    terminal_failure: Option<String>,
    /// Transport/process failure initiated teardown, so a later exit remains observable.
    failure_stopping: bool,
    exit_reported: bool,
}

impl CodexAppServerManager {
    /// A manager for `thread_id` that reports on `events`. Nothing runs until
    /// [`Self::start_session`].
    pub fn new(input: &CodexAppServerStartSessionInput, events: mpsc::Sender<ProviderEvent>) -> Self {
        let now = now_iso();
        let cwd = input
            .cwd
            .clone()
            .or_else(|| std::env::current_dir().ok().map(|dir| dir.to_string_lossy().into_owned()));
        Self {
            session: ProviderSession {
                provider: ProviderKind::Codex.into(),
                provider_instance_id: input.provider_instance_id.clone(),
                status: ProviderSessionStatus::Connecting,
                runtime_mode: input.runtime_mode,
                cwd,
                model: normalize_codex_model_slug(input.model.as_deref()),
                thread_id: input.thread_id.clone(),
                resume_cursor: None,
                active_turn_id: None,
                created_at: now.clone(),
                updated_at: now,
                last_error: None,
            },
            lifecycle_generation: input.lifecycle_generation.clone(),
            account: CodexAccountSnapshot::default(),
            events,
            writer: None,
            requests: JsonRpcStdioRequestRegistry::new(),
            incoming: None,
            exited: Mutex::new(None),
            terminate: Mutex::new(None),
            pending_approvals: Vec::new(),
            pending_user_inputs: Vec::new(),
            session_approval_override: None,
            collab_receiver_turns: HashMap::new(),
            collab_receiver_parents: HashMap::new(),
            active_interaction_mode: None,
            next_request_id: 1,
            stopping: false,
            terminal_failure: None,
            failure_stopping: false,
            exit_reported: false,
        }
    }

    pub fn session(&self) -> &ProviderSession {
        &self.session
    }

    /// Whether the session has ended (stopped, failed, or its process exited).
    pub fn is_finished(&self) -> bool {
        self.exit_reported
    }

    /// Synara `startSession` (codexAppServerManager.ts:1304)
    pub async fn start_session(
        &mut self,
        input: &CodexAppServerStartSessionInput,
        spawner: Arc<dyn Spawner>,
    ) -> Result<ProviderSession> {
        let resume_thread_id = read_resume_cursor_thread_id(input.resume_cursor.as_ref());
        let fork_source_thread_id = read_resume_cursor_thread_id(input.fork_source_resume_cursor.as_ref());
        let codex_options = input.provider_options.as_ref().and_then(|options| options.codex.clone()).unwrap_or_default();
        let spec = SpawnSpec {
            program: codex_options.binary_path.clone().unwrap_or_else(|| "codex".to_string()),
            args: vec!["app-server".to_string()],
            cwd: self.session.cwd.clone().map(Into::into),
            env: codex_options.environment.clone().unwrap_or_default().into_iter().collect(),
            env_remove: Vec::new(),
        };
        let child = match spawner.spawn(&spec) {
            Ok(child) => child,
            Err(error) => {
                let message = format!("Failed to start codex app-server ({}): {error}", spec.program);
                self.update_session(|session| {
                    session.status = ProviderSessionStatus::Error;
                    session.last_error = Some(message.clone());
                });
                self.emit_error_event("session/startFailed", &message).await;
                self.stopping = true;
                self.exit_reported = true;
                self.emit_lifecycle_event("session/exited", &message).await;
                return Err(anyhow!(message));
            }
        };

        let (incoming_tx, incoming_rx) = mpsc::unbounded_channel();
        let writer_failures = incoming_tx.clone();
        let writer_requests = self.requests.clone();
        self.writer = Some(CodexJsonlWriter::spawn(child.stdin, move |message| {
            writer_requests.reject_all(&message);
            let _ = writer_failures.send(CodexIncoming::TransportFailure { message, reason: None });
        }));
        self.incoming = Some(incoming_rx);
        *self.exited.get_mut().unwrap() = Some(child.exited);
        *self.terminate.get_mut().unwrap() = Some(child.terminate);
        attach_process_listeners(child.stdout, child.stderr, self.requests.clone(), incoming_tx);

        self.emit_lifecycle_event("session/connecting", "Starting codex app-server").await;

        match self.open_thread(input, resume_thread_id, fork_source_thread_id).await {
            Ok(()) => Ok(self.session.clone()),
            Err(error) => {
                let message = self.terminal_failure.clone().unwrap_or_else(|| error.to_string());
                if self.terminal_failure.is_none() && (!self.stopping || self.failure_stopping) {
                    self.update_session(|session| {
                        session.status = ProviderSessionStatus::Error;
                        session.last_error = Some(message.clone());
                    });
                    self.emit_error_event("session/startFailed", &message).await;
                }
                self.stop_session().await;
                Err(anyhow!(message))
            }
        }
    }

    /// The handshake and thread open of `startSession` (codexAppServerManager.ts:1416-1606).
    async fn open_thread(
        &mut self,
        input: &CodexAppServerStartSessionInput,
        resume_thread_id: Option<String>,
        fork_source_thread_id: Option<String>,
    ) -> Result<()> {
        self.send_request("initialize", build_codex_initialize_params()).await?;
        self.write_message(&json!({ "method": "initialized" }))?;
        // Model discovery is lazy, as in Synara; the account only gates the Spark model.
        match self.send_request("account/read", json!({})).await {
            Ok(response) => self.account = read_codex_account_snapshot(&response),
            Err(error) => {
                if self.terminal_failure.is_some() {
                    return Err(error);
                }
                tracing::warn!(%error, "codex account/read failed");
            }
        }

        let normalized_model =
            resolve_codex_model_for_account(normalize_codex_model_slug(input.model.as_deref()), &self.account);
        let session_overrides = CodexThreadSessionOverrides {
            model: normalized_model,
            service_tier: input.service_tier.clone(),
            cwd: self.session.cwd.clone().unwrap_or_default(),
            mode: map_codex_runtime_mode(input.runtime_mode),
        };
        let thread_open_request = build_codex_thread_open_request(
            fork_source_thread_id.as_deref(),
            resume_thread_id.as_deref(),
            &session_overrides,
        )?;
        let open_message = match thread_open_request.method {
            "thread/fork" => format!("Forking Codex thread {}.", fork_source_thread_id.as_deref().unwrap_or_default()),
            "thread/resume" => {
                format!("Attempting to resume thread {}.", resume_thread_id.as_deref().unwrap_or_default())
            }
            _ => "Starting a new Codex thread.".to_string(),
        };
        self.emit_lifecycle_event("session/threadOpenRequested", &open_message).await;

        let mut thread_open_method = thread_open_request.method;
        let thread_open_response = match self
            .send_request(thread_open_request.method, thread_open_request.params.clone())
            .await
        {
            Ok(response) => response,
            Err(error) => {
                if let Some(failure) = &self.terminal_failure {
                    return Err(anyhow!(failure.clone()));
                }
                let message = error.to_string();
                let recoverable_resume_failure =
                    thread_open_request.method == "thread/resume" && is_recoverable_thread_resume_error(&message);
                if !recoverable_resume_failure {
                    let thread_open_error = match (&resume_thread_id, thread_open_request.method) {
                        (Some(thread_id), "thread/resume") => format_codex_thread_resume_error(&message, thread_id),
                        _ => message,
                    };
                    let method = match thread_open_request.method {
                        "thread/fork" => "session/threadForkFailed",
                        "thread/resume" => "session/threadResumeFailed",
                        _ => "session/threadStartFailed",
                    };
                    self.emit_error_event(method, &thread_open_error).await;
                    return Err(anyhow!(thread_open_error));
                }
                thread_open_method = "thread/start";
                self.emit_lifecycle_event(
                    "session/threadResumeFallback",
                    &format!(
                        "Could not resume thread {}; started a new thread instead.",
                        resume_thread_id.as_deref().unwrap_or_default()
                    ),
                )
                .await;
                let fallback = build_codex_thread_open_request(None, None, &session_overrides)?;
                self.send_request(fallback.method, fallback.params).await?
            }
        };

        let provider_thread_id = read_string(read_object(Some(&thread_open_response), "thread"), "id")
            .or_else(|| read_string(Some(&thread_open_response), "threadId"))
            .map(str::to_string)
            .ok_or_else(|| anyhow!("{thread_open_method} response did not include a thread id."))?;
        // Not in Synara: a session started without a model learns the one Codex chose, so a
        // collaboration mode later names that model rather than Synara's fallback.
        if self.session.model.is_none() {
            let model = normalize_codex_model_slug(read_string(Some(&thread_open_response), "model"));
            self.update_session(|session| session.model = model);
        }
        self.mark_session_ready_after_thread_open(thread_open_method, &provider_thread_id).await;
        Ok(())
    }

    fn provider_thread_id(&self) -> Option<String> {
        read_resume_cursor_thread_id(self.session.resume_cursor.as_ref())
    }

    fn require_session(&self) -> Result<()> {
        if self.stopping || self.session.status == ProviderSessionStatus::Closed {
            return Err(anyhow!("Session is closed: {}", self.session.thread_id));
        }
        Ok(())
    }

    /// Synara `sendTurn` (codexAppServerManager.ts:1648)
    pub async fn send_turn(&mut self, input: CodexAppServerSendTurnInput) -> Result<ProviderTurnStartResult> {
        self.require_session()?;
        self.collab_receiver_turns.clear();
        self.collab_receiver_parents.clear();

        // Normal sends never interrupt active work. The orchestration layer decides when a queued
        // follow-up is ready to become a provider turn.
        let turn_input = build_codex_turn_input(CodexTurnInputParts {
            input: input.input.as_deref(),
            attachments: input.attachments.as_deref(),
            skills: input.skills.as_deref(),
            mentions: input.mentions.as_deref(),
        });
        if turn_input.is_empty() {
            return Err(anyhow!("Turn input must include text or attachments."));
        }
        let provider_thread_id =
            self.provider_thread_id().ok_or_else(|| anyhow!("Session is missing provider resume thread id."))?;
        let mut params = Map::new();
        params.insert("threadId".into(), json!(provider_thread_id));
        params.insert("input".into(), serde_json::to_value(&turn_input)?);
        params.insert("summary".into(), json!("auto"));
        self.resolve_codex_turn_overrides().write_into(&mut params);

        let normalized_model = resolve_codex_model_for_account(
            normalize_codex_model_slug(input.model.as_deref().or(self.session.model.as_deref())),
            &self.account,
        );
        if let Some(model) = &normalized_model {
            params.insert("model".into(), json!(model));
            if model == CODEX_SPARK_MODEL {
                params.insert("summary".into(), json!("none"));
            }
        }
        if let Some(service_tier) = &input.service_tier {
            params.insert("serviceTier".into(), json!(service_tier));
        }
        if let Some(effort) = &input.effort {
            params.insert("effort".into(), json!(effort));
        }
        if let Some(collaboration_mode) =
            build_codex_collaboration_mode(input.interaction_mode, normalized_model.as_deref(), input.effort.as_deref())
        {
            if !params.contains_key("model") {
                params.insert("model".into(), collaboration_mode["settings"]["model"].clone());
            }
            params.insert("collaborationMode".into(), collaboration_mode);
        }

        self.active_interaction_mode = Some(input.interaction_mode.unwrap_or_default());
        let response = self.send_request("turn/start", Value::Object(params)).await?;
        let turn_id = to_turn_id(read_string(read_object(Some(&response), "turn"), "id"))
            .ok_or_else(|| anyhow!("turn/start response did not include a turn id."))?;
        let interaction_mode = self.active_interaction_mode;
        self.update_session(|session| {
            session.status = ProviderSessionStatus::Running;
            session.active_turn_id = Some(turn_id.clone());
        });
        self.active_interaction_mode = interaction_mode;
        Ok(ProviderTurnStartResult {
            thread_id: self.session.thread_id.clone(),
            turn_id,
            resume_cursor: self.session.resume_cursor.clone(),
        })
    }

    /// Synara `steerTurn` (codexAppServerManager.ts:1749): redirects the live turn, or starts a
    /// turn when none is running.
    pub async fn steer_turn(&mut self, input: CodexAppServerSendTurnInput) -> Result<ProviderTurnStartResult> {
        self.require_session()?;
        let active_turn_id = match (&self.session.status, &self.session.active_turn_id) {
            (ProviderSessionStatus::Running, Some(turn_id)) => turn_id.clone(),
            _ => return self.send_turn(input).await,
        };
        let turn_input = build_codex_turn_input(CodexTurnInputParts {
            input: input.input.as_deref(),
            attachments: input.attachments.as_deref(),
            skills: input.skills.as_deref(),
            mentions: input.mentions.as_deref(),
        });
        if turn_input.is_empty() {
            return Err(anyhow!("Turn input must include text or attachments."));
        }
        let provider_thread_id =
            self.provider_thread_id().ok_or_else(|| anyhow!("Session is missing provider resume thread id."))?;
        let response = self
            .send_request(
                "turn/steer",
                json!({
                    "threadId": provider_thread_id,
                    "input": turn_input,
                    "expectedTurnId": active_turn_id,
                }),
            )
            .await?;
        let turn_id = to_turn_id(read_string(Some(&response), "turnId"))
            .ok_or_else(|| anyhow!("turn/steer response did not include a turn id."))?;
        self.update_session(|session| {
            session.status = ProviderSessionStatus::Running;
            session.active_turn_id = Some(turn_id.clone());
        });
        Ok(ProviderTurnStartResult {
            thread_id: self.session.thread_id.clone(),
            turn_id,
            resume_cursor: self.session.resume_cursor.clone(),
        })
    }

    /// Synara `interruptTurn` (codexAppServerManager.ts:1917), without the review recovery.
    pub async fn interrupt_turn(
        &mut self,
        turn_id: Option<TurnId>,
        provider_thread_id_override: Option<String>,
    ) -> Result<()> {
        self.require_session()?;
        let effective_turn_id = turn_id.or_else(|| self.session.active_turn_id.clone());

        // Stop must also unpark codex from any question/approval it is blocked on;
        // turn/interrupt alone does not settle server-initiated requests.
        let owner = provider_thread_id_override.clone().map(|provider_thread_id| (provider_thread_id, effective_turn_id.clone()));
        self.settle_pending_human_requests("turn interrupted", owner).await;

        let provider_thread_id = provider_thread_id_override.or_else(|| self.provider_thread_id());
        let (Some(effective_turn_id), Some(provider_thread_id)) = (effective_turn_id, provider_thread_id) else {
            tracing::info!(thread_id = %self.session.thread_id, "codex turn/interrupt skipped: no active turn");
            return Ok(());
        };
        match self
            .send_request("turn/interrupt", json!({ "threadId": provider_thread_id, "turnId": effective_turn_id }))
            .await
        {
            Ok(_) => Ok(()),
            Err(error) if is_turn_already_idle_error(&error.to_string()) => {
                self.handle_server_notification(
                    "turn/aborted",
                    Some(json!({
                        "threadId": provider_thread_id,
                        "turn": { "id": effective_turn_id },
                        "reason": "provider-already-idle",
                    })),
                )
                .await;
                Ok(())
            }
            Err(error) => Err(error),
        }
    }

    /// Synara `resolveApprovalRequest` (codexAppServerManager.ts:2729). A settle (`best_effort`)
    /// reports the decision even when the answer could not be written, so the request's card
    /// closes; a human's answer that could not be written is an error.
    async fn resolve_approval_request(
        &mut self,
        pending_request: &PendingApprovalRequest,
        decision: ProviderApprovalDecision,
        best_effort: bool,
    ) -> Result<()> {
        let accepted = matches!(decision, ProviderApprovalDecision::Accept | ProviderApprovalDecision::AcceptForSession);
        let decision_value = serde_json::to_value(decision)?;
        let result = if pending_request.method == MCP_SERVER_ELICITATION_REQUEST_METHOD {
            json!({
                "action": if accepted { json!("accept") } else { decision_value.clone() },
                "content": null,
                "_meta": if decision == ProviderApprovalDecision::AcceptForSession
                    && pending_request.mcp_session_persistence_advertised == Some(true)
                {
                    json!({ "persist": "session" })
                } else {
                    Value::Null
                },
            })
        } else if is_permission_approval_request(pending_request) {
            let requested = pending_request.requested_permissions.clone().unwrap_or_default();
            let mut granted = Map::new();
            for key in ["network", "fileSystem"] {
                if let Some(value) = requested.get(key).filter(|value| !value.is_null()) {
                    granted.insert(key.into(), value.clone());
                }
            }
            json!({
                "permissions": if accepted { Value::Object(granted) } else { json!({}) },
                "scope": if decision == ProviderApprovalDecision::AcceptForSession { "session" } else { "turn" },
            })
        } else {
            json!({ "decision": decision_value })
        };
        let written = self.write_message(&json!({ "id": pending_request.json_rpc_id, "result": result }));
        if let Err(error) = written {
            if !best_effort {
                return Err(error);
            }
        }

        let mut event = self.base_event(ProviderEventKind::Notification, "item/requestApproval/decision");
        event.turn_id = pending_request.turn_id.clone();
        event.parent_turn_id = pending_request.parent_turn_id.clone();
        event.item_id = pending_request.item_id.clone();
        event.provider_thread_id = pending_request.provider_thread_id.clone();
        event.provider_parent_thread_id = pending_request.provider_parent_thread_id.clone();
        event.request_id = Some(pending_request.request_id.clone());
        event.request_kind = Some(pending_request.request_kind);
        event.payload = Some(json!({
            "requestId": pending_request.request_id,
            "requestKind": pending_request.request_kind,
            "decision": decision_value,
        }));
        self.emit_event(event).await;
        Ok(())
    }

    /// Synara `resolveRemainingSessionApprovalRequests` (codexAppServerManager.ts:2793)
    async fn resolve_remaining_session_approval_requests(&mut self) -> Result<()> {
        let (remaining, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.pending_approvals)
            .into_iter()
            .partition(|request| approval_session_grant_widens_session_policy(Some(request.request_kind)));
        self.pending_approvals = kept;
        for pending_request in remaining {
            self.resolve_approval_request(&pending_request, ProviderApprovalDecision::AcceptForSession, false)
                .await?;
        }
        Ok(())
    }

    /// Synara `respondToRequest` (codexAppServerManager.ts:2805)
    pub async fn respond_to_request(
        &mut self,
        request_id: &ApprovalRequestId,
        decision: ProviderApprovalDecision,
    ) -> Result<()> {
        self.require_session()?;
        let index = self
            .pending_approvals
            .iter()
            .position(|request| &request.request_id == request_id)
            .ok_or_else(|| anyhow!("Unknown pending approval request: {request_id}"))?;
        let pending_request = self.pending_approvals.remove(index);
        let is_permission_request = is_permission_approval_request(&pending_request);
        // The session override widens every later approval, so only a command/file prompt may
        // set it. A tool call keeps its own channel (`_meta.persist: "session"`).
        let overrides_session_policy = decision == ProviderApprovalDecision::AcceptForSession
            && approval_session_grant_widens_session_policy(Some(pending_request.request_kind));
        if overrides_session_policy {
            self.session_approval_override = Some(CODEX_ALWAYS_ALLOW_SESSION_TURN_OVERRIDES);
        }
        self.resolve_approval_request(&pending_request, decision, false).await?;
        if decision == ProviderApprovalDecision::Cancel
            && (is_permission_request || pending_request.request_kind == ProviderRequestKind::Tool)
        {
            self.interrupt_turn(pending_request.turn_id.clone(), pending_request.provider_thread_id.clone()).await?;
        }
        if overrides_session_policy {
            self.resolve_remaining_session_approval_requests().await?;
        }
        Ok(())
    }

    /// Synara `respondToUserInput` (codexAppServerManager.ts:2838)
    pub async fn respond_to_user_input(
        &mut self,
        request_id: &ApprovalRequestId,
        answers: &ProviderUserInputAnswers,
    ) -> Result<()> {
        self.require_session()?;
        let pending_request = self
            .pending_user_inputs
            .iter()
            .find(|request| &request.request_id == request_id)
            .cloned()
            .ok_or_else(|| anyhow!("Unknown pending user-input request: {request_id}"))?;
        let codex_answers = to_codex_user_input_answers(answers)?;
        self.resolve_user_input_request(&pending_request, codex_answers, false).await
    }

    /// Synara `resolveUserInputRequest` (codexAppServerManager.ts:2852). The pending entry
    /// survives a failed write so the request stays answerable.
    async fn resolve_user_input_request(
        &mut self,
        pending_request: &PendingUserInputRequest,
        codex_answers: Map<String, Value>,
        best_effort: bool,
    ) -> Result<()> {
        let written =
            self.write_message(&json!({ "id": pending_request.json_rpc_id, "result": { "answers": codex_answers } }));
        if let Err(error) = written {
            if !best_effort {
                return Err(error);
            }
        }
        self.pending_user_inputs.retain(|request| request.request_id != pending_request.request_id);

        let mut event = self.base_event(ProviderEventKind::Notification, "item/tool/requestUserInput/answered");
        event.turn_id = pending_request.turn_id.clone();
        event.parent_turn_id = pending_request.parent_turn_id.clone();
        event.item_id = pending_request.item_id.clone();
        event.provider_thread_id = pending_request.provider_thread_id.clone();
        event.provider_parent_thread_id = pending_request.provider_parent_thread_id.clone();
        event.request_id = Some(pending_request.request_id.clone());
        event.payload = Some(json!({ "requestId": pending_request.request_id, "answers": codex_answers }));
        self.emit_event(event).await;
        Ok(())
    }

    fn has_pending_human_requests(&self) -> bool {
        !self.pending_approvals.is_empty() || !self.pending_user_inputs.is_empty()
    }

    /// Synara `settlePendingHumanRequests` (codexAppServerManager.ts:2904): answers every
    /// outstanding human-facing server request (cancel, or no answers), so an abnormal end can
    /// never leave codex parked on an id nobody will answer. `owner` limits it to one provider
    /// thread (and turn).
    async fn settle_pending_human_requests(&mut self, reason: &str, owner: Option<(String, Option<TurnId>)>) {
        let belongs = |provider_thread_id: &Option<String>, turn_id: &Option<TurnId>| match &owner {
            None => true,
            Some((owner_thread, owner_turn)) => {
                provider_thread_id.as_deref() == Some(owner_thread.as_str())
                    && (owner_turn.is_none() || turn_id == owner_turn)
            }
        };
        let (approvals, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.pending_approvals)
            .into_iter()
            .partition(|request| belongs(&request.provider_thread_id, &request.turn_id));
        self.pending_approvals = kept;
        let user_inputs: Vec<_> = self
            .pending_user_inputs
            .iter()
            .filter(|request| belongs(&request.provider_thread_id, &request.turn_id))
            .cloned()
            .collect();
        if approvals.is_empty() && user_inputs.is_empty() {
            return;
        }
        tracing::info!(
            thread_id = %self.session.thread_id,
            reason,
            approvals = approvals.len(),
            user_inputs = user_inputs.len(),
            "settling pending codex human requests"
        );
        for pending_request in approvals {
            let _ = self.resolve_approval_request(&pending_request, ProviderApprovalDecision::Cancel, true).await;
        }
        for pending_request in user_inputs {
            let _ = self.resolve_user_input_request(&pending_request, Map::new(), true).await;
            self.pending_user_inputs.retain(|request| request.request_id != pending_request.request_id);
        }
    }

    /// Not in Synara, whose ProviderService restarts a session for a new mode. Codex takes its
    /// permissions on every `turn/start`, so the next turn runs under the new mode; a deliberate
    /// mode change also ends an "always allow" grant.
    pub fn set_runtime_mode(&mut self, runtime_mode: RuntimeMode) -> Result<()> {
        self.require_session()?;
        self.session_approval_override = None;
        self.update_session(|session| session.runtime_mode = runtime_mode);
        Ok(())
    }

    /// Synara `stopSession` / `stopSessionContext` (codexAppServerManager.ts:2980-3069):
    /// answers parked requests, reports `session/closed`, then closes stdin and ends the process.
    pub async fn stop_session(&mut self) {
        if !self.stopping {
            self.begin_stop().await;
        }
        if !self.exit_reported {
            self.exit_reported = true;
            self.emit_lifecycle_event("session/closed", "Session stopped").await;
        }
        self.teardown_context_process(true).await;
    }

    /// The first half of Synara `stopSessionContext` (codexAppServerManager.ts:2988): pending
    /// requests are rejected, parked server requests answered while stdin is still writable
    /// (time-boxed), and the session marked closed.
    async fn begin_stop(&mut self) {
        self.stopping = true;
        self.requests.reject_all("Session stopped before request completed.");
        if self.has_pending_human_requests() {
            let deadline = Duration::from_millis(CODEX_PENDING_SETTLE_DEADLINE_MS);
            let _ = tokio::time::timeout(deadline, self.settle_pending_human_requests("session stopped", None)).await;
        }
        self.update_session(|session| {
            session.status = ProviderSessionStatus::Closed;
            session.active_turn_id = None;
        });
    }

    /// Synara `teardownContextProcess` (codexAppServerManager.ts:2955): stdin is closed after
    /// what was queued is written, the process group is asked to leave, and (unless the session
    /// loop is to hear it) the exit is awaited.
    async fn teardown_context_process(&mut self, await_exit: bool) {
        if let Some(drained) = self.writer.as_ref().and_then(CodexJsonlWriter::close) {
            let _ = tokio::time::timeout(Duration::from_millis(CODEX_PENDING_SETTLE_DEADLINE_MS), drained).await;
        }
        if let Some(terminate) = self.terminate.get_mut().unwrap().as_mut() {
            terminate();
        }
        if await_exit {
            if let Some(exited) = self.exited.get_mut().unwrap().take() {
                let deadline = Duration::from_millis(CODEX_TEARDOWN_EXIT_DEADLINE_MS);
                if tokio::time::timeout(deadline, exited).await.is_err() {
                    tracing::error!(thread_id = %self.session.thread_id, "codex app-server did not exit after stop");
                }
            }
        }
    }

    /// The next thing the process said, or its exit. Cancel-safe.
    pub async fn next_incoming(&mut self) -> CodexIncoming {
        let Self { incoming, exited, .. } = self;
        let message = async {
            match incoming.as_mut() {
                Some(incoming) => incoming.recv().await,
                None => None,
            }
        };
        let exit = async {
            match exited.get_mut().unwrap().as_mut() {
                Some(exited) => exited.await,
                None => std::future::pending().await,
            }
        };
        let outcome = tokio::select! {
            biased;
            Some(message) = message => Ok(message),
            code = exit => Err(code),
        };
        match outcome {
            Ok(message) => message,
            Err(code) => {
                *self.exited.get_mut().unwrap() = None;
                CodexIncoming::Exited(code)
            }
        }
    }

    /// Handles one [`CodexIncoming`]. Returns false once the session has ended.
    pub async fn handle_incoming(&mut self, incoming: CodexIncoming) -> bool {
        match incoming {
            CodexIncoming::Message(message) => self.handle_stdout_message(message).await,
            CodexIncoming::Stderr(message) => {
                if !self.stopping {
                    self.emit_error_event("process/stderr", &message).await;
                }
            }
            CodexIncoming::TransportFailure { message, reason } => {
                self.handle_transport_failure(message, reason).await;
            }
            CodexIncoming::Exited(code) => {
                self.handle_exit(code).await;
                return false;
            }
        }
        !self.is_finished()
    }

    /// The `exit` listener of `attachProcessListeners` (codexAppServerManager.ts:3908).
    async fn handle_exit(&mut self, code: Option<i32>) {
        if self.stopping && !self.failure_stopping {
            return;
        }
        // What the process wrote before it left is still worth reading.
        let deadline = tokio::time::Instant::now() + Duration::from_millis(CODEX_EXIT_DRAIN_DEADLINE_MS);
        if let Some(writer) = self.writer.as_ref() {
            writer.close();
        }
        loop {
            let Some(incoming) = self.incoming.as_mut() else { break };
            match tokio::time::timeout_at(deadline, incoming.recv()).await {
                Ok(Some(CodexIncoming::Message(message))) => self.handle_stdout_message(message).await,
                Ok(Some(CodexIncoming::Stderr(message))) => self.emit_error_event("process/stderr", &message).await,
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => break,
            }
        }
        let message = format!(
            "codex app-server exited (code={}, signal={}).",
            code.map(|code| code.to_string()).unwrap_or_else(|| "null".into()),
            if code.is_none() { "unknown" } else { "null" }
        );
        self.requests.reject_all(&message);
        // The child is gone, so the answers cannot land; settling still clears the maps and
        // reports the resolutions that close the pending cards.
        self.settle_pending_human_requests("session exited", None).await;
        self.stopping = true;
        self.update_session(|session| {
            session.status = ProviderSessionStatus::Closed;
            session.active_turn_id = None;
            if code != Some(0) {
                session.last_error = Some(message.clone());
            }
        });
        self.exit_reported = true;
        self.emit_lifecycle_event("session/exited", &message).await;
    }

    /// Synara `handleTransportFailure` (codexAppServerManager.ts:3938)
    async fn handle_transport_failure(&mut self, message: String, _reason: Option<CodexAppServerTransportErrorReason>) {
        if self.stopping || self.terminal_failure.is_some() {
            return;
        }
        let pending_methods = self.requests.pending_methods();
        let operation = pending_methods
            .iter()
            .find(|method| *method == "thread/resume" || *method == "thread/fork")
            .cloned()
            .or_else(|| (pending_methods.len() == 1).then(|| pending_methods[0].clone()));
        let message = match operation {
            Some(operation) => format!("{message} Operation: {operation}."),
            None => message,
        };
        self.terminal_failure = Some(message.clone());
        self.requests.reject_all(&message);
        self.update_session(|session| {
            session.status = ProviderSessionStatus::Error;
            session.last_error = Some(message.clone());
        });
        self.emit_error_event("protocol/transportError", &message).await;
        self.stop_failed_context().await;
    }

    /// Synara `stopFailedContext` (codexAppServerManager.ts:3976): the process is ended, and its
    /// exit is still reported as `session/exited`.
    async fn stop_failed_context(&mut self) {
        self.failure_stopping = true;
        if !self.stopping {
            self.begin_stop().await;
        }
        self.teardown_context_process(false).await;
    }

    /// Synara `handleStdoutLine` (codexAppServerManager.ts:3989), after the reader has settled
    /// responses: a server request, a notification, or an unknown shape.
    async fn handle_stdout_message(&mut self, message: Value) {
        if self.stopping && !self.failure_stopping {
            return;
        }
        let method = message.get("method").and_then(Value::as_str).map(str::to_string);
        let id = message.get("id").filter(|id| id.is_string() || id.is_number()).cloned();
        match (method, id) {
            (Some(method), Some(id)) => {
                let params = message.get("params").cloned();
                if let Err(error) = self.handle_server_request(id, &method, params).await {
                    self.handle_transport_failure(error.to_string(), None).await;
                }
            }
            (Some(method), None) if message.get("id").is_none() => {
                self.handle_server_notification(&method, message.get("params").cloned()).await;
            }
            _ => {
                self.emit_error_event("protocol/unrecognizedMessage", "Received protocol message in an unknown shape.")
                    .await;
            }
        }
    }

    /// Synara `handleServerNotification` (codexAppServerManager.ts:4039)
    async fn handle_server_notification(&mut self, method: &str, params: Option<Value>) {
        let raw_route = read_route_fields(params.as_ref());
        self.remember_collab_receiver_turns(params.as_ref(), raw_route.turn_id.as_ref());
        let route = self.resolve_collaboration_route(params.as_ref());
        if route.is_child_conversation && should_suppress_child_conversation_notification(method) {
            return;
        }
        let text_delta =
            (method == "item/agentMessage/delta").then(|| read_string(params.as_ref(), "delta").map(str::to_string)).flatten();
        let terminal_error_message = (method == "error")
            .then(|| {
                read_string(read_object(params.as_ref(), "error"), "message").map(normalize_codex_user_visible_error_message)
            })
            .flatten();
        let terminal_error_will_retry = method == "error" && read_boolean(params.as_ref(), "willRetry") == Some(true);

        let mut event = self.base_event(ProviderEventKind::Notification, method);
        event.turn_id = raw_route.turn_id.clone();
        event.parent_turn_id = route.parent_turn_id.clone();
        event.item_id = raw_route.item_id.clone();
        event.provider_thread_id = route.provider_thread_id.clone();
        event.provider_parent_thread_id = route.provider_parent_thread_id.clone();
        event.text_delta = text_delta;
        event.payload = params.clone();
        self.emit_event(event).await;

        match method {
            "thread/started" => {
                let started = normalize_provider_thread_id(read_string(read_object(params.as_ref(), "thread"), "id"));
                if let (Some(started), false) = (started, route.is_child_conversation) {
                    self.update_session(|session| session.resume_cursor = Some(json!({ "threadId": started })));
                }
            }
            "thread/compacted" => {
                // Compaction is the only work that can hold the session "running" without a turn.
                if !route.is_child_conversation
                    && self.session.active_turn_id.is_none()
                    && self.session.status == ProviderSessionStatus::Running
                {
                    self.update_session(|session| session.status = ProviderSessionStatus::Ready);
                }
            }
            "turn/started" => {
                if route.is_child_conversation {
                    return;
                }
                let turn_id = to_turn_id(read_string(read_object(params.as_ref(), "turn"), "id"));
                let interaction_mode = self.active_interaction_mode;
                self.update_session(|session| {
                    session.status = ProviderSessionStatus::Running;
                    session.active_turn_id = turn_id;
                });
                if self.session.active_turn_id.is_some() {
                    self.active_interaction_mode = interaction_mode;
                }
            }
            "turn/completed" => {
                if route.is_child_conversation {
                    return;
                }
                self.collab_receiver_turns.clear();
                self.collab_receiver_parents.clear();
                let turn = read_object(params.as_ref(), "turn");
                let failed = read_string(turn, "status") == Some("failed");
                let error_message =
                    read_string(read_object(turn, "error"), "message").map(normalize_codex_user_visible_error_message);
                self.update_session(|session| {
                    session.status = if failed { ProviderSessionStatus::Error } else { ProviderSessionStatus::Ready };
                    session.active_turn_id = None;
                    if error_message.is_some() {
                        session.last_error = error_message;
                    }
                });
            }
            "turn/aborted" => {
                if route.is_child_conversation {
                    return;
                }
                self.collab_receiver_turns.clear();
                self.collab_receiver_parents.clear();
                self.update_session(|session| {
                    session.status = ProviderSessionStatus::Ready;
                    session.active_turn_id = None;
                    session.last_error = None;
                });
            }
            "error" => {
                if route.is_child_conversation {
                    return;
                }
                if terminal_error_will_retry {
                    // Only a live turn may restore "running".
                    if self.session.active_turn_id.is_some() {
                        self.update_session(|session| session.status = ProviderSessionStatus::Running);
                    }
                    return;
                }
                if terminal_error_message.as_deref().is_some_and(is_non_fatal_codex_error_message) {
                    return;
                }
                self.update_session(|session| {
                    session.status = ProviderSessionStatus::Error;
                    if terminal_error_message.is_some() {
                        session.last_error = terminal_error_message;
                    }
                });
            }
            _ => {}
        }
    }

    /// Synara `handleServerRequest` (codexAppServerManager.ts:4312), without the gateway's
    /// auto-approval of Synara's own MCP tools.
    async fn handle_server_request(&mut self, id: Value, method: &str, params: Option<Value>) -> Result<()> {
        let raw_route = read_route_fields(params.as_ref());
        let route = self.resolve_collaboration_route(params.as_ref());
        let is_mcp_tool_call_approval = method == MCP_SERVER_ELICITATION_REQUEST_METHOD
            && read_string(read_object(params.as_ref(), "_meta"), "codex_approval_kind") == Some(MCP_TOOL_CALL_APPROVAL_KIND);
        if method == MCP_SERVER_ELICITATION_REQUEST_METHOD && !is_mcp_tool_call_approval {
            // An elicitation form has no UI here; it is declined, which Codex reports to the tool.
            self.write_message(&json!({ "id": id, "result": { "action": "decline", "content": null, "_meta": null } }))?;
            self.emit_error_event(
                "mcpServer/elicitation/request/unrenderable",
                "Cascade declined an MCP elicitation it cannot render yet.",
            )
            .await;
            return Ok(());
        }

        let request_kind =
            if is_mcp_tool_call_approval { Some(ProviderRequestKind::Tool) } else { request_kind_for_method(method) };
        let mut request_id = None;
        let mcp_session_persistence_advertised = is_mcp_tool_call_approval.then(|| {
            match params.as_ref().and_then(|params| params.get("_meta")).and_then(|meta| meta.get("persist")) {
                Some(Value::String(persist)) => persist == "session",
                Some(Value::Array(values)) => values.iter().any(|value| value == "session"),
                _ => false,
            }
        });
        if let Some(request_kind) = request_kind {
            let approval_id = ApprovalRequestId::new(Uuid::new_v4().to_string());
            let pending_request = PendingApprovalRequest {
                request_id: approval_id.clone(),
                json_rpc_id: id.clone(),
                method: method.to_string(),
                request_kind,
                turn_id: raw_route.turn_id.clone(),
                parent_turn_id: route.parent_turn_id.clone(),
                item_id: raw_route.item_id.clone(),
                provider_thread_id: route.provider_thread_id.clone(),
                provider_parent_thread_id: route.provider_parent_thread_id.clone(),
                requested_permissions: (method == "item/permissions/requestApproval")
                    .then(|| read_object(params.as_ref(), "permissions").and_then(Value::as_object).cloned())
                    .flatten(),
                mcp_session_persistence_advertised,
            };
            // A session grant answers the command/file prompts it came from.
            if self.session_approval_override.is_some() && approval_session_grant_widens_session_policy(Some(request_kind)) {
                return self
                    .resolve_approval_request(&pending_request, ProviderApprovalDecision::AcceptForSession, false)
                    .await;
            }
            self.pending_approvals.push(pending_request);
            request_id = Some(approval_id);
        }

        let is_user_input_request = method == "item/tool/requestUserInput";
        // Parsed up front: a request whose questions cannot be shown must never become a pending
        // entry, because nothing would ever answer its id.
        let user_input_questions =
            if is_user_input_request { parse_codex_user_input_questions(params.as_ref()) } else { None };
        if user_input_questions.is_some() {
            let input_id = ApprovalRequestId::new(Uuid::new_v4().to_string());
            self.pending_user_inputs.push(PendingUserInputRequest {
                request_id: input_id.clone(),
                json_rpc_id: id.clone(),
                turn_id: raw_route.turn_id.clone(),
                parent_turn_id: route.parent_turn_id.clone(),
                item_id: raw_route.item_id.clone(),
                provider_thread_id: route.provider_thread_id.clone(),
                provider_parent_thread_id: route.provider_parent_thread_id.clone(),
            });
            request_id = Some(input_id);
        }

        let mut event = self.base_event(ProviderEventKind::Request, method);
        event.turn_id = raw_route.turn_id.clone();
        event.parent_turn_id = route.parent_turn_id.clone();
        event.item_id = raw_route.item_id.clone();
        event.provider_thread_id = route.provider_thread_id.clone();
        event.provider_parent_thread_id = route.provider_parent_thread_id.clone();
        event.request_id = request_id;
        event.request_kind = request_kind;
        // An MCP approval that did not advertise session persistence cannot honour "always allow".
        event.payload = if is_mcp_tool_call_approval && mcp_session_persistence_advertised != Some(true) {
            let mut payload = params.as_ref().and_then(Value::as_object).cloned().unwrap_or_default();
            payload.insert("sessionApprovalAvailable".into(), json!(false));
            Some(Value::Object(payload))
        } else {
            params.clone()
        };
        self.emit_event(event).await;

        if request_kind.is_some() {
            return Ok(());
        }
        if is_user_input_request {
            if user_input_questions.is_some() {
                // Intentionally unanswered: a human replies through respond_to_user_input.
                return Ok(());
            }
            self.emit_error_event(
                "item/tool/requestUserInput/unrenderable",
                "Codex asked a question Cascade could not render, so it was declined.",
            )
            .await;
            return self.write_message(&json!({
                "id": id,
                "error": { "code": -32602, "message": "item/tool/requestUserInput did not include a renderable question." },
            }));
        }
        // Dynamic tools, auth-token refresh and every other server request are not offered.
        self.write_message(&json!({
            "id": id,
            "error": { "code": -32601, "message": format!("Unsupported server request: {method}") },
        }))
    }

    /// Synara `sendRequest` (codexAppServerManager.ts:4512)
    async fn send_request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = json!(self.next_request_id);
        self.next_request_id += 1;
        let outcome = self.requests.register(&id, method).map_err(|message| anyhow!(message))?;
        if let Err(error) = self.write_message(&json_rpc_request(&id, method, &params)) {
            self.requests.forget(&id);
            return Err(error);
        }
        match tokio::time::timeout(Duration::from_millis(JSONRPC_STDIO_REQUEST_TIMEOUT_MS), outcome).await {
            Ok(Ok(Ok(result))) => Ok(result),
            Ok(Ok(Err(message))) => Err(anyhow!(message)),
            Ok(Err(_)) => Err(anyhow!("Session stopped before request completed.")),
            Err(_) => {
                self.requests.forget(&id);
                Err(anyhow!(request_timeout_message(method)))
            }
        }
    }

    /// Synara `writeMessage` (codexAppServerManager.ts:4558)
    fn write_message(&self, message: &Value) -> Result<()> {
        let writer = self.writer.as_ref().ok_or_else(|| anyhow!("Codex app-server stdin closed during write"))?;
        writer.write(message).map_err(|error: CodexAppServerTransportError| anyhow!(error))
    }

    /// Synara `markSessionReadyAfterThreadOpen` (codexAppServerManager.ts:4565)
    async fn mark_session_ready_after_thread_open(&mut self, thread_open_method: &str, provider_thread_id: &str) {
        self.update_session(|session| {
            session.status = ProviderSessionStatus::Ready;
            session.resume_cursor = Some(json!({ "threadId": provider_thread_id }));
        });
        self.emit_lifecycle_event("session/threadOpenResolved", &format!("Codex {thread_open_method} resolved."))
            .await;
        self.emit_lifecycle_event("session/ready", &format!("Connected to thread {provider_thread_id}")).await;
        // Resume/fork do not notify session start; emit it so idle-stop re-arms.
        self.emit_lifecycle_event("session/started", &format!("Codex session ready for thread {provider_thread_id}"))
            .await;
    }

    fn base_event(&self, kind: ProviderEventKind, method: &str) -> ProviderEvent {
        ProviderEvent {
            id: EventId::new(Uuid::new_v4().to_string()),
            kind,
            provider: ProviderDriverKind::from(ProviderKind::Codex),
            provider_instance_id: self.session.provider_instance_id.clone(),
            thread_id: self.session.thread_id.clone(),
            created_at: now_iso(),
            method: method.to_string(),
            message: None,
            turn_id: None,
            parent_turn_id: None,
            item_id: None,
            request_id: None,
            request_kind: None,
            lifecycle_generation: self.lifecycle_generation.clone(),
            provider_thread_id: None,
            provider_parent_thread_id: None,
            text_delta: None,
            payload: None,
        }
    }

    /// Synara `emitLifecycleEvent` (codexAppServerManager.ts:4595)
    async fn emit_lifecycle_event(&self, method: &str, message: &str) {
        let mut event = self.base_event(ProviderEventKind::Session, method);
        event.message = Some(message.to_string());
        self.emit_event(event).await;
    }

    /// Synara `emitErrorEvent` (codexAppServerManager.ts:4616)
    async fn emit_error_event(&self, method: &str, message: &str) {
        let mut event = self.base_event(ProviderEventKind::Error, method);
        event.message = Some(message.to_string());
        self.emit_event(event).await;
    }

    async fn emit_event(&self, event: ProviderEvent) {
        let _ = self.events.send(event).await;
    }

    /// Synara `updateSession` (codexAppServerManager.ts:4778)
    fn update_session(&mut self, update: impl FnOnce(&mut ProviderSession)) {
        update(&mut self.session);
        self.session.updated_at = now_iso();
        if self.session.active_turn_id.is_none() || self.session.status != ProviderSessionStatus::Running {
            self.active_interaction_mode = None;
        }
    }

    /// Synara `resolveCodexTurnOverrides` (codexAppServerManager.ts:827): "always allow" is live
    /// session state, re-sent on every turn.
    fn resolve_codex_turn_overrides(&self) -> CodexTurnOverrides {
        self.session_approval_override
            .unwrap_or_else(|| map_codex_runtime_mode_to_turn_overrides(self.session.runtime_mode))
    }

    /// Synara `resolveCollaborationRoute` (codexAppServerManager.ts:4957)
    fn resolve_collaboration_route(&self, params: Option<&Value>) -> ResolvedCollaborationRoute {
        let conversation_id = read_provider_conversation_id(params);
        let parent_turn_id =
            conversation_id.as_ref().and_then(|id| self.collab_receiver_turns.get(id)).cloned();
        let provider_thread_id = normalize_provider_thread_id(conversation_id.as_deref());
        let mapped_provider_parent_thread_id =
            conversation_id.as_ref().and_then(|id| self.collab_receiver_parents.get(id)).cloned();
        let active_provider_thread_id = self.provider_thread_id();
        // A child can speak before its collab tool call populates the maps: during a live turn,
        // another provider thread belongs to that turn's conversation.
        let is_unmapped_child_conversation = mapped_provider_parent_thread_id.is_none()
            && self.session.status == ProviderSessionStatus::Running
            && self.session.active_turn_id.is_some()
            && provider_thread_id.is_some()
            && active_provider_thread_id.is_some()
            && provider_thread_id != active_provider_thread_id;
        let provider_parent_thread_id = mapped_provider_parent_thread_id
            .clone()
            .or_else(|| is_unmapped_child_conversation.then(|| active_provider_thread_id.clone()).flatten());
        ResolvedCollaborationRoute {
            is_child_conversation: parent_turn_id.is_some()
                || provider_parent_thread_id.is_some()
                || is_unmapped_child_conversation,
            parent_turn_id,
            provider_thread_id,
            provider_parent_thread_id,
        }
    }

    /// Synara `rememberCollabReceiverTurns` (codexAppServerManager.ts:5014)
    fn remember_collab_receiver_turns(&mut self, params: Option<&Value>, parent_turn_id: Option<&TurnId>) {
        let Some(parent_turn_id) = parent_turn_id else { return };
        let Some(payload) = params.and_then(Value::as_object) else { return };
        let item = payload.get("item").and_then(Value::as_object).unwrap_or(payload);
        let item_type = item.get("type").or_else(|| item.get("kind")).and_then(Value::as_str);
        if item_type != Some("collabAgentToolCall") && item_type != Some("collabToolCall") {
            return;
        }
        let parent_provider_thread_id = normalize_provider_thread_id(read_provider_conversation_id(params).as_deref());
        for receiver_thread_id in decode_subagent_receiver_thread_ids(item) {
            self.collab_receiver_turns.insert(receiver_thread_id.clone(), parent_turn_id.clone());
            if let Some(parent) = &parent_provider_thread_id {
                self.collab_receiver_parents.insert(receiver_thread_id, parent.clone());
            }
        }
    }
}

/// The stdout and stderr listeners of Synara `attachProcessListeners`
/// (codexAppServerManager.ts:3854). Responses settle their requests here; everything else goes
/// to the session in order.
fn attach_process_listeners(
    mut stdout: std::pin::Pin<Box<dyn AsyncRead + Send>>,
    stderr: Option<std::pin::Pin<Box<dyn AsyncRead + Send>>>,
    requests: JsonRpcStdioRequestRegistry,
    incoming: mpsc::UnboundedSender<CodexIncoming>,
) {
    let stdout_incoming = incoming.clone();
    tokio::spawn(async move {
        let mut framer = CodexJsonlFramer::default();
        let mut buffer = vec![0_u8; 64 * 1024];
        let failure = loop {
            match stdout.read(&mut buffer).await {
                Ok(0) => {
                    break match framer.finish() {
                        Ok(()) => CodexAppServerTransportError::new(
                            CodexAppServerTransportErrorReason::ReadClosed,
                            framer.max_frame_bytes,
                            0,
                        ),
                        Err(error) => error,
                    };
                }
                Ok(read) => match framer.push(&buffer[..read]) {
                    Ok(lines) => {
                        for line in lines {
                            route_stdout_line(&line, &requests, &stdout_incoming);
                        }
                    }
                    Err(error) => break error,
                },
                Err(error) => {
                    let message = format!("Codex app-server transport failed: {error}");
                    requests.reject_all(&message);
                    let _ = stdout_incoming.send(CodexIncoming::TransportFailure { message, reason: None });
                    return;
                }
            }
        };
        let message = failure.to_string();
        requests.reject_all(&message);
        let _ = stdout_incoming.send(CodexIncoming::TransportFailure { message, reason: Some(failure.reason) });
    });

    if let Some(stderr) = stderr {
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Some(message) = classify_codex_stderr_line(&line) {
                    let _ = incoming.send(CodexIncoming::Stderr(message));
                }
            }
        });
    }
}

/// The parsing half of Synara `handleStdoutLine` (codexAppServerManager.ts:3989) and its
/// `handleResponse` (codexAppServerManager.ts:4497).
fn route_stdout_line(raw_line: &str, requests: &JsonRpcStdioRequestRegistry, incoming: &mpsc::UnboundedSender<CodexIncoming>) {
    let line = normalize_codex_process_line(raw_line);
    if is_ignorable_codex_process_line(&line) {
        return;
    }
    // App-server stdout is JSONL, but subprocesses and hooks can leak arbitrary output onto the
    // same pipe; only JSON-RPC-shaped envelopes belong to app-server itself.
    let Ok(parsed) = serde_json::from_str::<Value>(raw_line) else {
        tracing::warn!(preview = %line.chars().take(160).collect::<String>(), "ignoring non-protocol codex app-server stdout");
        return;
    };
    let Some(envelope) = parsed.as_object().filter(|value| is_codex_protocol_envelope(value)) else {
        tracing::warn!(preview = %line.chars().take(160).collect::<String>(), "ignoring JSON without a JSON-RPC envelope on codex stdout");
        return;
    };
    let has_id = envelope.get("id").is_some_and(|id| id.is_string() || id.is_number());
    let has_method = envelope.get("method").is_some_and(Value::is_string);
    if has_id && !has_method {
        // Only an error carrying a message rejects a request; older builds sent bare codes.
        let error = envelope.get("error").and_then(|error| {
            let message = error.get("message").and_then(Value::as_str)?.to_string();
            Some(JsonRpcError {
                code: error.get("code").and_then(Value::as_i64),
                message: Some(message),
                data: error.get("data").cloned(),
            })
        });
        requests.handle_response(&envelope["id"], envelope.get("result").cloned(), error);
        return;
    }
    let _ = incoming.send(CodexIncoming::Message(parsed));
}

/// Synara `requestKindForMethod` (codexAppServerManager.ts:4789)
fn request_kind_for_method(method: &str) -> Option<ProviderRequestKind> {
    match method {
        "item/commandExecution/requestApproval" => Some(ProviderRequestKind::Command),
        "item/fileRead/requestApproval" => Some(ProviderRequestKind::FileRead),
        "item/fileChange/requestApproval" => Some(ProviderRequestKind::FileChange),
        "item/permissions/requestApproval" => Some(ProviderRequestKind::Permissions),
        _ => None,
    }
}

/// Synara `readRouteFields` (codexAppServerManager.ts:4917)
fn read_route_fields(params: Option<&Value>) -> RouteFields {
    let message = read_object(params, "msg");
    RouteFields {
        turn_id: to_turn_id(
            read_string(params, "turnId")
                .or_else(|| read_string(read_object(params, "turn"), "id"))
                .or_else(|| read_string(message, "turn_id"))
                .or_else(|| read_string(message, "turnId")),
        ),
        item_id: to_provider_item_id(
            read_string(params, "itemId")
                .or_else(|| read_string(params, "targetItemId"))
                .or_else(|| read_string(read_object(params, "item"), "id")),
        ),
    }
}

/// Synara `readProviderConversationId` (codexAppServerManager.ts:4949)
fn read_provider_conversation_id(params: Option<&Value>) -> Option<String> {
    read_string(params, "threadId")
        .or_else(|| read_string(read_object(params, "thread"), "id"))
        .or_else(|| read_string(params, "conversationId"))
        .map(str::to_string)
}

/// Synara `shouldSuppressChildConversationNotification` (codexAppServerManager.ts:5041). Plan
/// updates are kept even for a child, so the plan card advances.
fn should_suppress_child_conversation_notification(method: &str) -> bool {
    matches!(
        method,
        "thread/started"
            | "thread/status/changed"
            | "thread/archived"
            | "thread/unarchived"
            | "thread/closed"
            | "thread/compacted"
            | "thread/name/updated"
            | "thread/tokenUsage/updated"
            | "turn/started"
            | "turn/completed"
            | "turn/aborted"
    )
}

/// Synara `isTurnAlreadyIdleError` (codexAppServerManager.ts:5127):
/// `/turn\/interrupt[^\n]*no active turn(?: to interrupt)?/i`.
fn is_turn_already_idle_error(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.lines().any(|line| {
        line.find("turn/interrupt").is_some_and(|at| line[at..].contains("no active turn"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_field_message_survives_text_whose_lowercase_changes_length() {
        assert_eq!(
            normalize_codex_user_visible_error_message("İİİ Failed to parse function arguments: duplicate field `path`"),
            "Tool call failed because the same argument was sent twice (path)."
        );
    }

    #[test]
    fn runtime_modes_map_to_codex_permissions() {
        assert_eq!(
            map_codex_runtime_mode(RuntimeMode::ApprovalRequired),
            CodexThreadModeOverrides { approval_policy: "untrusted", approvals_reviewer: "user", sandbox: "read-only" }
        );
        assert_eq!(
            map_codex_runtime_mode(RuntimeMode::Auto),
            CodexThreadModeOverrides {
                approval_policy: "on-request",
                approvals_reviewer: "auto_review",
                sandbox: "workspace-write"
            }
        );
        assert_eq!(
            map_codex_runtime_mode(RuntimeMode::FullAccess),
            CodexThreadModeOverrides {
                approval_policy: "never",
                approvals_reviewer: "user",
                sandbox: "danger-full-access"
            }
        );
        let sandbox_types: Vec<_> = [RuntimeMode::ApprovalRequired, RuntimeMode::Auto, RuntimeMode::FullAccess]
            .into_iter()
            .map(|mode| map_codex_runtime_mode_to_turn_overrides(mode).sandbox_policy_type)
            .collect();
        assert_eq!(sandbox_types, ["readOnly", "workspaceWrite", "dangerFullAccess"]);
    }

    #[test]
    fn thread_open_requests_follow_the_cursor() {
        let overrides = CodexThreadSessionOverrides {
            model: None,
            service_tier: None,
            cwd: "/work".into(),
            mode: map_codex_runtime_mode(RuntimeMode::ApprovalRequired),
        };
        let start = build_codex_thread_open_request(None, None, &overrides).unwrap();
        assert_eq!(start.method, "thread/start");
        assert_eq!(
            start.params,
            json!({
                "model": null, "cwd": "/work", "approvalPolicy": "untrusted",
                "approvalsReviewer": "user", "sandbox": "read-only", "experimentalRawEvents": false
            })
        );
        let resume = build_codex_thread_open_request(None, Some("thr_1"), &overrides).unwrap();
        assert_eq!(resume.method, "thread/resume");
        assert_eq!(resume.params["threadId"], "thr_1");
        assert_eq!(resume.params["excludeTurns"], true);
        assert!(build_codex_thread_open_request(Some("a"), Some("b"), &overrides).is_err());
        assert_eq!(read_resume_cursor_thread_id(Some(&json!({ "threadId": " thr_2 " }))), Some("thr_2".into()));
    }

    #[test]
    fn resume_errors_that_can_fall_back_are_recognised() {
        assert!(is_recoverable_thread_resume_error("thread/resume failed: thread not found"));
        assert!(!is_recoverable_thread_resume_error("thread/start failed: not found"));
        assert!(!is_recoverable_thread_resume_error("thread/resume failed: permission denied"));
        assert!(is_turn_already_idle_error("turn/interrupt failed: no active turn to interrupt"));
    }

    #[test]
    fn stderr_lines_are_classified() {
        assert_eq!(classify_codex_stderr_line("2026-10-05T10:00:00Z  INFO codex: started"), None);
        assert_eq!(
            classify_codex_stderr_line("2026-10-05T10:00:00Z ERROR codex: \u{1b}[31mboom\u{1b}[0m"),
            Some("2026-10-05T10:00:00Z ERROR codex: boom".into())
        );
        assert_eq!(classify_codex_stderr_line("^CToken usage: 12"), None);
        assert_eq!(classify_codex_stderr_line("plain failure"), Some("plain failure".into()));
    }

    #[test]
    fn user_input_questions_are_parsed_leniently() {
        let questions = parse_codex_user_input_questions(Some(&json!({
            "questions": [
                { "id": "q1", "header": "Scope", "question": "Which?", "options": [{ "label": "A" }, { "label": "B", "description": "bee" }] },
                { "id": "", "header": "x", "question": "y" }
            ]
        })))
        .unwrap();
        assert_eq!(questions.len(), 1);
        assert_eq!(questions[0].options[0].description, "A");
        assert_eq!(questions[0].options[1].description, "bee");
        assert!(parse_codex_user_input_questions(Some(&json!({ "questions": [] }))).is_none());
    }

    #[test]
    fn plan_mode_builds_a_collaboration_mode() {
        let mode = build_codex_collaboration_mode(Some(ProviderInteractionMode::Plan), Some("gpt-x"), None).unwrap();
        assert_eq!(mode["mode"], "plan");
        assert_eq!(mode["settings"]["model"], "gpt-x");
        assert_eq!(mode["settings"]["reasoning_effort"], "medium");
        assert!(build_codex_collaboration_mode(None, Some("gpt-x"), None).is_none());
    }

    #[test]
    fn spark_is_swapped_for_plans_without_it() {
        let plus = read_codex_account_snapshot(&json!({ "account": { "type": "chatgpt", "planType": "plus" } }));
        assert!(!plus.spark_enabled);
        assert_ne!(resolve_codex_model_for_account(Some(CODEX_SPARK_MODEL.into()), &plus).as_deref(), Some(CODEX_SPARK_MODEL));
        let pro = read_codex_account_snapshot(&json!({ "account": { "type": "chatgpt", "planType": "pro" } }));
        assert_eq!(resolve_codex_model_for_account(Some(CODEX_SPARK_MODEL.into()), &pro).as_deref(), Some(CODEX_SPARK_MODEL));
    }
}
