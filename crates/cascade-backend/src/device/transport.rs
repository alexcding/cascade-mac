//! The frame fan-out: every viewer of a device's stream gets its frames, in the helper's own record
//! format, without a slow viewer holding up the others.
//!
//! Port of Synara's `packages/shared/src/frameTransport.ts` (`FrameTransport`) behind its device
//! adapter `apps/server/src/device/deviceFrameTransport.ts`. Synara hands each frame to a
//! WebSocket sink and reads its `bufferedAmount`; here a viewer is a queue a socket writer drains
//! (`frames.rs`), so "the socket has room" is "the queue is empty" and the caps are the queue's.
//!
//! The transport keeps the latest codec config and keyframe per device, so a viewer that arrives
//! mid-stream decodes from its first frame; a viewer that falls behind drops its backlog and waits
//! for the next keyframe rather than receiving deltas it cannot decode.

use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
};

use tokio::sync::Notify;

use super::{
    backend::DeviceStreamFrame,
    frame::{encode_device_frame, encode_length_prefixed_record, DeviceFrame, DeviceFrameHeader},
};

/// Synara `DEVICE_FRAME_QUEUE_LIMIT`.
pub const DEVICE_FRAME_QUEUE_LIMIT: usize = 8;
/// Synara `DEVICE_FRAME_SOCKET_BUDGET_BYTES`.
pub const DEVICE_FRAME_SOCKET_BUDGET_BYTES: usize = 2 * 1024 * 1024;

/// One encoded record: the `u32` little-endian length, then the envelope.
pub type FrameRecord = Arc<[u8]>;

/// What a viewer has been sent and lost; for tests and diagnostics.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ViewerStats {
    pub sent: u64,
    pub dropped: u64,
    pub awaiting_keyframe: bool,
    pub queued: usize,
}

struct Viewer {
    device: String,
    queue: VecDeque<FrameRecord>,
    queued_bytes: usize,
    awaiting_keyframe: bool,
    sent: u64,
    dropped: u64,
    notify: Arc<Notify>,
}

#[derive(Default)]
struct Viewers {
    next_id: u64,
    viewers: HashMap<u64, Viewer>,
    latest_keyframe: HashMap<String, FrameRecord>,
    codec_config: HashMap<String, FrameRecord>,
    closed: bool,
}

/// Bounded, keyframe-aware fan-out of each device's frames to its viewers.
pub struct FrameTransport {
    viewers: Mutex<Viewers>,
    queue_limit: usize,
    budget_bytes: usize,
}

impl Default for FrameTransport {
    fn default() -> Self {
        Self::new(DEVICE_FRAME_QUEUE_LIMIT, DEVICE_FRAME_SOCKET_BUDGET_BYTES)
    }
}

/// A device's frame as its viewers read it: the helper's envelope, re-wrapped with the device the
/// stream belongs to, behind its length.
pub fn encode_frame_record(udid: &str, frame: &DeviceStreamFrame) -> Option<FrameRecord> {
    let envelope = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader {
            device_id: udid.to_owned(),
            sequence: frame.sequence,
            timestamp_ms: frame.timestamp_ms,
            keyframe: frame.keyframe,
            codec_config: frame.codec_config,
        },
        payload: frame.data.to_vec(),
    })
    .ok()?;
    Some(encode_length_prefixed_record(&envelope).into())
}

impl FrameTransport {
    pub fn new(queue_limit: usize, budget_bytes: usize) -> Self {
        Self { viewers: Mutex::new(Viewers::default()), queue_limit: queue_limit.max(1), budget_bytes }
    }

    /// Adds a viewer of `device`, primed with the cached codec config and keyframe so it can
    /// decode from the first frame it is sent.
    pub fn subscribe(&self, device: &str) -> u64 {
        let mut viewers = self.viewers.lock().unwrap();
        viewers.next_id += 1;
        let id = viewers.next_id;
        let config = viewers.codec_config.get(device).cloned();
        let keyframe = viewers.latest_keyframe.get(device).cloned();
        let mut viewer = Viewer {
            device: device.to_owned(),
            queue: VecDeque::new(),
            queued_bytes: 0,
            awaiting_keyframe: true,
            sent: 0,
            dropped: 0,
            notify: Arc::new(Notify::new()),
        };
        if let Some(config) = &config {
            self.deliver(&mut viewer, config.clone(), true, None);
        }
        if let Some(keyframe) = keyframe {
            viewer.awaiting_keyframe = false;
            self.deliver(&mut viewer, keyframe, false, config.as_ref());
        }
        viewers.viewers.insert(id, viewer);
        id
    }

    pub fn unsubscribe(&self, id: u64) {
        if let Some(viewer) = self.viewers.lock().unwrap().viewers.remove(&id) {
            viewer.notify.notify_one();
        }
    }

    pub fn subscriber_count(&self, device: &str) -> usize {
        self.viewers.lock().unwrap().viewers.values().filter(|viewer| viewer.device == device).count()
    }

