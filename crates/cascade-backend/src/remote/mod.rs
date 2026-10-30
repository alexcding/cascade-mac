//! Another Mac's way in (docs/remote/05-mac-to-mac.md): a second server, off until it is turned
//! on, that answers paired Macs over TLS with a token and serves only what `listener` names.
//!
//! `AppState.remote` is its handle. Turning it on makes the certificate the first time, binds the
//! port it had before when it can, and keeps serving across restarts until it is turned off.

mod client;
mod identity;
mod links;
mod listener;
mod pairing;
pub(crate) mod routes;
mod store;
#[cfg(test)]
mod tests;

use std::net::{IpAddr, Ipv6Addr, SocketAddr};

use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::{
    sync::{broadcast, mpsc, Mutex},
    task::JoinHandle,
};

use crate::{AppState, Event};

/// Where the listener binds: every interface, IPv4 through the dual-stack socket included.
const EVERYWHERE: IpAddr = IpAddr::V6(Ipv6Addr::UNSPECIFIED);

pub struct Remote {
    /// The server while it runs. An async lock: turning it on binds and stores the port under it,
    /// so an enable and a disable never interleave.
    running: Mutex<Option<Running>>,
    /// Ids of revoked clients, so their open streams end.
    revoked: broadcast::Sender<String>,
    /// The pairing window, while the host's sheet is open (`pairing`). A short lock: never held
    /// across an await.
    pairing: std::sync::Mutex<Option<pairing::Window>>,
    /// This Mac's links to the Macs it paired with.
    links: links::Links,
    /// A client that paired again, by its new id, and the old one it replaces: the old goes once
    /// the new token is first used, so a pairing whose answer was lost keeps the old one working.
    /// Short lock; lost on restart, which leaves the old client listed until revoked by hand.
    replacing: std::sync::Mutex<std::collections::HashMap<String, String>>,
    /// The Remote log's one writer, started by the first line: lines are kept in the order told.
    log: std::sync::OnceLock<mpsc::UnboundedSender<(&'static str, &'static str, Value)>>,
    /// Each `log_seldom` kind: when it was last written, and how many were held back since.
    seldom: std::sync::Mutex<std::collections::HashMap<&'static str, Seldom>>,
}

struct Running {
    port: u16,
    task: JoinHandle<()>,
}

