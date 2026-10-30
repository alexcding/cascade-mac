//! This Mac's side of each pairing: a task per peer that keeps the peer's event stream open,
//! retrying while it cannot be reached, and tells the app what it hears (`Event::Remote`) and
//! whether the peer answers (`Event::RemotePeer`). Requests the app makes of a peer are
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
use serde_json::Value;
use tokio::task::JoinHandle;

use super::{client, identity, store};
use crate::{AppState, Event};

/// Waits between tries while a peer cannot be reached: doubling from the first to the last.
const RETRY_FIRST: Duration = if cfg!(test) { Duration::from_millis(50) } else { Duration::from_secs(2) };
const RETRY_LAST: Duration = if cfg!(test) { Duration::from_millis(200) } else { Duration::from_secs(60) };
/// The host sends a keep-alive every 15 seconds; a stream silent for longer than this is dead.
const SILENT: Duration = if cfg!(test) { Duration::from_secs(2) } else { Duration::from_secs(45) };
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
        Err(error) => tracing::warn!(%error, "read the paired Macs"),
    }
}

/// (Re)links one peer: a pairing replaced its token, or it is new.
pub fn link(state: &AppState, id: &str) {
    let generation = state.remote.links.made.fetch_add(1, Ordering::Relaxed);
    // Spawned under the lock, so the task finds its link in place the first time it looks; the
    // link it replaces is dropped, and its task with it.
    let mut links = state.remote.links.lock();
    let task = tokio::spawn(run(state.clone(), id.to_owned(), generation));
    links.insert(id.to_owned(), Link { task, reach: Reach::Connecting, generation });
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
        state.publish(Event::RemotePeer { peer: id.to_owned(), reach: reach.name() });
    }
}

async fn run(state: AppState, id: String, generation: u64) {
    let mut wait = RETRY_FIRST;
    loop {
        match listen(&state, &id, generation).await {
            // Heard from it, then lost it: try again soon.
            Ok(true) => wait = RETRY_FIRST,
            Ok(false) => {}
            Err(Refused::Revoked) => {
                set_reach(&state, &id, Some(generation), Reach::Revoked);
                return;
            }
            Err(Refused::Changed) => {
                set_reach(&state, &id, Some(generation), Reach::Changed);
                return;
            }
            Err(Refused::Gone) => return,
        }
        set_reach(&state, &id, Some(generation), Reach::Offline);
        tokio::time::sleep(wait).await;
        wait = (wait * 2).min(RETRY_LAST);
    }
}

enum Refused {
    /// The peer answered `401`.
    Revoked,
    /// The address answered with another certificate.
    Changed,
    /// The peer was forgotten here.
    Gone,
}

/// Opens the peer's stream at the first address that answers and relays it until it ends.
/// Answers whether it was ever online; `Changed` only when no address got through and one showed
/// another certificate.
async fn listen(state: &AppState, id: &str, generation: u64) -> Result<bool, Refused> {
    let Ok(Some((peer, token))) = peer(state, id).await else { return Err(Refused::Gone) };
    let mut changed = false;
    for address in &peer.addresses {
        let Ok(tls) = identity::pinned_client_config(&peer.id) else { return Ok(false) };
        let open = match client::open(address, tls, Method::GET, "/api/stream", Some(&token), None).await {
            Ok(open) => open,
            Err(error) => {
                changed |= error.is::<client::CertificateChanged>();
                continue;
            }
        };
        match open.response.status() {
            StatusCode::OK => {}
            StatusCode::UNAUTHORIZED => return Err(Refused::Revoked),
            _ => continue,
        }
        set_reach(state, id, Some(generation), Reach::Online);
        let client::Open { response, connection: _connection } = open;
        relay(state, id, response.into_body()).await;
        return Ok(true);
    }
    if changed {
        Err(Refused::Changed)
    } else {
        Ok(false)
    }
}

/// Passes each `data:` event of an SSE body on as `Event::Remote`, until the body ends, breaks,
/// or is silent past `SILENT`.
async fn relay(state: &AppState, id: &str, mut body: hyper::body::Incoming) {
    let mut parser = Sse::default();
    loop {
        let frame = match tokio::time::timeout(SILENT, body.frame()).await {
            Ok(Some(Ok(frame))) => frame,
            _ => return,
        };
        let Ok(data) = frame.into_data() else { continue };
        for data in parser.push(&data) {
            if let Ok(event) = serde_json::from_str::<Value>(&data) {
                state.publish(Event::Remote { peer: id.to_owned(), event });
            }
        }
        if parser.pending.len() > EVENT_LIMIT {
            return;
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
            Ok(answer) => return Ok(Some(answer)),
            // A changed certificate is the failure told, over an address that did not answer.
            Err(error) => {
                if failure.as_ref().is_none_or(|failure: &anyhow::Error| !failure.is::<client::CertificateChanged>()) {
                    failure = Some(error);
                }
            }
        }
    }
    let failure = failure.unwrap_or_else(|| anyhow::anyhow!("no address for {}", peer.name));
    if failure.is::<client::CertificateChanged>() {
        set_reach(state, id, None, Reach::Changed);
    }
    Err(failure)
}
