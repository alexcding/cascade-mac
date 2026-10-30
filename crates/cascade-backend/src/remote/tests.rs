//! The listener over real TLS on loopback, with a client that pins its certificate as a paired
//! Mac does.

use std::{
    net::{IpAddr, Ipv4Addr},
    sync::Arc,
    time::Duration,
};

use serde_json::{json, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use tokio_rustls::{client::TlsStream, TlsConnector};

use super::{identity, start, store, Status};
use crate::{AppState, Event};

const LOOPBACK: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

async fn listening(dir: &std::path::Path) -> (AppState, Status) {
    let state = AppState::new(crate::Database::open(dir).unwrap(), Some("test-host".into()));
    let status = start(&state, LOOPBACK).await.unwrap();
    (state, status)
}

async fn connect(status: &Status, fingerprint: &str) -> std::io::Result<TlsStream<TcpStream>> {
    let config = identity::pinned_client_config(fingerprint).unwrap();
    let tcp = TcpStream::connect((LOOPBACK, status.port.unwrap())).await?;
    let name = rustls::pki_types::ServerName::try_from("cascade").unwrap();
    TlsConnector::from(Arc::new(config)).connect(name, tcp).await
}

async fn send(stream: &mut TlsStream<TcpStream>, method: &str, path: &str, token: Option<&str>, body: Option<Value>) {
    let body = body.map(|body| body.to_string()).unwrap_or_default();
    let auth = token.map(|token| format!("Authorization: Bearer {token}\r\n")).unwrap_or_default();
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: cascade\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(format!("{head}{body}").as_bytes()).await.unwrap();
}

/// One request; its status and body, the body decoded as JSON when it is.
async fn call(status: &Status, method: &str, path: &str, token: Option<&str>, body: Option<Value>) -> (u16, Value) {
    let mut stream = connect(status, status.fingerprint.as_deref().unwrap()).await.unwrap();
    send(&mut stream, method, path, token, body).await;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await.unwrap();
    let text = String::from_utf8(raw).unwrap();
    let (head, body) = text.split_once("\r\n\r\n").unwrap();
    let code = head.split(' ').nth(1).unwrap().parse().unwrap();
    let body = if head.to_ascii_lowercase().contains("transfer-encoding: chunked") { unchunk(body) } else { body.to_owned() };
    (code, serde_json::from_str(&body).unwrap_or(Value::String(body)))
}

fn unchunk(mut body: &str) -> String {
    let mut out = String::new();
    while let Some((size, rest)) = body.split_once("\r\n") {
        let size = usize::from_str_radix(size.trim(), 16).unwrap_or(0);
        if size == 0 {
            break;
        }
        out.push_str(&rest[..size]);
        body = &rest[size + 2..];
    }
    out
}

#[tokio::test]
async fn a_request_needs_a_paired_clients_token() {
    let dir = tempfile::tempdir().unwrap();
    let (state, status) = listening(dir.path()).await;
    let (_, token) = store::add_client(&state.db, "MacBook").await.unwrap();

    assert_eq!(call(&status, "GET", "/api/tasks", None, None).await.0, 401);
    assert_eq!(call(&status, "GET", "/api/tasks", Some("not-a-token"), None).await.0, 401);
    // Unknown paths are not found, token or none.
    assert_eq!(call(&status, "GET", "/api/nowhere", None, None).await.0, 404);
    assert_eq!(call(&status, "GET", "/api/config", None, None).await.0, 404);

    let (code, tasks) = call(&status, "GET", "/api/tasks", Some(&token), None).await;
    assert_eq!((code, tasks), (200, json!([])));
    let (code, health) = call(&status, "GET", "/api/backend/health", Some(&token), None).await;
    assert_eq!((code, health["instanceId"].as_str()), (200, Some("test-host")));
}

#[tokio::test]
async fn only_the_allowlist_is_served() {
    let dir = tempfile::tempdir().unwrap();
    let (state, status) = listening(dir.path()).await;
    let (_, token) = store::add_client(&state.db, "MacBook").await.unwrap();

    // Routes the loopback router serves, which a paired Mac must not reach: unknown here (404), or
    // a method the allowlisted path does not take (405).
    for (method, path) in [("GET", "/api/config"), ("GET", "/api/db"), ("POST", "/api/tasks"), ("GET", "/api/remote/clients"), ("POST", "/api/remote/enable")] {
        let code = call(&status, method, path, Some(&token), Some(json!({}))).await.0;
        assert!(matches!(code, 404 | 405), "{method} {path}: {code}");
    }
    // A project shows its name and icon, none of its paths.
    state.db.add_project(json!({ "name": "cascade-mac", "workspace": "/Users/someone/cascade-mac" }).as_object().unwrap()).await.unwrap();
    let (_, projects) = call(&status, "GET", "/api/projects", Some(&token), None).await;
    assert_eq!(projects[0]["name"], "cascade-mac");
    assert!(!projects.to_string().contains("/Users/someone"), "{projects}");
}

#[tokio::test]
async fn the_chat_answers_reads_and_refuses_everything_else() {
    let dir = tempfile::tempdir().unwrap();
    let (state, status) = listening(dir.path()).await;
    let (_, token) = store::add_client(&state.db, "MacBook").await.unwrap();

    for method in ["orchestration.dispatchCommand", "projects.readFile", "attachments.save", "provider.compactThread"] {
        let (code, reply) = call(&status, "POST", "/api/chat/rpc", Some(&token), Some(json!({ "method": method, "params": {} }))).await;
        assert_eq!((code, reply["error"]["code"].as_str()), (403, Some("forbidden")), "{method}");
    }
    // Allowed, and passed to the chat, which has no engine in this test.
    let (code, reply) = call(&status, "POST", "/api/chat/rpc", Some(&token), Some(json!({ "method": "chat.listThreads" }))).await;
    assert_eq!((code, reply["error"]["code"].as_str()), (404, Some("unavailable")));
}

#[tokio::test]
async fn a_client_trusts_only_the_pinned_certificate() {
    let dir = tempfile::tempdir().unwrap();
    let (_state, status) = listening(dir.path()).await;
    let other = identity::Identity::generate(None).unwrap().fingerprint();
    assert!(connect(&status, &other).await.is_err());
    assert!(connect(&status, status.fingerprint.as_deref().unwrap()).await.is_ok());
}

#[tokio::test]
async fn only_a_hash_of_the_token_is_stored() {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let (_, token) = store::add_client(&state.db, "MacBook").await.unwrap();
    let stored = std::fs::read(dir.path().join("cascade.db")).unwrap();
    let wal = std::fs::read(dir.path().join("cascade.db-wal")).unwrap_or_default();
    for bytes in [&stored, &wal] {
        assert!(!bytes.windows(token.len()).any(|window| window == token.as_bytes()));
    }
}

#[tokio::test]
async fn the_stream_carries_only_the_allowed_events_and_ends_when_its_client_is_revoked() {
    let dir = tempfile::tempdir().unwrap();
    let (state, status) = listening(dir.path()).await;
    let (id, token) = store::add_client(&state.db, "MacBook").await.unwrap();
    let mut stream = connect(&status, status.fingerprint.as_deref().unwrap()).await.unwrap();
    send(&mut stream, "GET", "/api/stream", Some(&token), None).await;
    let mut seen = String::new();
    let mut buffer = [0u8; 4096];
    while !seen.contains("connected") {
        let read = stream.read(&mut buffer).await.unwrap();
        seen.push_str(&String::from_utf8_lossy(&buffer[..read]));
    }

    state.publish(Event::Config);
    state.publish(Event::Tasks);
    while !seen.contains(r#"{"type":"tasks"}"#) {
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buffer)).await.unwrap().unwrap();
        seen.push_str(&String::from_utf8_lossy(&buffer[..read]));
    }
    assert!(!seen.contains("config"), "{seen}");

    assert!(super::revoke(&state, &id).await.unwrap());
    let ended = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match stream.read(&mut buffer).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
        }
    })
    .await;
    assert!(ended.is_ok(), "the revoked client's stream stayed open");
    assert_eq!(call(&status, "GET", "/api/tasks", Some(&token), None).await.0, 401);
}