impl Drop for Running {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Default for Remote {
    fn default() -> Self {
        Self { running: Mutex::new(None), revoked: broadcast::channel(16).0, pairing: std::sync::Mutex::new(None), links: links::Links::default(), replacing: Default::default(), log: Default::default(), seldom: Default::default() }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub enabled: bool,
    pub port: Option<u16>,
    /// SHA-256 of the certificate, once one is made.
    pub fingerprint: Option<String>,
}

impl Remote {
    pub(crate) fn revocations(&self) -> broadcast::Receiver<String> {
        self.revoked.subscribe()
    }
}

/// A line in Activity's Remote log (`logs.db`, category `remote`): what went on between this Mac
/// and another, for a pairing or a link that misbehaves where nobody can attach a debugger. Written
/// behind the caller by one writer, in the order told, so a short lock may be held; never a token
/// or a code.
pub(crate) fn log(state: &AppState, level: &'static str, kind: &'static str, payload: Value) {
    tracing::info!(kind, %payload, "remote");
    let writer = state.remote.log.get_or_init(|| {
        let (sender, mut lines) = mpsc::unbounded_channel::<(&'static str, &'static str, Value)>();
        let db = state.db.clone();
        tokio::spawn(async move {
            while let Some((level, kind, payload)) = lines.recv().await {
                let _ = db.add_log("remote", level, kind, &payload).await;
            }
        });
        sender
    });
    let _ = writer.send((level, kind, payload));
}

/// A `log_seldom` kind: when it was last written, and the lines held back since, the last kept.
#[derive(Default)]
struct Seldom {
    at: Option<std::time::Instant>,
    held: u64,
    last: Option<(&'static str, Value)>,
}

const SELDOM: std::time::Duration = std::time::Duration::from_secs(60);

/// `log`, at most once a minute per `kind`: for what anyone on the network can make happen, which
/// must not push everything else out of `logs.db`. Lines held back are told when the minute ends,
/// as the last of them with how many there were (`heldBack`).
pub(crate) fn log_seldom(state: &AppState, level: &'static str, kind: &'static str, mut payload: Value) {
    let now = std::time::Instant::now();
    {
        let mut seldom = state.remote.seldom.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let entry = seldom.entry(kind).or_default();
        if let Some(at) = entry.at.filter(|at| now.duration_since(*at) < SELDOM) {
            entry.held += 1;
            entry.last = Some((level, payload));
            if entry.held == 1 {
                let state = state.clone();
                let wait = SELDOM - now.duration_since(at);
                tokio::spawn(async move {
                    tokio::time::sleep(wait).await;
                    let told = take_held(&mut state.remote.seldom.lock().unwrap_or_else(|poisoned| poisoned.into_inner()), kind);
                    if let Some((level, payload)) = told {
                        log(&state, level, kind, payload);
                    }
                });
            }
            return;
        }
        // Held lines not told yet (their timer is late) go first, so the log keeps its order.
        let held = take_held(&mut seldom, kind);
        seldom.entry(kind).or_default().at = Some(now);
        if let Some((level, payload)) = held {
            log(state, level, kind, payload);
        }
        // Under the lock too: a late timer cannot tell a newer line ahead of this one.
        payload["heldBack"] = json!(0);
        log(state, level, kind, payload);
    }
}

/// The last line held back of `kind`, with how many were, its minute started again; None when
/// none is held.
fn take_held(seldom: &mut std::collections::HashMap<&'static str, Seldom>, kind: &'static str) -> Option<(&'static str, Value)> {
    let entry = seldom.get_mut(kind)?;
    let (level, mut payload) = entry.last.take()?;
    payload["heldBack"] = json!(std::mem::take(&mut entry.held));
    entry.at = Some(std::time::Instant::now());
    Some((level, payload))
}

/// A certificate fingerprint, shortened for a log line.
pub(crate) fn short(id: &str) -> &str {
    id.get(..12).unwrap_or(id)
}

pub async fn status(state: &AppState) -> Result<Status> {
    let port = state.remote.running.lock().await.as_ref().map(|running| running.port);
    let host = store::host(&state.db).await?;
    Ok(Status { enabled: port.is_some(), port, fingerprint: host.map(|host| host.identity.fingerprint()) })
}

pub async fn enable(state: &AppState) -> Result<Status> {
    start(state, EVERYWHERE).await
}

/// Turns the listener on at `address`, on the port it had before when that is free.
async fn start(state: &AppState, address: IpAddr) -> Result<Status> {
    let mut running = state.remote.running.lock().await;
    if running.is_none() {
        let host = match store::host(&state.db).await? {
            Some(host) => host,
            None => store::keep_identity(&state.db, identity::Identity::generate(state.instance_id.as_deref())?).await?,
        };
        let listener = match tokio::net::TcpListener::bind(SocketAddr::new(address, host.port)).await {
            Ok(listener) => listener,
            // Taken since, or never chosen: any free port, which a paired Mac finds again by Bonjour.
            Err(error) => {
                log(state, "info", "port_taken", json!({ "port": host.port, "error": error.to_string() }));
                tokio::net::TcpListener::bind(SocketAddr::new(address, 0)).await.context("bind the remote port")?
            }
        };
        let port = listener.local_addr()?.port();
        let tls = host.identity.server_config()?;
        // Stored before it serves, so a listener never runs that the next start would not resume.
        store::set_enabled(&state.db, true, Some(port)).await?;
        let task = tokio::spawn(listener::serve(state.clone(), listener, tls, listener::router(state.clone())));
        *running = Some(Running { port, task });
        log(state, "info", "listener_on", json!({ "port": port }));
        state.publish(Event::RemoteHost);
    }
    drop(running);
    status(state).await
}

pub async fn disable(state: &AppState) -> Result<Status> {
    let mut running = state.remote.running.lock().await;
    pairing::close(state);
    if running.take().is_some() {
        log(state, "info", "listener_off", json!({}));
        state.publish(Event::RemoteHost);
    }
    if store::host(&state.db).await?.is_some() {
        store::set_enabled(&state.db, false, None).await?;
    }
    drop(running);
    status(state).await
}

/// At start: the listener on again if it was on when the app last ran, and the links to the
/// paired Macs.
pub async fn resume(state: &AppState) {
    links::start_all(state).await;
    match store::host(&state.db).await {
        Ok(Some(host)) if host.enabled => {
            if let Err(error) = enable(state).await {
                log(state, "error", "listener_failed", json!({ "error": format!("{error:#}") }));
            }
        }
        Ok(_) => {}
        Err(error) => log(state, "error", "listener_unread", json!({ "error": format!("{error:#}") })),
    }
}

/// `new` was given in place of `old` (`pairing::finish`); `old` goes when `new` is first used.
pub(crate) fn replace(state: &AppState, new: String, old: String) {
    if new != old {
        state.remote.replacing.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(new, old);
    }
}

/// A client's token was used: the client it replaced, if any, is revoked now.
pub(crate) async fn used(state: &AppState, id: &str) {
    let old = state.remote.replacing.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(id);
    if let Some(old) = old {
        log(state, "info", "client_replaced", json!({ "old": old, "new": id }));
        let _ = revoke(state, &old).await;
    }
}

/// Forgets a paired client and ends its open stream. Its next request is refused.
pub async fn revoke(state: &AppState, id: &str) -> Result<bool> {
    let removed = store::remove_client(&state.db, id).await?;
    let _ = state.remote.revoked.send(id.to_owned());
    if removed {
        log(state, "info", "client_revoked", json!({ "client": id }));
        state.publish(Event::RemoteClients);
    }
    Ok(removed)
}
