//! HelperClient - the only module that knows the native device helper's wire protocol.
//!
//! Port of Synara's `apps/server/src/device/helperClient.ts`. The helper (vendored under
//! `vendor/synara-device-helper`, built by `ios_simulator.rs`) speaks two channels:
//!
//! - Control: newline-delimited JSON-RPC 2.0 over stdin/stdout. Requests carry an integer id;
//!   responses carry `result` or `error`. It also sends a `ready` notification at startup, which
//!   needs no wait and no reply.
//! - Frames: this side listens on a unix socket and passes its path to `stream.start`; the helper
//!   connects as a client and writes `u32` little-endian length prefixed device-frame envelopes
//!   (`frame.rs`). The envelope is stripped here and each frame is broadcast with the device it
//!   was streamed for, so the pane and the backend can both read one stream.
//!
//! Two protocol facts shape callers: the helper attaches to one simulator at a time (`attach`)
//! and every input, read and stream method acts on that attachment; and input coordinates are
//! normalized to 0..1, converted from device points with the geometry `attach` returns.
//!
//! The process is started through the `Spawner` seam the chat engine uses: `chat::CliSpawner` in
//! production, a `ScriptedSpawner` that plays the helper in tests.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use cascade_chat::provider::process::{SpawnSpec, Spawner};
use serde_json::{json, Map, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{broadcast, mpsc, oneshot},
    task::JoinHandle,
};

use super::{
    backend::{DeviceFrameRecord, DeviceStreamFrame},
    frame::{decode_device_frame, LengthPrefixedRecordParser},
    sandbox::describe_sandbox_suspicion,
};

/// The helper's JSON-RPC methods.
pub mod methods {
    pub const PING: &str = "ping";
    pub const LIST: &str = "list";
    pub const ATTACH: &str = "attach";
    pub const STREAM_START: &str = "stream.start";
    pub const STREAM_STOP: &str = "stream.stop";
    pub const STREAM_STATS: &str = "stream.stats";
    pub const TAP: &str = "tap";
    pub const TOUCH: &str = "touch";
    pub const SWIPE: &str = "swipe";
    pub const KEY: &str = "key";
    pub const TEXT: &str = "text";
    pub const BUTTON: &str = "button";
    pub const SCREENSHOT: &str = "screenshot";
    pub const DESCRIBE_UI: &str = "describe-ui";
    pub const SET_FOCUSED_VALUE: &str = "set-focused-value";
}

pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
pub const MAX_CONTROL_LINE_BYTES: usize = 4 * 1024 * 1024;
/// Helper diagnostics belong in a failure message but must never grow without bound.
const STDERR_TAIL_CHARS: usize = 4_096;

/// A helper failure. `code` is `helper_<json-rpc code>` for an error the helper answered, or one of
/// `helper_timeout`, `helper_exited`, `helper_disposed`, `helper_unavailable`,
/// `helper_spawn_failed`, `helper_write_failed`, `helper_protocol_error`, `helper_not_attached`,
/// `helper_malformed_response`, `device_coordinate_out_of_bounds`, `frame_socket_failed`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceHelperError {
    pub code: String,
    pub message: String,
}

impl DeviceHelperError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_owned(), message: message.into() }
    }

    fn disposed() -> Self {
        Self::new("helper_disposed", "Device helper was shut down")
    }
}

impl std::fmt::Display for DeviceHelperError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for DeviceHelperError {}

/// Geometry from `attach`, used to convert device points into normalized input.
#[derive(Clone, Debug, PartialEq)]
pub struct DeviceHelperAttachment {
    pub udid: String,
    pub point_width: f64,
    pub point_height: f64,
    pub pixel_width: f64,
    pub pixel_height: f64,
    pub scale: f64,
    pub input_available: bool,
    pub accessibility_available: bool,
}

/// What to spawn: the helper itself, or `sandbox-exec` around it (`sandbox.rs`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HelperLaunch {
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    /// The Seatbelt profile it runs under, named in a timeout's message; None when unconfined.
    pub profile_path: Option<PathBuf>,
}

