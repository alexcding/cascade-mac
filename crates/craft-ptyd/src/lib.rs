// ptyd — the detached PTY daemon. Every terminal Craft opens lives HERE, not in the app process,
// so quitting, crashing, or rebuilding Craft never kills a shell (the unpeel / tmux model: the app
// is only an attachment). `craft __ptyd__ <dir>` runs this loop outside the app, so terminals
// outlive it; the
// host (terminals.rs) spawns it detached (own session, stdio to <dir>/ptyd.log) the first time it
// cannot connect, then talks to it over the Unix socket sock_path().
//
// Wire protocol: newline-delimited JSON, both directions, on one connection.
//   request  {"id":<n>, "op":"hello"|"create"|"write"|"resize"|"kill"|"killAll"|"list"|"attach"|"flow"|"foreground", ...}
//   response {"id":<n>, "ok":<value>}  or  {"id":<n>, "err":"..."}
//   event    {"ev":"data", "id":"pty..", "chunk":"..", "seq":<n>}   (fanned out to EVERY client)
//            {"ev":"exit", "id":"pty..", "exitCode":<n>, "signal":<n>}
// Protocol 2 extension: hello {dataEncoding:"base64"} opts one connection into
// exact byte output/attachments via `bytes` (standard padded base64), replacing
// `chunk`/`buf`. `write` accepts either `bytes` or legacy UTF-8 `data`, never both.
// Output sequences are shared across encodings, including incomplete UTF-8 batches.
// A request without "id" gets no response (writes/resizes/flow are fire-and-forget).
//
// Performance model (borrowed from unpeel's PTY core):
//   • The PTY master is O_NONBLOCK and each terminal has ONE poll()-driven thread that owns both
//     directions. Output is BATCHED: after the first byte it keeps collecting for a short window
//     (BATCH_WAIT_MS, up to BATCH_MAX_MS / BATCH_MAX_BYTES) so a flood becomes a few large events
//     per frame instead of thousands of tiny ones. One `seq` per batch == one ring chunk, so a
//     reattaching client's "replay ring, then events with seq > ring seq" stays exact.
//   • Input never blocks anyone: a write copies into the terminal's bounded queue (INPUT_MAX),
//     the poll thread drains it on POLLOUT. A program that stops reading stdin stalls only itself.
//   • Every client has its own outbox thread + byte budget. A client above OUTBOX_MAX, or one that
//     made no progress for STALL_DROP while owing bytes, is dropped — never waited on. While any
//     client owes more than BACKLOG_HIGH the PTY reads pause (resuming below BACKLOG_LOW), so a slow
//     viewer bounds memory instead of growing it. The renderer can also ask for a pause directly
//     ("flow") when its xterm write buffer runs ahead.
//
// On disk (for inspection / scripting; the daemon itself is the source of truth):
//   <dir>/terms/<id>.json   manifest — cwd, title, pairKey, hasContext, shell pid, created
//   <dir>/ptyd.pid          the daemon's pid
//   /tmp/craft-ptyd-<uid>.sock  the control socket (see sock_path)
// The daemon exits by itself once it holds no terminals and no client for IDLE_EXIT.
use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::io::RawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
mod utf8;
mod shell_integration;
mod geometry;
mod appearance;
pub use appearance::TerminalAppearance;
#[cfg(test)]
mod outbox_tests;
pub use geometry::TerminalGeometry;
#[cfg(feature = "terminal-snapshots")]
mod snapshot;

pub const PROTOCOL: u32 = 2;
const RING_MAX: usize = 256 * 1024; // per-terminal rolling output tail replayed to (re)attaching clients
const IDLE_EXIT: Duration = Duration::from_secs(30);

const BATCH_WAIT_MS: i32 = 12; // after a read, wait this long for more before emitting
const BATCH_MAX_MS: u128 = 32; // …but never hold a batch longer than this
const BATCH_MAX_BYTES: usize = 128 * 1024; // …or larger than this
const READ_CHUNK: usize = 64 * 1024;

const INPUT_MAX: usize = 1024 * 1024; // maximum queued keystrokes/paste per terminal
const OUTBOX_MAX: usize = 8 * 1024 * 1024; // per-client unsent bytes before the client is dropped
const STALL_DROP: Duration = Duration::from_secs(60); // owing bytes with no progress this long → drop
const BACKLOG_HIGH: usize = 4 * 1024 * 1024; // any client owing this much pauses PTY reads…
const BACKLOG_LOW: usize = 1024 * 1024; // …until every client is below this

// The socket lives in a PRIVATE per-user directory at a SHORT path: AF_UNIX paths are capped at
// 104 bytes on macOS and "~/Library/Application Support/<bundle id>/…" overruns that for longer
// usernames, and a predictable name in the shared sticky /tmp could be squatted by another local
// user (our probe would then defer to their listener and the app would talk to it). macOS's
// per-user $TMPDIR (/var/folders/…/T/, mode 0700) is both short and private; otherwise
// /tmp/craft-<uid>/ is created 0700. Callers verify the path's owner before trusting it.
pub fn sock_path() -> PathBuf {
  // CRAFT_PTYD_SOCK overrides it — for tests and for running a second, isolated daemon.
  if let Some(p) = std::env::var_os("CRAFT_PTYD_SOCK").filter(|p| !p.is_empty()) {
    return PathBuf::from(p);
  }
  let uid = unsafe { libc::getuid() };
  let dir = std::env::var_os("TMPDIR")
    .map(PathBuf::from)
    .filter(|d| d.is_absolute() && d.as_os_str().len() < 70 && owned_private_dir(d))
    .unwrap_or_else(|| {
      let d = PathBuf::from(format!("/tmp/craft-{uid}"));
      let _ = std::fs::DirBuilder::new().mode(0o700).create(&d);
      d
    });
  dir.join("craft-ptyd.sock")
}

// True when `p` exists, is owned by us, and grants nothing to group/other.
pub fn owned_private_dir(p: &Path) -> bool {
  use std::os::unix::fs::MetadataExt;
  match std::fs::metadata(p) {
    Ok(m) => m.is_dir() && m.uid() == unsafe { libc::getuid() } && (m.mode() & 0o077) == 0,
    Err(_) => false,
  }
}

// True when the socket file at `p` is owned by us (refuse to talk to anyone else's listener).
pub fn owned_socket(p: &Path) -> bool {
  use std::os::unix::fs::MetadataExt;
  std::fs::metadata(p).map(|m| m.uid() == unsafe { libc::getuid() }).unwrap_or(false)
}

struct OutputChunk {
  bytes: Vec<u8>,
  text: String,
}

impl OutputChunk {
  // Both representations together retain at most twice the ring's byte budget.
  fn size(&self) -> usize { self.bytes.len().max(self.text.len()) }
}

struct Ring {
  chunks: VecDeque<OutputChunk>,
  len: usize,
  seq: u64,
  truncated: bool,
  state_seq: u64,
  cols: u16,
  rows: u16,
  geometry: Option<TerminalGeometry>,
  appearance: Option<TerminalAppearance>,
  #[cfg(feature = "terminal-snapshots")]
  terminal: Result<craft_vt::Terminal, String>,
  state_response_owner: bool,
  identity_version: Option<String>,
  responses: Result<Vec<u8>, String>,
}

