//! `POST /mcp`: Synara's `httpRoute.ts` and `mcpTransport.ts`. One JSON-RPC message per request,
//! answered with JSON; a notification is answered `202` with no body. A request the client
//! abandons drops its handler, which is how a cancelled tool call stops here.

use axum::{
    body::Bytes,
    extract::State,
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

use super::{Caller, ToolResult, CWD_HEADER, RUN_HEADER, SERVER_NAME};
use crate::AppState;

/// Synara `AGENT_GATEWAY_MCP_MAX_BODY_BYTES`.
pub const MAX_BODY_BYTES: usize = 1024 * 1024;
/// The protocol versions this server speaks, newest first; an unknown request gets the newest.
const PROTOCOL_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;

pub async fn post(State(state): State<AppState>, headers: HeaderMap, body: Bytes) -> Response {
    let authorization = headers.get(header::AUTHORIZATION).and_then(|value| value.to_str().ok());
    let run_id = headers.get(RUN_HEADER).and_then(|value| value.to_str().ok());
    let cwd = headers.get(CWD_HEADER).and_then(|value| value.to_str().ok());
    let Some(caller) = state.gateway.caller(authorization, run_id, cwd) else {
        return rpc_error_response(
            StatusCode::UNAUTHORIZED,
            Value::Null,
            INVALID_REQUEST,
            "caller_session_inactive: Missing, revoked, or invalid provider-session credential.",
        );
    };
    if body.len() > MAX_BODY_BYTES {
        return rpc_error_response(StatusCode::PAYLOAD_TOO_LARGE, Value::Null, INVALID_REQUEST, "Request body exceeds the 1 MiB limit.");
    }
    let Ok(message) = serde_json::from_slice::<Value>(&body) else {
        return rpc_error_response(StatusCode::BAD_REQUEST, Value::Null, PARSE_ERROR, "Invalid JSON body.");
    };
    match handle(&state, &caller, message).await {
        Some(response) => (StatusCode::OK, Json(response)).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

/// GET and DELETE: this server keeps no stream and no session to end.
pub async fn not_allowed() -> Response {
    (StatusCode::METHOD_NOT_ALLOWED, [(header::ALLOW, "POST")]).into_response()
}

fn rpc_error_response(status: StatusCode, id: Value, code: i64, message: &str) -> Response {
    (status, Json(rpc_error(id, code, message))).into_response()
}

fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

fn rpc_result(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

/// Answers one message; `None` for a notification or a response, which need no answer.
pub(crate) async fn handle(state: &AppState, caller: &Caller, message: Value) -> Option<Value> {
    let Some(object) = message.as_object() else {
        return Some(rpc_error(Value::Null, INVALID_REQUEST, "Expected a JSON-RPC message object."));
    };
    let method = object.get("method").and_then(Value::as_str);
    let id = object.get("id").cloned();
    let (Some(method), Some(id)) = (method, id) else {
        // Notifications (initialized, cancelled) and responses: nothing to answer.
        return None;
    };
    let params = object.get("params").cloned().unwrap_or(Value::Null);
    Some(match method {
        "initialize" => rpc_result(id, initialize_result(state, caller, &params)),
        "ping" => rpc_result(id, json!({})),
        "tools/list" => {
            let tools: Vec<Value> = state
                .gateway
                .tools_for(state, caller)
                .iter()
                .map(|tool| {
                    let definition = tool.definition();
                    json!({
                        "name": definition.name,
                        "description": definition.description,
                        "inputSchema": definition.input_schema,
                        "annotations": definition.annotations,
                    })
                })
                .collect();
            rpc_result(id, json!({ "tools": tools }))
        }
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return Some(rpc_error(id, INVALID_PARAMS, "tools/call needs a tool name."));
            };
            let Some(tool) = state.gateway.tools_for(state, caller).into_iter().find(|tool| tool.definition().name == name) else {
                return Some(rpc_error(id, INVALID_PARAMS, &format!("Unknown tool \"{name}\".")));
            };
            let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let result = tool.call(state.clone(), caller.clone(), arguments).await;
            rpc_result(id, tool_result(result))
        }
        _ => rpc_error(id, METHOD_NOT_FOUND, &format!("Method \"{method}\" is not supported.")),
    })
}

fn tool_result(result: ToolResult) -> Value {
    let mut value = json!({ "content": result.content });
    if result.is_error {
        value["isError"] = json!(true);
    }
    value
}

/// Synara `buildMcpInitializeResult`: the requested version when spoken, the tools capability,
/// and the instructions of the tools this caller is offered (Synara's harness policy lines).
fn initialize_result(state: &AppState, caller: &Caller, params: &Value) -> Value {
    let requested = params.get("protocolVersion").and_then(Value::as_str);
    let version = requested.filter(|v| PROTOCOL_VERSIONS.contains(v)).unwrap_or(PROTOCOL_VERSIONS[0]);
    let mut instructions: Vec<&'static str> = Vec::new();
    for tool in state.gateway.tools_for(state, caller) {
        if let Some(line) = tool.instructions() {
            if !instructions.contains(&line) {
                instructions.push(line);
            }
        }
    }
    let mut result = json!({
        "protocolVersion": version,
        "capabilities": { "tools": { "listChanged": false } },
        "serverInfo": { "name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION") },
    });
    if !instructions.is_empty() {
        result["instructions"] = json!(instructions.join("\n"));
    }
    result
}