pub type HelperExitListener = Arc<dyn Fn(String) + Send + Sync>;

pub struct HelperClientOptions {
    pub spawner: Arc<dyn Spawner>,
    pub launch: HelperLaunch,
    pub request_timeout: Duration,
    /// Where the frames of a stream go.
    pub frames: broadcast::Sender<DeviceFrameRecord>,
    /// Told once, with a reason, when the process exits by itself.
    pub on_exit: Option<HelperExitListener>,
}

/// Owns one helper process: spawn, JSON-RPC over stdio, and the unix socket the helper connects
/// back to with frames.
#[derive(Clone)]
pub struct HelperClient {
    shared: Arc<Shared>,
}

struct Shared {
    options: HelperClientOptions,
    state: Mutex<State>,
}

type Pending = oneshot::Sender<Result<Value, DeviceHelperError>>;

#[derive(Default)]
struct State {
    /// Bumped for every process started and at disposal: a task left from an older process sees
    /// it changed and touches nothing.
    generation: u64,
    process: Option<Process>,
    exited: bool,
    disposed: bool,
    next_id: i64,
    pending: HashMap<i64, Pending>,
    attachment: Option<DeviceHelperAttachment>,
    stderr_tail: String,
    frame_server: Option<FrameServer>,
}

struct Process {
    /// Lines for stdin; dropping it closes stdin, which is how the helper is asked to leave.
    writer: Option<mpsc::UnboundedSender<Vec<u8>>>,
    terminate: Box<dyn FnMut() + Send>,
}

struct FrameServer {
    directory: PathBuf,
    accept: JoinHandle<()>,
}

impl FrameServer {
    /// Stops accepting, ends the connection, and removes the socket's folder.
    fn close(self) {
        self.accept.abort();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// Aborts a task when dropped, so a frame connection ends with the server that accepted it.
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Removes a pending request whose caller stopped waiting (a timeout, a dropped future).
struct PendingGuard<'a> {
    shared: &'a Shared,
    id: i64,
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        self.shared.state.lock().unwrap().pending.remove(&self.id);
    }
}

impl HelperClient {
    pub fn new(options: HelperClientOptions) -> Self {
        Self {
            shared: Arc::new(Shared {
                options,
                state: Mutex::new(State { next_id: 1, ..State::default() }),
            }),
        }
    }

    /// Whether a process is up and has not exited.
    pub fn running(&self) -> bool {
        let state = self.shared.state.lock().unwrap();
        state.process.is_some() && !state.exited
    }

    /// The simulator this helper is bound to, if any.
    pub fn attached_device(&self) -> Option<DeviceHelperAttachment> {
        self.shared.state.lock().unwrap().attachment.clone()
    }

    /// Starts the process if it is not running yet. A disposed client stays disposed: restarting
    /// would resurrect a helper its owner already tore down, and nothing would ever stop it.
    pub fn start(&self) -> Result<(), DeviceHelperError> {
        let mut state = self.shared.state.lock().unwrap();
        self.start_locked(&mut state)
    }

    fn start_locked(&self, state: &mut State) -> Result<(), DeviceHelperError> {
        if state.disposed {
            return Err(DeviceHelperError::disposed());
        }
        if state.process.is_some() {
            return Ok(());
        }
        let launch = &self.shared.options.launch;
        let spec = SpawnSpec {
            program: launch.command.clone(),
            args: launch.args.clone(),
            cwd: None,
            env: launch.env.clone(),
            env_remove: Vec::new(),
        };
        let child = self
            .shared
            .options
            .spawner
            .spawn(&spec)
            .map_err(|error| DeviceHelperError::new("helper_spawn_failed", error.to_string()))?;
        state.generation += 1;
        state.exited = false;
        state.stderr_tail.clear();
        let generation = state.generation;

        let (writer, mut lines) = mpsc::unbounded_channel::<Vec<u8>>();
        let mut stdin = child.stdin;
        tokio::spawn(async move {
            while let Some(line) = lines.recv().await {
                if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
                    break;
                }
            }
            let _ = stdin.shutdown().await;
        });

