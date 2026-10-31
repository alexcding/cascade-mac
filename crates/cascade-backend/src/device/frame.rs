//! The helper's frame records: `u32` little-endian length prefixes around a device-frame
//! envelope, and the envelope itself.
//!
//! Port of Synara's `packages/shared/src/deviceFrame.ts`, the envelope codec it wraps
//! (`packages/shared/src/frameTransport.ts` `encodeFrameEnvelope`/`decodeFrameEnvelope`) and
//! `packages/shared/src/lengthPrefixedRecords.ts`.
//!
//! Little-endian envelope layout:
//!
//! ```text
//! 0  u16  magic (DEVICE_FRAME_MAGIC)
//! 2  u8   version (DEVICE_FRAME_VERSION)
//! 3  u8   flags (bit 0 = keyframe, bit 1 = codec config / parameter sets)
//! 4  u32  sequence (per device, wraps at 2^32; gaps mean dropped frames)
//! 8  f64  timestampMs (helper capture clock, milliseconds)
//! 16 u8   deviceId byte length
//! 17 ..   deviceId (UTF-8)
//! ..      payload (H.264 Annex B access unit, or SPS/PPS for a codec-config record)
//! ```

pub const DEVICE_FRAME_MAGIC: u16 = 0x5346;
pub const DEVICE_FRAME_VERSION: u8 = 1;
pub const DEVICE_FRAME_FLAG_KEYFRAME: u8 = 0b0000_0001;
pub const DEVICE_FRAME_FLAG_CODEC_CONFIG: u8 = 0b0000_0010;
/// Bytes before the variable-length device id.
pub const DEVICE_FRAME_HEADER_FIXED_BYTES: usize = 17;
pub const DEVICE_FRAME_MAX_DEVICE_ID_BYTES: usize = 255;

pub const LENGTH_PREFIX_BYTES: usize = 4;
/// Ceiling on one record, past which the stream is treated as desynced.
pub const DEFAULT_MAX_RECORD_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceFrameHeader {
    pub device_id: String,
    pub sequence: u32,
    pub timestamp_ms: f64,
    pub keyframe: bool,
    pub codec_config: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceFrame {
    pub header: DeviceFrameHeader,
    pub payload: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceFrameDecodeError {
    TooShort,
    BadMagic,
    UnsupportedVersion,
    TruncatedDeviceId,
    InvalidDeviceId,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceFrameEncodeError(pub String);

impl std::fmt::Display for DeviceFrameEncodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DeviceFrameEncodeError {}

/// Serializes a device frame into the envelope.
pub fn encode_device_frame(frame: &DeviceFrame) -> Result<Vec<u8>, DeviceFrameEncodeError> {
    let id = frame.header.device_id.as_bytes();
    if id.is_empty() {
        return Err(DeviceFrameEncodeError("Device frame header requires a non-empty deviceId".into()));
    }
    if id.len() > DEVICE_FRAME_MAX_DEVICE_ID_BYTES {
        return Err(DeviceFrameEncodeError(format!(
            "Device frame deviceId exceeds {DEVICE_FRAME_MAX_DEVICE_ID_BYTES} UTF-8 bytes"
        )));
    }
    let mut flags = 0u8;
    if frame.header.keyframe {
        flags |= DEVICE_FRAME_FLAG_KEYFRAME;
    }
    if frame.header.codec_config {
        flags |= DEVICE_FRAME_FLAG_CODEC_CONFIG;
    }
    let mut bytes = Vec::with_capacity(DEVICE_FRAME_HEADER_FIXED_BYTES + id.len() + frame.payload.len());
    bytes.extend_from_slice(&DEVICE_FRAME_MAGIC.to_le_bytes());
    bytes.push(DEVICE_FRAME_VERSION);
    bytes.push(flags);
    bytes.extend_from_slice(&frame.header.sequence.to_le_bytes());
    bytes.extend_from_slice(&frame.header.timestamp_ms.to_le_bytes());
    bytes.push(id.len() as u8);
    bytes.extend_from_slice(id);
    bytes.extend_from_slice(&frame.payload);
    Ok(bytes)
}

/// Parses an envelope. The payload is the rest of `bytes`, borrowed rather than copied.
pub fn decode_device_frame(bytes: &[u8]) -> Result<(DeviceFrameHeader, &[u8]), DeviceFrameDecodeError> {
    if bytes.len() < DEVICE_FRAME_HEADER_FIXED_BYTES {
        return Err(DeviceFrameDecodeError::TooShort);
    }
    if u16::from_le_bytes([bytes[0], bytes[1]]) != DEVICE_FRAME_MAGIC {
        return Err(DeviceFrameDecodeError::BadMagic);
    }
    if bytes[2] != DEVICE_FRAME_VERSION {
        return Err(DeviceFrameDecodeError::UnsupportedVersion);
    }
    let flags = bytes[3];
    let id_length = bytes[16] as usize;
    let payload_offset = DEVICE_FRAME_HEADER_FIXED_BYTES + id_length;
    if id_length == 0 || bytes.len() < payload_offset {
        return Err(DeviceFrameDecodeError::TruncatedDeviceId);
    }
    let device_id = std::str::from_utf8(&bytes[DEVICE_FRAME_HEADER_FIXED_BYTES..payload_offset])
        .map_err(|_| DeviceFrameDecodeError::InvalidDeviceId)?
        .to_owned();
    let header = DeviceFrameHeader {
        device_id,
        sequence: u32::from_le_bytes(bytes[4..8].try_into().expect("four bytes")),
        timestamp_ms: f64::from_le_bytes(bytes[8..16].try_into().expect("eight bytes")),
        keyframe: flags & DEVICE_FRAME_FLAG_KEYFRAME != 0,
        codec_config: flags & DEVICE_FRAME_FLAG_CODEC_CONFIG != 0,
    };
    Ok((header, &bytes[payload_offset..]))
}

/// A record claimed more bytes than the limit: the reader has lost the framing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LengthPrefixedRecordError {
    pub declared_bytes: usize,
    pub max_bytes: usize,
}

impl std::fmt::Display for LengthPrefixedRecordError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Length-prefixed record claims {} bytes, past the {} byte limit",
            self.declared_bytes, self.max_bytes
        )
    }
}

