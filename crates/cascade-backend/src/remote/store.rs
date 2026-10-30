//! The listener's rows in `cascade.db`: its identity, whether it is on and on which port, and
//! the paired clients. Each call goes to the durable store's thread (`db::Store`).

use chrono::{Duration, Utc};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use uuid::Uuid;

use super::identity::{self, Identity};
use crate::Database;

fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// How stale `last_seen_at` may be before a request writes it again.
const SEEN_EVERY: Duration = Duration::seconds(60);

pub(crate) struct Host {
    pub identity: Identity,
    pub enabled: bool,
    pub port: u16,
}

pub(crate) async fn host(db: &Database) -> rusqlite::Result<Option<Host>> {
    db.durable
        .call(|conn| {
            conn.query_row("SELECT enabled, port, cert_der, key_der FROM remote_host WHERE id=1", [], |row| {
                Ok(Host {
                    enabled: row.get::<_, i64>(0)? != 0,
                    port: row.get::<_, i64>(1)?.try_into().unwrap_or(0),
                    identity: Identity { cert: row.get(2)?, key: row.get(3)? },
                })
            })
            .optional()
        })
        .await
}

/// Stores `identity` unless one is stored already, and answers whichever is.
pub(crate) async fn keep_identity(db: &Database, identity: Identity) -> rusqlite::Result<Host> {
    db.durable
        .call(move |conn| {
            conn.execute(
                "INSERT OR IGNORE INTO remote_host (id, cert_der, key_der) VALUES (1, ?1, ?2)",
                params![identity.cert, identity.key],
            )?;
            Ok(())
        })
        .await?;
    host(db).await?.ok_or(rusqlite::Error::QueryReturnedNoRows)
}

pub(crate) async fn set_enabled(db: &Database, enabled: bool, port: Option<u16>) -> rusqlite::Result<()> {
    db.durable
        .call(move |conn| {
            conn.execute(
                "UPDATE remote_host SET enabled=?1, port=COALESCE(?2, port) WHERE id=1",
                params![enabled as i64, port.map(i64::from)],
            )?;
            Ok(())
        })
        .await
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Client {
    pub id: String,
    pub label: String,
    pub created_at: String,
    pub last_seen_at: Option<String>,
}

/// A new paired client, and the token it is given; only the token's hash is stored.
pub(crate) async fn add_client(db: &Database, label: &str) -> anyhow::Result<(String, String)> {
    let id = Uuid::new_v4().to_string();
    let token = identity::token()?;
    let (row, digest, label) = (id.clone(), identity::digest(&token), label.to_owned());
    db.durable
        .call(move |conn| {
            conn.execute(
                "INSERT INTO remote_clients (id, label, token_sha256, created_at) VALUES (?1, ?2, ?3, ?4)",
                params![row, label, digest, now()],
            )?;
            Ok(())
        })
        .await?;
    Ok((id, token))
}

/// The client a token belongs to, if any. A request that finds one marks it seen, at most once a
/// minute.
pub(crate) async fn client_for(db: &Database, token: &str) -> rusqlite::Result<Option<String>> {
    let digest = identity::digest(token);
    db.durable
        .call(move |conn| {
            let found: Option<(String, Option<String>)> = conn
                .query_row("SELECT id, last_seen_at FROM remote_clients WHERE token_sha256=?1", [digest], |row| {
                    Ok((row.get(0)?, row.get(1)?))
                })
                .optional()?;
            let Some((id, seen)) = found else { return Ok(None) };
            let stale = (Utc::now() - SEEN_EVERY).to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
            if seen.is_none_or(|seen| seen < stale) {
                conn.execute("UPDATE remote_clients SET last_seen_at=?1 WHERE id=?2", params![now(), id])?;
            }
            Ok(Some(id))
        })
        .await
}

pub(crate) async fn clients(db: &Database) -> rusqlite::Result<Vec<Client>> {
    db.durable
        .call(|conn| {
            let mut statement =
                conn.prepare("SELECT id, label, created_at, last_seen_at FROM remote_clients ORDER BY created_at")?;
            let rows = statement.query_map([], |row| {
                Ok(Client { id: row.get(0)?, label: row.get(1)?, created_at: row.get(2)?, last_seen_at: row.get(3)? })
            })?;
            rows.collect()
        })
        .await
}

pub(crate) async fn client_exists(db: &Database, id: &str) -> rusqlite::Result<bool> {
    let id = id.to_owned();
    db.durable
        .call(move |conn| conn.query_row("SELECT EXISTS(SELECT 1 FROM remote_clients WHERE id=?1)", [id], |row| row.get(0)))
        .await
}

/// Forgets a client; answers whether there was one.
pub(crate) async fn remove_client(db: &Database, id: &str) -> rusqlite::Result<bool> {
    let id = id.to_owned();
    db.durable.call(move |conn| Ok(conn.execute("DELETE FROM remote_clients WHERE id=?1", [id])? > 0)).await
}

/// A Mac this one paired with, as it is kept; the token is read only to make a request.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Peer {
    /// SHA-256 of the other Mac's certificate: what every connection to it pins, and what it is
    /// known by, since it lasts across its restarts. Its Bonjour TXT `id` is the same.
    pub id: String,
    pub name: String,
    /// `host:port`s it was reached at, the latest first.
    pub addresses: Vec<String>,
}

