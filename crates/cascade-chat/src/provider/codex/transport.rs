//! Ported from Synara `apps/server/src/codexAppServerTransport.ts` and the parts of
//! `packages/shared/src/jsonrpc-stdio.ts` it builds on: raw-byte JSONL framing of the
//! app-server's stdout, a bounded writer for its stdin, and the registry that pairs a request
//! with its response.
//!
//! Synara's writer is a promise queue that honours stream drain. Here it is a task that owns
//! stdin and writes frames in the order they were queued; [`CodexJsonlWriter::write`] queues and
//! returns at once, and a write that fails later reports itself through the writer's failure
//! callback, which the manager treats as a transport failure, as Synara's `writeMessage` does.

use std::{
    collections::HashMap,
    fmt,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
};

use serde_json::{json, Value};
use tokio::{
    io::{AsyncWrite, AsyncWriteExt},
    sync::{mpsc, oneshot},
};

/// Synara `JSONRPC_STDIO_MAX_FRAME_BYTES` (jsonrpc-stdio.ts:6)
pub const JSONRPC_STDIO_MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
/// Synara `JSONRPC_STDIO_MAX_QUEUED_STDIN_BYTES` (jsonrpc-stdio.ts:7)
pub const JSONRPC_STDIO_MAX_QUEUED_STDIN_BYTES: usize = 32 * 1024 * 1024;

/// Synara `CODEX_APP_SERVER_MAX_FRAME_BYTES` (codexAppServerTransport.ts:10)
pub const CODEX_APP_SERVER_MAX_FRAME_BYTES: usize = JSONRPC_STDIO_MAX_FRAME_BYTES;
/// Synara `CODEX_APP_SERVER_MAX_QUEUED_STDIN_BYTES` (codexAppServerTransport.ts:11)
pub const CODEX_APP_SERVER_MAX_QUEUED_STDIN_BYTES: usize = JSONRPC_STDIO_MAX_QUEUED_STDIN_BYTES;

/// Synara `JsonRpcStdioRequestRegistry`'s default `requestTimeoutMs` (jsonrpc-stdio.ts:395).
pub const JSONRPC_STDIO_REQUEST_TIMEOUT_MS: u64 = 20_000;

/// Synara `CodexAppServerTransportErrorReason` (codexAppServerTransport.ts:13)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CodexAppServerTransportErrorReason {
    FrameTooLarge,
    InvalidUtf8,
    UnterminatedFrame,
    ReadClosed,
    WriteOverloaded,
    WriteClosed,
}

impl CodexAppServerTransportErrorReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FrameTooLarge => "frame-too-large",
            Self::InvalidUtf8 => "invalid-utf8",
            Self::UnterminatedFrame => "unterminated-frame",
            Self::ReadClosed => "read-closed",
            Self::WriteOverloaded => "write-overloaded",
            Self::WriteClosed => "write-closed",
        }
    }
}

/// Synara `CodexAppServerTransportError` (codexAppServerTransport.ts:22)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexAppServerTransportError {
    pub reason: CodexAppServerTransportErrorReason,
    pub max_bytes: usize,
    pub observed_bytes: usize,
}

impl CodexAppServerTransportError {
    pub fn new(reason: CodexAppServerTransportErrorReason, max_bytes: usize, observed_bytes: usize) -> Self {
        Self { reason, max_bytes, observed_bytes }
    }
}

impl fmt::Display for CodexAppServerTransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&transport_error_message(self))
    }
}

impl std::error::Error for CodexAppServerTransportError {}

/// Synara `isFatalCodexLineError` (codexAppServerTransport.ts:39): only an oversized line ends
/// the session. A frame past the budget was on the wire, so a response we may be waiting on is
/// gone; invalid UTF-8 costs only its own line.
pub fn is_fatal_codex_line_error(error: &CodexAppServerTransportError) -> bool {
    error.reason == CodexAppServerTransportErrorReason::FrameTooLarge
}

/// Synara `CodexJsonlFramer` (codexAppServerTransport.ts:43) over `JsonRpcStdioFramer`
/// (jsonrpc-stdio.ts:67). Retaining bytes until the newline keeps split UTF-8 safe.
pub struct CodexJsonlFramer {
    pending: Vec<u8>,
    pub max_frame_bytes: usize,
    ended: bool,
    /// Set while the remainder of a dropped line is being skipped to its newline.
    skipping: bool,
}

impl Default for CodexJsonlFramer {
    fn default() -> Self {
        Self::new(CODEX_APP_SERVER_MAX_FRAME_BYTES)
    }
}

impl CodexJsonlFramer {
    pub fn new(max_frame_bytes: usize) -> Self {
        assert!(max_frame_bytes > 0, "JSON-RPC stdio frame budget must be positive");
        Self { pending: Vec::new(), max_frame_bytes, ended: false, skipping: false }
    }

