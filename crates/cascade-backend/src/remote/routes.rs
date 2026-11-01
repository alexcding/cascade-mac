//! The loopback routes the app turns the listener on and off with and manages paired clients by.
//! A page in a browser is turned away from the ones that change something (`foreign_origin`).

use axum::{
    extract::{Path, RawQuery, State},
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

/// A paired Mac's session's transcript, named by the session (`listener::session_transcript`).
pub async fn peer_session_transcript(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>, RawQuery(query): RawQuery) -> Response {
    if let Err(error) = local_only(&headers) {
        return error.into_response();
    }
    let path = match query {
        Some(query) => format!("/api/session-transcript?{query}"),
        None => "/api/session-transcript".to_string(),
    };
    forward(&state, &id, Method::GET, &path, None).await
}

/// A command for a paired Mac's session or project (`commands`), answered at once; what its app
/// did is told later as `session-command-done`.
pub async fn peer_session_command(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>, Json(body): Json<Value>) -> Response {
    if let Err(error) = local_only(&headers) {
        return error.into_response();
    }
    forward(&state, &id, Method::POST, "/api/session-command", Some(&body)).await
}

/// This app's answer to a paired Mac's command (`Event::RemoteCommand`).
pub async fn command_result(State(state): State<AppState>, headers: HeaderMap, Json(done): Json<super::commands::Done>) -> ApiResult<Value> {
    local_only(&headers)?;
    super::commands::done(&state, done);
    Ok(Json(json!({})))
}

pub async fn peer_session_status(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    forward(&state, &id, Method::GET, "/api/session-status", None).await
}

/// The app's sessions' agent states, by session id, for paired Macs (`listener::session_status`).
/// Told again only when they changed; a change is announced to them as `session-status`.
pub async fn set_session_status(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<StatusBody>) -> ApiResult<Value> {
    local_only(&headers)?;
    let changed = {
        let mut statuses = state.remote.statuses.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let changed = *statuses != body.sessions;
        *statuses = body.sessions;
        changed
    };
    if changed {
        state.publish(crate::Event::SessionStatus);
    }
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
pub struct StatusBody {
    sessions: serde_json::Map<String, Value>,
}

/// The chat page's calls for a remote session, which the peer answers or refuses by its own
/// list (`listener::CHAT_METHODS`).
pub async fn peer_chat_rpc(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>, Json(body): Json<Value>) -> Response {
    if let Err(error) = local_only(&headers) {
        return error.into_response();
    }
    forward(&state, &id, Method::POST, "/api/chat/rpc", Some(&body)).await
}

#[derive(Default, Deserialize)]
pub struct ConnectBody {
    address: Option<String>,
}

/// `POST /api/remote/peers/{id}/connect` `{address?}` → `{reach}`: tries a paired Mac again,
/// for Settings → Remote while it is open, at `address` when Bonjour sees it there.
pub async fn connect_peer(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>, body: Option<Json<ConnectBody>>) -> ApiResult<Value> {
    local_only(&headers)?;
    let address = body.and_then(|Json(body)| body.address);
    match links::connect(&state, &id, address.as_deref()).await.map_err(ApiError::internal)? {
        Some(reach) => Ok(Json(json!({ "reach": reach }))),
        None => Err(ApiError::not_found("No such Mac")),
    }
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
    super::log(&state, "info", "peer_forgotten", json!({ "peer": super::short(&id) }));
    state.publish(crate::Event::RemotePeers);
    Ok(Json(json!({ "ok": true })))
}

/// How long the app has to connect to a terminal socket it was given before it is taken down.
const TERMINAL_ACCEPT: std::time::Duration = std::time::Duration::from_secs(15);

/// `POST /api/remote/peers/{id}/terminal` → `{socket}`: opens a connection to the peer's terminal
/// daemon and offers it on a Unix socket of its own, which the app's terminal client connects to
/// as it would to its own daemon. The socket takes one connection, in a folder only this user can
/// enter, and is removed once taken or after `TERMINAL_ACCEPT`.
pub async fn open_peer_terminal(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>) -> Response {
    if let Err(error) = local_only(&headers) {
        return error.into_response();
    }
    let peer = match links::terminal(&state, &id).await {
        Ok(Some(peer)) => peer,
        Ok(None) => return ApiError::not_found("No such Mac").into_response(),
        Err(error) => return ApiError::status(axum::http::StatusCode::BAD_GATEWAY, format!("{error:#}")).into_response(),
    };
    let (path, listener) = match terminal_socket() {
        Ok(opened) => opened,
        Err(error) => return ApiError::internal(error).into_response(),
    };
    let socket = path.clone();
    tokio::spawn(async move {
        let accepted = tokio::time::timeout(TERMINAL_ACCEPT, listener.accept()).await;
        let _ = std::fs::remove_file(&socket);
        let Ok(Ok((mut app, _))) = accepted else { return };
        let mut peer = peer;
        let _ = tokio::io::copy_bidirectional(&mut app, &mut peer).await;
    });
    Json(json!({ "socket": path })).into_response()
}

/// A fresh socket path in this process's private folder (`0700`), short enough for `sun_path`.
fn terminal_socket() -> std::io::Result<(std::path::PathBuf, tokio::net::UnixListener)> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let folder = std::env::temp_dir().join(format!("cascade-rt-{}", std::process::id()));
    match std::fs::DirBuilder::new().mode(0o700).create(&folder) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    // A folder someone else made, or opened up, is not ours to offer a terminal in.
    let metadata = std::fs::symlink_metadata(&folder)?;
    use std::os::unix::fs::MetadataExt;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::getuid() } || metadata.permissions().mode() & 0o077 != 0 {
        return Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "the terminal socket folder is not private"));
    }
    let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|time| time.subsec_nanos()).unwrap_or(0);
    let name = format!("{:x}-{:x}.sock", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed), nonce);
    let path = folder.join(name);
    let listener = tokio::net::UnixListener::bind(&path)?;
    Ok((path, listener))
}

#[derive(Deserialize)]
pub struct DaemonBody {
    socket: String,
}

/// `POST /api/remote/terminal-daemon` `{socket}`: where the app's terminal daemon listens, which
/// a paired Mac's terminals are relayed to (`terminal`). Said by the app once it is connected.
pub async fn set_terminal_daemon(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<DaemonBody>) -> ApiResult<Value> {
    local_only(&headers)?;
    let path = std::path::PathBuf::from(&body.socket);
    if !path.is_absolute() {
        return Err(ApiError::bad_request("the terminal daemon's socket must be an absolute path"));
    }
    *state.remote.daemon.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(path);
    Ok(Json(json!({})))
}
