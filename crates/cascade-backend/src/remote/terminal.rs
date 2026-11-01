//! A paired Mac's way into this Mac's agent terminals (docs/remote/03-architecture.md §6).
//!
//! The paired Mac asks `GET /api/terminal` with `Upgrade: cascade-pty`; once upgraded, the
//! connection speaks the terminal daemon's own protocol (newline-delimited JSON, `cascade-ptyd`),
//! relayed to the daemon the app runs through a filter:
//!
//! - Only `OPS` pass. Creating, killing, resizing and recolouring a terminal are this Mac's own;
//!   a paired Mac watches and types into a terminal at the size this Mac gives it.
//! - `hello` is narrowed to the terminals the connection attached to (`eventScope: attached`), so
//!   it hears no other terminal's output.
//! - `list` answers only session terminals (paired, keyed by a session this Mac has), and an op
//!   naming a terminal is refused unless a `list` on this connection answered it.
//!
//! The app tells the backend where its daemon listens (`routes::set_terminal_daemon`): not an
//! environment variable, which every shell would inherit and a build run from one would follow to
//! another app's daemon. Until it says, none is offered.

use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{Arc, Mutex},
};

use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader},
    net::UnixStream,
    sync::mpsc,
};

use crate::AppState;

/// The `Upgrade` token both ends name.
pub(crate) const UPGRADE: &str = "cascade-pty";

/// The terminals a paired Mac may hold open at once, across every paired Mac.
pub(crate) const TERMINALS: usize = if cfg!(test) { 2 } else { 8 };

/// The ops a paired Mac may send, and of them the ones that name a terminal.
pub(crate) const OPS: &[&str] = &["hello", "list", "attach", "write", "flow", "foreground", "snapshotBegin", "snapshotRead", "snapshotEnd"];
const TERM_OPS: &[&str] = &["attach", "write", "flow", "foreground", "snapshotBegin"];

/// The most requests one connection may have waiting on the daemon, and the longest id one may
/// be asked with (a number, or a string this long), so what is kept for them stays small.
const WAITING: usize = 1024;
const ID: usize = 64;

/// The longest line either way: the daemon's own frames are at most 2 MiB.
const LINE: usize = 4 * 1024 * 1024;

pub(crate) fn socket(state: &AppState) -> Option<PathBuf> {
    state.remote.daemon.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
}

/// Connects to the app's daemon: only a socket this user owns, as the app itself checks
/// (`PtydHost`), so a path another user made cannot be handed the paired Macs' keystrokes.
pub(crate) async fn connect_daemon(state: &AppState) -> std::io::Result<UnixStream> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    let path = socket(state).ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no terminal daemon"))?;
    let metadata = std::fs::symlink_metadata(&path)?;
    if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::getuid() } {
        return Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "the terminal daemon's socket is not this user's"));
    }
    UnixStream::connect(path).await
}

/// What one connection has been told, and the requests waiting on the daemon. A short lock,
/// never held across an await.
///
/// Every request with an id is sent on under an id of the relay's own (`next`), and its answer is
/// given back under the id the paired Mac chose: so no answer can pass for another's, whatever ids
/// the paired Mac reuses, and a `list`'s answer is always the one filtered.
#[derive(Default)]
struct Seen {
    terminals: HashSet<String>,
    waiting: HashMap<u64, Waiting>,
    next: u64,
}

struct Waiting {
    id: Value,
    list: bool,
}

/// What to do with a line the paired Mac sent.
#[derive(Debug, PartialEq)]
pub(crate) enum Verdict {
    /// Send this on to the daemon.
    Pass(Vec<u8>),
    /// Answer the paired Mac this, and send the daemon nothing.
    Refuse(Vec<u8>),
    /// Send nothing either way (a refused request without an id, which wants no answer).
    Drop,
}

fn line(value: &Value) -> Vec<u8> {
    let mut bytes = value.to_string().into_bytes();
    bytes.push(b'\n');
    bytes
}

fn refuse(id: Option<&Value>, message: &str) -> Verdict {
    match id {
        Some(id) => Verdict::Refuse(line(&json!({ "id": id, "err": message }))),
        None => Verdict::Drop,
    }
}

/// The relay's own first line to the daemon, before anything of the paired Mac's: the daemon
/// starts a connection hearing every terminal, and this narrows it to the ones it attaches to.
/// Without an id, so the daemon sends no answer.
pub(crate) fn opening() -> Vec<u8> {
    line(&json!({ "op": "hello", "eventScope": "attached" }))
}