    /// Frames a chunk, returning every complete line it completed.
    ///
    /// A line that cannot be framed costs exactly that line: its bytes are dropped and the scan
    /// continues to the next newline. A dropped line that is fatal (see
    /// [`is_fatal_codex_line_error`]) fails the whole push, as Synara's throwing handler does;
    /// one that is not is logged and skipped.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<String>, CodexAppServerTransportError> {
        if self.ended {
            return Err(CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::UnterminatedFrame,
                self.max_frame_bytes,
                self.pending.len(),
            ));
        }
        let mut frames = Vec::new();
        let mut errors = Vec::new();
        let mut start = 0;
        while start < chunk.len() {
            let newline = chunk[start..].iter().position(|byte| *byte == b'\n').map(|at| start + at);
            let end = newline.unwrap_or(chunk.len());
            if !self.skipping {
                if let Some(overflow) = self.append(&chunk[start..end]) {
                    self.pending.clear();
                    self.skipping = true;
                    errors.push(overflow);
                }
            }
            let Some(newline) = newline else { break };
            start = newline + 1;
            if self.skipping {
                self.skipping = false;
                continue;
            }
            match self.take_frame() {
                Ok(frame) => frames.push(frame),
                Err(error) => errors.push(error),
            }
        }
        for error in errors {
            if is_fatal_codex_line_error(&error) {
                return Err(error);
            }
            tracing::warn!(reason = error.reason.as_str(), "dropped an unreadable codex app-server stdout line");
        }
        Ok(frames)
    }

    pub fn finish(&mut self) -> Result<(), CodexAppServerTransportError> {
        self.ended = true;
        if !self.pending.is_empty() {
            return Err(CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::UnterminatedFrame,
                self.max_frame_bytes,
                self.pending.len(),
            ));
        }
        Ok(())
    }

    /// Discards buffered bytes and permanently closes this framer.
    pub fn close(&mut self) {
        self.pending.clear();
        self.skipping = false;
        self.ended = true;
    }

    pub fn buffered_bytes(&self) -> usize {
        self.pending.len()
    }

    fn append(&mut self, chunk: &[u8]) -> Option<CodexAppServerTransportError> {
        if chunk.is_empty() {
            return None;
        }
        let observed_bytes = self.pending.len() + chunk.len();
        if observed_bytes > self.max_frame_bytes {
            return Some(CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::FrameTooLarge,
                self.max_frame_bytes,
                observed_bytes,
            ));
        }
        self.pending.extend_from_slice(chunk);
        None
    }

    fn take_frame(&mut self) -> Result<String, CodexAppServerTransportError> {
        let mut frame = std::mem::take(&mut self.pending);
        if frame.last() == Some(&b'\r') {
            frame.pop();
        }
        let observed_bytes = frame.len();
        String::from_utf8(frame).map_err(|_| {
            CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::InvalidUtf8,
                self.max_frame_bytes,
                observed_bytes,
            )
        })
    }
}

/// Synara `CodexJsonlWriter` (codexAppServerTransport.ts:59) over `JsonRpcStdioWriter`
/// (jsonrpc-stdio.ts:213): serializes JSONL writes and bounds the bytes waiting for stdin.
pub struct CodexJsonlWriter {
    frames: Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    queued_bytes: Arc<AtomicUsize>,
    closed: Arc<AtomicBool>,
    drained: Mutex<Option<oneshot::Receiver<()>>>,
    pub max_frame_bytes: usize,
    pub max_queued_bytes: usize,
}

impl CodexJsonlWriter {
    /// Starts the task that owns `writable`. `on_failure` hears the first write that failed.
    pub fn spawn(
        writable: Pin<Box<dyn AsyncWrite + Send>>,
        on_failure: impl FnOnce(String) + Send + 'static,
    ) -> Self {
        Self::spawn_with_budgets(
            writable,
            on_failure,
            CODEX_APP_SERVER_MAX_FRAME_BYTES,
            CODEX_APP_SERVER_MAX_QUEUED_STDIN_BYTES,
        )
    }

