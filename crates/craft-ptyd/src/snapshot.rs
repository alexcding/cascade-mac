//! One pull-based, immutable snapshot per connection. Never enqueue a whole
//! snapshot in the socket outbox; each acknowledged read returns at most 128 KiB.
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

pub const CHUNK_BYTES: usize = 128 * 1024;
const TRANSFER_LIFETIME: Duration = Duration::from_secs(60);

pub struct Capture {
    pub bytes: Vec<u8>,
    pub seq: u64,
    pub state_seq: u64,
    pub cols: u16,
    pub rows: u16,
    pub geometry: Option<crate::TerminalGeometry>,
    pub appearance: Option<crate::TerminalAppearance>,
}

struct Transfer {
    token: u64,
    capture: Capture,
    expires: Instant,
}

#[derive(Default)]
pub struct Transfers {
    generation: u64,
    current: Option<Transfer>,
}

impl Transfers {
    pub fn clear(&mut self) {
        self.current = None;
    }

    pub fn begin(&mut self, capture: Capture) -> Result<Value, String> {
        self.clear();
        if capture.bytes.len() > craft_vt::SNAPSHOT_LIMIT {
            return Err("terminal snapshot exceeds its size limit".into());
        }
        self.generation = self
            .generation
            .checked_add(1)
            .ok_or("snapshot token exhausted")?;
        let mut header = json!({
            "token": self.generation, "size": capture.bytes.len(), "chunkBytes": CHUNK_BYTES,
            "seq": capture.seq, "stateSeq": capture.state_seq,
            "cols": capture.cols, "rows": capture.rows,
            "revision": craft_vt::GHOSTTY_REVISION,
        });
        if let Some(geometry) = capture.geometry {
            header["geometry"] = json!(geometry);
        }
        if let Some(appearance) = &capture.appearance { header["appearance"] = json!(appearance); }
        self.current = Some(Transfer {
            token: self.generation,
            capture,
            expires: Instant::now() + TRANSFER_LIFETIME,
        });
        Ok(header)
    }

    pub fn read(&mut self, token: u64, offset: u64) -> Result<Value, String> {
        if self
            .current
            .as_ref()
            .is_some_and(|t| Instant::now() >= t.expires)
        {
            self.clear();
        }
        let transfer = self
            .current
            .as_ref()
            .filter(|t| t.token == token)
            .ok_or("snapshot transfer is missing, replaced or expired")?;
        let offset = usize::try_from(offset).map_err(|_| "invalid snapshot offset")?;
        let bytes = &transfer.capture.bytes;
        if offset >= bytes.len() || offset % CHUNK_BYTES != 0 {
            return Err("invalid snapshot offset".into());
        }
        let end = offset.saturating_add(CHUNK_BYTES).min(bytes.len());
        Ok(
            json!({"token": token, "offset": offset, "bytes": BASE64.encode(&bytes[offset..end]), "done": end == bytes.len()}),
        )
    }

    pub fn end(&mut self, token: u64) -> Result<Value, String> {
        if self.current.as_ref().is_some_and(|t| t.token == token) {
            self.clear();
            Ok(Value::Null)
        } else {
            Err("snapshot transfer is missing or replaced".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn capture(bytes: Vec<u8>) -> Capture {
        Capture {
            bytes,
            seq: 42,
            state_seq: 45,
            cols: 90,
            rows: 30,
            geometry: None,
            appearance: None,
        }
    }

    #[test]
    fn chunks_are_bounded_repeatable_and_owned_by_one_connection() {
        let bytes: Vec<_> = (0..CHUNK_BYTES * 3 + 7).map(|i| (i % 251) as u8).collect();
        let mut owner = Transfers::default();
        let header = owner.begin(capture(bytes.clone())).unwrap();
        let token = header["token"].as_u64().unwrap();
        assert_eq!(header["seq"], 42);
        assert_eq!(header["stateSeq"], 45);
        let mut other = Transfers::default();
        assert!(other.read(token, 0).is_err());
        let mut restored = Vec::new();
        for offset in (0..bytes.len()).step_by(CHUNK_BYTES) {
            let chunk = owner.read(token, offset as u64).unwrap();
            assert_eq!(chunk, owner.read(token, offset as u64).unwrap());
            assert!(serde_json::to_vec(&chunk).unwrap().len() < 200 * 1024);
            restored.extend(BASE64.decode(chunk["bytes"].as_str().unwrap()).unwrap());
        }
        assert_eq!(restored, bytes);
        assert!(owner.read(token, 1).is_err());
        assert!(owner.read(token, u64::MAX).is_err());
        let next = owner.begin(capture(vec![1, 2, 3])).unwrap()["token"]
            .as_u64()
            .unwrap();
        assert_ne!(token, next);
        assert!(owner.read(token, 0).is_err());
        assert!(owner.end(token).is_err()); // a stale release cannot remove the new capture
        assert!(owner.read(next, 0).is_ok());
        owner.end(next).unwrap();
        assert!(owner.read(next, 0).is_err());
    }

    #[test]
    fn expired_transfer_is_released_before_reading() {
        let mut transfers = Transfers::default();
        transfers.begin(capture(vec![1, 2, 3])).unwrap();
        transfers.current.as_mut().unwrap().expires = Instant::now() - Duration::from_secs(1);
        assert!(transfers.read(1, 0).is_err());
        assert!(transfers.current.is_none());
    }
}