fn judge(seen: &Mutex<Seen>, raw: &[u8]) -> Verdict {
    let Ok(Value::Object(mut request)) = serde_json::from_slice::<Value>(raw) else {
        return Verdict::Drop;
    };
    let id = request.get("id").cloned();
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
    if !OPS.contains(&op.as_str()) {
        return refuse(id.as_ref(), "not allowed from another Mac");
    }
    let mut seen = seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if TERM_OPS.contains(&op.as_str()) {
        let term = request.get("term").and_then(Value::as_str).unwrap_or_default();
        if !seen.terminals.contains(term) {
            return refuse(id.as_ref(), "not a session terminal of this Mac");
        }
    }
    if op == "hello" {
        request.insert("eventScope".into(), json!("attached"));
    }
    if let Some(id) = id {
        let short = match &id {
            Value::Number(_) | Value::Null => true,
            Value::String(text) => text.len() <= ID,
            _ => false,
        };
        if !short {
            return refuse(None, "");
        }
        if seen.waiting.len() >= WAITING {
            return refuse(Some(&id), "too many requests waiting");
        }
        seen.next += 1;
        let own = seen.next;
        seen.waiting.insert(own, Waiting { id, list: op == "list" });
        request.insert("id".into(), json!(own));
    }
    Verdict::Pass(line(&Value::Object(request)))
}

/// A line the daemon sent, for the paired Mac: an event as it came; an answer under the id the
/// paired Mac asked with, a `list`'s keeping only the session terminals, which become the ones it
/// may name. An answer to nothing it asked is dropped.
fn answer(seen: &Mutex<Seen>, sessions: &HashSet<String>, raw: Vec<u8>) -> Option<Vec<u8>> {
    // An event starts `{"ev"`, as the daemon writes it: the output streaming past is not parsed.
    if raw.starts_with(br#"{"ev""#) {
        return Some(raw);
    }
    let Ok(Value::Object(mut message)) = serde_json::from_slice::<Value>(&raw) else {
        return None;
    };
    if message.contains_key("ev") {
        return Some(raw);
    }
    let own = message.get("id").and_then(Value::as_u64)?;
    let mut seen = seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let waiting = seen.waiting.remove(&own)?;
    message.insert("id".into(), waiting.id);
    if waiting.list {
        let listed = match message.get("ok") {
            Some(Value::Array(terminals)) => terminals
                .iter()
                .filter(|terminal| {
                    terminal["paired"].as_bool() == Some(true)
                        && terminal["pairKey"].as_str().is_some_and(|key| sessions.contains(key))
                })
                .cloned()
                .collect::<Vec<_>>(),
            _ => Vec::new(),
        };
        seen.terminals = listed.iter().filter_map(|terminal| terminal["id"].as_str().map(str::to_string)).collect();
        if message.contains_key("ok") {
            message.insert("ok".into(), Value::Array(listed));
        }
    }
    Some(line(&Value::Object(message)))
}

/// Whether `raw` is the answer to a list on this connection, so the sessions are read for it:
/// only then, never for the output that streams past.
fn answers_list(seen: &Mutex<Seen>, raw: &[u8]) -> bool {
    {
        let seen = seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !seen.waiting.values().any(|waiting| waiting.list) {
            return false;
        }
    }
    // An event starts `{"ev"`, as the daemon writes it: it is not parsed to find that out.
    if raw.starts_with(br#"{"ev""#) {
        return false;
    }
    let Ok(Value::Object(message)) = serde_json::from_slice::<Value>(raw) else { return false };
    let Some(own) = message.get("id").and_then(Value::as_u64) else { return false };
    let seen = seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    seen.waiting.get(&own).is_some_and(|waiting| waiting.list)
}

/// Reads one line, without its newline, into `buffer`; false at the end of the stream. A line
/// longer than `LINE` is an error, so neither end can make the relay hold more.
async fn read_line<R: AsyncBufRead + Unpin>(reader: &mut R, buffer: &mut Vec<u8>) -> std::io::Result<bool> {
    buffer.clear();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok(!buffer.is_empty());
        }
        let (used, done) = match available.iter().position(|byte| *byte == b'\n') {
            Some(at) => {
                buffer.extend_from_slice(&available[..at]);
                (at + 1, true)
            }
            None => {
                buffer.extend_from_slice(available);
                (available.len(), false)
            }
        };
        reader.consume(used);
        if buffer.len() > LINE {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "line too long"));
        }
        if done {
            return Ok(true);
        }
    }
}