impl std::error::Error for LengthPrefixedRecordError {}

/// Accumulates chunks and yields whole records. A record larger than the limit is an error
/// rather than skipped: the length comes from the same bytes that would have to be trusted to
/// find the next record, so the caller drops the connection.
pub struct LengthPrefixedRecordParser {
    pending: Vec<u8>,
    max_record_bytes: usize,
}

impl Default for LengthPrefixedRecordParser {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_RECORD_BYTES)
    }
}

impl LengthPrefixedRecordParser {
    pub fn new(max_record_bytes: usize) -> Self {
        Self { pending: Vec::new(), max_record_bytes }
    }

    /// Every complete payload now available, in order. Each is a copy, so later chunks cannot
    /// touch a payload already handed out.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<Vec<u8>>, LengthPrefixedRecordError> {
        self.pending.extend_from_slice(chunk);
        let mut payloads = Vec::new();
        let mut offset = 0;
        while self.pending.len() - offset >= LENGTH_PREFIX_BYTES {
            let length =
                u32::from_le_bytes(self.pending[offset..offset + 4].try_into().expect("four bytes")) as usize;
            if length > self.max_record_bytes {
                return Err(LengthPrefixedRecordError { declared_bytes: length, max_bytes: self.max_record_bytes });
            }
            if self.pending.len() - offset < LENGTH_PREFIX_BYTES + length {
                break;
            }
            let start = offset + LENGTH_PREFIX_BYTES;
            payloads.push(self.pending[start..start + length].to_vec());
            offset = start + length;
        }
        self.pending.drain(..offset);
        Ok(payloads)
    }
}

/// Frames a payload the way the helper does.
pub fn encode_length_prefixed_record(payload: &[u8]) -> Vec<u8> {
    let mut record = Vec::with_capacity(LENGTH_PREFIX_BYTES + payload.len());
    record.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    record.extend_from_slice(payload);
    record
}