/// Keeps a peer, replacing one paired before under the same id.
pub(crate) async fn keep_peer(db: &Database, peer: &Peer, token: &str) -> rusqlite::Result<()> {
    let (peer, token) = (peer.clone(), token.to_owned());
    let addresses = serde_json::to_string(&peer.addresses).unwrap_or_else(|_| "[]".into());
    db.durable
        .call(move |conn| {
            conn.execute(
                "INSERT INTO remote_peers (id, name, addresses, token, created_at) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(id) DO UPDATE SET name=excluded.name, addresses=excluded.addresses, token=excluded.token",
                params![peer.id, peer.name, addresses, token, now()],
            )?;
            Ok(())
        })
        .await
}

pub(crate) async fn peers(db: &Database) -> rusqlite::Result<Vec<Peer>> {
    db.durable
        .call(|conn| {
            let mut statement = conn.prepare("SELECT id, name, addresses FROM remote_peers ORDER BY created_at")?;
            let rows = statement.query_map([], |row| {
                let addresses: String = row.get(2)?;
                Ok(Peer {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    addresses: serde_json::from_str(&addresses).unwrap_or_default(),
                })
            })?;
            rows.collect()
        })
        .await
}

pub(crate) async fn set_addresses(db: &Database, id: &str, addresses: &[String]) -> rusqlite::Result<()> {
    let (id, addresses) = (id.to_owned(), serde_json::to_string(addresses).unwrap_or_else(|_| "[]".into()));
    db.durable
        .call(move |conn| {
            conn.execute("UPDATE remote_peers SET addresses=?1 WHERE id=?2", params![addresses, id])?;
            Ok(())
        })
        .await
}

/// Every paired Mac's token, by its id.
pub(crate) async fn peer_tokens(db: &Database) -> rusqlite::Result<std::collections::HashMap<String, String>> {
    db.durable
        .call(|conn| {
            let mut statement = conn.prepare("SELECT id, token FROM remote_peers")?;
            let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect()
        })
        .await
}

/// The token a request to a peer carries.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) async fn peer_token(db: &Database, id: &str) -> rusqlite::Result<Option<String>> {
    let id = id.to_owned();
    db.durable
        .call(move |conn| conn.query_row("SELECT token FROM remote_peers WHERE id=?1", [id], |row| row.get(0)).optional())
        .await
}

pub(crate) async fn forget_peer(db: &Database, id: &str) -> rusqlite::Result<bool> {
    let id = id.to_owned();
    db.durable.call(move |conn| Ok(conn.execute("DELETE FROM remote_peers WHERE id=?1", [id])? > 0)).await
}