        let shared = Arc::downgrade(&self.shared);
        let mut stdout = child.stdout;
        tokio::spawn(async move {
            let mut framer = ControlLineFramer::new(MAX_CONTROL_LINE_BYTES);
            let mut buffer = vec![0u8; 64 * 1024];
            loop {
                let read = match stdout.read(&mut buffer).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => read,
                };
                let (lines, overflowed) = framer.push(&buffer[..read]);
                let Some(shared) = shared.upgrade() else { break };
                for line in lines {
                    shared.handle_control_line(generation, &line);
                }
                // An oversized line means a response being waited for is gone: fail fast rather
                // than sit out the timeout. The helper is still there and stays usable.
                if overflowed {
                    shared.reject_in_flight(
                        generation,
                        DeviceHelperError::new("helper_protocol_error", "Device helper control line exceeded limit"),
                    );
                }
            }
        });

        if let Some(mut stderr) = child.stderr {
            let shared = Arc::downgrade(&self.shared);
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 8 * 1024];
                loop {
                    let read = match stderr.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(read) => read,
                    };
                    let Some(shared) = shared.upgrade() else { break };
                    let mut state = shared.state.lock().unwrap();
                    if state.generation != generation {
                        break;
                    }
                    state.stderr_tail.push_str(&String::from_utf8_lossy(&buffer[..read]));
                    let count = state.stderr_tail.chars().count();
                    if count > STDERR_TAIL_CHARS {
                        let cut = state.stderr_tail.char_indices().nth(count - STDERR_TAIL_CHARS).map_or(0, |(at, _)| at);
                        state.stderr_tail.drain(..cut);
                    }
                }
            });
        }

        let shared = Arc::downgrade(&self.shared);
        let exited = child.exited;
        tokio::spawn(async move {
            let code = exited.await;
            if let Some(shared) = shared.upgrade() {
                shared.process_exited(generation, code);
            }
        });

        state.process = Some(Process { writer: Some(writer), terminate: child.terminate });
        Ok(())
    }

    /// Sends one request and waits for its answer, up to the request timeout.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, DeviceHelperError> {
        let (id, receiver, writer) = {
            let mut state = self.shared.state.lock().unwrap();
            if state.process.is_none() {
                self.start_locked(&mut state)?;
            }
            let writer = match (&state.process, state.exited) {
                (Some(Process { writer: Some(writer), .. }), false) => writer.clone(),
                _ => return Err(DeviceHelperError::new("helper_unavailable", "Device helper is not running")),
            };
            let id = state.next_id;
            state.next_id += 1;
            let (sender, receiver) = oneshot::channel();
            state.pending.insert(id, sender);
            (id, receiver, writer)
        };
        let _guard = PendingGuard { shared: &self.shared, id };
        let params = if params.is_null() { Value::Object(Map::new()) } else { params };
        let mut line = serde_json::to_vec(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))
            .map_err(|error| DeviceHelperError::new("helper_write_failed", error.to_string()))?;
        line.push(b'\n');
        if writer.send(line).is_err() {
            return Err(DeviceHelperError::new("helper_write_failed", "Device helper stdin is closed"));
        }
        match tokio::time::timeout(self.shared.options.request_timeout, receiver).await {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Err(DeviceHelperError::new("helper_unavailable", "Device helper is not running")),
            Err(_) => Err(DeviceHelperError::new(
                "helper_timeout",
                format!(
                    "Device helper {method} timed out.{}",
                    describe_sandbox_suspicion(self.shared.options.launch.profile_path.as_deref())
                ),
            )),
        }
    }

    /// Binds the helper to one simulator. The helper holds a single attachment, so attaching to a
    /// different device replaces the previous one.
    pub async fn attach(&self, udid: &str, force: bool) -> Result<DeviceHelperAttachment, DeviceHelperError> {
        {
            let mut state = self.shared.state.lock().unwrap();
            if !force {
                if let Some(attachment) = state.attachment.as_ref().filter(|attachment| attachment.udid == udid) {
                    return Ok(attachment.clone());
                }
            }
            // Cleared before the request: a failed re-attach must not leave the caller believing
            // the previous, now-dead attachment is still good.
            state.attachment = None;
        }
        let result = self.request(methods::ATTACH, json!({ "udid": udid })).await?;
        let read = |key: &str, fallback: f64| result.get(key).and_then(Value::as_f64).filter(|value| value.is_finite()).unwrap_or(fallback);
        let pixel_width = read("pixelWidth", 0.0);
        let pixel_height = read("pixelHeight", 0.0);
        let scale = read("scale", 3.0);
        let capabilities = result.get("capabilities");
        let attachment = DeviceHelperAttachment {
            udid: udid.to_owned(),
            pixel_width,
            pixel_height,
            scale,
            point_width: read("pointWidth", pixel_width / scale),
            point_height: read("pointHeight", pixel_height / scale),
            input_available: capabilities.and_then(|value| value.get("input")) == Some(&Value::Bool(true)),
            accessibility_available: capabilities.and_then(|value| value.get("accessibility")) == Some(&Value::Bool(true)),
        };
        if !(attachment.point_width > 0.0) || !(attachment.point_height > 0.0) {
            return Err(DeviceHelperError::new(
                "helper_malformed_response",
                "Device helper reported no usable screen geometry",
            ));
        }
        self.shared.state.lock().unwrap().attachment = Some(attachment.clone());
        Ok(attachment)
    }

    /// Forgets the attachment for a device. It holds a display descriptor tied to one boot; the
    /// helper outlives the simulator, so without this the next `attach` would short-circuit on
    /// the matching udid and every call would fail against a dead framebuffer.
    pub fn invalidate_attachment(&self, udid: &str) {
        let mut state = self.shared.state.lock().unwrap();
        if state.attachment.as_ref().is_some_and(|attachment| attachment.udid == udid) {
            state.attachment = None;
        }
    }

    /// Device points as the 0..1 coordinates the helper's input methods take. Out of bounds is
    /// refused, never clamped: a caller sending frame pixels instead of points must hear about it
    /// rather than have every tap pinned to the screen edge and acked.
    pub fn normalize(&self, x: f64, y: f64) -> Result<(f64, f64), DeviceHelperError> {
        let attachment = self.attached_device().ok_or_else(|| {
            DeviceHelperError::new("helper_not_attached", "Device helper is not attached to a device")
        })?;
        Ok((
            normalize_coordinate(x, attachment.point_width, "x", &attachment)?,
            normalize_coordinate(y, attachment.point_height, "y", &attachment)?,
        ))
    }

    /// Starts capture for the attached device. This side owns the socket: it listens first and
    /// passes the path, so the helper never guesses where to connect and a stale socket file is
    /// never reused.
    pub async fn start_stream(&self, udid: &str) -> Result<(), DeviceHelperError> {
        self.stop_stream().await;
        self.attach(udid, false).await?;

        let directory = frame_socket_directory()
            .map_err(|error| DeviceHelperError::new("frame_socket_failed", format!("Could not create the frame socket: {error}")))?;
        let socket_path = directory.join("frames.sock");
        let listener = match tokio::net::UnixListener::bind(&socket_path) {
            Ok(listener) => listener,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&directory);
                return Err(DeviceHelperError::new(
                    "frame_socket_failed",
                    format!("Could not listen on {}: {error}", socket_path.display()),
                ));
            }
        };
        let frames = self.shared.options.frames.clone();
        let routing: Arc<str> = Arc::from(udid);
        let accept = tokio::spawn(async move {
            let mut connection: Option<AbortOnDrop> = None;
            while let Ok((stream, _)) = listener.accept().await {
                // A new connection replaces the old one, as the helper reconnects per stream.
                connection = Some(AbortOnDrop(tokio::spawn(read_frames(stream, routing.clone(), frames.clone()))));
            }
            drop(connection);
        });
        // A stream started meanwhile (two devices attached at once) is replaced, not leaked.
        let replaced = self.shared.state.lock().unwrap().frame_server.replace(FrameServer { directory, accept });
        if let Some(replaced) = replaced {
            replaced.close();
        }

        if let Err(error) = self
            .request(methods::STREAM_START, json!({ "socketPath": socket_path.to_string_lossy() }))
            .await
        {
            self.close_frame_socket();
            return Err(error);
        }
        Ok(())
    }

    pub async fn stop_stream(&self) {
        let streaming = self.running() && self.shared.state.lock().unwrap().frame_server.is_some();
        if streaming {
            let _ = self.request(methods::STREAM_STOP, Value::Null).await;
        }
        self.close_frame_socket();
    }

    /// Stops the stream, fails what is in flight, closes stdin and ends the process.
    pub async fn dispose(&self) {
        self.shared.state.lock().unwrap().disposed = true;
        self.stop_stream().await;
        let process = {
            let mut state = self.shared.state.lock().unwrap();
            for (_, pending) in state.pending.drain() {
                let _ = pending.send(Err(DeviceHelperError::disposed()));
            }
            state.generation += 1;
            state.attachment = None;
            state.exited = true;
            state.process.take()
        };
        if let Some(mut process) = process {
            drop(process.writer.take());
            (process.terminate)();
        }
    }

    fn close_frame_socket(&self) {
        let server = self.shared.state.lock().unwrap().frame_server.take();
        if let Some(server) = server {
            server.close();
        }
    }
}