/// The ids of this Mac's sessions, which their terminals are keyed by.
async fn sessions(state: &AppState) -> HashSet<String> {
    state.db.tasks().await.map(|tasks| tasks.into_iter().map(|task| task.id).collect()).unwrap_or_default()
}

/// Relays `peer` (the upgraded connection) to `daemon` through the filter until either end
/// closes or `ended` resolves.
pub(crate) async fn relay<P>(state: AppState, peer: P, daemon: UnixStream, ended: impl std::future::Future<Output = ()>)
where
    P: AsyncRead + AsyncWrite + Send + 'static,
{
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (peer_read, mut peer_write) = tokio::io::split(peer);
    let (daemon_read, mut daemon_write) = daemon.into_split();
    // Narrowed before the daemon reads a line of the paired Mac's, so it never hears another
    // terminal's output, whatever it sends or leaves out.
    if daemon_write.write_all(&opening()).await.is_err() {
        return;
    }
    // One writer to the paired Mac: the daemon's lines and the filter's refusals, in order.
    let (to_peer, mut outbox) = mpsc::channel::<Vec<u8>>(64);

    let writer = async move {
        while let Some(bytes) = outbox.recv().await {
            if peer_write.write_all(&bytes).await.is_err() {
                return;
            }
        }
    };
    let requests = {
        let (seen, to_peer) = (seen.clone(), to_peer.clone());
        async move {
            let mut reader = BufReader::new(peer_read);
            let mut buffer = Vec::new();
            while let Ok(true) = read_line(&mut reader, &mut buffer).await {
                match judge(&seen, &buffer) {
                    Verdict::Pass(bytes) => {
                        if daemon_write.write_all(&bytes).await.is_err() {
                            return;
                        }
                    }
                    Verdict::Refuse(bytes) => {
                        if to_peer.send(bytes).await.is_err() {
                            return;
                        }
                    }
                    Verdict::Drop => {}
                }
            }
        }
    };
    let answers = async move {
        let mut reader = BufReader::new(daemon_read);
        let mut buffer = Vec::new();
        while let Ok(true) = read_line(&mut reader, &mut buffer).await {
            let known = if answers_list(&seen, &buffer) { sessions(&state).await } else { HashSet::new() };
            let Some(mut bytes) = answer(&seen, &known, std::mem::take(&mut buffer)) else { continue };
            if bytes.last() != Some(&b'\n') {
                bytes.push(b'\n');
            }
            if to_peer.send(bytes).await.is_err() {
                return;
            }
        }
    };
    tokio::select! {
        _ = writer => {}
        _ = requests => {}
        _ = answers => {}
        _ = ended => {}
    }
}

#[cfg(test)]
pub(crate) mod filter_tests {
    use super::*;

    fn seen(terminals: &[&str]) -> Mutex<Seen> {
        Mutex::new(Seen { terminals: terminals.iter().map(|term| term.to_string()).collect(), ..Default::default() })
    }

    fn parsed(bytes: &[u8]) -> Value {
        serde_json::from_slice(bytes).unwrap()
    }

    fn passed(verdict: Verdict) -> Value {
        match verdict {
            Verdict::Pass(bytes) => parsed(&bytes),
            other => panic!("not passed: {other:?}"),
        }
    }