impl Ring {
  fn new(geometry: Option<TerminalGeometry>) -> Result<Self, String> {
    if let Some(size) = geometry { size.pty_size()?; }
    let (cols, rows) = geometry.map_or((80, 24), |size| (size.cols, size.rows));
    #[cfg(feature = "terminal-snapshots")]
    let terminal = {
      let mut terminal = craft_vt::Terminal::new(cols, rows).map_err(|e| e.to_string())?;
      if let Some(size) = geometry { terminal.resize_geometry(size.runtime()).map_err(|e| e.to_string())?; }
      terminal
    };
    Ok(Self {
      chunks: VecDeque::new(), len: 0, seq: 0, truncated: false,
      state_seq: 0, cols, rows, geometry, appearance: None,
      state_response_owner: false, identity_version: None, responses: Ok(Vec::new()),
      #[cfg(feature = "terminal-snapshots")]
      terminal: Ok(terminal),
    })
  }

  #[cfg(feature = "terminal-snapshots")]
  fn capture(&mut self) -> Result<snapshot::Capture, String> {
    let terminal = self.terminal.as_mut().map_err(|e| e.clone())?;
    let bytes = terminal.snapshot().map_err(|e| e.to_string())?;
    Ok(snapshot::Capture { bytes, seq: self.seq, state_seq: self.state_seq, cols: self.cols, rows: self.rows, geometry: self.geometry, appearance: self.appearance.clone() })
  }

  fn set_appearance(&mut self, appearance: TerminalAppearance) -> Result<bool, String> {
    appearance.validate()?;
    if self.appearance.as_ref() == Some(&appearance) { return Ok(false); }
    let changed_scheme = self.appearance.as_ref().is_some_and(|old| old.values[259] != appearance.values[259]);
    #[cfg(feature = "terminal-snapshots")]
    {
      let terminal = self.terminal.as_mut().map_err(|e| e.clone())?;
      self.responses = terminal.set_appearance(&appearance.runtime()?, changed_scheme).map_err(|e| e.to_string());
      if let Err(error) = &self.responses { self.terminal = Err(error.clone()); return Err(error.clone()); }
    }
    #[cfg(not(feature = "terminal-snapshots"))]
    let _ = changed_scheme;
    self.appearance = Some(appearance);
    self.state_seq += 1;
    Ok(true)
  }

  fn resized(&mut self, cols: u16, rows: u16, geometry: Option<TerminalGeometry>) -> Result<u64, String> {
    self.cols = cols;
    self.rows = rows;
    self.geometry = geometry;
    self.state_seq += 1;
    #[cfg(feature = "terminal-snapshots")]
    {
      let terminal = self.terminal.as_mut().map_err(|e| e.clone())?;
      self.responses = match geometry {
        Some(geometry) => terminal.resize_geometry(geometry.runtime()),
        None => terminal.resize(cols, rows).map(|_| Vec::new()),
      }.map_err(|e| e.to_string());
      if let Err(error) = &self.responses {
        // The kernel size already changed. Never serve stale VT state as valid.
        self.terminal = Err(error.clone());
        return Err(error.clone());
      }
    }
    Ok(self.state_seq)
  }

  fn push(&mut self, bytes: Vec<u8>, text: String) -> u64 {
    #[cfg(feature = "terminal-snapshots")]
    if let Ok(terminal) = &mut self.terminal {
      if self.state_response_owner {
        self.responses = match self.identity_version.as_deref() {
          Some(version) if self.appearance.is_some() => terminal.feed_appearance_responses(&bytes, version, &self.appearance.as_ref().unwrap().runtime().expect("validated appearance")),
          Some(version) if self.geometry.is_some() => terminal.feed_geometry_responses(&bytes, version),
          Some(version) => terminal.feed_identity_responses(&bytes, version),
          None => terminal.feed_state_responses(&bytes),
        }.map_err(|e| e.to_string());
        if let Err(error) = &self.responses {
          // Input was consumed, but its replies could not all be delivered.
          // Invalidate the snapshot and latch input failure; never replay it.
          self.terminal = Err(error.clone());
        }
      } else { terminal.feed(&bytes); }
    }
    self.seq += 1;
    self.state_seq += 1;
    let chunk = OutputChunk { bytes, text };
    self.len += chunk.size();
    self.chunks.push_back(chunk);
    while self.len > RING_MAX {
      self.len -= self.chunks.pop_front().unwrap().size();
      self.truncated = true;
    }
    self.seq
  }
}

#[cfg(test)]
mod ring_tests {
  use super::*;

  #[test]
  fn truncation_is_reported_at_the_atomic_sequence_boundary() {
    let mut ring = Ring::new(None).unwrap();
    assert_eq!(ring.push(vec![b'a'; RING_MAX / 2], "a".repeat(RING_MAX / 2)), 1);
    assert_eq!(ring.push(vec![b'b'; RING_MAX / 2], "b".repeat(RING_MAX / 2)), 2);
    assert!(!ring.truncated); // exactly full still contains the entire history
    assert_eq!(ring.push("日本語".as_bytes().to_vec(), "日本語".into()), 3);
    assert!(ring.truncated);
    assert_eq!(ring.len, RING_MAX / 2 + "日本語".len());
    assert_eq!(ring.chunks.back().unwrap().text, "日本語");
    ring.push(b"small later update".to_vec(), "small later update".into());
    assert!(ring.truncated); // a small subsequent batch cannot make a tail complete
  }

  #[test]
  fn invalid_utf8_expansion_cannot_exceed_the_ring_budget() {
    let mut ring = Ring::new(None).unwrap();
    ring.push(vec![0xff; RING_MAX / 2], "\u{fffd}".repeat(RING_MAX / 2));
    assert!(ring.truncated);
    assert_eq!(ring.seq, 1);
    assert!(ring.len <= RING_MAX);
    ring.push(vec![b'a'], "a".into());
    assert_eq!(ring.len, 1);
    assert!(ring.truncated);
  }
}

// The write side of a PTY: the (non-blocking) writer plus the bounded queue of bytes it could not
// take yet. Held only for the duration of a non-blocking write, so it never blocks the caller.
struct Input {
  writer: Box<dyn Write + Send>,
  queue: VecDeque<u8>,
  failure: Option<String>,
}

struct ResizeRequest {
  cols: u16,
  rows: u16,
  geometry: Option<TerminalGeometry>,
  appearance: Option<TerminalAppearance>,
  reply: mpsc::SyncSender<Result<(), String>>,
}

struct Term {
  master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
  resizes: Arc<Mutex<VecDeque<ResizeRequest>>>,
  child: Arc<Mutex<Box<dyn Child + Send + Sync>>>,
  input: Arc<Mutex<Input>>,
  wake_w: RawFd, // self-pipe: poke the poll thread (queued input, flow change, kill)
  paused: Arc<AtomicBool>, // renderer-requested flow pause
  pause_owners: HashSet<u64>, // protected by the terms lock; only the owner can release a pause
  killed: Arc<AtomicBool>, // kill requested: the I/O thread reaps, removes, and announces exit
  info: TermInfo,
  ring: Arc<Mutex<Ring>>,
}

