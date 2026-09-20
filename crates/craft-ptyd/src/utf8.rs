// JSON output is UTF-8. Retain incomplete codepoints across reads, but replace
// invalid byte sequences instead of retaining them forever and stalling output.
pub(crate) fn take_text(pending: &mut Vec<u8>, eof: bool) -> String {
    let mut text = String::new();
    let mut consumed = 0;
    while consumed < pending.len() {
        match std::str::from_utf8(&pending[consumed..]) {
            Ok(valid) => {
                text.push_str(valid);
                consumed = pending.len();
            }
            Err(error) => {
                let end = consumed + error.valid_up_to();
                text.push_str(std::str::from_utf8(&pending[consumed..end]).unwrap());
                consumed = end;
                match error.error_len() {
                    Some(length) => { text.push('\u{fffd}'); consumed += length; }
                    None if eof => { text.push('\u{fffd}'); consumed = pending.len(); }
                    None => break,
                }
            }
        }
    }
    pending.drain(..consumed);
    text
}

#[cfg(test)]
mod tests {
    use super::take_text;

    #[test]
    fn preserves_codepoints_split_at_every_byte() {
        let mut pending = Vec::new();
        let mut text = String::new();
        for byte in "hello é 日本語 🦀\x1b[31m".as_bytes() {
            pending.push(*byte);
            text.push_str(&take_text(&mut pending, false));
        }
        assert_eq!(text, "hello é 日本語 🦀\x1b[31m");
        assert!(pending.is_empty());
    }

    #[test]
    fn invalid_bytes_do_not_stall_later_output() {
        let mut pending = vec![0xff, b'a', 0xc3, b'b', b'\n'];
        assert_eq!(take_text(&mut pending, false), "\u{fffd}a\u{fffd}b\n");
        assert!(pending.is_empty());
    }

    #[test]
    fn flushes_incomplete_final_codepoint_on_eof() {
        let mut pending = vec![b'a', 0xe2, 0x82];
        assert_eq!(take_text(&mut pending, false), "a");
        assert_eq!(take_text(&mut pending, true), "\u{fffd}");
        assert!(pending.is_empty());
    }
}
