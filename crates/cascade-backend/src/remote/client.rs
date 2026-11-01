//! Requests to another Mac's listener: one TLS connection per request, with the client
//! configuration the caller chose (`identity`): observing for pairing's first step, pinned after.

use std::{sync::Arc, time::Duration};

use anyhow::{Context, Result};
use axum::{
    body::Bytes,
    http::{header, Method, Request, Response, StatusCode},
};
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper_util::rt::TokioIo;
use rustls::pki_types::ServerName;
use serde_json::Value;
use tokio::{net::TcpStream, task::JoinHandle};
use tokio_rustls::TlsConnector;

use super::identity;

/// Connecting and the TLS handshake; then the answer's headers, and each piece of its body after
/// them. A large answer that keeps coming is not cut off; pairing bounds its whole exchange itself.
const CONNECT: Duration = Duration::from_secs(5);
const EXCHANGE: Duration = Duration::from_secs(15);

/// A pinned connection met another certificate: the Mac at that address is not the one paired
/// (its data was reset, or another Mac took the address). Only pairing again helps.
#[derive(Debug)]
pub(crate) struct CertificateChanged;

impl std::fmt::Display for CertificateChanged {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the other Mac's certificate is not the one paired; pair it again")
    }
}

impl std::error::Error for CertificateChanged {}

fn not_pinned(error: &std::io::Error) -> bool {
    matches!(
        error.get_ref().and_then(|inner| inner.downcast_ref::<rustls::Error>()),
        Some(rustls::Error::General(message)) if message == identity::NOT_PINNED
    )
}

/// The most an answer may hold. Before pairing the other end is anyone who answered the address,
/// and its answers are small; a paired Mac's can be a long chat's whole thread.
pub(crate) const PAIRING_BODY: usize = 64 * 1024;
pub(crate) const PAIRED_BODY: usize = 64 * 1024 * 1024;

/// An answer whose body is still to be read, with the connection serving it.
pub(crate) struct Open {
    pub response: Response<Incoming>,
    pub connection: Connection,
}

/// The task driving a connection; dropping it closes the connection.
pub(crate) struct Connection(JoinHandle<()>);

impl Drop for Connection {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Sends one request and answers as soon as the headers come; the body is the caller's to read.
pub(crate) async fn open(
    address: &str,
    tls: rustls::ClientConfig,
    method: Method,
    path: &str,
    token: Option<&str>,
    body: Option<&Value>,
) -> Result<Open> {
    let stream = tokio::time::timeout(CONNECT, async {
        let tcp = TcpStream::connect(address).await.with_context(|| format!("connect to {address}"))?;
        // The name is never checked: the certificate is taken or pinned by fingerprint.
        let name = ServerName::try_from("cascade")?;
        match TlsConnector::from(Arc::new(tls)).connect(name, tcp).await {
            Ok(stream) => Ok(stream),
            Err(error) if not_pinned(&error) => Err(anyhow::Error::new(CertificateChanged)),
            Err(error) => Err(anyhow::Error::new(error).context("TLS with the other Mac")),
        }
    })
    .await
    .context("the other Mac did not answer")??;
    tokio::time::timeout(EXCHANGE, async {
        let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
        let connection = tokio::spawn(async move {
            let _ = connection.await;
        });
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
        Ok(Open { response, connection: Connection(connection) })
    })
    .await
    .context("the other Mac stopped answering")?
}

/// One request, read whole: the status and the body as JSON (`Null` when it is not). `address`
/// is `host:port`; the body may hold at most `limit` bytes.
pub(crate) async fn request(
    address: &str,
    tls: rustls::ClientConfig,
    method: Method,
    path: &str,
    token: Option<&str>,
    body: Option<&Value>,
    limit: usize,
) -> Result<(StatusCode, Value)> {
    let Open { response, connection: _connection } = open(address, tls, method, path, token, body).await?;
    let status = response.status();
    let mut body = response.into_body();
    let mut bytes = Vec::new();
    loop {
        let frame = match tokio::time::timeout(EXCHANGE, body.frame()).await {
            Err(_) => anyhow::bail!("the other Mac stopped answering"),
            Ok(None) => break,
            Ok(Some(frame)) => frame.context("the other Mac's answer")?,
        };
        if let Ok(data) = frame.into_data() {
            if bytes.len() + data.len() > limit {
                anyhow::bail!("the other Mac's answer is too large");
            }
            bytes.extend_from_slice(&data);
        }
    }
    Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
}

/// A connection to the other Mac's terminal daemon (`terminal`), upgraded from `GET path`: what
/// is written to it and read from it is the daemon's protocol, through the other Mac's filter.
pub(crate) type Upgraded = TokioIo<hyper::upgrade::Upgraded>;

/// Opens `path` with `Upgrade: <protocol>` and answers the upgraded connection; an answer other
/// than `101` is the status it came with, for the caller to read.
pub(crate) async fn upgrade(
    address: &str,
    tls: rustls::ClientConfig,
    path: &str,
    protocol: &str,
    token: &str,
) -> Result<std::result::Result<Upgraded, StatusCode>> {
    let stream = tokio::time::timeout(CONNECT, async {
        let tcp = TcpStream::connect(address).await.with_context(|| format!("connect to {address}"))?;
        // A terminal stays open for as long as it is looked at: a Mac gone without a word is found.
        super::listener::keep_alive(&tcp);
        let name = ServerName::try_from("cascade")?;
        match TlsConnector::from(Arc::new(tls)).connect(name, tcp).await {
            Ok(stream) => Ok(stream),
            Err(error) if not_pinned(&error) => Err(anyhow::Error::new(CertificateChanged)),
            Err(error) => Err(anyhow::Error::new(error).context("TLS with the other Mac")),
        }
    })
    .await
    .context("the other Mac did not answer")??;
    tokio::time::timeout(EXCHANGE, async {
        let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
        // Runs until the upgrade hands the connection over, then ends by itself.
        tokio::spawn(async move {
            let _ = connection.with_upgrades().await;
        });
        let request = Request::builder()
            .method(Method::GET)
            .uri(path)
            .header(header::HOST, "cascade")
            .header(header::CONNECTION, "upgrade")
            .header(header::UPGRADE, protocol)
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .body(Full::new(Bytes::new()))?;
        let response = sender.send_request(request).await?;
        if response.status() != StatusCode::SWITCHING_PROTOCOLS {
            return Ok(Err(response.status()));
        }
        Ok(Ok(TokioIo::new(hyper::upgrade::on(response).await.context("the other Mac's terminal")?)))
    })
    .await
    .context("the other Mac stopped answering")?
}