impl Drop for Term {
  fn drop(&mut self) {
    unsafe { libc::close(self.wake_w) };
  }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TermInfo {
  pub id: String,
  pub cwd: String,
  pub title: String,
  pub paired: bool,
  pub pair_key: String,
  pub has_context: bool,
  #[serde(default)]
  pub pid: u32,
  #[serde(default)]
  pub created: u64,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub state_response_owner: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub terminal_profile: Option<TerminalProfile>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub geometry_response_owner: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub appearance_response_owner: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct CreateOpts {
  pub cwd: Option<String>,
  pub shell: Option<String>,
  #[serde(default)]
  pub paired: bool,
  #[serde(default)]
  pub pair_key: String,
  pub state_response_owner: Option<String>,
  pub terminal_profile: Option<TerminalProfile>,
  pub geometry_response_owner: Option<String>,
  pub geometry: Option<TerminalGeometry>,
  pub appearance_response_owner: Option<String>,
  pub appearance: Option<TerminalAppearance>,
}

/// Identity is fixed at shell creation. The returned profile records the
/// daemon-owned terminfo copy, so app relocation/rebuild cannot invalidate it.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TerminalProfile {
  pub version: String,
  pub terminfo_directory: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub resources_directory: Option<String>,
}

struct PreparedProfile { profile: TerminalProfile, root: PathBuf }
impl Drop for PreparedProfile {
  fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.root); }
}
impl TerminalProfile {
  fn prepare(&self, directory: &Path, id: &str) -> Result<PreparedProfile, String> {
    if self.version.is_empty() || self.version.len() > 128 ||
        !self.version.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
      return Err("invalid native terminal version".into());
    }
    let source = Path::new(&self.terminfo_directory);
    if !source.is_absolute() { return Err("native terminfo directory must be absolute".into()); }
    let file = [source.join("78/xterm-ghostty"), source.join("x/xterm-ghostty")]
      .into_iter().find(|path| path.is_file()).ok_or("bundled xterm-ghostty terminfo is missing")?;
    let mut bytes = Vec::new();
    std::fs::File::open(file).map_err(|e| e.to_string())?.take(1024 * 1024 + 1)
      .read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.len() < 12 || bytes.len() > 1024 * 1024 ||
        ![0x011au16, 0x021e].contains(&u16::from_le_bytes([bytes[0], bytes[1]])) {
      return Err("invalid compiled xterm-ghostty terminfo".into());
    }
    let root = directory.join("terminfo").join(id);
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&root).map_err(|e| e.to_string())?;
    let prepared = PreparedProfile { profile: Self {
      version: self.version.clone(), terminfo_directory: root.to_string_lossy().into_owned(),
      resources_directory: self.resources_directory.as_ref().map(|_| root.join("resources").to_string_lossy().into_owned()),
    }, root };
    std::fs::create_dir(prepared.root.join("78")).map_err(|e| e.to_string())?;
    std::fs::write(prepared.root.join("78/xterm-ghostty"), bytes).map_err(|e| e.to_string())?;
    if let Some(source) = &self.resources_directory {
      shell_integration::copy_resources(Path::new(source), &prepared.root.join("resources"))?;
    }
    Ok(prepared)
  }
}

// A connected client: lines go through `tx` to its outbox thread, which is the ONLY writer on the
// socket (responses and events share it, so frames never interleave). `owed` is the byte budget.
struct Client {
  id: u64,
  byte_transport: bool,
  tx: mpsc::Sender<Arc<str>>,
  owed: Arc<AtomicUsize>,
  progress: Arc<Mutex<Instant>>,
  sock: UnixStream,
}

impl Client {
  fn stalled(&self) -> bool {
    self.owed.load(Ordering::Relaxed) > 0 && self.progress.lock().unwrap().elapsed() > STALL_DROP
  }
}

#[derive(Default)]
struct ClientSession {
  #[cfg(feature = "terminal-snapshots")]
  snapshots: snapshot::Transfers,
  #[cfg(feature = "terminal-snapshots")]
  snapshot_negotiated: bool,
}

struct Daemon {
  dir: PathBuf,
  terms: Mutex<HashMap<String, Term>>,
  clients: Mutex<Vec<Client>>,
  seq: AtomicU64,
  client_seq: AtomicU64,
  boot: u64,
  idle_since: Mutex<Option<Instant>>,
}

fn now_ms() -> u64 {
  SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn log(msg: &str) {
  eprintln!("[ptyd {}] {msg}", chrono::Local::now().format("%H:%M:%S"));
}

// The executable name of a pid (macOS proc_pidpath), "" when it can't be read.
fn proc_path(pid: libc::pid_t) -> String {
  let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
  let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_void, buf.len() as u32) };
  if n <= 0 {
    return String::new();
  }
  String::from_utf8_lossy(&buf[..n as usize]).trim_end_matches('\0').to_string()
}

fn set_nonblocking(fd: RawFd) {
  unsafe {
    let fl = libc::fcntl(fd, libc::F_GETFL);
    if fl >= 0 {
      libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
    }
  }
}

fn poll2(fds: &mut [libc::pollfd], timeout_ms: i32) -> i32 {
  loop {
    let r = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
    if r < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
      continue;
    }
    return r;
  }
}

fn poke(fd: RawFd) {
  unsafe { libc::write(fd, [1u8].as_ptr() as *const libc::c_void, 1) };
}

// Drain the input queue with non-blocking writes. Returns true when something is still queued.
fn drain_input(inp: &mut Input) -> Result<bool, String> {
  if let Some(error) = &inp.failure { return Err(error.clone()); }
  while !inp.queue.is_empty() {
    let (a, _) = inp.queue.as_slices();
    let error = match inp.writer.write(a) {
      Ok(0) => Some("terminal input writer made no progress".to_string()),
      Ok(n) => { inp.queue.drain(..n); None }
      Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
      Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
      Err(e) => Some(format!("terminal input write failed: {e}")),
    };
    if let Some(error) = error {
      inp.failure = Some(error.clone());
      inp.queue.clear();
      return Err(error);
    }
  }
  Ok(!inp.queue.is_empty())
}

fn queue_input(inp: &mut Input, data: &[u8]) -> Result<bool, String> {
  if let Some(error) = &inp.failure { return Err(error.clone()); }
  // Reject the whole new chunk before modifying the queue. Never acknowledge a
  // dropped suffix: a caller must know that earlier input may already have run.
  if data.len() > INPUT_MAX.saturating_sub(inp.queue.len()) {
    return Err("terminal input queue is full; this input was not accepted".into());
  }
  inp.queue.extend(data);
  drain_input(inp)
}

fn queue_responses(inp: &mut Input, responses: Result<Vec<u8>, String>) -> Result<(), String> {
  let result = responses.and_then(|bytes| {
    if bytes.is_empty() { Ok(()) } else { queue_input(inp, &bytes).map(|_| ()) }
  });
  if let Err(error) = &result {
    inp.failure = Some(error.clone());
    inp.queue.clear();
  }
  result
}

#[cfg(test)]
mod input_tests {
  use super::*;

