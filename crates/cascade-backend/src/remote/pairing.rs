//! Pairing two Macs once, with a 6-digit code the host shows and the person types on the other
//! Mac (docs/remote/05-mac-to-mac.md, "Pairing").
//!
//! The code is never sent. Both sides run SPAKE2 with it (`/pair/start`), which gives them the
//! same key only if they used the same code, and tells someone watching nothing they could test
//! guesses against. Then each proves it has the key with an HMAC over the exchange and the
//! certificate fingerprint as it sees it (`/pair/finish`): a machine in the middle shows the client
//! another certificate, so the two disagree and pairing fails. Only then does the host hand out a
//! token, over that same certificate, which the client pins from then on.
//!
//! A pairing window is open while the host's sheet is: until it is closed, a client pairs, five
//! minutes pass, or three attempts are used.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use axum::{
    extract::State,
    http::{Method, StatusCode},
    Json,
};
use ring::hmac;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use spake2::{Ed25519Group, Identity as Side, Password, Spake2};
use uuid::Uuid;

use super::{client, identity, store};
use crate::{error::ApiError, AppState, Event};

const WINDOW: Duration = Duration::from_secs(5 * 60);
pub(crate) const ATTEMPTS: u8 = 3;
const CLIENT: &[u8] = b"cascade-client";
const HOST: &[u8] = b"cascade-host";

/// The host's open pairing window.
pub(crate) struct Window {
    code: String,
    name: String,
    /// The listener's certificate, which the client's proof must cover.
    fingerprint: String,
    closes: Instant,
    attempts: u8,
    /// Exchanges past `/pair/start`, by session id, each finished at most once.
    started: HashMap<String, Started>,
}

struct Started {
    key: Vec<u8>,
    transcript: Transcript,
    label: String,
}

/// What both sides' proofs cover: both SPAKE2 messages, in order.
#[derive(Clone)]
struct Transcript {
    from_client: Vec<u8>,
    from_host: Vec<u8>,
}

/// What a proof signs: who is proving, the transcript and the fingerprint, each length-prefixed.
fn proven(side: &[u8], transcript: &Transcript, fingerprint: &str) -> Vec<u8> {
    let mut message = Vec::new();
    for part in [side, &transcript.from_client, &transcript.from_host, fingerprint.as_bytes()] {
        message.extend_from_slice(&(part.len() as u64).to_be_bytes());
        message.extend_from_slice(part);
    }
    message
}

/// HMAC-SHA256 of `proven`, keyed by the SPAKE2 key, hex.
fn proof(key: &[u8], side: &[u8], transcript: &Transcript, fingerprint: &str) -> String {
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, key), &proven(side, transcript, fingerprint));
    identity::hex(tag.as_ref())
}

/// Checks a presented proof in constant time.
fn verify(key: &[u8], side: &[u8], transcript: &Transcript, fingerprint: &str, presented: &str) -> bool {
    let Some(presented) = identity::unhex(presented) else { return false };
    hmac::verify(&hmac::Key::new(hmac::HMAC_SHA256, key), &proven(side, transcript, fingerprint), &presented).is_ok()
}

fn code() -> Result<String> {
    let token = identity::token()?;
    let number = u64::from_str_radix(&token[..15], 16)?;
    Ok(format!("{:06}", number % 1_000_000))
}

// ---- host ------------------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Opened {
    pub code: String,
    pub seconds: u64,
}

/// Opens a pairing window under `name` (the Mac's name, shown to the other Mac), replacing any
/// open one. The listener must be on: the window is answered there.
pub async fn open(state: &AppState, name: &str) -> Result<Opened> {
    // Under the listener's lock, so turning it off cannot come between the check and the window.
    let running = state.remote.running.lock().await;
    if running.is_none() {
        bail!("turn on other Macs' access first");
    }
    let host = store::host(&state.db).await?.context("the listener has no certificate")?;
    let code = code()?;
    *lock(&state.remote.pairing) = Some(Window {
        code: code.clone(),
        name: name.to_owned(),
        fingerprint: host.identity.fingerprint(),
        closes: Instant::now() + WINDOW,
        attempts: 0,
        started: HashMap::new(),
    });
    drop(running);
    state.publish(Event::RemotePairing);
    Ok(Opened { code, seconds: WINDOW.as_secs() })
}

