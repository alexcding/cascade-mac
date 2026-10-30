//! Requests to another Mac's listener: one TLS connection per request, with the client
//! configuration the caller chose (`identity`): observing for pairing's first step, pinned after.

use std::{sync::Arc, time::Duration};

use anyhow::{Context, Result};
use axum::{
    body::Bytes,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::{BodyExt, Full, Limited};
use hyper_util::rt::TokioIo;
use rustls::pki_types::ServerName;
use serde_json::Value;
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

/// Connecting and the TLS handshake, then the whole exchange after it.
const CONNECT: Duration = Duration::from_secs(5);
const EXCHANGE: Duration = Duration::from_secs(15);
/// The most an answer may hold: before pairing the other end is anyone who answered the address.
const MAX_BODY: usize = 8 * 1024 * 1024;

/// `address` is `host:port`. Answers the status and the body as JSON (`Null` when it is not).
pub(crate) async fn request(
    address: &str,
    tls: rustls::ClientConfig,
    method: Method,
    path: &str,
    token: Option<&str>,
    body: Option<&Value>,
) -> Result<(StatusCode, Value)> {
    let stream = tokio::time::timeout(CONNECT, async {
        let tcp = TcpStream::connect(address).await.with_context(|| format!("connect to {address}"))?;
        // The name is never checked: the certificate is taken or pinned by fingerprint.
        let name = ServerName::try_from("cascade")?;
        TlsConnector::from(Arc::new(tls)).connect(name, tcp).await.context("TLS with the other Mac")
    })
    .await
    .context("the other Mac did not answer")??;
    tokio::time::timeout(EXCHANGE, async {
        let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
        let connection = tokio::spawn(connection);
        let mut builder = Request::builder()
            .method(method)
            .uri(path)
            .header(header::HOST, "cascade")
            .header(header::CONTENT_TYPE, "application/json");
        if let Some(token) = token {
            builder = builder.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }
        let body = body.map(Value::to_string).unwrap_or_default();
        let response = sender.send_request(builder.body(Full::new(Bytes::from(body)))?).await?;
        let status = response.status();
        let bytes = Limited::new(response.into_body(), MAX_BODY)
            .collect()
            .await
            .map_err(|error| anyhow::anyhow!("the other Mac's answer: {error}"))?
            .to_bytes();
        connection.abort();
        Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
    })
    .await
    .context("the other Mac stopped answering")?
}