  struct Writer { bytes: Arc<Mutex<Vec<u8>>>, budget: Arc<Mutex<usize>>, fatal: bool }
  impl Write for Writer {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
      let mut budget = self.budget.lock().unwrap();
      if *budget == 0 {
        return Err(std::io::Error::from(if self.fatal { std::io::ErrorKind::BrokenPipe } else { std::io::ErrorKind::WouldBlock }));
      }
      let count = bytes.len().min(*budget);
      self.bytes.lock().unwrap().extend_from_slice(&bytes[..count]);
      *budget -= count;
      Ok(count)
    }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
  }

  #[test]
  fn full_input_queue_rejects_whole_chunk_and_preserves_accepted_order() {
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let budget = Arc::new(Mutex::new(2));
    let mut input = Input { writer: Box::new(Writer { bytes: bytes.clone(), budget: budget.clone(), fatal: false }), queue: VecDeque::new(), failure: None };
    let accepted = vec![b'a'; INPUT_MAX];
    assert!(queue_input(&mut input, &accepted).unwrap());
    let before = input.queue.clone();
    assert!(queue_input(&mut input, b"REJECTED").is_err());
    assert_eq!(input.queue, before);
    *budget.lock().unwrap() = INPUT_MAX;
    assert!(!drain_input(&mut input).unwrap());
    assert_eq!(*bytes.lock().unwrap(), accepted);
    assert!(!queue_input(&mut input, b"ok").unwrap());
    assert!(bytes.lock().unwrap().ends_with(b"ok"));
  }

  #[test]
  fn response_failures_latch_input_without_replaying_a_partial_reply() {
    for collection_failure in [false, true] {
      let bytes = Arc::new(Mutex::new(Vec::new()));
      let budget = Arc::new(Mutex::new(0));
      let mut input = Input { writer: Box::new(Writer { bytes: bytes.clone(), budget: budget.clone(), fatal: false }), queue: VecDeque::new(), failure: None };
      assert!(queue_input(&mut input, &vec![b'a'; INPUT_MAX]).unwrap());
      let response = if collection_failure { Err("response limit exceeded".into()) } else { Ok(b"reply".to_vec()) };
      assert!(queue_responses(&mut input, response).is_err());
      assert!(input.failure.is_some() && input.queue.is_empty());
      *budget.lock().unwrap() = INPUT_MAX;
      assert!(queue_input(&mut input, b"later").is_err());
      assert!(bytes.lock().unwrap().is_empty());
    }
  }

  #[test]
  fn partial_writer_failure_is_reported_and_never_replayed() {
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let budget = Arc::new(Mutex::new(2));
    let mut input = Input { writer: Box::new(Writer { bytes: bytes.clone(), budget: budget.clone(), fatal: true }), queue: VecDeque::new(), failure: None };
    assert!(queue_input(&mut input, b"abcdef").is_err());
    assert_eq!(*bytes.lock().unwrap(), b"ab");
    assert!(input.queue.is_empty() && input.failure.is_some());
    *budget.lock().unwrap() = 100;
    assert!(queue_input(&mut input, b"later").is_err());
    assert_eq!(*bytes.lock().unwrap(), b"ab");
  }
}

impl Daemon {
  fn manifest_path(&self, id: &str) -> PathBuf {
    self.dir.join("terms").join(format!("{id}.json"))
  }

  fn write_manifest(&self, info: &TermInfo) {
    let p = self.manifest_path(&info.id);
    let _ = std::fs::create_dir_all(p.parent().unwrap());
    if let Ok(s) = serde_json::to_string_pretty(info) {
      let _ = std::fs::write(p, s);
    }
  }

  // Fan one line out to every client through its outbox. Never blocks: a client over budget, or
  // stalled while owing bytes, is dropped right here (its outbox thread then closes the socket).
  fn broadcast(&self, v: &Value) {
    let line: Arc<str> = Arc::from(format!("{v}\n"));
    let mut cs = self.clients.lock().unwrap();
    cs.retain(|c| self.offer(c, &line));
  }

  // Encode at most once per representation, regardless of viewer count. Legacy
  // Tauri clients keep their streaming UTF-8 text; native clients receive the
  // exact bytes, with no replacement or incomplete-codepoint delay in the daemon.
  fn broadcast_output(&self, id: &str, seq: u64, state_seq: u64, bytes: &[u8], text: &str) {
    let mut cs = self.clients.lock().unwrap();
    let mut raw_line: Option<Arc<str>> = None;
    let mut text_line: Option<Arc<str>> = None;
    cs.retain(|c| {
      let line = if c.byte_transport {
        raw_line.get_or_insert_with(|| Arc::from(format!("{}\n",
          json!({ "ev": "data", "id": id, "bytes": BASE64.encode(bytes), "seq": seq, "stateSeq": state_seq }))))
      } else {
        text_line.get_or_insert_with(|| Arc::from(format!("{}\n",
          json!({ "ev": "data", "id": id, "chunk": text, "seq": seq, "stateSeq": state_seq }))))
      };
      self.offer(c, line)
    });
  }

  fn offer(&self, c: &Client, line: &Arc<str>) -> bool {
    let owed = c.owed.load(Ordering::Relaxed);
    let stalled = c.stalled();
    if line.len() > OUTBOX_MAX.saturating_sub(owed) || stalled {
      log(&format!("client {} dropped: owed {owed} bytes{}", c.id, if stalled { ", stalled" } else { "" }));
      let _ = c.sock.shutdown(std::net::Shutdown::Both);
      return false;
    }
    // An idle connection has no delivery deadline. Start its clock when it
    // acquires work, rather than expiring the first output after a long idle.
    if owed == 0 { *c.progress.lock().unwrap() = Instant::now(); }
    c.owed.fetch_add(line.len(), Ordering::Relaxed);
    c.tx.send(line.clone()).is_ok()
  }

  fn reply(&self, cid: u64, v: &Value) {
    let line: Arc<str> = Arc::from(format!("{v}\n"));
    let cs = self.clients.lock().unwrap();
    if let Some(c) = cs.iter().find(|c| c.id == cid) {
      self.offer(c, &line);
    }
  }

  fn max_owed(&self) -> usize {
    self.reap_stalled_clients()
  }

  fn reap_stalled_clients(&self) -> usize {
    // Must run independently of offer(): BACKLOG_HIGH suspends every PTY read,
    // so there may never be another output event to detect a blocked writer.
    let mut max_owed = 0;
    self.clients.lock().unwrap().retain(|c| {
      if !c.stalled() {
        max_owed = max_owed.max(c.owed.load(Ordering::Relaxed));
        return true;
      }
      log(&format!("client {} dropped: stalled with {} bytes owed", c.id, c.owed.load(Ordering::Relaxed)));
      let _ = c.sock.shutdown(std::net::Shutdown::Both);
      false
    });
    max_owed
  }

  fn create(self: &Arc<Self>, opts: CreateOpts) -> Result<TermInfo, String> {
    if let Some(owner) = opts.state_response_owner.as_deref() {
      #[cfg(feature = "terminal-snapshots")]
      let supported = [craft_vt::STATE_RESPONSE_OWNER, craft_vt::IDENTITY_RESPONSE_OWNER].contains(&owner);
      #[cfg(not(feature = "terminal-snapshots"))]
      let supported = { let _ = owner; false };
      if !supported { return Err("unsupported terminal state response owner".into()); }
    }
    let identity_owned = opts.state_response_owner.as_deref() == Some("daemon-identity-v1");
    if identity_owned != opts.terminal_profile.is_some() {
      return Err("native terminal identity ownership requires its creation profile".into());
    }
    if let Some(owner) = opts.geometry_response_owner.as_deref() {
      #[cfg(feature = "terminal-snapshots")]
      let supported = owner == craft_vt::GEOMETRY_RESPONSE_OWNER;
      #[cfg(not(feature = "terminal-snapshots"))]
      let supported = { let _ = owner; false };
      if !supported || !identity_owned {
        return Err("terminal geometry ownership requires supported native identity ownership".into());
      }
    }
    if opts.geometry_response_owner.is_some() != opts.geometry.is_some() {
      return Err("terminal geometry ownership requires complete initial geometry".into());
    }
    if opts.appearance_response_owner.is_some() != opts.appearance.is_some() {
      return Err("terminal appearance ownership requires complete native defaults".into());
    }
    if let Some(owner) = opts.appearance_response_owner.as_deref() {
      #[cfg(feature = "terminal-snapshots")]
      let supported = owner == craft_vt::APPEARANCE_RESPONSE_OWNER;
      #[cfg(not(feature = "terminal-snapshots"))]
      let supported = { let _ = owner; false };
      if !supported || opts.geometry_response_owner.is_none() { return Err("unsupported terminal appearance owner".into()); }
      opts.appearance.as_ref().unwrap().validate()?;
    }
    let initial_size = opts.geometry.map(TerminalGeometry::pty_size).transpose()?
      .unwrap_or(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 });
    let n = self.seq.fetch_add(1, Ordering::SeqCst) + 1;
    // Unique across daemon restarts so a stale id persisted by the renderer never collides.
    let id = format!("pty{}-{n}", self.boot);
    let dir = opts
      .cwd
      .filter(|c| !c.is_empty())
      .unwrap_or_else(|| std::env::var("HOME").unwrap_or_else(|_| "/".into()));
    if !Path::new(&dir).is_dir() {
      return Err(format!("working directory does not exist: {dir}"));
    }
    let shell_path = opts
      .shell
      .filter(|s| !s.is_empty())
      .or_else(|| std::env::var("SHELL").ok())
      .unwrap_or_else(|| "/bin/zsh".into());