    pub fn spawn_with_budgets(
        mut writable: Pin<Box<dyn AsyncWrite + Send>>,
        on_failure: impl FnOnce(String) + Send + 'static,
        max_frame_bytes: usize,
        max_queued_bytes: usize,
    ) -> Self {
        assert!(
            max_frame_bytes > 0 && max_queued_bytes >= max_frame_bytes,
            "JSON-RPC stdio budgets must be positive and queue >= frame"
        );
        let (sender, mut receiver) = mpsc::unbounded_channel::<Vec<u8>>();
        let queued_bytes = Arc::new(AtomicUsize::new(0));
        let closed = Arc::new(AtomicBool::new(false));
        let (drained_tx, drained_rx) = oneshot::channel();
        let task_queued = queued_bytes.clone();
        let task_closed = closed.clone();
        tokio::spawn(async move {
            let mut on_failure = Some(on_failure);
            while let Some(frame) = receiver.recv().await {
                let length = frame.len();
                let written = async {
                    writable.write_all(&frame).await?;
                    writable.flush().await
                }
                .await;
                task_queued.fetch_sub(length.min(task_queued.load(Ordering::SeqCst)), Ordering::SeqCst);
                if let Err(error) = written {
                    task_closed.store(true, Ordering::SeqCst);
                    if let Some(report) = on_failure.take() {
                        report(format!("Codex app-server stdin closed during write: {error}"));
                    }
                    break;
                }
            }
            let _ = writable.shutdown().await;
            let _ = drained_tx.send(());
        });
        Self {
            frames: Mutex::new(Some(sender)),
            queued_bytes,
            closed,
            drained: Mutex::new(Some(drained_rx)),
            max_frame_bytes,
            max_queued_bytes,
        }
    }

    /// Queues one message as a JSONL frame.
    pub fn write(&self, message: &Value) -> Result<(), CodexAppServerTransportError> {
        let mut frame = serde_json::to_vec(message).unwrap_or_else(|_| b"null".to_vec());
        frame.push(b'\n');
        if frame.len() > self.max_frame_bytes {
            return Err(CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::FrameTooLarge,
                self.max_frame_bytes,
                frame.len(),
            ));
        }
        let queued = self.queued_bytes.load(Ordering::SeqCst);
        let frames = self.frames.lock().unwrap();
        let Some(sender) = frames.as_ref().filter(|_| !self.closed.load(Ordering::SeqCst)) else {
            return Err(CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::WriteClosed,
                self.max_queued_bytes,
                frame.len(),
            ));
        };
        if queued + frame.len() > self.max_queued_bytes {
            return Err(CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::WriteOverloaded,
                self.max_queued_bytes,
                queued + frame.len(),
            ));
        }
        let length = frame.len();
        self.queued_bytes.fetch_add(length, Ordering::SeqCst);
        sender.send(frame).map_err(|_| {
            CodexAppServerTransportError::new(
                CodexAppServerTransportErrorReason::WriteClosed,
                self.max_queued_bytes,
                length,
            )
        })
    }

    pub fn buffered_bytes(&self) -> usize {
        self.queued_bytes.load(Ordering::SeqCst)
    }

    /// Accepts no more frames. Frames already queued are still written, then stdin is closed;
    /// the returned receiver resolves once that is done.
    pub fn close(&self) -> Option<oneshot::Receiver<()>> {
        self.frames.lock().unwrap().take();
        self.drained.lock().unwrap().take()
    }
}

/// Synara `JsonRpcResponse` (jsonrpc-stdio.ts:356), the error half.
#[derive(Clone, Debug, PartialEq)]
pub struct JsonRpcError {
    pub code: Option<i64>,
    pub message: Option<String>,
    pub data: Option<Value>,
}

/// A request's outcome: its result, or the message it failed with.
pub type JsonRpcOutcome = Result<Value, String>;

struct JsonRpcPendingRequest {
    method: String,
    reply: oneshot::Sender<JsonRpcOutcome>,
}

/// Synara `JsonRpcStdioRequestRegistry` (jsonrpc-stdio.ts:382): pairs requests with responses.
/// Shared between the task that reads stdout (which settles requests as their responses arrive)
/// and the session (which waits on them); the timeout is the waiter's.
#[derive(Clone, Default)]
pub struct JsonRpcStdioRequestRegistry {
    pending: Arc<Mutex<HashMap<String, JsonRpcPendingRequest>>>,
}

impl JsonRpcStdioRequestRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn size(&self) -> usize {
        self.pending.lock().unwrap().len()
    }

    /// The methods still waiting on a response.
    pub fn pending_methods(&self) -> Vec<String> {
        self.pending.lock().unwrap().values().map(|pending| pending.method.clone()).collect()
    }

    /// Registers `id` before the request is written, so a fast response cannot be missed.
    pub fn register(&self, id: &Value, method: &str) -> Result<oneshot::Receiver<JsonRpcOutcome>, String> {
        let key = request_key(id);
        let mut pending = self.pending.lock().unwrap();
        if pending.contains_key(&key) {
            return Err(format!("Duplicate JSON-RPC request id {id}."));
        }
        let (reply, outcome) = oneshot::channel();
        pending.insert(key, JsonRpcPendingRequest { method: method.to_string(), reply });
        Ok(outcome)
    }

    /// Forgets a request whose waiter gave up.
    pub fn forget(&self, id: &Value) {
        self.pending.lock().unwrap().remove(&request_key(id));
    }

    /// Resolves a response. Returns false for an unknown id.
    pub fn handle_response(&self, id: &Value, result: Option<Value>, error: Option<JsonRpcError>) -> bool {
        let Some(request) = self.pending.lock().unwrap().remove(&request_key(id)) else {
            return false;
        };
        let outcome = match error {
            Some(error) => Err(format!(
                "{} failed: {}",
                request.method,
                error.message.unwrap_or_else(|| "JSON-RPC peer reported an error".to_string())
            )),
            None => Ok(result.unwrap_or(Value::Null)),
        };
        let _ = request.reply.send(outcome);
        true
    }

    pub fn reject_all(&self, message: &str) {
        for (_, request) in self.pending.lock().unwrap().drain() {
            let _ = request.reply.send(Err(message.to_string()));
        }
    }
}