#[tokio::test]
async fn turned_off_it_refuses_connections_and_turned_on_again_it_keeps_its_port_and_certificate() {
    let dir = tempfile::tempdir().unwrap();
    let (state, first) = listening(dir.path()).await;
    let (_, token) = store::add_client(&state.db, "MacBook").await.unwrap();

    let off = super::disable(&state).await.unwrap();
    assert!(!off.enabled);
    assert!(TcpStream::connect((LOOPBACK, first.port.unwrap())).await.is_err());

    let again = start(&state, LOOPBACK).await.unwrap();
    assert_eq!((again.port, &again.fingerprint), (first.port, &first.fingerprint));
    assert_eq!(call(&again, "GET", "/api/tasks", Some(&token), None).await.0, 200);
}

#[tokio::test]
async fn the_app_turns_it_on_and_off_and_a_browser_page_cannot() {
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    let dir = tempfile::tempdir().unwrap();
    let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let router = crate::build_app(state.clone());
    let foreign = Request::post("/api/remote/enable").header("origin", "https://example.com").body(Body::empty()).unwrap();
    assert_eq!(router.clone().oneshot(foreign).await.unwrap().status(), 403);
    assert!(!super::status(&state).await.unwrap().enabled);

    let status = router.clone().oneshot(Request::get("/api/remote").body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(status.status(), 200);
    let off = router.oneshot(Request::post("/api/remote/disable").body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(off.status(), 200);
}

#[tokio::test]
async fn a_connection_that_sends_nothing_is_closed() {
    let dir = tempfile::tempdir().unwrap();
    let (state, status) = listening(dir.path()).await;
    let (_, token) = store::add_client(&state.db, "MacBook").await.unwrap();
    let mut buffer = [0u8; 4096];

    // Silent from the start.
    let mut silent = connect(&status, status.fingerprint.as_deref().unwrap()).await.unwrap();
    let closed = tokio::time::timeout(Duration::from_secs(5), silent.read(&mut buffer)).await;
    assert!(matches!(closed, Ok(Ok(0) | Err(_))), "a silent connection stayed open");

    // Silent after a request on a kept-alive connection.
    let mut kept = connect(&status, status.fingerprint.as_deref().unwrap()).await.unwrap();
    let head = format!("GET /api/tasks HTTP/1.1\r\nHost: cascade\r\nAuthorization: Bearer {token}\r\n\r\n");
    kept.write_all(head.as_bytes()).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match kept.read(&mut buffer).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
        }
    })
    .await;
    assert!(ended.is_ok(), "an idle kept-alive connection stayed open");
}