    // Allocate the parser before spawning a shell, so a parser failure cannot
    // orphan a child. It sees every raw output batch, even without a viewer.
    let mut state = Ring::new(opts.geometry)?;
    if let Some(appearance) = opts.appearance.clone() { state.set_appearance(appearance)?; }
    state.state_response_owner = opts.state_response_owner.is_some();
    let prepared_profile = opts.terminal_profile.as_ref().map(|profile| profile.prepare(&self.dir, &id)).transpose()?;
    state.identity_version = prepared_profile.as_ref().map(|value| format!("ghostty {}", value.profile.version));
    let ring = Arc::new(Mutex::new(state));
    let pair = native_pty_system()
      .openpty(initial_size)
      .map_err(|e| e.to_string())?;

    // Login + interactive shell so it sources dotfiles and gets the full environment
    // (PATH, nvm, Homebrew, aliases) — like a Terminal.app tab.
    let mut cmd = CommandBuilder::new(&shell_path);
    if let Some(resources) = prepared_profile.as_ref().and_then(|value| value.profile.resources_directory.as_deref()) {
      shell_integration::configure(&mut cmd, Path::new(&shell_path), Path::new(resources));
    }
    cmd.args(["-l", "-i"]);
    cmd.cwd(&dir);
    if let Some(prepared) = &prepared_profile {
      cmd.env("TERM", "xterm-ghostty");
      cmd.env("TERMINFO", &prepared.profile.terminfo_directory);
      cmd.env("TERM_PROGRAM", "ghostty");
      cmd.env("TERM_PROGRAM_VERSION", &prepared.profile.version);
    } else {
      cmd.env("TERM", "xterm-256color");
    }
    cmd.env("COLORTERM", "truecolor");
    cmd.env("LANG", std::env::var("LANG").unwrap_or_else(|_| "en_US.UTF-8".into()));
    // CRAFT_RUN_ID lets an installed Claude/Codex hook ping back tagged with THIS terminal's id.
    cmd.env("CRAFT_RUN_ID", &id);

    let child = pair
      .slave
      .spawn_command(cmd)
      .map_err(|e| format!("failed to start shell {shell_path} in {dir}: {e}"))?;
    drop(pair.slave); // the master must see EOF when the child closes its side
    let pid = child.process_id().unwrap_or(0);
    let master_fd = pair.master.as_raw_fd().ok_or("pty master has no fd")?;
    set_nonblocking(master_fd); // shared by the reader/writer dups below
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    let mut pipe = [0 as RawFd; 2];
    if unsafe { libc::pipe(pipe.as_mut_ptr()) } != 0 {
      return Err("pipe() failed".into());
    }
    set_nonblocking(pipe[0]);
    set_nonblocking(pipe[1]);
    let (wake_r, wake_w) = (pipe[0], pipe[1]);

    let title = Path::new(&dir).file_name().and_then(|s| s.to_str()).unwrap_or(&dir).to_string();
    let info = TermInfo {
      id: id.clone(),
      cwd: dir,
      title,
      paired: opts.paired,
      pair_key: opts.pair_key,
      has_context: false,
      pid,
      created: now_ms(),
      state_response_owner: opts.state_response_owner,
      terminal_profile: prepared_profile.as_ref().map(|value| value.profile.clone()),
      geometry_response_owner: opts.geometry_response_owner,
      appearance_response_owner: opts.appearance_response_owner,
    };
    let master = Arc::new(Mutex::new(pair.master));
    let resizes = Arc::new(Mutex::new(VecDeque::<ResizeRequest>::new()));
    let input = Arc::new(Mutex::new(Input { writer, queue: VecDeque::new(), failure: None }));
    let paused = Arc::new(AtomicBool::new(false));
    let killed = Arc::new(AtomicBool::new(false));
    let child = Arc::new(Mutex::new(child));
    self.terms.lock().unwrap().insert(
      id.clone(),
      Term {
        master: master.clone(),
        resizes: resizes.clone(),
        child: child.clone(),
        input: input.clone(),
        wake_w,
        paused: paused.clone(),
        pause_owners: HashSet::new(),
        killed: killed.clone(),
        info: info.clone(),
        ring: ring.clone(),
      },
    );
    self.write_manifest(&info);
    *self.idle_since.lock().unwrap() = None;
    log(&format!("create {id} pid={pid} cwd={}", info.cwd));