impl Shared {
    fn handle_control_line(&self, generation: u64, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        // Helper logs that are not JSON are ignored, and so are notifications (`ready`), which
        // carry no id.
        let Ok(message) = serde_json::from_str::<Value>(line) else { return };
        let Some(id) = message.get("id").and_then(Value::as_f64) else { return };
        let mut state = self.state.lock().unwrap();
        if state.generation != generation {
            return;
        }
        let Some(pending) = state.pending.remove(&(id as i64)) else { return };
        drop(state);
        let answer = match message.get("error").filter(|error| !error.is_null()) {
            Some(error) => Err(DeviceHelperError {
                code: match error.get("code").and_then(Value::as_f64) {
                    Some(code) => format!("helper_{}", format_js_number(code)),
                    None => "helper_error".into(),
                },
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Device helper reported an error")
                    .to_owned(),
            }),
            None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
        };
        let _ = pending.send(answer);
    }

    /// Rejects everything in flight without ending the transport.
    fn reject_in_flight(&self, generation: u64, error: DeviceHelperError) {
        let mut state = self.state.lock().unwrap();
        if state.generation != generation {
            return;
        }
        for (_, pending) in state.pending.drain() {
            let _ = pending.send(Err(error.clone()));
        }
    }

    fn process_exited(&self, generation: u64, code: Option<i32>) {
        let reason = {
            let mut state = self.state.lock().unwrap();
            if state.generation != generation {
                return;
            }
            state.exited = true;
            state.attachment = None;
            let tail = state.stderr_tail.trim().to_owned();
            let status = match code {
                Some(code) => format!("code={code}, signal=null"),
                None => "code=null, signal=unknown".to_owned(),
            };
            let reason = if tail.is_empty() {
                format!("device helper exited ({status})")
            } else {
                format!("device helper exited ({status}): {tail}")
            };
            let error = DeviceHelperError::new("helper_exited", reason.clone());
            for (_, pending) in state.pending.drain() {
                let _ = pending.send(Err(error.clone()));
            }
            if let Some(process) = state.process.as_mut() {
                process.writer = None;
            }
            reason
        };
        if let Some(on_exit) = &self.options.on_exit {
            on_exit(reason);
        }
    }
}