#[tokio::test]
async fn connections_past_one_addresss_share_are_closed_as_they_come() {
    let dir = tempfile::tempdir().unwrap();
    let (_state, status) = listening(dir.path()).await;
    let fingerprint = status.fingerprint.clone().unwrap();
    // One address cannot take every slot: its share is less than the whole.
    const { assert!(super::listener::PER_SOURCE < super::listener::CONNECTIONS) };
    let mut held = Vec::new();
    for _ in 0..super::listener::PER_SOURCE {
        held.push(connect(&status, &fingerprint).await.unwrap());
    }
    assert!(connect(&status, &fingerprint).await.is_err(), "a connection past the limit was served");
    drop(held);
    // Slots come back as the held ones close.
    let served = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if connect(&status, &fingerprint).await.is_ok() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await;
    assert!(served.is_ok());
}

// ---- pairing ---------------------------------------------------------------------------------

use super::{client, pairing};
use axum::http::Method;

/// A host listening with its pairing window open, a second Mac's state, and the code.
async fn pairing_pair(host_dir: &std::path::Path, client_dir: &std::path::Path) -> (AppState, Status, AppState, String) {
    let (host, status) = listening(host_dir).await;
    let code = pairing::open(&host, "mac-mini").await.unwrap().code;
    let other = AppState::new(crate::Database::open(client_dir).unwrap(), Some("test-client".into()));
    (host, status, other, code)
}

