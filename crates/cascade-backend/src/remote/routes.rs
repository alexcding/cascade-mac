//! The loopback routes the app turns the listener on and off with and manages paired clients by.
//! A page in a browser is turned away from the ones that change something (`foreign_origin`).

use axum::{
    extract::{Path, State},
    http::{HeaderMap, Method},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use super::{links, pairing, store, Status};
use crate::{error::ApiError, local::foreign_origin, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;

fn local_only(headers: &HeaderMap) -> Result<(), ApiError> {
    if foreign_origin(headers) {
        Err(ApiError::forbidden("forbidden"))
    } else {
        Ok(())
    }
}

pub async fn status(State(state): State<AppState>) -> ApiResult<Status> {
    Ok(Json(super::status(&state).await.map_err(ApiError::internal)?))
}

pub async fn enable(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Status> {
    local_only(&headers)?;
    Ok(Json(super::enable(&state).await.map_err(ApiError::internal)?))
}

pub async fn disable(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Status> {
    local_only(&headers)?;
    Ok(Json(super::disable(&state).await.map_err(ApiError::internal)?))
}

pub async fn clients(State(state): State<AppState>) -> ApiResult<Vec<store::Client>> {
    Ok(Json(store::clients(&state.db).await?))
}

pub async fn revoke(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>) -> ApiResult<Value> {
    local_only(&headers)?;
    if !super::revoke(&state, &id).await.map_err(ApiError::internal)? {
        return Err(ApiError::not_found("Not found"));
    }
    Ok(Json(json!({ "ok": true })))
}

/// This Mac's name, for the other Mac to show when the app gives none.
fn host_name() -> String {
    let mut buffer = [0u8; 256];
    let named = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0;
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    let name = String::from_utf8_lossy(&buffer[..end]).trim_end_matches(".local").to_owned();
    if named && !name.is_empty() { name } else { "Mac".into() }
}

#[derive(Default, Deserialize)]
pub struct OpenBody {
    name: Option<String>,
}

/// `POST /api/remote/pairing` `{name?}` → `{code, seconds}`: the code to show while it is open.
pub async fn open_pairing(State(state): State<AppState>, headers: HeaderMap, body: Option<Json<OpenBody>>) -> ApiResult<pairing::Opened> {
    local_only(&headers)?;
    let name = body.and_then(|Json(body)| body.name).filter(|name| !name.trim().is_empty()).unwrap_or_else(host_name);
    Ok(Json(pairing::open(&state, &name).await.map_err(|error| ApiError::conflict(error.to_string()))?))
}

pub async fn pairing_state(State(state): State<AppState>) -> Json<pairing::WindowState> {
    Json(pairing::window(&state))
}

pub async fn close_pairing(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Value> {
    local_only(&headers)?;
    pairing::close(&state);
    Ok(Json(json!({ "ok": true })))
}

/// The paired Macs, each with whether it answers now (`reach`).
pub async fn peers(State(state): State<AppState>) -> ApiResult<Vec<Value>> {
    let peers = store::peers(&state.db).await?;
    Ok(Json(
        peers
            .into_iter()
            .map(|peer| {
                let reach = state.remote.links.reach(&peer.id);
                let mut value = serde_json::to_value(peer).unwrap_or_default();
                value["reach"] = json!(reach);
                value
            })
            .collect(),
    ))
}

/// Answers what the peer answered, status and all; `404` for a Mac not paired, `502` when it
/// could not be reached.
async fn forward(state: &AppState, id: &str, method: Method, path: &str, body: Option<&Value>) -> Response {
    match links::forward(state, id, method, path, body).await {
        Ok(Some((status, answer))) => (status, Json(answer)).into_response(),
        Ok(None) => ApiError::not_found("No such Mac").into_response(),
        Err(error) => ApiError::status(axum::http::StatusCode::BAD_GATEWAY, format!("{error:#}")).into_response(),
    }
}

pub async fn peer_tasks(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    forward(&state, &id, Method::GET, "/api/tasks", None).await
}

pub async fn peer_projects(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    forward(&state, &id, Method::GET, "/api/projects", None).await
}

/// The chat page's calls for a remote session, which the peer answers or refuses by its own
/// list (`listener::CHAT_METHODS`).
pub async fn peer_chat_rpc(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>, Json(body): Json<Value>) -> Response {
    if let Err(error) = local_only(&headers) {
        return error.into_response();
    }
    forward(&state, &id, Method::POST, "/api/chat/rpc", Some(&body)).await
}

#[derive(Deserialize)]
pub struct PairBody {
    address: String,
    code: String,
    label: Option<String>,
}

/// `POST /api/remote/peers/pair` `{address, code, label?}` → the peer. A failure says why in
/// `error`: a wrong code, a Mac not pairing, one that could not be reached.
pub async fn pair(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<PairBody>) -> ApiResult<store::Peer> {
    local_only(&headers)?;
    let label = body.label.filter(|label| !label.trim().is_empty()).unwrap_or_else(host_name);
    let peer = pairing::pair(&state, body.address.trim(), &body.code, &label)
        .await
        .map_err(|error| ApiError::bad_request(format!("{error:#}")))?;
    Ok(Json(peer))
}

pub async fn forget_peer(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>) -> ApiResult<Value> {
    local_only(&headers)?;
    links::unlink(&state, &id);
    if !store::forget_peer(&state.db, &id).await? {
        return Err(ApiError::not_found("Not found"));
    }
    state.publish(crate::Event::RemotePeers);
    Ok(Json(json!({ "ok": true })))
}
