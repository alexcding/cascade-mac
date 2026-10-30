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
use tokio::{
    sync::{broadcast, Mutex},
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
        Self { running: Mutex::new(None), revoked: broadcast::channel(16).0, pairing: std::sync::Mutex::new(None), links: links::Links::default() }
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
            Err(_) => tokio::net::TcpListener::bind(SocketAddr::new(address, 0)).await.context("bind the remote port")?,
        };
        let port = listener.local_addr()?.port();
        let tls = host.identity.server_config()?;
        // Stored before it serves, so a listener never runs that the next start would not resume.
        store::set_enabled(&state.db, true, Some(port)).await?;
        let task = tokio::spawn(listener::serve(listener, tls, listener::router(state.clone())));
        *running = Some(Running { port, task });
        tracing::info!(port, "remote listener on");
        state.publish(Event::RemoteHost);
    }
    drop(running);
    status(state).await
}

pub async fn disable(state: &AppState) -> Result<Status> {
    let mut running = state.remote.running.lock().await;
    pairing::close(state);
    if running.take().is_some() {
        tracing::info!("remote listener off");
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
                tracing::warn!(%error, "the remote listener did not start");
            }
        }
        Ok(_) => {}
        Err(error) => tracing::warn!(%error, "read the remote listener's state"),
    }
}

/// Forgets a paired client and ends its open stream. Its next request is refused.
pub async fn revoke(state: &AppState, id: &str) -> Result<bool> {
    let removed = store::remove_client(&state.db, id).await?;
    let _ = state.remote.revoked.send(id.to_owned());
    if removed {
        state.publish(Event::RemoteClients);
    }
    Ok(removed)
}