pub fn close(state: &AppState) {
    if lock(&state.remote.pairing).take().is_some() {
        state.publish(Event::RemotePairing);
    }
}

/// `GET /api/remote/pairing`: whether a window is open, and what is left of it. The host's sheet
/// reads it on a `remote-pairing` event, to say when the window is used up or a Mac paired.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowState {
    pub open: bool,
    pub attempts_left: u8,
    pub seconds: u64,
}

pub fn window(state: &AppState) -> WindowState {
    let now = Instant::now();
    match lock(&state.remote.pairing).as_ref().filter(|window| window.closes > now) {
        Some(window) => WindowState {
            open: true,
            attempts_left: ATTEMPTS.saturating_sub(window.attempts),
            seconds: (window.closes - now).as_secs(),
        },
        None => WindowState { open: false, attempts_left: 0, seconds: 0 },
    }
}

fn lock(window: &Mutex<Option<Window>>) -> std::sync::MutexGuard<'_, Option<Window>> {
    window.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Deserialize)]
pub(crate) struct StartBody {
    message: String,
    #[serde(default)]
    label: String,
}

fn refused(status: StatusCode, message: &str) -> ApiError {
    ApiError::status(status, message)
}

/// `POST /pair/start` `{message, label}` → `{message, session}`. Each call is one attempt.
pub(crate) async fn start(State(state): State<AppState>, Json(body): Json<StartBody>) -> Result<Json<Value>, ApiError> {
    let from_client = identity::unhex(&body.message).ok_or_else(|| ApiError::bad_request("bad message"))?;
    let mut guard = lock(&state.remote.pairing);
    if guard.as_ref().is_some_and(|window| window.closes <= Instant::now()) {
        *guard = None;
    }
    // Past its attempts the window stays, refusing new ones, so an attempt already started can
    // still finish; it closes when that one fails (`finish`).
    let Some(window) = guard.as_mut().filter(|window| window.attempts < ATTEMPTS) else {
        return Err(refused(StatusCode::NOT_FOUND, "not pairing"));
    };
    window.attempts += 1;
    let used_up = window.attempts == ATTEMPTS;
    let (spake, from_host) =
        Spake2::<Ed25519Group>::start_b(&Password::new(window.code.as_bytes()), &Side::new(CLIENT), &Side::new(HOST));
    // A bad message still spent its attempt, and is told as one when it was the last.
    let answer = spake.finish(&from_client).map(|key| {
        let session = Uuid::new_v4().to_string();
        let label = body.label.chars().take(64).collect();
        window.started.insert(session.clone(), Started { key, transcript: Transcript { from_client, from_host: from_host.clone() }, label });
        json!({ "message": identity::hex(&from_host), "session": session })
    });
    drop(guard);
    if used_up {
        state.publish(Event::RemotePairing);
    }
    answer.map(Json).map_err(|_| ApiError::bad_request("bad message"))
}

#[derive(Deserialize)]
pub(crate) struct FinishBody {
    session: String,
    proof: String,
}

/// `POST /pair/finish` `{session, proof}` → `{proof, token, name}`, or `403` for a wrong code. A
/// right one closes the window.
///
/// The client is kept, and its token sent, before the client has checked the host's proof: if
/// this answer is lost, the host lists a Mac that holds no token until it is revoked. Accepted for
/// v1 (docs/remote/05-mac-to-mac.md).
pub(crate) async fn finish(State(state): State<AppState>, Json(body): Json<FinishBody>) -> Result<Json<Value>, ApiError> {
    let (started, name, fingerprint) = {
        let mut guard = lock(&state.remote.pairing);
        let Some(window) = guard.as_mut().filter(|window| window.closes > Instant::now()) else {
            *guard = None;
            return Err(refused(StatusCode::NOT_FOUND, "not pairing"));
        };
        let started = window.started.remove(&body.session).ok_or_else(|| refused(StatusCode::NOT_FOUND, "not pairing"))?;
        if !verify(&started.key, CLIENT, &started.transcript, &window.fingerprint, &body.proof) {
            if window.attempts >= ATTEMPTS && window.started.is_empty() {
                *guard = None;
                drop(guard);
                state.publish(Event::RemotePairing);
            }
            return Err(refused(StatusCode::FORBIDDEN, "wrong code"));
        }
        let taken = (started, window.name.clone(), window.fingerprint.clone());
        *guard = None;
        taken
    };
    let (_, token) = store::add_client(&state.db, &started.label).await.map_err(ApiError::internal)?;
    state.publish(Event::RemotePairing);
    state.publish(Event::RemoteClients);
    let proof = proof(&started.key, HOST, &started.transcript, &fingerprint);
    Ok(Json(json!({ "proof": proof, "token": token, "name": name })))
}