fn address(status: &Status) -> String {
    format!("127.0.0.1:{}", status.port.unwrap())
}

fn wrong(code: &str) -> String {
    format!("{:06}", (code.parse::<u32>().unwrap() + 1) % 1_000_000)
}

#[tokio::test]
async fn a_mac_pairs_with_the_code_and_its_token_then_works() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;

    let peer = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap();
    assert_eq!((Some(&peer.id), peer.name.as_str()), (status.fingerprint.as_ref(), "mac-mini"));
    assert_eq!(store::peers(&other.db).await.unwrap().len(), 1);
    let clients = store::clients(&host.db).await.unwrap();
    assert_eq!(clients.iter().map(|c| c.label.as_str()).collect::<Vec<_>>(), ["MacBook"]);

    let token = store::peer_token(&other.db, &peer.id).await.unwrap().unwrap();
    let tls = identity::pinned_client_config(&peer.id).unwrap();
    let (code_now, tasks) = client::request(&address(&status), tls, Method::GET, "/api/tasks", Some(&token), None, client::PAIRED_BODY).await.unwrap();
    assert_eq!((code_now.as_u16(), tasks), (200, json!([])));

    // The window closed with the pairing: the same code pairs nothing more.
    let again = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap_err();
    assert!(again.to_string().contains("not pairing"), "{again:#}");
}

#[tokio::test]
async fn a_wrong_code_fails_and_three_close_the_window() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;

    let error = pairing::pair(&other, &address(&status), &wrong(&code), "MacBook").await.unwrap_err();
    assert!(error.to_string().contains("wrong code"), "{error:#}");
    // A second attempt with the right code still pairs.
    pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap();

    let code = pairing::open(&host, "mac-mini").await.unwrap().code;
    for _ in 0..pairing::ATTEMPTS {
        assert!(pairing::pair(&other, &address(&status), &wrong(&code), "MacBook").await.is_err());
    }
    let error = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap_err();
    assert!(error.to_string().contains("not pairing"), "{error:#}");
    assert!(store::peer_token(&other.db, status.fingerprint.as_deref().unwrap()).await.unwrap().is_some(), "the first pairing stands");
    assert_eq!(store::clients(&host.db).await.unwrap().len(), 1);
}

#[tokio::test]
async fn nothing_pairs_without_an_open_window_or_with_the_listener_off() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;
    pairing::close(&host);
    let error = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap_err();
    assert!(error.to_string().contains("not pairing"), "{error:#}");

    super::disable(&host).await.unwrap();
    assert!(pairing::open(&host, "mac-mini").await.is_err());
}

#[tokio::test]
async fn a_proof_made_over_another_certificate_is_refused() {
    // A machine in the middle shows the client its own certificate, so the client's proof covers
    // that fingerprint, not the host's.
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, _other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;
    let (spake, from_client) = pairing::testing::start(&code);
    let tls = identity::pinned_client_config(status.fingerprint.as_deref().unwrap()).unwrap();
    let body = json!({ "message": identity::hex(&from_client), "label": "MacBook" });
    let (_, started) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/start", None, Some(&body), client::PAIRED_BODY).await.unwrap();
    let from_host = identity::unhex(started["message"].as_str().unwrap()).unwrap();
    let key = spake.finish(&from_host).unwrap();

    let impostor = identity::Identity::generate(None).unwrap().fingerprint();
    let proof = pairing::testing::proof_for(&key, &from_client, &from_host, &impostor);
    let body = json!({ "session": started["session"], "proof": proof });
    let (refused, _) = client::request(&address(&status), tls, Method::POST, "/pair/finish", None, Some(&body), client::PAIRED_BODY).await.unwrap();
    assert_eq!(refused.as_u16(), 403);
    assert!(store::clients(&host.db).await.unwrap().is_empty());
}