/// A JSON number as JavaScript prints it: `-32000`, not `-32000.0`.
fn format_js_number(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// One axis of a device-point coordinate as a 0..1 fraction of the screen. The error names the
/// value and the range, because the common cause is frame pixels: "1019 is outside 0..402"
/// makes the scale factor obvious.
fn normalize_coordinate(
    value: f64,
    extent: f64,
    axis: &str,
    attachment: &DeviceHelperAttachment,
) -> Result<f64, DeviceHelperError> {
    if !value.is_finite() || value < 0.0 || value > extent {
        return Err(DeviceHelperError::new(
            "device_coordinate_out_of_bounds",
            format!(
                "Device {axis}={} is outside the screen bounds 0..{} device points ({}x{} points at {}x; pass device \
                 points, not frame pixels).",
                format_js_number(value),
                format_js_number(extent),
                format_js_number(attachment.point_width),
                format_js_number(attachment.point_height),
                format_js_number(attachment.scale),
            ),
        ));
    }
    Ok(if extent == 0.0 { 0.0 } else { value / extent })
}

/// A fresh private folder for the frame socket, short enough for a socket path (104 bytes).
fn frame_socket_directory() -> std::io::Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    let suffix = uuid::Uuid::new_v4().simple().to_string();
    let directory = std::env::temp_dir().join(format!("cascade-device-frames-{}", &suffix[..8]));
    std::fs::DirBuilder::new().mode(0o700).create(&directory)?;
    Ok(directory)
}