    /// Whether a keyframe is cached for `device`, which a new viewer is primed with.
    pub fn has_keyframe(&self, device: &str) -> bool {
        self.viewers.lock().unwrap().latest_keyframe.contains_key(device)
    }

    pub fn publish(&self, device: &str, frame: &DeviceStreamFrame) {
        let Some(encoded) = encode_frame_record(device, frame) else { return };
        let mut viewers = self.viewers.lock().unwrap();
        if frame.codec_config {
            viewers.codec_config.insert(device.to_owned(), encoded.clone());
            // The cached keyframe belongs to the previous config and cannot be decoded under this
            // one, so a viewer arriving before the next keyframe must not be primed with it.
            viewers.latest_keyframe.remove(device);
        } else if frame.keyframe {
            viewers.latest_keyframe.insert(device.to_owned(), encoded.clone());
        }
        let config = viewers.codec_config.get(device).cloned();
        for viewer in viewers.viewers.values_mut().filter(|viewer| viewer.device == device) {
            if frame.codec_config {
                viewer.awaiting_keyframe = true;
                self.deliver(viewer, encoded.clone(), true, None);
                continue;
            }
            if viewer.awaiting_keyframe {
                if !frame.keyframe {
                    viewer.dropped += 1;
                    continue;
                }
                viewer.awaiting_keyframe = false;
            }
            self.deliver(viewer, encoded.clone(), false, config.as_ref());
        }
    }

    /// Forgets what was cached for `device` and makes its viewers wait for a fresh keyframe: the
    /// stream is being rebuilt, and nothing from the old one decodes under the new.
    pub fn reset(&self, device: &str) {
        let mut viewers = self.viewers.lock().unwrap();
        viewers.latest_keyframe.remove(device);
        viewers.codec_config.remove(device);
        for viewer in viewers.viewers.values_mut().filter(|viewer| viewer.device == device) {
            viewer.queue.clear();
            viewer.queued_bytes = 0;
            viewer.awaiting_keyframe = true;
        }
    }

    pub fn stats_for(&self, device: &str) -> Vec<ViewerStats> {
        self.viewers
            .lock()
            .unwrap()
            .viewers
            .values()
            .filter(|viewer| viewer.device == device)
            .map(|viewer| ViewerStats {
                sent: viewer.sent,
                dropped: viewer.dropped,
                awaiting_keyframe: viewer.awaiting_keyframe,
                queued: viewer.queue.len(),
            })
            .collect()
    }

    /// The next record for a viewer to write, waiting for one; none once the viewer is gone.
    pub async fn next(&self, id: u64) -> Option<FrameRecord> {
        loop {
            let notify = {
                let mut viewers = self.viewers.lock().unwrap();
                if viewers.closed {
                    return None;
                }
                let viewer = viewers.viewers.get_mut(&id)?;
                if let Some(record) = viewer.queue.pop_front() {
                    viewer.queued_bytes -= record.len();
                    viewer.sent += 1;
                    return Some(record);
                }
                viewer.notify.clone()
            };
            notify.notified().await;
        }
    }

    /// Ends every viewer: their writers see no next record and close.
    pub fn close(&self) {
        let mut viewers = self.viewers.lock().unwrap();
        viewers.closed = true;
        for (_, viewer) in viewers.viewers.drain() {
            viewer.notify.notify_one();
        }
        viewers.latest_keyframe.clear();
        viewers.codec_config.clear();
    }

    /// Synara `deliver`: straight through when the viewer keeps up, otherwise queued within the
    /// caps. Codec config is never dropped (nothing decodes without it), but a stalled viewer keeps
    /// one, the latest, in place of its backlog.
    fn deliver(&self, viewer: &mut Viewer, encoded: FrameRecord, essential: bool, config: Option<&FrameRecord>) {
        if viewer.queue.is_empty() {
            viewer.queued_bytes = encoded.len();
            viewer.queue.push_back(encoded);
            viewer.notify.notify_one();
            return;
        }
        if essential {
            // A new config makes the queued frames moot: they belong to the old config.
            viewer.dropped += viewer.queue.len() as u64;
            viewer.queue.clear();
            viewer.queued_bytes = encoded.len();
            viewer.queue.push_back(encoded);
            viewer.awaiting_keyframe = true;
            viewer.notify.notify_one();
            return;
        }
        // Bounded in count and in bytes: whichever ceiling trips first drops the backlog.
        if viewer.queue.len() >= self.queue_limit || viewer.queued_bytes + encoded.len() > self.budget_bytes {
            viewer.dropped += viewer.queue.len() as u64 + 1;
            viewer.queue.clear();
            viewer.queued_bytes = 0;
            if let Some(config) = config {
                viewer.queued_bytes = config.len();
                viewer.queue.push_back(config.clone());
            }
            viewer.awaiting_keyframe = true;
            viewer.notify.notify_one();
            return;
        }
        viewer.queued_bytes += encoded.len();
        viewer.queue.push_back(encoded);
        viewer.notify.notify_one();
    }
}
