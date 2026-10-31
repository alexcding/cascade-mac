//! The agent gateway: the MCP server Cascade gives the agents it runs, so a chat's or a terminal
//! session's CLI can show an inline visual or drive an iOS Simulator. A port of Synara's agent
//! gateway transport (`apps/server/src/agentGateway/{httpRoute,mcpTransport,mcpInjection}.ts`),
//! reduced to what a single-user app needs.
//!
//! One route, `POST /mcp`, on the backend's loopback port: stateless JSON-RPC over HTTP, one
//! message per request, answered with plain JSON. Who is calling is told by the bearer token:
//!
//! - A chat's CLI is started by the chat engine, which asks [`Gateway`] (as cascade-chat's
//!   `AgentGateway`) for the thread's connection: the endpoint and a token minted for that thread,
//!   kept in memory. A new backend starts the chat CLIs again, with new tokens.
//! - A terminal agent outlives the app that started it, and its port with it, so it reaches the
//!   gateway through `cascade-mcp-proxy.sh`, which reads the port file on every message and sends
//!   the data folder's own token (`.gateway-token`, the user's alone) with the terminal's run id.
//!
//! The CLI's own permission flow asks before a tool runs (Claude's `can_use_tool`, Codex's MCP
//! tool-call approval), so the gateway keeps no approval gate of its own, unlike Synara's.

pub mod mcp;
pub mod visuals;

use std::{
    collections::HashMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex, OnceLock},
};

use cascade_chat::{contracts::base::ThreadId, AgentGateway, GatewayConnection};
use serde_json::Value;

use crate::AppState;

/// The name the CLIs know the gateway by: Claude calls its tools `mcp__cascade__<tool>`.
pub const SERVER_NAME: &str = "cascade";
/// The route, as Synara's `AGENT_GATEWAY_MCP_PATH`.
pub const MCP_PATH: &str = "/mcp";
/// The header the stdio proxy names its terminal by (`CASCADE_RUN_ID`, set by cascade-ptyd).
pub const RUN_HEADER: &str = "x-cascade-run";
/// The folder the terminal's agent works in, base64: the session's worktree.
pub const CWD_HEADER: &str = "x-cascade-cwd-base64";
const TOKEN_FILE: &str = ".gateway-token";

/// Who called a tool.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Caller {
    /// A chat's CLI, started by the chat engine for this thread.
    Chat { thread_id: String },
    /// A terminal agent, by the run id cascade-ptyd gave its terminal, working in `cwd`.
    Terminal { run_id: String, cwd: Option<String> },
}

/// One MCP tool: Synara's `ToolEntry` (`toolRuntime.ts`).
pub struct ToolDefinition {
    pub name: &'static str,
    pub description: String,
    pub input_schema: Value,
    pub annotations: Value,
}

/// What a tool answers: MCP `content` parts, and whether it failed.
#[derive(Debug, Default)]
pub struct ToolResult {
    pub content: Vec<Value>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn text(text: impl Into<String>) -> Self {
        Self { content: vec![serde_json::json!({ "type": "text", "text": text.into() })], is_error: false }
    }

    /// Synara `mcpToolResultJson`: one text part of pretty JSON.
    pub fn json(value: &Value) -> Self {
        Self::text(serde_json::to_string_pretty(value).unwrap_or_default())
    }

    /// Synara `gatewayToolErrorResult`: `{error: {code, message}}`, flagged as an error.
    pub fn error(code: &str, message: impl Into<String>) -> Self {
        let mut result = Self::json(&serde_json::json!({ "error": { "code": code, "message": message.into() } }));
        result.is_error = true;
        result
    }
}

pub type ToolFuture = Pin<Box<dyn Future<Output = ToolResult> + Send>>;

/// A tool the gateway serves.
pub trait Tool: Send + Sync {
    fn definition(&self) -> &ToolDefinition;
    /// A line for the server's `instructions` (Synara's harness policy), shared by a tool family.
    fn instructions(&self) -> Option<&'static str> {
        None
    }
    /// Whether `caller` is offered the tool at all.
    fn offered_to(&self, state: &AppState, caller: &Caller) -> bool;
    fn call(&self, state: AppState, caller: Caller, arguments: Value) -> ToolFuture;
}

/// The gateway's credentials and endpoint; `AppState.gateway`.
#[derive(Default)]
pub struct Gateway {
    endpoint: OnceLock<Endpoint>,
    /// Chat tokens, minted per thread.
    chats: Mutex<HashMap<String, String>>,
    /// Registered at startup by the modules that serve tools.
    registered: Mutex<Vec<Arc<dyn Tool>>>,
}

