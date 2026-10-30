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
    // Unknown paths are refused before they are looked up.
    assert_eq!(call(&status, "GET", "/api/nowhere", None, None).await.0, 401);

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
async fn connections_past_the_limit_are_closed_as_they_come() {
    let dir = tempfile::tempdir().unwrap();
    let (_state, status) = listening(dir.path()).await;
    let fingerprint = status.fingerprint.clone().unwrap();
    let mut held = Vec::new();
    for _ in 0..super::listener::CONNECTIONS {
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
