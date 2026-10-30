//! This Mac's side of each pairing: a task per peer that keeps the peer's event stream open while
//! it answers, and tells the app what it hears (`Event::Remote`) and whether the peer answers
//! (`Event::RemotePeer`). A peer that cannot be reached, or whose stream ends, is not tried again
//! on a timer: only when someone opens Settings → Remote to look for it (`connect`). Requests the app makes of a peer are
//! forwarded as they are, with the peer's token, over a connection pinned to its certificate.

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::Duration,
};

use anyhow::Result;
use axum::http::{Method, StatusCode};
use http_body_util::BodyExt;
use serde::Serialize;
use serde_json::{json, Value};
use tokio::task::JoinHandle;

use super::{client, identity, store};
use crate::{AppState, Event};

/// The host sends a keep-alive every 15 seconds; a stream silent for longer than this is dead.
const SILENT: Duration = if cfg!(test) { Duration::from_secs(2) } else { Duration::from_secs(45) };
/// A reopened stream that lasts less than this is not reopened again (`run`).
const BRIEF: Duration = if cfg!(test) { Duration::from_millis(500) } else { Duration::from_secs(10) };
/// The most addresses kept for a peer; the one it last answered at first.
const ADDRESSES: usize = 4;
/// The most one event may hold before the stream is dropped as broken.
const EVENT_LIMIT: usize = 16 * 1024 * 1024;

/// Whether a peer answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Reach {
    Connecting,
    Online,
    Offline,
    /// The peer refused this Mac's token: it was revoked there, and only pairing again helps.
    Revoked,
    /// The Mac at the peer's address shows another certificate: not the one paired (its data was
    /// reset, or another took the address). Only pairing again helps.
    Changed,
}

impl Reach {
    fn name(self) -> &'static str {
        match self {
            Reach::Connecting => "connecting",
            Reach::Online => "online",
            Reach::Offline => "offline",
            Reach::Revoked => "revoked",
            Reach::Changed => "changed",
        }
    }
}

/// The running links, by peer id. A short lock: never held across an await.
#[derive(Default)]
pub struct Links {
    links: Mutex<HashMap<String, Link>>,
    /// Numbers each link, so a task that was replaced cannot change its successor's state.
    made: AtomicU64,
}

struct Link {
    task: JoinHandle<()>,
    reach: Reach,
    generation: u64,
}

impl Drop for Link {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Links {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Link>> {
        self.links.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn reach(&self, id: &str) -> Reach {
        self.lock().get(id).map_or(Reach::Offline, |link| link.reach)
    }