struct Endpoint {
    port: u16,
    terminal_token: String,
}

impl Gateway {
    /// Called once the loopback port is bound: the gateway serves from then on.
    pub fn configure(&self, port: u16, data_dir: &Path) -> anyhow::Result<()> {
        let terminal_token = terminal_token(data_dir)?;
        let _ = self.endpoint.set(Endpoint { port, terminal_token });
        Ok(())
    }

    /// Every tool the backend serves, registered once at startup. A module that serves tools
    /// adds its line here.
    pub fn register_all(&self) {
        let mut tools: Vec<Arc<dyn Tool>> = vec![Arc::new(visuals::ShowVisual::default())];
        tools.extend(crate::device::tools::all());
        self.register(tools);
    }

    /// Adds tools; a module that serves tools registers them at startup.
    pub fn register(&self, tools: Vec<Arc<dyn Tool>>) {
        self.registered.lock().unwrap().extend(tools);
    }

    fn url(&self) -> Option<String> {
        self.endpoint.get().map(|endpoint| format!("http://127.0.0.1:{}{MCP_PATH}", endpoint.port))
    }

    /// The caller a request's headers name, or `None` for a token the gateway did not issue.
    pub fn caller(&self, authorization: Option<&str>, run_id: Option<&str>, cwd_base64: Option<&str>) -> Option<Caller> {
        let token = authorization?.strip_prefix("Bearer ")?.trim();
        if token.is_empty() {
            return None;
        }
        let endpoint = self.endpoint.get()?;
        if constant_time_eq(token, &endpoint.terminal_token) {
            let run_id = run_id.map(str::trim).filter(|id| !id.is_empty())?;
            let cwd = cwd_base64.and_then(|encoded| {
                use base64::Engine;
                let bytes = base64::engine::general_purpose::STANDARD.decode(encoded.trim()).ok()?;
                String::from_utf8(bytes).ok().filter(|path| path.starts_with('/'))
            });
            return Some(Caller::Terminal { run_id: run_id.to_owned(), cwd });
        }
        let chats = self.chats.lock().unwrap();
        chats
            .iter()
            .find(|(_, issued)| constant_time_eq(token, issued))
            .map(|(thread_id, _)| Caller::Chat { thread_id: thread_id.clone() })
    }

    /// The tools `caller` is offered, in registration order.
    pub fn tools_for(&self, state: &AppState, caller: &Caller) -> Vec<Arc<dyn Tool>> {
        self.registered.lock().unwrap().iter().filter(|tool| tool.offered_to(state, caller)).cloned().collect()
    }
}

impl AgentGateway for Gateway {
    fn connection(&self, thread_id: &ThreadId) -> Option<GatewayConnection> {
        let url = self.url()?;
        let mut chats = self.chats.lock().unwrap();
        let token = chats.entry(thread_id.as_str().to_owned()).or_insert_with(new_token).clone();
        Some(GatewayConnection { name: SERVER_NAME.to_owned(), url, bearer_token: token })
    }

    fn release(&self, thread_id: &ThreadId) {
        self.chats.lock().unwrap().remove(thread_id.as_str());
    }
}

fn new_token() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