fn request_key(id: &Value) -> String {
    match id {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// A request frame, without Synara's optional `jsonrpc` field (`includeJsonRpcVersion` is false
/// for Codex).
pub fn json_rpc_request(id: &Value, method: &str, params: &Value) -> Value {
    json!({ "id": id, "method": method, "params": params })
}

/// Synara `JsonRpcStdioRequestTimeoutError`'s message (jsonrpc-stdio.ts:42).
pub fn request_timeout_message(method: &str) -> String {
    format!("Timed out waiting for {method}.")
}

/// Synara `transportErrorMessage` (codexAppServerTransport.ts:87)
fn transport_error_message(error: &CodexAppServerTransportError) -> String {
    let (max, observed) = (error.max_bytes, error.observed_bytes);
    match error.reason {
        CodexAppServerTransportErrorReason::InvalidUtf8 => {
            format!("Codex app-server emitted invalid UTF-8 ({observed} bytes).")
        }
        CodexAppServerTransportErrorReason::ReadClosed => {
            "Codex app-server stdout closed before process shutdown.".to_string()
        }
        CodexAppServerTransportErrorReason::UnterminatedFrame => format!(
            "Codex app-server stdout ended with an unterminated JSONL frame ({observed}/{max} bytes)."
        ),
        CodexAppServerTransportErrorReason::FrameTooLarge => {
            format!("Codex app-server JSONL frame exceeded its byte limit ({observed}/{max}).")
        }
        CodexAppServerTransportErrorReason::WriteOverloaded => {
            format!("Codex app-server stdin queue exceeded its byte limit ({observed}/{max}).")
        }
        CodexAppServerTransportErrorReason::WriteClosed => {
            "Codex app-server stdin closed before the frame was written.".to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framer_keeps_split_lines_and_utf8() {
        let mut framer = CodexJsonlFramer::new(64);
        let text = "{\"a\":\"é\"}\n{\"b\":1}\r\n";
        let bytes = text.as_bytes();
        let split = 7; // inside the two-byte "é"
        assert!(framer.push(&bytes[..split]).unwrap().is_empty());
        let frames = framer.push(&bytes[split..]).unwrap();
        assert_eq!(frames, vec!["{\"a\":\"é\"}".to_string(), "{\"b\":1}".to_string()]);
        framer.finish().unwrap();
    }

    #[test]
    fn framer_fails_an_oversized_line_and_drops_invalid_utf8() {
        let mut framer = CodexJsonlFramer::new(8);
        let error = framer.push(b"0123456789\n").unwrap_err();
        assert_eq!(error.reason, CodexAppServerTransportErrorReason::FrameTooLarge);

        let mut framer = CodexJsonlFramer::new(64);
        let frames = framer.push(b"\xff\xfe\n{}\n").unwrap();
        assert_eq!(frames, vec!["{}".to_string()]);
    }

    #[test]
    fn framer_reports_an_unterminated_frame_at_the_end() {
        let mut framer = CodexJsonlFramer::new(64);
        framer.push(b"{\"partial\"").unwrap();
        let error = framer.finish().unwrap_err();
        assert_eq!(error.reason, CodexAppServerTransportErrorReason::UnterminatedFrame);
    }

    #[test]
    fn registry_pairs_responses_with_requests() {
        let registry = JsonRpcStdioRequestRegistry::new();
        let mut first = registry.register(&json!(1), "initialize").unwrap();
        let mut second = registry.register(&json!(2), "thread/start").unwrap();
        assert!(registry.register(&json!(1), "again").is_err());
        assert!(registry.handle_response(&json!(1), Some(json!({"ok": true})), None));
        assert!(registry.handle_response(
            &json!(2),
            None,
            Some(JsonRpcError { code: Some(-1), message: Some("nope".into()), data: None })
        ));
        assert!(!registry.handle_response(&json!(3), None, None));
        assert_eq!(first.try_recv().unwrap(), Ok(json!({"ok": true})));
        assert_eq!(second.try_recv().unwrap(), Err("thread/start failed: nope".to_string()));
    }
}
