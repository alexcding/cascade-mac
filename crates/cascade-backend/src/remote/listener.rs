//! What another Mac reaches: a TLS server whose every request needs a paired client's token, and
//! whose routes are named one by one here. Nothing falls through to the loopback router
//! (`build_app`), which has no authentication and trusts its callers.

use std::{collections::HashMap, convert::Infallible, net::IpAddr, sync::Arc, time::Duration};

use axum::{
    extract::{rejection::JsonRejection, DefaultBodyLimit, Request, State},
    http::{header, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{
        sse::{Event, KeepAlive},
        IntoResponse, Response, Sse,
    },
    routing::{get, post},
    Extension, Json, Router,
};
use futures_util::StreamExt;
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{json, Value};
use tokio::{
    net::TcpListener,
    sync::{broadcast::error::RecvError, Semaphore},
    task::JoinSet,
};
use tokio_rustls::TlsAcceptor;
use tokio_stream::wrappers::BroadcastStream;
use tower::Service;
use tower_http::set_header::SetResponseHeaderLayer;

use super::{pairing, store};
use crate::{
    chat::{self, RpcError},
    error::ApiError,
    routes, AppState,
};

/// The chat calls a paired Mac may make: reads only. Anything else is `403`.
pub(crate) const CHAT_METHODS: &[&str] = &[
    "orchestration.getShellSnapshot",
    "orchestration.getThreadDetailSnapshot",
    "orchestration.getTurnDiff",
    "orchestration.getFullThreadDiff",
    "chat.listThreads",
    "chat.providerStatuses",
];

/// The events a paired Mac's stream carries (`Event`'s `type`s).
pub(crate) const EVENTS: &[&str] = &["tasks", "chat-thread", "chat-shell", "chat-removed", "reload"];

/// How often an idle stream says it is alive; a paired Mac drops one silent for three times as
/// long (`links::SILENT`).
const KEEP_ALIVE: Duration = if cfg!(test) { Duration::from_millis(300) } else { Duration::from_secs(15) };

/// How long a connection may take to finish its TLS handshake, and then each request's headers,
/// the first and every one after it on a kept-alive connection: a peer that opens connections and
/// sends nothing has them closed rather than holding the app's descriptors.
const HANDSHAKE: Duration = Duration::from_secs(10);
const HEADER_READ: Duration = if cfg!(test) { Duration::from_millis(500) } else { Duration::from_secs(10) };

/// Connections served at once, handshakes included. Past it a new one is closed as it comes:
/// a paired Mac holds a few (its stream and a request or two), and the app's descriptors are few.
pub(crate) const CONNECTIONS: usize = if cfg!(test) { 4 } else { 32 };
/// Of those, the most one address may hold: one device on the network, paired or not, cannot
/// take every slot from the others.
pub(crate) const PER_SOURCE: usize = if cfg!(test) { 3 } else { 8 };
/// And the most one global IPv6 /64 may hold, since a device can take as many addresses in its
/// network as it likes; the Macs sharing that network share this, so it is most of the whole.
pub(crate) const PER_NETWORK: usize = CONNECTIONS * 3 / 4;

/// What a connection from `address` is counted under, each with its limit: the address itself,
/// and for a global IPv6 address its /64 too. Link-local (`fe80::/10`, which every Mac on the
/// link shares as a /64) and IPv4 count by address alone.
pub(crate) fn sources(address: IpAddr) -> Vec<(IpAddr, usize)> {
    let address = address.to_canonical();
    let mut counted = vec![(address, PER_SOURCE)];
    if let IpAddr::V6(v6) = address {
        if !v6.is_unicast_link_local() && !v6.is_loopback() {
            let network = std::net::Ipv6Addr::from(v6.to_bits() & !((1u128 << 64) - 1));
            counted.push((IpAddr::V6(network), PER_NETWORK));
        }
    }
    counted
}

/// The connections each address and network holds now. A short lock, never held across an await.
#[derive(Default)]
struct Sources(std::sync::Mutex<HashMap<IpAddr, usize>>);

/// A connection's share of the slots, given back when it ends.
struct SourceSlot {
    sources: Arc<Sources>,
    counted: Vec<IpAddr>,
}

impl Sources {
    fn take(self: &Arc<Self>, address: IpAddr) -> Option<SourceSlot> {
        let counted = sources(address);
        let mut held = self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if counted.iter().any(|(key, limit)| held.get(key).copied().unwrap_or(0) >= *limit) {
            return None;
        }
        for (key, _) in &counted {
            *held.entry(*key).or_default() += 1;
        }
        Some(SourceSlot { sources: self.clone(), counted: counted.into_iter().map(|(key, _)| key).collect() })
    }
}

impl Drop for SourceSlot {
    fn drop(&mut self) {
        let mut held = self.sources.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for key in &self.counted {
            if let Some(count) = held.get_mut(key) {
                *count -= 1;
                if *count == 0 {
                    held.remove(key);
                }
            }
        }
    }
}

/// The most a pairing request's body may take to arrive.
const PAIR_BODY: Duration = if cfg!(test) { Duration::from_millis(500) } else { Duration::from_secs(10) };

/// The client a request was authorised as, for the handlers that need it.
#[derive(Clone)]
struct Client(String);

pub(crate) fn router(state: AppState) -> Router {
    let no_store = SetResponseHeaderLayer::overriding(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Router::new()
        .route("/api/backend/health", get(health))
        .route("/api/tasks", get(routes::get_tasks))
        .route("/api/projects", get(projects))
        .route("/api/stream", get(stream))
        .route("/api/chat/rpc", post(chat_rpc))
        // Every route above needs a token; the two below are how a Mac gets one, and answer only
        // while the host's pairing window is open (`pairing`).
        .route_layer(middleware::from_fn_with_state(state.clone(), authorize))
        .merge(
            Router::new()
                .route("/pair/start", post(pairing::start))
                .route("/pair/finish", post(pairing::finish))
                .route_layer(middleware::from_fn_with_state(state.clone(), pairing_gate)),
        )
        .fallback(|| async { ApiError::not_found("Not found") })
        .layer(no_store)
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .with_state(state)
}

/// Anyone can reach `/pair/*`: it is answered only while a window is open, before its body is
/// read, and the body must come whole within `PAIR_BODY`, so a slow sender cannot hold a slot.
async fn pairing_gate(State(state): State<AppState>, request: Request, next: Next) -> Response {
    if !pairing::accepting(&state) {
        return ApiError::not_found("not pairing").into_response();
    }
    let (parts, body) = request.into_parts();
    match tokio::time::timeout(PAIR_BODY, axum::body::to_bytes(body, 64 * 1024)).await {
        Ok(Ok(bytes)) => next.run(Request::from_parts(parts, axum::body::Body::from(bytes))).await,
        Ok(Err(_)) => ApiError::bad_request("bad body").into_response(),
        Err(_) => ApiError::status(StatusCode::REQUEST_TIMEOUT, "too slow").into_response(),
    }
}

async fn authorize(State(state): State<AppState>, mut request: Request, next: Next) -> Response {
    let token = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    let client = match token {
        Some(token) => store::client_for(&state.db, token).await,
        None => Ok(None),
    };
    match client {
        Ok(Some(id)) => {
            super::used(&state, &id).await;
            request.extensions_mut().insert(Client(id));
            next.run(request).await
        }
        Ok(None) => ApiError::status(StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
        Err(error) => ApiError::from(error).into_response(),
    }
}

/// `id` is the certificate's fingerprint, what a paired Mac knows this one by.
async fn health(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    let id = store::host(&state.db).await?.map(|host| host.identity.fingerprint());
    Ok(Json(json!({ "service": "cascade", "protocol": 1, "id": id, "instanceId": state.instance_id })))
}

/// Each project's name and icon, for the label beside a remote session; nothing of its paths,
/// repository or Jira.
async fn projects(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    let projects = state.db.projects().await?;
    Ok(Json(projects.iter().map(|project| json!({ "id": project.id, "name": project.name, "icon": project.icon })).collect()))
}

/// The loopback stream's events, only those in `EVENTS`, until this client is revoked.
async fn stream(State(state): State<AppState>, Extension(Client(id)): Extension<Client>) -> Response {
    // Listening before looking again: a revoke between `authorize` and here is seen either way.
    let mut revoked = state.remote.revocations();
    match store::client_exists(&state.db, &id).await {
        Ok(true) => {}
        Ok(false) => return ApiError::status(StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
        Err(error) => return ApiError::from(error).into_response(),
    }
    let db = state.db.clone();
    let ended = async move {
        loop {
            match revoked.recv().await {
                Ok(gone) if gone == id => return,
                Ok(_) => {}
                Err(RecvError::Closed) => return,
                // Revocations were missed, maybe this one's: ask the store.
                Err(RecvError::Lagged(_)) => {
                    if !store::client_exists(&db, &id).await.unwrap_or(false) {
                        return;
                    }
                }
            }
        }
    };
    let initial = futures_util::stream::once(async {
        Ok::<_, Infallible>(Event::default().comment("connected").retry(Duration::from_secs(1)))
    });
    let events = BroadcastStream::new(state.events.subscribe()).filter_map(|message| async move {
        match message {
            Ok(value) => EVENTS
                .contains(&value["type"].as_str().unwrap_or_default())
                .then(|| Ok(Event::default().data(value.to_string()))),
            Err(_) => Some(Ok(Event::default().data(crate::Event::lagged()))),
        }
    });
    Sse::new(initial.chain(events).take_until(Box::pin(ended)))
        .keep_alive(KeepAlive::new().interval(KEEP_ALIVE))
        .into_response()
}

async fn chat_rpc(State(app): State<AppState>, request: Result<Json<chat::RpcRequest>, JsonRejection>) -> Response {
    let request = match request {
        Ok(Json(request)) => request,
        Err(rejection) => return RpcError::from(rejection).into_response(),
    };
    if !CHAT_METHODS.contains(&request.method()) {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": { "message": "not allowed from another Mac", "code": "forbidden" } })))
            .into_response();
    }
    chat::answer(&app, request).await
}

/// Serves `router` over TLS on `listener` until the task running it is aborted, which ends every
/// connection with it: a stream never finishes by itself, so it is never waited for.
pub(crate) async fn serve(listener: TcpListener, tls: rustls::ServerConfig, router: Router) {
    let acceptor = TlsAcceptor::from(Arc::new(tls));
    let slots = Arc::new(Semaphore::new(CONNECTIONS));
    let sources = Arc::new(Sources::default());
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let Ok((stream, peer)) = accepted else {
                    // Out of descriptors and the like: wait rather than spin.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let Some(source) = sources.take(peer.ip()) else { continue };
                let Ok(slot) = slots.clone().try_acquire_owned() else { continue };
                let (acceptor, router) = (acceptor.clone(), router.clone());
                connections.spawn(async move {
                    let _slots = (slot, source);
                    let Ok(Ok(tls)) = tokio::time::timeout(HANDSHAKE, acceptor.accept(stream)).await else { return };
                    let service = hyper::service::service_fn(move |request| router.clone().call(request));
                    let _ = hyper::server::conn::http1::Builder::new()
                        .timer(TokioTimer::new())
                        .header_read_timeout(HEADER_READ)
                        .serve_connection(TokioIo::new(tls), service)
                        .await;
                });
            }
            Some(_) = connections.join_next() => {}
        }
    }
}