    #[cfg(test)]
    pub(super) fn linked(&self, id: &str) -> bool {
        self.lock().contains_key(id)
    }
}

/// Links every stored peer; at start.
pub async fn start_all(state: &AppState) {
    match store::peers(&state.db).await {
        Ok(peers) => peers.iter().for_each(|peer| link(state, &peer.id)),
        Err(error) => super::log(state, "error", "peers_unread", json!({ "error": error.to_string() })),
    }
}

/// (Re)links one peer: a pairing replaced its token, or it is new.
pub fn link(state: &AppState, id: &str) {
    link_at(state, id, None);
}

/// Links a peer, trying `seen` first: an address Bonjour saw it at, kept among its addresses only
/// once the peer answers there.
fn link_at(state: &AppState, id: &str, seen: Option<String>) {
    let generation = state.remote.links.made.fetch_add(1, Ordering::Relaxed);
    // Spawned under the lock, so the task finds its link in place the first time it looks; the
    // link it replaces is dropped, and its task with it.
    let mut links = state.remote.links.lock();
    let task = tokio::spawn(run(state.clone(), id.to_owned(), generation, seen));
    links.insert(id.to_owned(), Link { task, reach: Reach::Connecting, generation });
}

/// Tries a peer again that is not linked now, for someone looking for it; `address` is where
/// Bonjour sees it, tried first and kept first among its addresses once the peer answers there
/// (anyone on the network can advertise a peer's id). A peer online or being reached is left as
/// it is, and a revoked one too: only pairing again helps it.
pub async fn connect(state: &AppState, id: &str, address: Option<&str>) -> Result<Option<Reach>> {
    if !store::peers(&state.db).await?.iter().any(|peer| peer.id == id) {
        return Ok(None);
    }
    let reach = state.remote.links.reach(id);
    if matches!(reach, Reach::Online | Reach::Connecting | Reach::Revoked) {
        return Ok(Some(reach));
    }
    let seen = address.map(str::trim).filter(|address| !address.is_empty()).map(str::to_owned);
    super::log(state, "info", "peer_retry", json!({ "peer": super::short(id), "seen": seen }));
    link_at(state, id, seen);
    Ok(Some(Reach::Connecting))
}

pub fn unlink(state: &AppState, id: &str) {
    state.remote.links.lock().remove(id);
}

/// Records how a peer answers and tells the app when that changed. `generation` is the link's
/// that saw it; None for a forwarded request, which speaks for whichever link is current.
pub(super) fn set_reach(state: &AppState, id: &str, generation: Option<u64>, reach: Reach) {
    let changed = match state.remote.links.lock().get_mut(id) {
        Some(link) if link.reach != reach && generation.is_none_or(|generation| generation == link.generation) => {
            link.reach = reach;
            true
        }
        _ => false,
    };
    if changed {
        // "Errors only" in Activity shows what needs pairing again.
        let level = if matches!(reach, Reach::Revoked | Reach::Changed) { "error" } else { "info" };
        super::log(state, level, "peer_reach", json!({ "peer": super::short(id), "reach": reach.name() }));
        state.publish(Event::RemotePeer { peer: id.to_owned(), reach: reach.name() });
    }
}

/// Tries the peer and relays its stream for as long as it lasts. A stream that ends is opened
/// again at once, which hears why: the peer went away, or it revoked this Mac. A reopened stream
/// that ends within `BRIEF` is not opened a third time: a peer that answers and hangs up at once
/// is not tried in a loop.
async fn run(state: AppState, id: String, generation: u64, seen: Option<String>) {
    let mut outcome = listen(&state, &id, generation, seen.as_deref()).await;
    let mut brief = false;
    while let Ok(true) = outcome {
        if brief {
            super::log(&state, "info", "peer_not_reopened", json!({ "peer": super::short(&id), "reason": "its stream ended again within seconds" }));
            break;
        }
        let opened = tokio::time::Instant::now();
        outcome = listen(&state, &id, generation, None).await;
        brief = opened.elapsed() < BRIEF;
    }
    let reach = match outcome {
        Ok(_) => Reach::Offline,
        Err(Refused::Revoked) => Reach::Revoked,
        Err(Refused::Changed) => Reach::Changed,
        Err(Refused::Gone) => return,
    };
    set_reach(&state, &id, Some(generation), reach);
}

enum Refused {
    /// The peer answered `401`.
    Revoked,
    /// The address answered with another certificate.
    Changed,
    /// The peer was forgotten here.
    Gone,
}

/// Opens the peer's stream at the first address that answers, `seen` before the stored ones, and
/// relays it until it ends. Answers whether it was ever online; `Changed` only when no address got
/// through and a stored one showed another certificate (an address only seen proves nothing).
async fn listen(state: &AppState, id: &str, generation: u64, seen: Option<&str>) -> Result<bool, Refused> {
    let (peer, token) = match peer(state, id).await {
        Ok(Some(found)) => found,
        Ok(None) => return Err(Refused::Gone),
        // Not read now: offline, so the next look tries it again.
        Err(error) => {
            super::log(state, "error", "peer_unread", json!({ "peer": super::short(id), "error": error.to_string() }));
            return Ok(false);
        }
    };
    let seen = seen.filter(|seen| !peer.addresses.iter().any(|known| known == seen));
    let mut changed = false;
    for address in seen.into_iter().chain(peer.addresses.iter().map(String::as_str)) {
        let tls = match identity::pinned_client_config(&peer.id) {
            Ok(tls) => tls,
            Err(error) => {
                super::log(state, "error", "peer_unpinned", json!({ "peer": super::short(id), "error": format!("{error:#}") }));
                return Ok(false);
            }
        };
        let open = match client::open(address, tls, Method::GET, "/api/stream", Some(&token), None).await {
            Ok(open) => open,
            Err(error) => {
                let other = error.is::<client::CertificateChanged>();
                super::log(state, "info", "peer_address_failed", json!({
                    "peer": super::short(id), "name": peer.name, "address": address,
                    "seen": Some(address) == seen, "certificateChanged": other, "error": format!("{error:#}"),
                }));
                changed |= Some(address) != seen && other;
                continue;
            }
        };
        match open.response.status() {
            StatusCode::OK => {}
            StatusCode::UNAUTHORIZED => {
                super::log(state, "error", "peer_refused_token", json!({ "peer": super::short(id), "name": peer.name, "address": address }));
                return Err(Refused::Revoked);
            }
            status => {
                super::log(state, "info", "peer_address_failed", json!({
                    "peer": super::short(id), "name": peer.name, "address": address, "status": status.as_u16(),
                }));
                continue;
            }
        }
        super::log(state, "info", "peer_online", json!({ "peer": super::short(id), "name": peer.name, "address": address }));
        set_reach(state, id, Some(generation), Reach::Online);
        if peer.addresses.first().map(String::as_str) != Some(address) {
            remember(state, &peer, address).await;
        }
        let client::Open { response, connection: _connection } = open;
        let ended = relay(state, id, response.into_body()).await;
        super::log(state, "info", "peer_stream_ended", json!({ "peer": super::short(id), "name": peer.name, "address": address, "reason": ended }));
        return Ok(true);
    }
    if changed {
        Err(Refused::Changed)
    } else {
        Ok(false)
    }
}

/// The peer answered at `address`: it goes first among its addresses, the oldest dropped past
/// `ADDRESSES`.
async fn remember(state: &AppState, peer: &store::Peer, address: &str) {
    let mut addresses = peer.addresses.clone();
    addresses.retain(|known| known != address);
    addresses.insert(0, address.to_owned());
    addresses.truncate(ADDRESSES);
    match store::set_addresses(&state.db, &peer.id, &addresses).await {
        Ok(()) => super::log(state, "info", "peer_address_kept", json!({ "peer": super::short(&peer.id), "addresses": addresses })),
        Err(error) => super::log(state, "error", "peer_address_unkept", json!({ "peer": super::short(&peer.id), "error": error.to_string() })),
    }
}

/// Passes each `data:` event of an SSE body on as `Event::Remote`, until the body ends, breaks,
/// or is silent past `SILENT`.
/// Answers why it ended, for the log.
async fn relay(state: &AppState, id: &str, mut body: hyper::body::Incoming) -> &'static str {
    let mut parser = Sse::default();
    loop {
        let frame = match tokio::time::timeout(SILENT, body.frame()).await {
            Ok(Some(Ok(frame))) => frame,
            Ok(Some(Err(_))) => return "broken",
            Ok(None) => return "closed by the other Mac",
            Err(_) => return "silent",
        };
        let Ok(data) = frame.into_data() else { continue };
        for data in parser.push(&data) {
            if let Ok(event) = serde_json::from_str::<Value>(&data) {
                state.publish(Event::Remote { peer: id.to_owned(), relayed: event });
            }
        }
        if parser.pending.len() > EVENT_LIMIT {
            return "event too large";
        }
    }
}

/// Server-sent events as they arrive in pieces: lines end in LF, CRLF or CR, and a blank line
/// ends an event, whose `data:` lines are joined by newlines.
#[derive(Default)]
pub(super) struct Sse {
    /// Bytes past the last whole event, with line ends made LF.
    pending: Vec<u8>,
    /// How far `pending` holds no event end, so each piece is searched once.
    searched: usize,
    /// The last byte was a CR, whose LF, if one comes next, is part of the same line end.
    after_cr: bool,
}

impl Sse {
    /// Takes the next piece; answers the data of each event it completes.
    pub(super) fn push(&mut self, piece: &[u8]) -> Vec<String> {
        for &byte in piece {
            match byte {
                b'\r' => {
                    self.pending.push(b'\n');
                    self.after_cr = true;
                }
                b'\n' if self.after_cr => self.after_cr = false,
                _ => {
                    self.pending.push(byte);
                    self.after_cr = false;
                }
            }
        }
        let mut events = Vec::new();
        while let Some(at) = self.pending[self.searched.saturating_sub(1)..].windows(2).position(|pair| pair == b"\n\n") {
            let end = self.searched.saturating_sub(1) + at + 2;
            let block: Vec<u8> = self.pending.drain(..end).collect();
            self.searched = 0;
            let text = String::from_utf8_lossy(&block);
            let data: Vec<&str> = text
                .split('\n')
                .filter_map(|line| line.strip_prefix("data:"))
                .map(|value| value.strip_prefix(' ').unwrap_or(value))
                .collect();
            if !data.is_empty() {
                events.push(data.join("\n"));
            }
        }
        self.searched = self.pending.len();
        events
    }
}

async fn peer(state: &AppState, id: &str) -> Result<Option<(store::Peer, String)>> {
    let peer = store::peers(&state.db).await?.into_iter().find(|peer| peer.id == id);
    let token = store::peer_token(&state.db, id).await?;
    Ok(peer.zip(token))
}

/// Sends the app's request on to the peer, at the first of its addresses that answers, and
/// answers what the peer did; None for a peer not paired. A `401` marks the peer revoked, another
/// certificate marks it changed.
pub async fn forward(
    state: &AppState,
    id: &str,
    method: Method,
    path: &str,
    body: Option<&Value>,
) -> Result<Option<(StatusCode, Value)>> {
    let Some((peer, token)) = peer(state, id).await? else { return Ok(None) };
    let mut failure = None;
    for address in &peer.addresses {
        let tls = identity::pinned_client_config(&peer.id)?;
        match client::request(address, tls, method.clone(), path, Some(&token), body, client::PAIRED_BODY).await {
            Ok((StatusCode::UNAUTHORIZED, answer)) => {
                set_reach(state, id, None, Reach::Revoked);
                return Ok(Some((StatusCode::UNAUTHORIZED, answer)));
            }
            Ok(answer) => {
                if !answer.0.is_success() {
                    // A refusal is the other Mac's list at work (a read-only page asks for more);
                    // anything else went wrong there.
                    let level = if answer.0 == StatusCode::FORBIDDEN { "info" } else { "error" };
                    super::log(state, level, "peer_request_refused", json!({
                        "peer": super::short(id), "name": peer.name, "path": path, "status": answer.0.as_u16(),
                        // What it said, not a whole body it may have sent.
                        "answer": answer.1.get("error").cloned().unwrap_or_else(|| json!(answer.1.to_string().chars().take(1000).collect::<String>())),
                    }));
                }
                return Ok(Some(answer));
            }
            // A changed certificate is the failure told, over an address that did not answer.
            Err(error) => {
                if failure.as_ref().is_none_or(|failure: &anyhow::Error| !failure.is::<client::CertificateChanged>()) {
                    failure = Some(error);
                }
            }
        }
    }
    let failure = failure.unwrap_or_else(|| anyhow::anyhow!("no address for {}", peer.name));
    super::log(state, "error", "peer_request_failed", json!({
        "peer": super::short(id), "name": peer.name, "path": path, "addresses": peer.addresses, "error": format!("{failure:#}"),
    }));
    if failure.is::<client::CertificateChanged>() {
        set_reach(state, id, None, Reach::Changed);
    }
    Err(failure)
}