/// Reads one frame connection until it ends or desyncs. A desynced stream cannot resynchronize,
/// so it is dropped rather than feeding garbage to a decoder.
async fn read_frames(
    mut stream: tokio::net::UnixStream,
    udid: Arc<str>,
    frames: broadcast::Sender<DeviceFrameRecord>,
) {
    let mut parser = LengthPrefixedRecordParser::default();
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        let read = match stream.read(&mut buffer).await {
            Ok(0) | Err(_) => return,
            Ok(read) => read,
        };
        let Ok(records) = parser.push(&buffer[..read]) else { return };
        for record in records {
            let Ok((header, payload)) = decode_device_frame(&record) else { continue };
            // The envelope is stripped: a reader re-wraps it with the routing id it already has.
            let _ = frames.send(DeviceFrameRecord {
                udid: udid.clone(),
                frame: DeviceStreamFrame {
                    sequence: header.sequence,
                    timestamp_ms: header.timestamp_ms,
                    keyframe: header.keyframe,
                    codec_config: header.codec_config,
                    data: Arc::from(payload),
                },
            });
        }
    }
}

/// Splits stdout into lines, dropping (and reporting) one that runs past the cap and skipping to
/// its newline, so one bad line costs exactly that line. Undecodable bytes are dropped like the
/// non-JSON diagnostics the helper also writes.
pub struct ControlLineFramer {
    pending: Vec<u8>,
    skipping: bool,
    max: usize,
}

impl ControlLineFramer {
    pub fn new(max: usize) -> Self {
        Self { pending: Vec::new(), skipping: false, max }
    }

    /// The complete lines in `chunk`, and whether a line was dropped for its size.
    pub fn push(&mut self, chunk: &[u8]) -> (Vec<String>, bool) {
        let mut lines = Vec::new();
        let mut overflowed = false;
        let mut start = 0;
        while start <= chunk.len() {
            let newline = chunk[start..].iter().position(|byte| *byte == b'\n').map(|at| start + at);
            let end = newline.unwrap_or(chunk.len());
            if !self.skipping {
                self.pending.extend_from_slice(&chunk[start..end]);
                if self.pending.len() > self.max {
                    self.pending.clear();
                    self.skipping = true;
                    overflowed = true;
                }
            }
            let Some(newline) = newline else { break };
            start = newline + 1;
            if self.skipping {
                self.skipping = false;
                continue;
            }
            let line = std::mem::take(&mut self.pending);
            if let Ok(line) = String::from_utf8(line) {
                lines.push(line);
            }
        }
        (lines, overflowed)
    }
}
