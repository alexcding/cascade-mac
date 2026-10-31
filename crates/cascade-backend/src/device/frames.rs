//! The pane's frame socket: a Unix socket per device that hands every connected viewer the
//! device's video, as the helper's own records (`u32` little-endian length, then the frame
//! envelope, H.264 Annex B inside).
//!
//! Synara's counterpart is the `/ws/device-frames` WebSocket route (`deviceFrameRoute.ts`). The
//! native pane reads a socket instead: the backend runs in the app's process, and a socket keeps
//! video off the JSON request path. As in Synara, a viewer is primed with the latest codec config
//! and keyframe, every viewer counts toward the stream's subscribers, and the one message a viewer
//! may send is a resync request, a line of `{"type":"device.frame.resync"}`, which rebuilds the
//! stream so a decoder that lost sync gets a fresh keyframe.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::Mutex,
};

use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    task::JoinHandle,
};

use super::manager::DeviceManager;

/// Synara `DEVICE_FRAME_RESYNC_MESSAGE`.
pub const RESYNC_MESSAGE: &str = "device.frame.resync";
/// A resync request is a few dozen bytes; a longer line is not one.
const MAX_CLIENT_MESSAGE_BYTES: usize = 1_024;

/// The sockets the backend serves, one per device asked for.
#[derive(Default)]
pub struct FrameSockets {
    inner: Mutex<Sockets>,
}

#[derive(Default)]
struct Sockets {
    /// `$TMPDIR/cascade-device-pane-<8 hex>/`, made on first use, the user's alone.
    root: Option<PathBuf>,
    listeners: HashMap<String, (PathBuf, JoinHandle<()>)>,
    next: u64,
    closed: bool,
}

/// Whether a line a viewer sent is a resync request (Synara `decodeFrameResyncRequest`).
pub fn is_resync_request(line: &str) -> bool {
    if line.len() > MAX_CLIENT_MESSAGE_BYTES {
        return false;
    }
    serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .is_some_and(|message| message.get("type").and_then(serde_json::Value::as_str) == Some(RESYNC_MESSAGE))
}

impl FrameSockets {
    /// The socket that streams `udid`, made the first time it is asked for. Sockets are named by a
    /// number, not the udid: a socket path has to fit in 104 bytes.
    pub fn socket_for(&self, manager: &DeviceManager, udid: &str) -> std::io::Result<PathBuf> {
        let mut sockets = self.inner.lock().unwrap();
        if sockets.closed {
            return Err(std::io::Error::other("the device manager has stopped"));
        }
        // `$TMPDIR` is cleaned behind running processes: a folder that is gone takes every socket in
        // it, so they are all made again in a new one.
        if sockets.root.as_ref().is_some_and(|root| !root.is_dir()) {
            sockets.root = None;
            for (_, (_, task)) in sockets.listeners.drain() {
                task.abort();
            }
        }
        if let Some((path, task)) = sockets.listeners.get(udid) {
            if path.exists() && !task.is_finished() {
                return Ok(path.clone());
            }
        }
        if let Some((path, task)) = sockets.listeners.remove(udid) {
            task.abort();
            let _ = std::fs::remove_file(path);
        }
        let root = match &sockets.root {
            Some(root) => root.clone(),
            None => {
                let root = make_root()?;
                sockets.root = Some(root.clone());
                root
            }
        };
        sockets.next += 1;
        let path = root.join(format!("{}.sock", sockets.next));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path)?;
        let task = tokio::spawn(accept(listener, manager.clone(), udid.to_owned()));
        sockets.listeners.insert(udid.to_owned(), (path.clone(), task));
        Ok(path)
    }

    /// Stops listening and removes the sockets; viewers end when the manager's transport closes.
    pub fn close(&self) {
        let mut sockets = self.inner.lock().unwrap();
        sockets.closed = true;
        for (_, (path, task)) in sockets.listeners.drain() {
            task.abort();
            let _ = std::fs::remove_file(path);
        }
        if let Some(root) = sockets.root.take() {
            let _ = std::fs::remove_dir_all(root);
        }
    }
}

fn make_root() -> std::io::Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    let suffix: String = uuid::Uuid::new_v4().simple().to_string().chars().take(8).collect();
    let root = std::env::temp_dir().join(format!("cascade-device-pane-{suffix}"));
    std::fs::DirBuilder::new().mode(0o700).create(&root)?;
    Ok(root)
}

async fn accept(listener: UnixListener, manager: DeviceManager, udid: String) {
    loop {
        let Ok((stream, _)) = listener.accept().await else { return };
        tokio::spawn(serve_viewer(stream, manager.clone(), udid.clone()));
    }
}

/// One viewer: subscribed for as long as it stays connected.
pub async fn serve_viewer(stream: UnixStream, manager: DeviceManager, udid: String) {
    let subscription = manager.subscribe_frames(&udid).await;
    let id = subscription.id();
    // An idle screen emits no frames, so a viewer joining a running stream with no keyframe cached
    // would wait for the next screen change: rebuild the stream for it instead.
    if manager.is_streaming(&udid).await && !manager.transport().has_keyframe(&udid) {
        let (manager, udid) = (manager.clone(), udid.clone());
        tokio::spawn(async move {
            let _ = manager.request_keyframe(&udid).await;
        });
    }
    let (read, mut write) = stream.into_split();
    let requests = async {
        let mut reader = BufReader::new(read);
        let mut line = Vec::new();
        loop {
            line.clear();
            // Read at most one message past the cap, so a client that never sends a newline cannot
            // make the backend buffer without end; such a client is dropped.
            let mut limited = (&mut reader).take(MAX_CLIENT_MESSAGE_BYTES as u64 + 1);
            match limited.read_until(b'\n', &mut line).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
            if !line.ends_with(b"\n") && line.len() > MAX_CLIENT_MESSAGE_BYTES {
                return;
            }
            if is_resync_request(String::from_utf8_lossy(&line).trim()) {
                let (manager, udid) = (manager.clone(), udid.clone());
                tokio::spawn(async move {
                    let _ = manager.request_keyframe(&udid).await;
                });
            }
        }
    };
    let frames = async {
        while let Some(record) = manager.transport().next(id).await {
            if write.write_all(&record).await.is_err() {
                return;
            }
        }
    };
    tokio::select! {
        () = requests => {}
        () = frames => {}
    }
    drop(subscription);
}
