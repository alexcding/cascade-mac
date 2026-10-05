//! The `claude` stream-json wire, which Synara reaches through `@anthropic-ai/claude-agent-sdk`
//! (0.3.259, `sdk.mjs`): the launch arguments `ProcessTransport` builds, the lines written to
//! the CLI's stdin, and the lines it prints on stdout. One JSON object per line both ways.
//!
//! - stdin: user messages (`{"type":"user",...}`), our `control_request`s (`initialize`,
//!   `interrupt`, `set_permission_mode`, `set_model`, `apply_flag_settings`), and our
//!   `control_response`s to the CLI's requests.
//! - stdout: SDK messages (`system`, `assistant`, `user`, `stream_event`, `result`, ...), the
//!   CLI's `control_request`s (`can_use_tool`, and kinds this crate does not serve),
//!   `control_cancel_request`s, `control_response`s to ours, and `keep_alive`.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Map, Value};

/// What the CLI is launched with: the subset of the SDK's `Options` the adapter sets.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClaudeLaunchOptions {
    pub model: Option<String>,
    /// `--effort`. The SDK passes only `max` here; lower levels ride in `settings.effortLevel`.
    pub effort: Option<String>,
    pub max_thinking_tokens: Option<u64>,
    pub permission_mode: Option<String>,
    pub allow_dangerously_skip_permissions: bool,
    pub resume: Option<String>,
    pub session_id: Option<String>,
    pub resume_session_at: Option<String>,
    pub fork_session: bool,
    pub include_partial_messages: bool,
    pub additional_directories: Vec<String>,
    /// The flag-settings layer (`--settings <json>`).
    pub settings: Option<Map<String, Value>>,
}

/// Synara `CLAUDE_SETTING_SOURCES` (ClaudeAdapter.ts:1359)
pub const CLAUDE_SETTING_SOURCES: &[&str] = &["user", "project", "local"];

/// The arguments `ProcessTransport` passes the CLI, in its order, for a session whose
/// permissions are answered over stdio (`canUseTool`).
pub fn launch_args(options: &ClaudeLaunchOptions) -> Vec<String> {
    let mut args: Vec<String> =
        ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]
            .into_iter()
            .map(str::to_owned)
            .collect();
    if let Some(tokens) = options.max_thinking_tokens {
        args.extend(["--max-thinking-tokens".to_owned(), tokens.to_string()]);
    }
    if let Some(effort) = &options.effort {
        args.extend(["--effort".to_owned(), effort.clone()]);
    }
    if let Some(model) = &options.model {
        args.extend(["--model".to_owned(), model.clone()]);
    }
    args.extend(["--permission-prompt-tool".to_owned(), "stdio".to_owned()]);
    if let Some(resume) = &options.resume {
        args.push(format!("--resume={resume}"));
    }
    args.push(format!("--setting-sources={}", CLAUDE_SETTING_SOURCES.join(",")));
    if let Some(mode) = &options.permission_mode {
        args.extend(["--permission-mode".to_owned(), mode.clone()]);
    }
    if options.allow_dangerously_skip_permissions {
        args.push("--allow-dangerously-skip-permissions".to_owned());
    }
    if options.include_partial_messages {
        args.push("--include-partial-messages".to_owned());
    }
    for directory in &options.additional_directories {
        args.extend(["--add-dir".to_owned(), directory.clone()]);
    }
    if options.fork_session {
        args.push("--fork-session".to_owned());
    }
    if let Some(at) = &options.resume_session_at {
        args.push(format!("--resume-session-at={at}"));
    }
    if let Some(session_id) = &options.session_id {
        args.push(format!("--session-id={session_id}"));
    }
    if let Some(settings) = &options.settings {
        args.extend(["--settings".to_owned(), Value::Object(settings.clone()).to_string()]);
    }
    args
}

/// One line for the CLI's stdin.
pub fn encode_line(value: &Value) -> Vec<u8> {
    let mut line = value.to_string().into_bytes();
    line.push(b'\n');
    line
}

/// Synara `buildUserMessage` (ClaudeAdapter.ts:1480): an `SDKUserMessage` carrying content blocks.
pub fn user_message(content: Vec<Value>) -> Value {
    json!({
        "type": "user",
        "session_id": "",
        "parent_tool_use_id": null,
        "message": { "role": "user", "content": content },
    })
}

