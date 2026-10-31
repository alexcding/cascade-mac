//! The helper's frame envelope and its length-prefixed records.
//!
//! Ported from `packages/shared/src/deviceFrame.test.ts` and the frame parts of
//! `apps/server/src/device/helperClient.test.ts`.

use crate::device::frame::{
    decode_device_frame, encode_device_frame, encode_length_prefixed_record, DeviceFrame, DeviceFrameDecodeError,
    DeviceFrameHeader, LengthPrefixedRecordParser, DEVICE_FRAME_HEADER_FIXED_BYTES,
};

const DEVICE: &str = "FAKE-0001";

fn header() -> DeviceFrameHeader {
    DeviceFrameHeader {
        device_id: "A1B2C3D4-1111-2222-3333-444455556666".into(),
        sequence: 42,
        timestamp_ms: 1_234.5,
        keyframe: false,
        codec_config: false,
    }
}

fn payload() -> Vec<u8> {
    vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0xff]
}

fn encoded() -> Vec<u8> {
    encode_device_frame(&DeviceFrame { header: header(), payload: payload() }).unwrap()
}

/// What the helper actually puts on the socket: the contract envelope, wrapped in its own `u32`
/// length prefix.
fn record(sequence: u32, keyframe: bool, payload: &[u8]) -> Vec<u8> {
    let envelope = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader {
            device_id: DEVICE.into(),
            sequence,
            timestamp_ms: 100.0,
            keyframe,
            codec_config: false,
        },
        payload: payload.to_vec(),
    })
    .unwrap();
    encode_length_prefixed_record(&envelope)
}

#[test]
fn round_trips_header_fields_and_payload_bytes() {
    let bytes = encoded();
    let (decoded, body) = decode_device_frame(&bytes).unwrap();
    assert_eq!(decoded, header());
    assert_eq!(body, payload().as_slice());
}

#[test]
fn round_trips_multibyte_device_ids() {
    let unicode_id = "emulator-5554-日本語";
    let bytes = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { device_id: unicode_id.into(), ..header() },
        payload: payload(),
    })
    .unwrap();
    let (decoded, _) = decode_device_frame(&bytes).unwrap();
    assert_eq!(decoded.device_id, unicode_id);
}

#[test]
fn carries_the_keyframe_and_codec_config_flags_independently() {
    let keyframe_only = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { keyframe: true, ..header() },
        payload: payload(),
    })
    .unwrap();
    let (decoded, _) = decode_device_frame(&keyframe_only).unwrap();
    assert!(decoded.keyframe);
    assert!(!decoded.codec_config);

    let both = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { keyframe: true, codec_config: true, ..header() },
        payload: payload(),
    })
    .unwrap();
    let (decoded, _) = decode_device_frame(&both).unwrap();
    assert!(decoded.keyframe);
    assert!(decoded.codec_config);

    let config_only = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { codec_config: true, ..header() },
        payload: payload(),
    })
    .unwrap();
    let (decoded, _) = decode_device_frame(&config_only).unwrap();
    assert!(!decoded.keyframe);
    assert!(decoded.codec_config);
}

#[test]
fn carries_the_largest_sequence_counter_without_corrupting_the_frame() {
    // Synara wraps a JavaScript number past 2^32; the sequence is a `u32` here, so the wrap is
    // the type's own and the edge to prove is the last value before it.
    let bytes = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { sequence: u32::MAX, ..header() },
        payload: payload(),
    })
    .unwrap();
    let (decoded, body) = decode_device_frame(&bytes).unwrap();
    assert_eq!(decoded.sequence, u32::MAX);
    assert_eq!(body, payload().as_slice());
}

#[test]
fn decodes_a_frame_carried_at_a_non_zero_offset_in_a_larger_buffer() {
    let bytes = encoded();
    let mut backing = vec![0u8; 8];
    backing.extend_from_slice(&bytes);

    let (decoded, body) = decode_device_frame(&backing[8..]).unwrap();
    assert_eq!(decoded.device_id, header().device_id);
    assert_eq!(body, payload().as_slice());
}

#[test]
fn rejects_an_empty_or_oversized_device_id_at_encode_time() {
    let empty = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { device_id: String::new(), ..header() },
        payload: payload(),
    });
    assert!(empty.is_err());

    let oversized = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { device_id: "u".repeat(256), ..header() },
        payload: payload(),
    });
    assert!(oversized.is_err());

    let widest = encode_device_frame(&DeviceFrame {
        header: DeviceFrameHeader { device_id: "u".repeat(255), ..header() },
        payload: payload(),
    });
    assert!(widest.is_ok());
}

#[test]
fn rejects_buffers_shorter_than_the_fixed_header() {
    let short = vec![0u8; DEVICE_FRAME_HEADER_FIXED_BYTES - 1];
    assert_eq!(decode_device_frame(&short).unwrap_err(), DeviceFrameDecodeError::TooShort);
}

#[test]
fn rejects_a_device_id_length_that_runs_past_the_buffer() {
    let mut corrupted = encoded();
    corrupted[16] = 255;
    assert_eq!(decode_device_frame(&corrupted).unwrap_err(), DeviceFrameDecodeError::TruncatedDeviceId);
}