    // The terminal's one I/O thread: poll the master (+ wake pipe), batch output, drain input.
    let me = self.clone();
    std::thread::spawn(move || {
      let mut tmp = vec![0u8; READ_CHUNK];
      let mut pending: Vec<u8> = Vec::new(); // raw output batch
      let mut text_pending: Vec<u8> = Vec::new(); // legacy decoder's incomplete codepoint only
      let mut backlog_paused = false;
      let hangup: bool;
      'io: loop {
        if killed.load(Ordering::Relaxed) {
          break 'io; // kill(): the child was signalled; fall through to reap + announce
        }
        // The previous batch is already parsed and sequenced. Apply resizes here,
        // on the same I/O thread, before reading any output at the new grid size.
        while let Some(request) = { resizes.lock().unwrap().pop_front() } {
          let mut state = ring.lock().unwrap();
          #[cfg(feature = "terminal-snapshots")]
          if let Err(error) = &state.terminal {
            let _ = request.reply.send(Err(error.clone()));
            continue;
          }
          if let Some(appearance) = request.appearance {
            let result = state.set_appearance(appearance);
            if matches!(result, Ok(true)) {
              me.broadcast(&json!({ "ev": "appearance", "id": id, "seq": state.seq,
                "stateSeq": state.state_seq, "appearance": state.appearance }));
            }
            let responses = std::mem::replace(&mut state.responses, Ok(Vec::new()));
            drop(state);
            let delivery = queue_responses(&mut input.lock().unwrap(), responses);
            if let Err(message) = &delivery {
              me.broadcast(&json!({ "ev": "inputError", "id": id, "message": message }));
            }
            let _ = request.reply.send(result.map(|_| ()).and(delivery));
            continue;
          }
          if request.geometry.is_some() && request.geometry == state.geometry {
            let _ = request.reply.send(Ok(()));
            continue;
          }
          let size = request.geometry.map(TerminalGeometry::pty_size).transpose()
            .map(|size| size.unwrap_or(PtySize { rows: request.rows, cols: request.cols, pixel_width: 0, pixel_height: 0 }));
          let result = size.and_then(|size| master.lock().unwrap().resize(size).map_err(|e| e.to_string()))
            .and_then(|_| state.resized(request.cols, request.rows, request.geometry));
          if result.is_ok() {
            let mut event = json!({ "ev": "resize", "id": id, "cols": state.cols,
              "rows": state.rows, "seq": state.seq, "stateSeq": state.state_seq });
            if let Some(geometry) = state.geometry { event["geometry"] = json!(geometry); }
            me.broadcast(&event);
          }
          let responses = std::mem::replace(&mut state.responses, Ok(Vec::new()));
          drop(state);
          let delivery = queue_responses(&mut input.lock().unwrap(), responses);
          if let Err(message) = &delivery {
            me.broadcast(&json!({ "ev": "inputError", "id": id, "message": message }));
          }
          let _ = request.reply.send(result.map(|_| ()).and(delivery));
        }
        // Interest: reads unless paused (renderer flow or client backlog); writes while queued.
        let owed = me.max_owed();
        if backlog_paused && owed < BACKLOG_LOW {
          backlog_paused = false;
        } else if !backlog_paused && owed > BACKLOG_HIGH {
          backlog_paused = true;
        }
        let read_ok = !paused.load(Ordering::Relaxed) && !backlog_paused;
        let want_write = !input.lock().unwrap().queue.is_empty();
        let mut ev: libc::c_short = 0;
        if read_ok {
          ev |= libc::POLLIN;
        }
        if want_write {
          ev |= libc::POLLOUT;
        }
        let mut fds = [
          libc::pollfd { fd: master_fd, events: ev, revents: 0 },
          libc::pollfd { fd: wake_r, events: libc::POLLIN, revents: 0 },
        ];
        // A client-backlog pause re-checks the budget on a short timer (no one pokes us when the
        // outbox drains); a renderer flow pause sleeps until flow()/kill()/write() pokes the pipe.
        let r = poll2(&mut fds, if backlog_paused { 20 } else { -1 });
        if r < 0 || fds[0].revents & libc::POLLNVAL != 0 {
          hangup = true; // poll failed or the master fd is gone
          break 'io;
        }
        if fds[1].revents & libc::POLLIN != 0 {
          let mut sink = [0u8; 64];
          while unsafe { libc::read(wake_r, sink.as_mut_ptr() as *mut libc::c_void, sink.len()) } > 0 {}
        }
        if fds[0].revents & libc::POLLOUT != 0 {
          let result = drain_input(&mut input.lock().unwrap());
          if let Err(message) = result {
            me.broadcast(&json!({ "ev": "inputError", "id": id, "message": message }));
          }
        }
        if fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
          // First read, then keep collecting for the batch window while bytes keep arriving.
          let start = Instant::now();
          let mut got_any = false;
          let mut eof = false;
          loop {
            match reader.read(&mut tmp) {
              Ok(0) => {
                eof = true;
                break;
              }
              Ok(n) => {
                got_any = true;
                pending.extend_from_slice(&tmp[..n]);
              }
              Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
              Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
              Err(_) => {
                eof = true; // EIO: the slave side is gone (macOS reports child exit this way)
                break;
              }
            }
            if !got_any && !eof {
              break; // spurious wake (POLLHUP with nothing to read yet) — poll again
            }
            let elapsed = start.elapsed().as_millis();
            if pending.len() >= BATCH_MAX_BYTES || elapsed >= BATCH_MAX_MS {
              break;
            }
            let wait = BATCH_WAIT_MS.min((BATCH_MAX_MS - elapsed) as i32);
            let mut one = [libc::pollfd { fd: master_fd, events: libc::POLLIN, revents: 0 }];
            if poll2(&mut one, wait) <= 0 {
              break; // quiet for the window → emit what we have
            }
          }
          if got_any || eof {
            let bytes = std::mem::take(&mut pending);
            text_pending.extend_from_slice(&bytes);
            let s = utf8::take_text(&mut text_pending, eof);
            if !bytes.is_empty() || !s.is_empty() {
              let (seq, state_seq, responses) = {
                let mut state = ring.lock().unwrap();
                let seq = state.push(bytes.clone(), s.clone());
                (seq, state.state_seq, std::mem::replace(&mut state.responses, Ok(Vec::new())))
              };
              me.broadcast_output(&id, seq, state_seq, &bytes, &s);
              // Protocol replies share the ordered, bounded input queue but do
              // not mark a shell as having user context. Never retry a response
              // after a partial write or collection failure.
              let result = {
                let mut inp = input.lock().unwrap();
                queue_responses(&mut inp, responses)
              };
              if let Err(message) = result {
                me.broadcast(&json!({ "ev": "inputError", "id": id, "message": message }));
              }
            }
          }
          if eof {
            hangup = true;
            break 'io;
          }
        }
      }
      let _ = hangup;
      // Shell exited (or the master failed): reap it, drop it from the registry, announce the death.
      let exit_code = child.lock().unwrap().wait().map(|s| s.exit_code() as i64).unwrap_or(0);
      drop(prepared_profile); // clean up before list reports completion to an explicit Quit
      me.terms.lock().unwrap().remove(&id); // drops Term → closes wake_w
      unsafe { libc::close(wake_r) };
      let _ = std::fs::remove_file(me.manifest_path(&id));
      log(&format!("exit {id} code={exit_code}"));
      me.broadcast(&json!({ "ev": "exit", "id": id, "exitCode": exit_code, "signal": 0 }));
      me.note_idle();
    });
    Ok(info)
  }

  // Queue input for a terminal and try to push it through right away (non-blocking). Holds the
  // registry lock only to look the terminal up — a stuck program stalls nobody else.
  fn write(&self, id: &str, data: &[u8]) -> Result<(), String> {
    let (input, wake, manifest) = {
      let mut map = self.terms.lock().unwrap();
      let Some(t) = map.get_mut(id) else { return Err("terminal no longer exists".into()) };
      let manifest = if !t.info.has_context {
        t.info.has_context = true;
        Some(t.info.clone())
      } else {
        None
      };
      (t.input.clone(), t.wake_w, manifest)
    };
    if let Some(info) = manifest {
      self.write_manifest(&info);
    }
    let still_queued = {
      let mut inp = input.lock().unwrap();
      queue_input(&mut inp, data)?
    };
    if still_queued {
      poke(wake); // make the poll thread watch POLLOUT
    }
    Ok(())
  }

  fn resize(&self, id: &str, cols: u16, rows: u16, geometry: Option<TerminalGeometry>) -> Result<(), String> {
    geometry::validate_grid(cols, rows)?;
    if let Some(size) = geometry {
      size.pty_size()?;
      if size.cols != cols || size.rows != rows { return Err("inconsistent terminal resize geometry".into()); }
    }
    let (tx, rx) = mpsc::sync_channel(1);
    {
      let terms = self.terms.lock().unwrap();
      let term = terms.get(id).ok_or("terminal no longer exists")?;
      if term.info.geometry_response_owner.is_some() != geometry.is_some() {
        return Err("resize geometry must match the terminal's response ownership".into());
      }
      let mut queue = term.resizes.lock().unwrap();
      if queue.len() >= 64 { return Err("too many pending terminal resizes".into()); }
      queue.push_back(ResizeRequest { cols, rows, geometry, appearance: None, reply: tx });
      poke(term.wake_w);
    }
    rx.recv().map_err(|_| "terminal exited before resizing".to_string())?
  }

  fn appearance(&self, id: &str, appearance: TerminalAppearance) -> Result<(), String> {
    appearance.validate()?;
    let (tx, rx) = mpsc::sync_channel(1);
    {
      let terms = self.terms.lock().unwrap();
      let term = terms.get(id).ok_or("terminal no longer exists")?;
      if term.info.appearance_response_owner.is_none() { return Err("this shell does not own native appearance replies".into()); }
      let mut queue = term.resizes.lock().unwrap();
      if queue.len() >= 64 { return Err("too many pending terminal state changes".into()); }
      queue.push_back(ResizeRequest { cols: 0, rows: 0, geometry: None, appearance: Some(appearance), reply: tx });
      poke(term.wake_w);
    }
    rx.recv().map_err(|_| "terminal exited before updating appearance".to_string())?
  }

  // Renderer-driven flow control: pause PTY reads while its xterm write buffer runs ahead.
  fn flow(&self, cid: u64, id: &str, pause: bool) {
    if let Some(t) = self.terms.lock().unwrap().get_mut(id) {
      if pause { t.pause_owners.insert(cid); } else { t.pause_owners.remove(&cid); }
      t.paused.store(!t.pause_owners.is_empty(), Ordering::Relaxed);
      poke(t.wake_w);
    }
  }

  // Kill a terminal: signal the child and flag the I/O thread, which owns teardown (reap, remove
  // from the registry — closing the master fd only once nobody polls it — manifest, exit event).
  // The registry entry stays until then so a second kill/write can't race a half-torn-down term.
  fn kill(&self, id: &str) -> bool {
    let map = self.terms.lock().unwrap();
    match map.get(id) {
      Some(t) => {
        if !t.killed.swap(true, Ordering::SeqCst) {
          let _ = t.child.lock().unwrap().kill();
          poke(t.wake_w);
          log(&format!("kill {id}"));
        }
        true
      }
      None => false,
    }
  }

  fn kill_all(&self) -> usize {
    let ids: Vec<String> = self.terms.lock().unwrap().keys().cloned().collect();
    for id in &ids {
      self.kill(id);
    }
    ids.len()
  }

  fn list(&self) -> Vec<TermInfo> {
    self.terms.lock().unwrap().values().map(|t| t.info.clone()).collect()
  }

  // What the PTY is running: its foreground process group, read from the master with tcgetpgrp.
  // `atShell` is whether that group is the shell's own — the renderer uses it to know whether a
  // build is still running (build.js watchBuild) and whether it may type a command (cli-launch.js).
  // An unknown terminal, or a failed query, reads as at-shell so callers never wait on it forever.
  fn foreground(&self, id: &str) -> Value {
    let terms = self.terms.lock().unwrap();
    let Some(t) = terms.get(id) else { return json!({ "process": "", "atShell": true }) };
    let master = t.master.lock().unwrap();
    let Some(fd) = master.as_raw_fd() else { return json!({ "process": "", "atShell": true }) };
    let pgid = unsafe { libc::tcgetpgrp(fd) };
    if pgid <= 0 {
      return json!({ "process": "", "atShell": true });
    }
    let at_shell = pgid as u32 == t.info.pid;
    let process_path = if at_shell { String::new() } else { proc_path(pgid) };
    let process = process_path.rsplit('/').next().unwrap_or("");
    json!({ "process": process, "processPath": process_path, "pgid": pgid, "atShell": at_shell })
  }

  // Attach: the ring for replay. A renderer flow pause belongs to the client that asked for it;
  // attaching releases only that client's pause, never another viewer's backpressure.
  fn attach(&self, cid: u64, id: &str) -> Value {
    let byte_transport = self.clients.lock().unwrap().iter().any(|c| c.id == cid && c.byte_transport);
    match self.terms.lock().unwrap().get_mut(id) {
      Some(t) => {
        if t.pause_owners.remove(&cid) {
          t.paused.store(!t.pause_owners.is_empty(), Ordering::Relaxed);
          poke(t.wake_w);
        }
        let b = t.ring.lock().unwrap();
        if byte_transport {
          let bytes: Vec<u8> = b.chunks.iter().flat_map(|c| c.bytes.iter().copied()).collect();
          json!({ "bytes": BASE64.encode(bytes), "seq": b.seq, "live": true, "truncated": b.truncated })
        } else {
          let text: String = b.chunks.iter().map(|c| c.text.as_str()).collect();
          json!({ "buf": text, "seq": b.seq, "live": true, "truncated": b.truncated })
        }
      }
      // Unknown id: the PTY exited (or never existed). Say so, so the renderer doesn't keep a view
      // for it — its exit broadcast may have predated the renderer's subscription.
      None => json!({ "buf": "", "bytes": "", "seq": 0, "live": false, "truncated": false }),
    }
  }

  // Start the idle clock if nothing is left to serve; the watchdog exits after IDLE_EXIT.
  fn note_idle(&self) {
    let empty = self.terms.lock().unwrap().is_empty() && self.clients.lock().unwrap().is_empty();
    let mut idle = self.idle_since.lock().unwrap();
    if empty {
      if idle.is_none() {
        *idle = Some(Instant::now());
      }
    } else {
      *idle = None;
    }
  }

  fn handle(self: &Arc<Self>, cid: u64, req: &Value, _session: &mut ClientSession) -> Result<Value, String> {
    let op = req.get("op").and_then(Value::as_str).unwrap_or("");
    let sid = || req.get("term").and_then(Value::as_str).unwrap_or("").to_string();
    match op {
      "hello" => {
        let mut clients = self.clients.lock().unwrap();
        let client = clients.iter_mut().find(|c| c.id == cid).ok_or("client disconnected")?;
        if let Some(encoding) = req.get("dataEncoding") {
          match encoding.as_str() {
            Some("utf8") => client.byte_transport = false,
            Some("base64") => client.byte_transport = true,
            _ => return Err("unsupported terminal data encoding".into()),
          }
        }
        let encoding = if client.byte_transport { "base64" } else { "utf8" };
        #[allow(unused_mut)]
        let mut hello = json!({ "protocol": PROTOCOL, "pid": std::process::id(), "version": env!("CARGO_PKG_VERSION"), "dataEncoding": encoding, "acknowledgedInput": true });
        #[cfg(feature = "terminal-snapshots")]
        {
          _session.snapshot_negotiated = false;
          _session.snapshots.clear();
          hello["snapshotRevision"] = json!(craft_vt::GHOSTTY_REVISION);
          hello["stateResponseOwner"] = json!(craft_vt::STATE_RESPONSE_OWNER);
          hello["identityResponseOwner"] = json!(craft_vt::IDENTITY_RESPONSE_OWNER);
          hello["geometryResponseOwner"] = json!(craft_vt::GEOMETRY_RESPONSE_OWNER);
          hello["appearanceResponseOwner"] = json!(craft_vt::APPEARANCE_RESPONSE_OWNER);
          hello["shellIntegration"] = json!(true);
          if let Some(revision) = req.get("snapshotRevision") {
            if !client.byte_transport || revision.as_str() != Some(craft_vt::GHOSTTY_REVISION) {
              return Err("snapshots require base64 output and the exact Ghostty revision".into());
            }
            _session.snapshot_negotiated = true;
          }
        }
        Ok(hello)
      }
      "create" => {
        let opts: CreateOpts = req.get("opts").cloned().map(serde_json::from_value).transpose().map_err(|e| e.to_string())?.unwrap_or_default();
        self.create(opts).map(|i| serde_json::to_value(i).unwrap())
      }
      "write" => {
        if let Some(encoded) = req.get("bytes") {
          if req.get("data").is_some() { return Err("write must supply bytes or data, not both".into()); }
          let encoded = encoded.as_str().ok_or("bytes must be a base64 string")?;
          if encoded.len() > ((INPUT_MAX + 2) / 3) * 4 { return Err("terminal input exceeds buffer limit".into()); }
          let bytes = BASE64.decode(encoded).map_err(|_| "invalid base64 terminal input")?;
          if bytes.len() > INPUT_MAX { return Err("terminal input exceeds buffer limit".into()); }
          self.write(&sid(), &bytes)?;
        } else {
          self.write(&sid(), req.get("data").and_then(Value::as_str).unwrap_or("").as_bytes())?;
        }
        Ok(Value::Null)
      }
      "resize" => {
        let dimension = |key, default| -> Result<u16, String> {
          match req.get(key) {
            None => Ok(default),
            Some(value) => value.as_u64().and_then(|n| u16::try_from(n).ok()).filter(|n| *n > 0)
              .ok_or_else(|| format!("invalid terminal {key}")),
          }
        };
        let geometry: Option<TerminalGeometry> = req.get("geometry").cloned()
          .map(serde_json::from_value).transpose().map_err(|e| e.to_string())?;
        self.resize(&sid(), dimension("cols", 80)?, dimension("rows", 24)?, geometry)?;
        Ok(Value::Null)
      }
      "appearance" => {
        let appearance = req.get("appearance").cloned().ok_or("missing terminal appearance")?;
        self.appearance(&sid(), serde_json::from_value(appearance).map_err(|e| e.to_string())?)?;
        Ok(Value::Null)
      }
      "flow" => {
        self.flow(cid, &sid(), req.get("pause").and_then(Value::as_bool).unwrap_or(false));
        Ok(Value::Null)
      }
      "kill" => Ok(json!(self.kill(&sid()))),
      "killAll" => Ok(json!(self.kill_all())),
      "list" => Ok(serde_json::to_value(self.list()).unwrap()),
      "attach" => Ok(self.attach(cid, &sid())),
      "foreground" => Ok(self.foreground(&sid())),
      #[cfg(feature = "terminal-snapshots")]
      "snapshotBegin" | "snapshotRead" | "snapshotEnd" => {
        if !_session.snapshot_negotiated { return Err("negotiate the snapshot revision first".into()); }
        match op {
          "snapshotBegin" => {
            _session.snapshots.clear();
            let ring = self.terms.lock().unwrap().get(&sid()).ok_or("terminal no longer exists")?.ring.clone();
            let capture = ring.lock().unwrap().capture()?;
            _session.snapshots.begin(capture)
          }
          _ => {
            let token = req.get("token").and_then(Value::as_u64).ok_or("missing snapshot token")?;
            if op == "snapshotEnd" { _session.snapshots.end(token) }
            else {
              let offset = req.get("offset").and_then(Value::as_u64).ok_or("missing snapshot offset")?;
              _session.snapshots.read(token, offset)
            }
          }
        }
      }
      other => Err(format!("unknown op {other:?}")),
    }
  }

  fn serve_client(self: Arc<Self>, stream: UnixStream) {
    let Ok(mut out) = stream.try_clone() else { return };
    let Ok(sock) = stream.try_clone() else { return };
    let cid = self.client_seq.fetch_add(1, Ordering::SeqCst) + 1;
    let (tx, rx) = mpsc::channel::<Arc<str>>();
    let owed = Arc::new(AtomicUsize::new(0));
    let progress = Arc::new(Mutex::new(Instant::now()));
    self.clients.lock().unwrap().push(Client { id: cid, byte_transport: false, tx, owed: owed.clone(), progress: progress.clone(), sock });
    *self.idle_since.lock().unwrap() = None;
    log(&format!("client {cid} connected"));

    // Outbox: the single writer on this socket. Blocking here blocks only this client.
    std::thread::spawn(move || {
      'outbox: for line in rx {
        let mut bytes = line.as_bytes();
        while !bytes.is_empty() {
          match out.write(bytes) {
            Ok(0) => break 'outbox,
            Ok(n) => {
              // Count actual socket progress, including partially written frames.
              // A large frame must not hide a reader that is still making progress.
              *progress.lock().unwrap() = Instant::now();
              owed.fetch_sub(n, Ordering::Relaxed);
              bytes = &bytes[n..];
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break 'outbox,
          }
        }
      }
      let _ = out.shutdown(std::net::Shutdown::Both);
    });

    let mut session = ClientSession::default();
    let reader = BufReader::new(stream);
    for line in reader.lines() {
      let Ok(line) = line else { break };
      if line.trim().is_empty() {
        continue;
      }
      let req: Value = match serde_json::from_str(&line) {
        Ok(v) => v,
        Err(e) => {
          log(&format!("bad request: {e}"));
          continue;
        }
      };
      let res = self.handle(cid, &req, &mut session);
      if let Some(id) = req.get("id") {
        let resp = match res {
          Ok(v) => json!({ "id": id, "ok": v }),
          Err(e) => json!({ "id": id, "err": e }),
        };
        self.reply(cid, &resp);
      }
    }
    // Client gone: forget its outbox (dropping the sender ends the outbox thread). Terminals are
    // untouched — that is the whole point.
    self.clients.lock().unwrap().retain(|c| c.id != cid);
    // Its flow pauses die with it — a paused PTY with no one to resume it would freeze forever.
    for t in self.terms.lock().unwrap().values_mut() {
      if t.pause_owners.remove(&cid) {
        t.paused.store(!t.pause_owners.is_empty(), Ordering::Relaxed);
        poke(t.wake_w);
      }
    }
    log(&format!("client {cid} disconnected"));
    self.note_idle();
  }
}