/// The requests the adapter makes of the CLI (`Query.request` in the SDK).
#[derive(Clone, Debug, PartialEq)]
pub enum ControlRequest {
    Initialize { append_system_prompt: Option<String> },
    Interrupt,
    SetPermissionMode { mode: String },
    SetModel { model: Option<String> },
    ApplyFlagSettings { settings: Map<String, Value> },
}

impl ControlRequest {
    pub fn subtype(&self) -> &'static str {
        match self {
            Self::Initialize { .. } => "initialize",
            Self::Interrupt => "interrupt",
            Self::SetPermissionMode { .. } => "set_permission_mode",
            Self::SetModel { .. } => "set_model",
            Self::ApplyFlagSettings { .. } => "apply_flag_settings",
        }
    }

    fn body(&self) -> Value {
        let mut body = Map::new();
        body.insert("subtype".into(), json!(self.subtype()));
        match self {
            Self::Initialize { append_system_prompt } => {
                if let Some(append) = append_system_prompt {
                    body.insert("appendSystemPrompt".into(), json!(append));
                }
            }
            Self::Interrupt => {}
            Self::SetPermissionMode { mode } => {
                body.insert("mode".into(), json!(mode));
            }
            Self::SetModel { model } => {
                body.insert("model".into(), json!(model));
            }
            Self::ApplyFlagSettings { settings } => {
                body.insert("settings".into(), Value::Object(settings.clone()));
            }
        }
        Value::Object(body)
    }
}

/// `{"type":"control_request","request_id":ID,"request":{...}}`
pub fn control_request(request_id: &str, request: &ControlRequest) -> Value {
    json!({ "type": "control_request", "request_id": request_id, "request": request.body() })
}

/// The answer to one of the CLI's requests.
pub fn control_response_success(request_id: &str, response: Value) -> Value {
    json!({
        "type": "control_response",
        "response": { "subtype": "success", "request_id": request_id, "response": response },
    })
}

pub fn control_response_error(request_id: &str, error: &str) -> Value {
    json!({
        "type": "control_response",
        "response": { "subtype": "error", "request_id": request_id, "error": error },
    })
}

/// The SDK's `PermissionResult`, the answer to `can_use_tool`.
#[derive(Clone, Debug, PartialEq)]
pub enum PermissionResult {
    Allow { updated_input: Value, updated_permissions: Option<Vec<Value>> },
    Deny { message: String },
}

impl PermissionResult {
    /// What `processControlRequest` writes back: the result plus the `toolUseID` it answers.
    pub fn to_response(&self, tool_use_id: Option<&str>) -> Value {
        let mut response = match self {
            Self::Allow { updated_input, updated_permissions } => {
                let mut map = Map::new();
                map.insert("behavior".into(), json!("allow"));
                map.insert("updatedInput".into(), updated_input.clone());
                if let Some(permissions) = updated_permissions {
                    map.insert("updatedPermissions".into(), Value::Array(permissions.clone()));
                }
                map
            }
            Self::Deny { message } => {
                let mut map = Map::new();
                map.insert("behavior".into(), json!("deny"));
                map.insert("message".into(), json!(message));
                map
            }
        };
        if let Some(id) = tool_use_id {
            response.insert("toolUseID".into(), json!(id));
        }
        Value::Object(response)
    }
}