#[tokio::test]
async fn a_browser_page_cannot_open_pairing_or_pair() {
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    let dir = tempfile::tempdir().unwrap();
    let router = crate::build_app(AppState::new(crate::Database::open(dir.path()).unwrap(), None));
    for (path, body) in [("/api/remote/pairing", "{}"), ("/api/remote/peers/pair", r#"{"address":"127.0.0.1:1","code":"123456"}"#)] {
        let request = Request::post(path)
            .header("origin", "https://example.com")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        assert_eq!(router.clone().oneshot(request).await.unwrap().status(), 403, "{path}");
    }
}

#[tokio::test]
async fn a_host_is_the_same_peer_across_its_restarts_and_needs_no_instance_id() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let other = AppState::new(crate::Database::open(client_dir.path()).unwrap(), None);
    let mut first_token = None;
    // Each launch of the app gives the backend a new instance id, or none.
    for instance in [Some("launch-1"), None] {
        let host = AppState::new(crate::Database::open(host_dir.path()).unwrap(), instance.map(String::from));
        let status = start(&host, LOOPBACK).await.unwrap();
        let code = pairing::open(&host, "mac-mini").await.unwrap().code;
        let peer = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap();
        assert_eq!(Some(&peer.id), status.fingerprint.as_ref());
        let token = store::peer_token(&other.db, &peer.id).await.unwrap();
        assert_ne!(token, first_token, "pairing again replaces the token");
        first_token = token;
        super::disable(&host).await.unwrap();
    }
    assert_eq!(store::peers(&other.db).await.unwrap().len(), 1);
}

#[tokio::test]
async fn an_exchange_finishes_at_most_once() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, _other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;
    let fingerprint = status.fingerprint.clone().unwrap();
    let tls = identity::pinned_client_config(&fingerprint).unwrap();
    // Two exchanges with the right code; the window must still be open for the second finish.
    let mut exchanges = Vec::new();
    for _ in 0..2 {
        let (spake, from_client) = pairing::testing::start(&code);
        let body = json!({ "message": identity::hex(&from_client), "label": "MacBook" });
        let (_, started) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/start", None, Some(&body), client::PAIRED_BODY).await.unwrap();
        let from_host = identity::unhex(started["message"].as_str().unwrap()).unwrap();
        let key = spake.finish(&from_host).unwrap();
        let proof = pairing::testing::proof_for(&key, &from_client, &from_host, &fingerprint);
        exchanges.push(json!({ "session": started["session"], "proof": proof }));
    }
    let wrong = json!({ "session": exchanges[0]["session"], "proof": "00" });
    let (refused, _) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/finish", None, Some(&wrong), client::PAIRED_BODY).await.unwrap();
    assert_eq!(refused.as_u16(), 403);
    // The session the wrong proof used is spent, right proof or not.
    let (gone, _) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/finish", None, Some(&exchanges[0]), client::PAIRED_BODY).await.unwrap();
    assert_eq!(gone.as_u16(), 404);
    let (paired, _) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/finish", None, Some(&exchanges[1]), client::PAIRED_BODY).await.unwrap();
    assert_eq!(paired.as_u16(), 200);
    let (again, _) = client::request(&address(&status), tls, Method::POST, "/pair/finish", None, Some(&exchanges[1]), client::PAIRED_BODY).await.unwrap();
    assert_eq!(again.as_u16(), 404);
    assert_eq!(store::clients(&host.db).await.unwrap().len(), 1);
}

#[tokio::test]
async fn starts_that_never_finish_use_the_window_up_and_the_host_hears_of_it() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;
    let mut events = host.events.subscribe();
    let tls = identity::pinned_client_config(status.fingerprint.as_deref().unwrap()).unwrap();
    for attempt in 1..=pairing::ATTEMPTS {
        let (_, mut from_client) = pairing::testing::start("000000");
        // The last is well-formed hex but no SPAKE2 message: refused, and still an attempt.
        let last = attempt == pairing::ATTEMPTS;
        if last {
            from_client.truncate(5);
        }
        let body = json!({ "message": identity::hex(&from_client) });
        let (started, _) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/start", None, Some(&body), client::PAIRED_BODY).await.unwrap();
        assert_eq!(started.as_u16(), if last { 400 } else { 200 });
    }
    let window = pairing::window(&host);
    assert!(window.open && window.attempts_left == 0);
    let mut heard = false;
    while let Ok(event) = events.try_recv() {
        heard |= event["type"] == "remote-pairing";
    }
    assert!(heard, "the window's end was not told");
    let error = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap_err();
    assert!(error.to_string().contains("not pairing"), "{error:#}");

    // The two left pending are given up after a while, and the window closes then, told.
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert!(!pairing::window(&host).open);
}