    #[test]
    fn only_the_listed_ops_pass() {
        let seen = seen(&["pty1"]);
        for op in ["create", "kill", "killAll", "resize", "appearance", "unknown"] {
            match judge(&seen, json!({ "id": 7, "op": op, "term": "pty1" }).to_string().as_bytes()) {
                Verdict::Refuse(bytes) => assert_eq!(parsed(&bytes)["id"], 7),
                other => panic!("{op}: {other:?}"),
            }
        }
        // A refused request that wants no answer gets none.
        assert_eq!(judge(&seen, br#"{"op":"resize","term":"pty1","cols":10,"rows":10}"#), Verdict::Drop);
        assert_eq!(judge(&seen, b"[1,2]"), Verdict::Drop);
        // An id too long to keep is not sent on, nor answered.
        let long = json!({ "id": "x".repeat(ID + 1), "op": "write", "term": "pty1", "data": "ls" });
        assert_eq!(judge(&seen, long.to_string().as_bytes()), Verdict::Drop);
        assert_eq!(judge(&seen, json!({ "id": [1], "op": "list" }).to_string().as_bytes()), Verdict::Drop);
        passed(judge(&seen, br#"{"id":1,"op":"write","term":"pty1","data":"ls"}"#));
    }

    #[test]
    fn a_terminal_no_list_answered_is_refused() {
        let seen = seen(&["pty1"]);
        for op in TERM_OPS {
            assert!(matches!(judge(&seen, json!({ "id": 1, "op": op, "term": "pty2" }).to_string().as_bytes()), Verdict::Refuse(_)));
            assert!(matches!(judge(&seen, json!({ "id": 1, "op": op }).to_string().as_bytes()), Verdict::Refuse(_)));
        }
        // A snapshot's later reads name its token, which is the connection's own.
        passed(judge(&seen, br#"{"id":1,"op":"snapshotRead","token":3,"offset":0}"#));
    }

    #[test]
    fn hello_hears_only_attached_terminals() {
        let seen = seen(&[]);
        let hello = passed(judge(&seen, br#"{"id":1,"op":"hello","dataEncoding":"base64","eventScope":"all"}"#));
        assert_eq!(hello["eventScope"], "attached");
        assert_eq!(hello["dataEncoding"], "base64");
        assert_eq!(parsed(&opening()), json!({ "op": "hello", "eventScope": "attached" }));
    }

    #[test]
    fn a_list_answers_only_session_terminals_and_allows_them() {
        let seen = seen(&[]);
        let list = passed(judge(&seen, br#"{"id":4,"op":"list"}"#));
        let sessions: HashSet<String> = ["s1".to_string()].into();
        let daemon = json!({ "id": list["id"], "ok": [
            { "id": "pty1", "pairKey": "s1", "paired": true },
            { "id": "pty2", "pairKey": "s1", "paired": false },
            { "id": "pty3", "pairKey": "shell:task:s1:1", "paired": false },
            { "id": "pty4", "pairKey": "s9", "paired": true },
        ] });
        assert!(answers_list(&seen, daemon.to_string().as_bytes()));
        assert!(!answers_list(&seen, br#"{"ev":"data","id":"pty1","bytes":"aGk=","seq":1}"#));
        let answered = parsed(&answer(&seen, &sessions, daemon.to_string().into_bytes()).unwrap());
        assert_eq!(answered["id"], 4, "answered under the id asked with");
        assert_eq!(answered["ok"], json!([{ "id": "pty1", "pairKey": "s1", "paired": true }]));
        passed(judge(&seen, br#"{"id":5,"op":"attach","term":"pty1"}"#));
        assert!(matches!(judge(&seen, br#"{"id":6,"op":"attach","term":"pty4"}"#), Verdict::Refuse(_)));
    }

    #[test]
    fn a_reused_id_cannot_pass_a_list_answer_unfiltered() {
        let seen = seen(&[]);
        let sessions: HashSet<String> = ["s1".to_string()].into();
        let hello = passed(judge(&seen, br#"{"id":1,"op":"hello"}"#));
        let list = passed(judge(&seen, br#"{"id":1,"op":"list"}"#));
        assert_ne!(hello["id"], list["id"], "each request goes on under an id of its own");
        let hello_answer = answer(&seen, &sessions, json!({ "id": hello["id"], "ok": { "protocol": 2 } }).to_string().into_bytes()).unwrap();
        assert_eq!(parsed(&hello_answer), json!({ "id": 1, "ok": { "protocol": 2 } }));
        let everything = json!({ "id": list["id"], "ok": [{ "id": "pty9", "pairKey": "other", "paired": true, "cwd": "/secret" }] });
        assert_eq!(parsed(&answer(&seen, &sessions, everything.to_string().into_bytes()).unwrap()), json!({ "id": 1, "ok": [] }));
        // An answer to nothing asked is not passed on.
        assert_eq!(answer(&seen, &sessions, json!({ "id": 999, "ok": [] }).to_string().into_bytes()), None);
    }

    #[test]
    fn events_pass_untouched() {
        let seen = seen(&[]);
        let event = br#"{"ev":"data","id":"pty1","bytes":"aGk=","seq":3}"#.to_vec();
        assert_eq!(answer(&seen, &HashSet::new(), event.clone()), Some(event));
    }
}