/// A `can_use_tool` request, as `processControlRequest` reads it.
#[derive(Clone, Debug, PartialEq)]
pub struct CanUseToolRequest {
    pub tool_name: String,
    pub input: Map<String, Value>,
    pub permission_suggestions: Option<Vec<Value>>,
    pub blocked_path: Option<String>,
    pub decision_reason: Option<String>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub tool_use_id: Option<String>,
    pub agent_id: Option<String>,
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

impl CanUseToolRequest {
    pub fn parse(request: &Value) -> Result<Self> {
        let tool_name = string_field(request, "tool_name").context("can_use_tool without a tool_name")?;
        let input = match request.get("input") {
            Some(Value::Object(map)) => map.clone(),
            _ => Map::new(),
        };
        let permission_suggestions = request
            .get("permission_suggestions")
            .and_then(Value::as_array)
            .filter(|suggestions| !suggestions.is_empty())
            .cloned();
        Ok(Self {
            tool_name,
            input,
            permission_suggestions,
            blocked_path: string_field(request, "blocked_path"),
            decision_reason: string_field(request, "decision_reason"),
            title: string_field(request, "title"),
            description: string_field(request, "description"),
            tool_use_id: string_field(request, "tool_use_id"),
            agent_id: string_field(request, "agent_id"),
        })
    }
}

/// One line the CLI printed.
#[derive(Clone, Debug, PartialEq)]
pub enum CliLine {
    /// The answer to one of our control requests: the success body, or the error text.
    ControlResponse { request_id: String, result: std::result::Result<Value, String> },
    /// A request from the CLI; `request` is the object under `"request"`.
    ControlRequest { request_id: String, request: Value },
    ControlCancelRequest { request_id: String },
    KeepAlive,
    /// Any SDK message (`system`, `assistant`, `user`, `stream_event`, `result`, ...).
    Message(Value),
}

/// Parses one stdout line. Blank lines are `None`.
pub fn parse_line(line: &str) -> Result<Option<CliLine>> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let value: Value = serde_json::from_str(trimmed).context("the CLI printed a line that is not JSON")?;
    let kind = value.get("type").and_then(Value::as_str).unwrap_or_default();
    Ok(Some(match kind {
        "control_response" => {
            let response = value.get("response").ok_or_else(|| anyhow!("control_response without a response"))?;
            let request_id = string_field(response, "request_id").unwrap_or_default();
            let result = if response.get("subtype").and_then(Value::as_str) == Some("error") {
                Err(string_field(response, "error").unwrap_or_else(|| "control request failed".to_owned()))
            } else {
                Ok(response.get("response").cloned().unwrap_or(Value::Null))
            };
            CliLine::ControlResponse { request_id, result }
        }
        "control_request" => CliLine::ControlRequest {
            request_id: string_field(&value, "request_id").unwrap_or_default(),
            request: value.get("request").cloned().unwrap_or(Value::Null),
        },
        "control_cancel_request" => CliLine::ControlCancelRequest {
            request_id: string_field(&value, "request_id").unwrap_or_default(),
        },
        "keep_alive" => CliLine::KeepAlive,
        _ => CliLine::Message(value),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_args_follow_the_sdk_order() {
        let mut settings = Map::new();
        settings.insert("autoCompactEnabled".into(), json!(true));
        let args = launch_args(&ClaudeLaunchOptions {
            model: Some("haiku".into()),
            permission_mode: Some("bypassPermissions".into()),
            allow_dangerously_skip_permissions: true,
            resume: Some("abc".into()),
            include_partial_messages: true,
            additional_directories: vec!["/w".into()],
            settings: Some(settings),
            ..Default::default()
        });
        assert_eq!(
            args,
            [
                "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                "--model", "haiku", "--permission-prompt-tool", "stdio", "--resume=abc",
                "--setting-sources=user,project,local", "--permission-mode", "bypassPermissions",
                "--allow-dangerously-skip-permissions", "--include-partial-messages", "--add-dir", "/w",
                "--settings", "{\"autoCompactEnabled\":true}",
            ]
        );
    }

    #[test]
    fn parses_control_lines() {
        let line = r#"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"nope"}}"#;
        assert_eq!(
            parse_line(line).unwrap(),
            Some(CliLine::ControlResponse { request_id: "r1".into(), result: Err("nope".into()) })
        );
        let line = r#"{"type":"control_cancel_request","request_id":"r2"}"#;
        assert_eq!(parse_line(line).unwrap(), Some(CliLine::ControlCancelRequest { request_id: "r2".into() }));
        assert_eq!(parse_line("  ").unwrap(), None);
        assert!(parse_line("not json").is_err());
    }

    #[test]
    fn permission_results_carry_the_tool_use_id() {
        let allow = PermissionResult::Allow { updated_input: json!({"a": 1}), updated_permissions: None };
        assert_eq!(
            allow.to_response(Some("toolu_1")),
            json!({"behavior": "allow", "updatedInput": {"a": 1}, "toolUseID": "toolu_1"})
        );
        let deny = PermissionResult::Deny { message: "no".into() };
        assert_eq!(deny.to_response(None), json!({"behavior": "deny", "message": "no"}));
    }
}