// Entry point for `craft __ptyd__ <dir>`. Never returns.
pub fn main(dir: PathBuf) -> ! {
  let _ = std::fs::create_dir_all(dir.join("terms"));
  let sock = sock_path();
  // Never adopt or defer to a socket that isn't ours (see sock_path).
  if sock.exists() && !owned_socket(&sock) {
    log(&format!("{} is owned by another user; refusing to start", sock.display()));
    std::process::exit(1);
  }
  // A stale socket from a dead daemon blocks bind(); only remove it when nobody answers.
  if UnixStream::connect(&sock).is_ok() {
    log("another ptyd already serves this socket; exiting");
    std::process::exit(0);
  }
  let _ = std::fs::remove_file(&sock);
  let listener = match UnixListener::bind(&sock) {
    Ok(l) => l,
    Err(e) => {
      log(&format!("bind {}: {e}", sock.display()));
      std::process::exit(1);
    }
  };
  let _ = std::fs::write(dir.join("ptyd.pid"), std::process::id().to_string());
  // Manifests left by a previous daemon describe shells that died with it — clear them.
  if let Ok(rd) = std::fs::read_dir(dir.join("terms")) {
    for e in rd.flatten() {
      let _ = std::fs::remove_file(e.path());
    }
  }
  // SIGPIPE would kill the daemon on a write to a client that vanished; we handle the error instead.
  unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
  log(&format!("listening on {} (protocol {PROTOCOL}, v{})", sock.display(), env!("CARGO_PKG_VERSION")));

  let d = Arc::new(Daemon {
    dir: dir.clone(),
    terms: Mutex::new(HashMap::new()),
    clients: Mutex::new(Vec::new()),
    seq: AtomicU64::new(0),
    client_seq: AtomicU64::new(0),
    boot: now_ms() % 100_000_000,
    idle_since: Mutex::new(Some(Instant::now())),
  });

  // Also enforce client delivery deadlines when no PTY thread is polling (for
  // example, a client owns an explicit flow pause or is only receiving replies).
  let d2 = d.clone();
  let sock2 = sock.clone();
  std::thread::spawn(move || loop {
    std::thread::sleep(Duration::from_secs(5));
    d2.reap_stalled_clients();
    let idle = *d2.idle_since.lock().unwrap();
    if let Some(t) = idle {
      if t.elapsed() >= IDLE_EXIT && d2.terms.lock().unwrap().is_empty() && d2.clients.lock().unwrap().is_empty() {
        log("idle with no terminals and no clients; exiting");
        let _ = std::fs::remove_file(&sock2);
        let _ = std::fs::remove_file(d2.dir.join("ptyd.pid"));
        std::process::exit(0);
      }
    }
  });

  for conn in listener.incoming() {
    match conn {
      Ok(stream) => {
        let d = d.clone();
        std::thread::spawn(move || d.serve_client(stream));
      }
      Err(e) => log(&format!("accept: {e}")),
    }
  }
  std::process::exit(0)
}