#[tokio::test]
async fn three_bad_starts_close_the_window_at_once() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, _other, _code) = pairing_pair(host_dir.path(), client_dir.path()).await;
    let tls = identity::pinned_client_config(status.fingerprint.as_deref().unwrap()).unwrap();
    for _ in 0..pairing::ATTEMPTS {
        let body = json!({ "message": "00" });
        let (started, _) = client::request(&address(&status), tls.clone(), Method::POST, "/pair/start", None, Some(&body), client::PAIRED_BODY).await.unwrap();
        assert_eq!(started.as_u16(), 400);
    }
    assert!(!pairing::window(&host).open, "nothing is pending, so nothing is left to finish");
}

// ---- links: this Mac's side ------------------------------------------------------------------

use super::links::{self, Reach};

/// A host and a second Mac paired with it, and the peer's id.
async fn paired(host_dir: &std::path::Path, client_dir: &std::path::Path) -> (AppState, Status, AppState, String) {
    let (host, status, other, code) = pairing_pair(host_dir, client_dir).await;
    let peer = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap();
    (host, status, other, peer.id)
}

async fn reaches(state: &AppState, id: &str, reach: Reach) {
    let reached = tokio::time::timeout(Duration::from_secs(5), async {
        while state.remote.links.reach(id) != reach {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    assert!(reached.is_ok(), "{id} never became {reach:?}, still {:?}", state.remote.links.reach(id));
}

async fn get(router: &axum::Router, path: &str) -> (u16, Value) {
    use axum::{body::Body, http::Request};
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    let response = router.clone().oneshot(Request::get(path).body(Body::empty()).unwrap()).await.unwrap();
    let status = response.status().as_u16();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

#[tokio::test]
async fn a_paired_mac_hears_the_hosts_allowed_events() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, _status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;
    let mut events = other.events.subscribe();

    host.publish(Event::Config);
    host.publish(Event::Tasks);
    let relayed = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = events.recv().await.unwrap();
            if event["type"] == "remote" {
                return event;
            }
        }
    })
    .await
    .unwrap();
    // `config` is not on the host's list, so the first event relayed is `tasks`.
    assert_eq!(relayed, json!({ "type": "remote", "peer": id, "relayed": { "type": "tasks" } }));
}

#[tokio::test]
async fn the_app_reads_a_peers_sessions_projects_and_chat_through_its_own_backend() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, _status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    host.db.add_project(json!({ "name": "cascade-mac", "workspace": "/Users/someone/cascade-mac" }).as_object().unwrap()).await.unwrap();
    let router = crate::build_app(other.clone());

    let (code, peers) = get(&router, "/api/remote/peers").await;
    assert_eq!((code, peers[0]["id"].as_str(), peers[0]["name"].as_str()), (200, Some(id.as_str()), Some("mac-mini")));
    assert_eq!(get(&router, &format!("/api/remote/peers/{id}/tasks")).await, (200, json!([])));
    let (code, projects) = get(&router, &format!("/api/remote/peers/{id}/projects")).await;
    assert_eq!((code, projects[0]["name"].as_str()), (200, Some("cascade-mac")));

    // The host's own list decides which chat calls pass.
    let (code, refused) = links::forward(&other, &id, Method::POST, "/api/chat/rpc", Some(&json!({ "method": "orchestration.dispatchCommand" }))).await.unwrap().unwrap();
    assert_eq!((code.as_u16(), refused["error"]["code"].as_str()), (403, Some("forbidden")));
    let (code, _) = links::forward(&other, &id, Method::POST, "/api/chat/rpc", Some(&json!({ "method": "chat.listThreads" }))).await.unwrap().unwrap();
    assert_eq!(code.as_u16(), 404, "passed on to a chat with no engine");
}

