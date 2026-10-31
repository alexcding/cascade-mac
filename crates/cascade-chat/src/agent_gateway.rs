//! The MCP server the backend gives a chat's CLI, and the shapes each CLI takes it in: Synara's
//! `agentGateway/mcpInjection.ts` (`buildClaudeMcpServers`, `buildCodexMcpThreadConfig`). The
//! backend serves the server (`cascade-backend/src/gateway`); this crate only passes it on.

use serde_json::{json, Value};

use crate::contracts::base::ThreadId;

/// Synara `AgentGatewayMcpConnection`: where a thread's CLI reaches the gateway, and its token.
#[derive(Clone, PartialEq, Eq)]
pub struct GatewayConnection {
    /// The MCP server's name in the CLI's configuration.
    pub name: String,
    pub url: String,
    pub bearer_token: String,
}

impl std::fmt::Debug for GatewayConnection {
    // The token stays out of logs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GatewayConnection").field("name", &self.name).field("url", &self.url).finish_non_exhaustive()
    }
}

/// What issues a thread's connection: the backend's gateway.
pub trait AgentGateway: Send + Sync {
    /// The connection a thread's CLI is started with; `None` when the gateway is not serving.
    fn connection(&self, thread_id: &ThreadId) -> Option<GatewayConnection>;
    /// The thread is gone: its token stops working.
    fn release(&self, thread_id: &ThreadId);
}

/// Where Claude finds the token its `--mcp-config` names. The CLI expands `${VAR}` in a server's
/// headers, so the token goes in the child's environment, which only its own user can read, and
/// not in its arguments, which every user's `ps` shows (Synara puts it in the JSON itself).
pub const CLAUDE_TOKEN_VARIABLE: &str = "CASCADE_GATEWAY_TOKEN";

/// Synara `buildClaudeMcpServers`, as the `--mcp-config` JSON the CLI reads; the token is the
/// child's `CLAUDE_TOKEN_VARIABLE`.
pub fn claude_mcp_config(connection: &GatewayConnection) -> String {
    json!({
        "mcpServers": {
            connection.name.as_str(): {
                "type": "http",
                "url": connection.url,
                "headers": { "Authorization": format!("Bearer ${{{CLAUDE_TOKEN_VARIABLE}}}") },
            }
        }
    })
    .to_string()
}

/// Synara `buildCodexMcpThreadConfig`: sent only over the app-server pipe, never written to the
/// shared Codex home.
pub fn codex_thread_config(connection: &GatewayConnection) -> Value {
    json!({
        "mcp_servers": {
            connection.name.as_str(): {
                "url": connection.url,
                "http_headers": { "Authorization": format!("Bearer {}", connection.bearer_token) },
            }
        }
    })
}