/// The data folder's terminal token: made once, readable by the user alone, kept across launches
/// so a terminal agent started by an earlier launch still reaches the gateway.
fn terminal_token(data_dir: &Path) -> anyhow::Result<String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let path: PathBuf = data_dir.join(TOKEN_FILE);
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim().to_owned();
        if existing.len() >= 32 {
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            return Ok(existing);
        }
    }
    let token = new_token();
    let temporary = data_dir.join(format!("{TOKEN_FILE}.{}.tmp", std::process::id()));
    {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temporary)?;
        file.write_all(token.as_bytes())?;
    }
    std::fs::rename(&temporary, &path)?;
    Ok(token)
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use axum::{
        body::{to_bytes, Body},
        http::{Request, StatusCode},
    };
    use serde_json::json;
    use tower::ServiceExt;

    use super::*;

    struct Echo;

    static ECHO: std::sync::LazyLock<ToolDefinition> = std::sync::LazyLock::new(|| ToolDefinition {
        name: "echo",
        description: "Echoes".into(),
        input_schema: json!({ "type": "object" }),
        annotations: json!({ "readOnlyHint": true }),
    });

    impl Tool for Echo {
        fn definition(&self) -> &ToolDefinition {
            &ECHO
        }
        fn instructions(&self) -> Option<&'static str> {
            Some("Echo when asked.")
        }
        fn offered_to(&self, _: &AppState, caller: &Caller) -> bool {
            matches!(caller, Caller::Chat { .. })
        }
        fn call(&self, _: AppState, caller: Caller, arguments: Value) -> ToolFuture {
            Box::pin(async move { ToolResult::json(&json!({ "caller": format!("{caller:?}"), "arguments": arguments })) })
        }
    }

    async fn mcp(app: &axum::Router, token: Option<&str>, run: Option<&str>, body: Value) -> (StatusCode, Value) {
        mcp_in(app, token, run, None, body).await
    }

    async fn mcp_in(app: &axum::Router, token: Option<&str>, run: Option<&str>, cwd: Option<&str>, body: Value) -> (StatusCode, Value) {
        let mut request = Request::post(MCP_PATH).header("content-type", "application/json");
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        if let Some(run) = run {
            request = request.header(RUN_HEADER, run);
        }
        if let Some(cwd) = cwd {
            request = request.header(CWD_HEADER, cwd);
        }
        let response = app.clone().oneshot(request.body(Body::from(body.to_string())).unwrap()).await.unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
    }

    #[tokio::test]
    async fn chat_and_terminal_callers_are_told_apart_by_their_token() {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        state.gateway.configure(4321, dir.path()).unwrap();
        state.gateway.register(vec![Arc::new(Echo)]);
        let app = crate::build_app(state.clone());

        let connection = state.gateway.connection(&ThreadId::new("thread-1")).unwrap();
        assert_eq!(connection.url, "http://127.0.0.1:4321/mcp");
        assert_eq!(state.gateway.connection(&ThreadId::new("thread-1")).unwrap(), connection, "one token per thread");
        let chat = connection.bearer_token.as_str();

        let (status, body) = mcp(&app, None, None, json!({ "jsonrpc": "2.0", "id": 1, "method": "ping" })).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["error"]["code"], -32600);

        let (status, body) = mcp(
            &app,
            Some(chat),
            None,
            json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2025-03-26" } }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(body["result"]["serverInfo"]["name"], "cascade");
        assert_eq!(body["result"]["instructions"], "Echo when asked.");

        let (status, _) = mcp(&app, Some(chat), None, json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })).await;
        assert_eq!(status, StatusCode::ACCEPTED);

        let (_, body) = mcp(&app, Some(chat), None, json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" })).await;
        assert_eq!(body["result"]["tools"][0]["name"], "echo");

        let (_, body) = mcp(
            &app,
            Some(chat),
            None,
            json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": { "name": "echo", "arguments": { "a": 1 } } }),
        )
        .await;
        let text: Value = serde_json::from_str(body["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(text["caller"], "Chat { thread_id: \"thread-1\" }");
        assert_eq!(text["arguments"], json!({ "a": 1 }));

        // The terminal token, from the data folder, with the terminal's run id; it is not
        // offered the chat-only tool.
        let terminal = std::fs::read_to_string(dir.path().join(TOKEN_FILE)).unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(dir.path().join(TOKEN_FILE)).unwrap().permissions().mode() & 0o777, 0o600);
        let (status, _) = mcp(&app, Some(&terminal), None, json!({ "jsonrpc": "2.0", "id": 4, "method": "ping" })).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "a terminal names its run");
        let (_, body) = mcp(&app, Some(&terminal), Some("run-7"), json!({ "jsonrpc": "2.0", "id": 5, "method": "tools/list" })).await;
        assert_eq!(body["result"]["tools"], json!([]));
        let (_, body) = mcp(
            &app,
            Some(&terminal),
            Some("run-7"),
            json!({ "jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": { "name": "echo" } }),
        )
        .await;
        assert_eq!(body["error"]["code"], -32602);

        // A deleted thread's token stops working; the terminal token survives a new backend.
        state.gateway.release(&ThreadId::new("thread-1"));
        let (status, _) = mcp(&app, Some(chat), None, json!({ "jsonrpc": "2.0", "id": 7, "method": "ping" })).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let again = Gateway::default();
        again.configure(1, dir.path()).unwrap();
        assert_eq!(
            again.caller(Some(&format!("Bearer {terminal}")), Some("run-7"), Some("L3ByaXZhdGUvdG1w")),
            Some(Caller::Terminal { run_id: "run-7".into(), cwd: Some("/private/tmp".into()) })
        );
    }
}