#[tokio::test]
async fn a_peer_gone_offline_is_tried_again_only_when_someone_looks_for_it() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, _status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;

    super::disable(&host).await.unwrap();
    reaches(&other, &id, Reach::Offline).await;
    let router = crate::build_app(other.clone());
    assert_eq!(get(&router, &format!("/api/remote/peers/{id}/tasks")).await.0, 502);

    start(&host, LOOPBACK).await.unwrap();
    // No timer tries it again.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(other.remote.links.reach(&id), Reach::Offline);

    use axum::{body::Body, http::Request};
    use tower::ServiceExt;
    let connect = Request::post(format!("/api/remote/peers/{id}/connect")).body(Body::empty()).unwrap();
    assert_eq!(router.clone().oneshot(connect).await.unwrap().status(), 200);
    reaches(&other, &id, Reach::Online).await;
    // A peer online is left as it is, and one not paired is not found.
    assert_eq!(links::connect(&other, &id, None).await.unwrap(), Some(Reach::Online));
    assert_eq!(links::connect(&other, "nobody", None).await.unwrap(), None);
}

#[tokio::test]
async fn a_revoked_mac_learns_it_and_stops_trying() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, _status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;

    let client = store::clients(&host.db).await.unwrap().remove(0);
    super::revoke(&host, &client.id).await.unwrap();
    reaches(&other, &id, Reach::Revoked).await;
    let (code, _) = links::forward(&other, &id, Method::GET, "/api/tasks", None).await.unwrap().unwrap();
    assert_eq!(code.as_u16(), 401);
}