// ---- client ----------------------------------------------------------------------------------

/// Pairs with the Mac at `address` (`host:port`) using the code it shows, and keeps it as a peer
/// under `label`, the name this Mac gives itself there.
pub async fn pair(state: &AppState, address: &str, code: &str, label: &str) -> Result<store::Peer> {
    let code = code.trim();
    if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
        bail!("the code is six digits");
    }
    let (spake, from_client) =
        Spake2::<Ed25519Group>::start_a(&Password::new(code.as_bytes()), &Side::new(CLIENT), &Side::new(HOST));
    let seen = Arc::new(Mutex::new(None));
    let (status, started) = client::request(
        address,
        identity::observing_client_config(seen.clone())?,
        Method::POST,
        "/pair/start",
        None,
        Some(&json!({ "message": identity::hex(&from_client), "label": label })),
    )
    .await?;
    check(status, &started)?;
    let fingerprint = lock_seen(&seen).context("no certificate from the other Mac")?;
    let from_host = started["message"].as_str().and_then(identity::unhex).ok_or_else(|| anyhow!("a bad answer from the other Mac"))?;
    let session = started["session"].as_str().unwrap_or_default();
    let key = spake.finish(&from_host).map_err(|_| anyhow!("a bad answer from the other Mac"))?;
    let transcript = Transcript { from_client, from_host };

    let mine = proof(&key, CLIENT, &transcript, &fingerprint);
    let (status, finished) = client::request(
        address,
        identity::pinned_client_config(&fingerprint)?,
        Method::POST,
        "/pair/finish",
        None,
        Some(&json!({ "session": session, "proof": mine })),
    )
    .await?;
    check(status, &finished)?;
    if !verify(&key, HOST, &transcript, &fingerprint, finished["proof"].as_str().unwrap_or_default()) {
        bail!("the other Mac could not prove it has the code");
    }
    let Some(token) = finished["token"].as_str() else {
        bail!("a bad answer from the other Mac");
    };
    // Known by its certificate, which lasts across its restarts; a new one is a new pairing.
    let peer = store::Peer {
        id: fingerprint,
        name: finished["name"].as_str().unwrap_or("Mac").to_owned(),
        addresses: vec![address.to_owned()],
    };
    store::keep_peer(&state.db, &peer, token).await?;
    state.publish(Event::RemotePeers);
    Ok(peer)
}

fn lock_seen(seen: &Mutex<Option<String>>) -> Option<String> {
    seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
}

fn check(status: StatusCode, body: &Value) -> Result<()> {
    match status {
        StatusCode::OK => Ok(()),
        StatusCode::FORBIDDEN => bail!("wrong code"),
        StatusCode::NOT_FOUND => bail!("the other Mac is not pairing; open Pair a Mac there"),
        _ => bail!("the other Mac answered {status}: {}", body["error"].as_str().unwrap_or_default()),
    }
}

#[cfg(test)]
pub(crate) mod testing {
    //! Steps of `pair` a test drives by hand, to play a machine in the middle.
    use super::*;

    pub(crate) fn proof_for(key: &[u8], from_client: &[u8], from_host: &[u8], fingerprint: &str) -> String {
        let transcript = Transcript { from_client: from_client.to_vec(), from_host: from_host.to_vec() };
        proof(key, CLIENT, &transcript, fingerprint)
    }

    pub(crate) fn start(code: &str) -> (Spake2<Ed25519Group>, Vec<u8>) {
        Spake2::<Ed25519Group>::start_a(&Password::new(code.as_bytes()), &Side::new(CLIENT), &Side::new(HOST))
    }
}