#[test]
fn rejects_a_zero_length_device_id() {
    let mut corrupted = encoded();
    corrupted[16] = 0;
    assert_eq!(decode_device_frame(&corrupted).unwrap_err(), DeviceFrameDecodeError::TruncatedDeviceId);
}

#[test]
fn rejects_a_device_id_that_is_not_valid_utf_8() {
    let mut corrupted = encoded();
    corrupted[DEVICE_FRAME_HEADER_FIXED_BYTES] = 0xff;
    assert_eq!(decode_device_frame(&corrupted).unwrap_err(), DeviceFrameDecodeError::InvalidDeviceId);
}

#[test]
fn rejects_a_wrong_magic_or_an_unsupported_version() {
    let mut wrong_magic = encoded();
    wrong_magic[0] ^= 0xff;
    assert_eq!(decode_device_frame(&wrong_magic).unwrap_err(), DeviceFrameDecodeError::BadMagic);

    let mut wrong_version = encoded();
    wrong_version[2] = 9;
    assert_eq!(decode_device_frame(&wrong_version).unwrap_err(), DeviceFrameDecodeError::UnsupportedVersion);
}

// helper frame prefix parser

#[test]
fn unwraps_one_whole_record() {
    let mut parser = LengthPrefixedRecordParser::default();

    let payloads = parser.push(&record(7, true, &[1, 2, 3])).unwrap();

    assert_eq!(payloads.len(), 1);
    // The payload is passed through untouched: it is already the envelope the transport and the
    // browser decode.
    assert!(payloads[0].len() > 17);
}

#[test]
fn reassembles_a_record_split_across_chunks() {
    let mut parser = LengthPrefixedRecordParser::default();
    let bytes = record(1, false, &[4, 5, 6, 7]);

    let first = parser.push(&bytes[..3]).unwrap();
    let second = parser.push(&bytes[3..12]).unwrap();
    let third = parser.push(&bytes[12..]).unwrap();

    assert_eq!(first.len(), 0);
    assert_eq!(second.len(), 0);
    assert_eq!(third.len(), 1);
    assert_eq!(third[0].len(), bytes.len() - 4);
}

#[test]
fn returns_every_record_in_a_chunk_carrying_several() {
    let mut parser = LengthPrefixedRecordParser::default();
    let chunk: Vec<u8> =
        [record(1, false, &[1, 2, 3]), record(2, true, &[1, 2, 3]), record(3, false, &[1, 2, 3])].concat();

    let payloads = parser.push(&chunk).unwrap();

    assert_eq!(payloads.len(), 3);
    let sequences: Vec<u32> = payloads.iter().map(|p| decode_device_frame(p).unwrap().0.sequence).collect();
    assert_eq!(sequences, vec![1, 2, 3]);
}

#[test]
fn copies_payloads_so_a_later_chunk_cannot_mutate_an_emitted_frame() {
    let mut parser = LengthPrefixedRecordParser::default();
    let mut bytes = record(1, false, &[7, 7]);

    let payloads = parser.push(&bytes).unwrap();
    let before = payloads[0].clone();
    bytes.fill(0);
    // A later chunk is accumulated in the parser's own buffer, away from what it handed out.
    parser.push(&record(2, false, &[9, 9])).unwrap();

    assert_eq!(payloads[0], before);
}

#[test]
fn rejects_an_implausible_length_prefix_instead_of_allocating() {
    let mut parser = LengthPrefixedRecordParser::default();
    let mut desynced = vec![0u8; 8];
    desynced[..4].copy_from_slice(&0xffff_ffffu32.to_le_bytes());

    let error = parser.push(&desynced).unwrap_err();
    assert_eq!(error.declared_bytes, 0xffff_ffff);
}

#[test]
fn emits_nothing_for_a_length_prefix_with_no_payload_yet() {
    let mut parser = LengthPrefixedRecordParser::default();
    let prefix_only = 64u32.to_le_bytes();

    assert_eq!(parser.push(&prefix_only).unwrap().len(), 0);
}

// helper frame envelope handling

#[test]
fn yields_an_access_unit_the_transport_can_re_envelope_exactly_once() {
    let access_unit = [0, 0, 0, 1, 0x67, 0x42, 0, 0x33];
    let mut parser = LengthPrefixedRecordParser::default();

    let payloads = parser.push(&record(1, true, &access_unit)).unwrap();
    let helper_record = payloads.first().expect("one record");

    // What the socket handler does before handing the frame to the transport.
    let (decoded_header, decoded_payload) = decode_device_frame(helper_record).unwrap();
    assert_eq!(decoded_payload, access_unit.as_slice());

    // What the transport then puts on the wire, and what the browser decodes.
    let republished = encode_device_frame(&DeviceFrame {
        header: decoded_header,
        payload: decoded_payload.to_vec(),
    })
    .unwrap();
    let (republished_header, republished_payload) = decode_device_frame(&republished).unwrap();
    assert_eq!(republished_payload, access_unit.as_slice());
    assert!(republished_header.keyframe);
}