#[tokio::test]
async fn a_forgotten_peer_is_unlinked() {
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (_host, _status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;
    let router = crate::build_app(other.clone());
    let forget = Request::delete(format!("/api/remote/peers/{id}")).body(Body::empty()).unwrap();
    assert_eq!(router.clone().oneshot(forget).await.unwrap().status(), 200);
    assert!(!other.remote.links.linked(&id));
    assert_eq!(get(&router, "/api/remote/peers").await.1, json!([]));
    assert_eq!(get(&router, &format!("/api/remote/peers/{id}/tasks")).await.0, 404);
}

#[test]
fn server_sent_events_are_read_across_pieces_and_line_ends() {
    let mut sse = links::Sse::default();
    assert!(sse.push(b": connected\n\nda").is_empty(), "a comment is no event");
    assert_eq!(sse.push(b"ta: {\"a\":1}\n\n"), [r#"{"a":1}"#]);
    // CRLF, a CR split from its LF across pieces, and lone CRs all end lines.
    assert!(sse.push(b"data: one\r").is_empty());
    assert_eq!(sse.push(b"\ndata:two\r\n\r\ndata: three\r\r"), ["one\ntwo", "three"]);
    // Many small pieces of one large event make one event.
    let large = format!("data: {}\n\n", "x".repeat(100_000));
    let mut events = Vec::new();
    for piece in large.as_bytes().chunks(1000) {
        events.extend(sse.push(piece));
    }
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].len(), 100_000);
}

#[tokio::test]
async fn a_replaced_link_cannot_change_its_successors_reach() {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    // Links to a peer that is not stored end at once; only their records matter here.
    links::link(&state, "peer");
    links::link(&state, "peer");
    links::set_reach(&state, "peer", Some(0), Reach::Revoked);
    assert_ne!(state.remote.links.reach("peer"), Reach::Revoked);
    links::set_reach(&state, "peer", Some(1), Reach::Revoked);
    assert_eq!(state.remote.links.reach("peer"), Reach::Revoked);
}

#[tokio::test]
async fn another_certificate_at_a_peers_address_stops_the_link() {
    let (host_dir, client_dir, impostor_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (_host, status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;
    // The paired address now answers with another Mac's certificate, as after a data reset.
    let (_impostor, elsewhere) = listening(impostor_dir.path()).await;
    let peer = store::Peer { id: id.clone(), name: "mac-mini".into(), addresses: vec![address(&elsewhere)] };
    let token = store::peer_token(&other.db, &id).await.unwrap().unwrap();
    store::keep_peer(&other.db, &peer, &token).await.unwrap();
    links::link(&other, &id);
    reaches(&other, &id, Reach::Changed).await;
    let error = links::forward(&other, &id, Method::GET, "/api/tasks", None).await.unwrap_err();
    assert!(error.is::<client::CertificateChanged>(), "{error:#}");

    // Bonjour sees the paired Mac at its own address: it is tried there, first.
    assert_eq!(links::connect(&other, &id, Some(&address(&status))).await.unwrap(), Some(Reach::Connecting));
    reaches(&other, &id, Reach::Online).await;
    let addresses = store::peers(&other.db).await.unwrap().remove(0).addresses;
    assert_eq!(addresses, [address(&status), address(&elsewhere)]);
}

#[tokio::test]
async fn an_idle_stream_is_kept_alive() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (_host, _status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;
    let mut events = other.events.subscribe();
    // Past the silence a link allows under test (2 s), with nothing published.
    tokio::time::sleep(Duration::from_millis(3000)).await;
    assert_eq!(other.remote.links.reach(&id), Reach::Online);
    while let Ok(event) = events.try_recv() {
        assert_ne!(event["type"], "remote-peer", "the link dropped: {event}");
    }
}

#[tokio::test]
async fn another_certificate_at_one_address_does_not_stop_a_peer_reached_at_another() {
    let (host_dir, client_dir, impostor_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (_host, status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    let (_impostor, elsewhere) = listening(impostor_dir.path()).await;
    // The first address answers with another certificate; the second is the paired Mac.
    let peer = store::Peer { id: id.clone(), name: "mac-mini".into(), addresses: vec![address(&elsewhere), address(&status)] };
    let token = store::peer_token(&other.db, &id).await.unwrap().unwrap();
    store::keep_peer(&other.db, &peer, &token).await.unwrap();
    links::link(&other, &id);
    reaches(&other, &id, Reach::Online).await;
    let (code, _) = links::forward(&other, &id, Method::GET, "/api/tasks", None).await.unwrap().unwrap();
    assert_eq!(code.as_u16(), 200);
    assert_eq!(other.remote.links.reach(&id), Reach::Online);
}

#[tokio::test]
async fn an_address_only_seen_is_kept_once_the_peer_answers_there() {
    let (host_dir, client_dir, impostor_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, other, id) = paired(host_dir.path(), client_dir.path()).await;
    reaches(&other, &id, Reach::Online).await;
    super::disable(&host).await.unwrap();
    reaches(&other, &id, Reach::Offline).await;

    // Something else on the network advertises the peer's id: another certificate there is not
    // the peer's doing, and the address is not kept.
    let (_impostor, elsewhere) = listening(impostor_dir.path()).await;
    links::connect(&other, &id, Some(&address(&elsewhere))).await.unwrap();
    reaches(&other, &id, Reach::Offline).await;
    assert_eq!(store::peers(&other.db).await.unwrap().remove(0).addresses, [address(&status)]);
}

#[tokio::test]
async fn pairing_again_replaces_the_client_and_its_old_token() {
    let (host_dir, client_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (host, status, other, code) = pairing_pair(host_dir.path(), client_dir.path()).await;
    let peer = pairing::pair(&other, &address(&status), &code, "MacBook").await.unwrap();
    let old = store::peer_token(&other.db, &peer.id).await.unwrap().unwrap();

    let again = pairing::open(&host, "mac-mini").await.unwrap();
    pairing::pair(&other, &address(&status), &again.code, "MacBook").await.unwrap();
    assert_eq!(store::clients(&host.db).await.unwrap().len(), 1, "listed once");
    assert_eq!(store::client_for(&host.db, &old).await.unwrap(), None, "the old token no longer works");
}
