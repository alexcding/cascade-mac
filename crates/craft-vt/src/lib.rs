//! Owned, exclusively accessed headless Ghostty state for daemon snapshots.
//! The renderer and daemon share the pinned runtime and Craft snapshot format.
//! Snapshot v3 retains glyph registrations, Kitty images, placements and transfers.
use std::{ffi::c_void, fmt, ptr::NonNull};

pub const GHOSTTY_REVISION: &str = "82938b633ba646db38591d969c3c526332bd7e65-taskhub-appearance-v3";
pub const SNAPSHOT_LIMIT: usize = 192 * 1024 * 1024;
pub const RESPONSE_LIMIT: usize = 256 * 1024;
/// Fixed ownership contract; extending this set requires a new version.
pub const STATE_RESPONSE_OWNER: &str = "daemon-state-v1";
pub const IDENTITY_RESPONSE_OWNER: &str = "daemon-identity-v1";
/// Identity/state replies, pixel geometry, Kitty graphics and glyph replies.
/// The daemon/native handshake must opt into this separately before using it.
pub const GEOMETRY_RESPONSE_OWNER: &str = "daemon-geometry-graphics-v2";
/// Configured native defaults and color-scheme responses, ordered with PTY output.
pub const APPEARANCE_RESPONSE_OWNER: &str = "daemon-appearance-v1";
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Appearance([u32; 260]);
impl Appearance {
    pub fn from_values(values: &[u32]) -> Result<Self, Error> {
        let values: [u32; 260] = values.try_into().map_err(|_| Error("Invalid terminal appearance length"))?;
        if values[..258].iter().any(|v| *v > 0xFFFFFF)
            || (values[258] > 0xFFFFFF && values[258] != u32::MAX) || values[259] > 1 {
            return Err(Error("Invalid terminal appearance colors"));
        }
        Ok(Self(values))
    }
}
type Writer = unsafe extern "C" fn(*mut c_void, *const u8, usize) -> bool;

extern "C" {
    fn craft_vt_new(cols: u16, rows: u16) -> *mut c_void;
    fn craft_vt_free(terminal: *mut c_void);
    fn craft_vt_feed(terminal: *mut c_void, bytes: *const u8, len: usize);
    fn craft_vt_feed_with_responses(
        terminal: *mut c_void,
        bytes: *const u8,
        len: usize,
        write: Writer,
        userdata: *mut c_void,
        version: *const u8,
        version_len: usize,
        geometry: bool,
        color_scheme: i32,
    ) -> i32;
    fn craft_vt_set_appearance(terminal: *mut c_void, values: *const u32, notify: bool, write: Writer, userdata: *mut c_void) -> i32;
    fn craft_vt_resize(terminal: *mut c_void, cols: u16, rows: u16) -> i32;
    fn craft_vt_resize_geometry(
        terminal: *mut c_void,
        cols: u16,
        rows: u16,
        cell_width: u32,
        cell_height: u32,
        write: Writer,
        userdata: *mut c_void,
    ) -> i32;
    fn craft_vt_geometry(
        terminal: *mut c_void,
        cols: *mut u16,
        rows: *mut u16,
        cell_width: *mut u32,
        cell_height: *mut u32,
    ) -> i32;
    fn craft_vt_snapshot(terminal: *mut c_void, write: Writer, userdata: *mut c_void) -> i32;
    fn craft_vt_restore(bytes: *const u8, len: usize) -> *mut c_void;
    fn craft_vt_format(terminal: *mut c_void, write: Writer, userdata: *mut c_void) -> i32;
    fn craft_vt_cursor(terminal: *mut c_void, x: *mut u16, y: *mut u16) -> i32;
    fn craft_vt_mode(terminal: *mut c_void, number: u16, ansi: bool, value: *mut bool) -> i32;
}

#[derive(Debug)]
pub struct Error(&'static str);
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Geometry {
    pub cols: u16,
    pub rows: u16,
    pub cell_width: u32,
    pub cell_height: u32,
}
impl Geometry {
    fn validate(self) -> Result<(), Error> {
        if self.cols == 0
            || self.rows == 0
            || self.cell_width == 0
            || self.cell_height == 0
            || self.cell_width.checked_mul(u32::from(self.cols)).is_none()
            || self.cell_height.checked_mul(u32::from(self.rows)).is_none()
        {
            Err(Error("Invalid or overflowing terminal geometry"))
        } else {
            Ok(())
        }
    }
}

pub struct Terminal(NonNull<c_void>);
// Ghostty requires exclusive access, but not thread affinity. No method exposes
// its pointer; every operation requires &mut self, and Terminal is not Sync.
unsafe impl Send for Terminal {}

impl Terminal {
    pub fn new(cols: u16, rows: u16) -> Result<Self, Error> {
        if cols == 0 || rows == 0 {
            return Err(Error("Terminal dimensions must be nonzero"));
        }
        NonNull::new(unsafe { craft_vt_new(cols, rows) })
            .map(Self)
            .ok_or(Error("Could not create Ghostty terminal"))
    }
    pub fn feed(&mut self, bytes: &[u8]) {
        unsafe { craft_vt_feed(self.0.as_ptr(), bytes.as_ptr(), bytes.len()) }
    }
    /// Parse once and collect Ghostty's synchronous terminal protocol responses.
    /// This does not write to a PTY or grant access to host clipboard/UI effects.
    /// An error can occur after input was consumed; retrying it is not safe.
    pub fn feed_with_responses(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Error> {
        self.collect_responses(bytes, write_response, None, false, None)
    }
    /// Collect only daemon-state-v1 replies: DSR status/cursor, DECRQM,
    /// DECRQSS, and Kitty keyboard flags. UI/config-dependent replies remain
    /// renderer-owned. Filtering complete runtime effect packets avoids a
    /// second VT request parser and preserves split-sequence handling.
    pub fn feed_state_responses(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Error> {
        self.collect_responses(bytes, write_state_response, None, false, None)
    }
    /// State replies plus native DA1/DA2, XTVERSION and XTGETTCAP. The profile
    /// must match the shell's TERM/terminfo and default native clipboard policy.
    /// `version` is the full printable product/version string fixed at creation.
    pub fn feed_identity_responses(
        &mut self,
        bytes: &[u8],
        version: &str,
    ) -> Result<Vec<u8>, Error> {
        validate_version(version)?;
        self.collect_responses(bytes, write_identity_response, Some(version), false, None)
    }
    /// Identity/state replies plus sizes from the parser's current geometry.
    /// Requires complete cell pixels, set before output is parsed. Title and
    /// other host effects remain excluded. As with other feeds, do not retry
    /// consumed bytes on failure.
    pub fn feed_geometry_responses(
        &mut self,
        bytes: &[u8],
        version: &str,
    ) -> Result<Vec<u8>, Error> {
        validate_version(version)?;
        self.geometry()?;
        self.collect_responses(bytes, write_geometry_response, Some(version), true, None)
    }
    pub fn feed_appearance_responses(&mut self, bytes: &[u8], version: &str, appearance: &Appearance) -> Result<Vec<u8>, Error> {
        validate_version(version)?;
        self.geometry()?;
        self.collect_responses(bytes, write_appearance_response, Some(version), true, Some(appearance.0[259]))
    }
    pub fn set_appearance(&mut self, appearance: &Appearance, notify: bool) -> Result<Vec<u8>, Error> {
        let mut responses = Vec::new();
        check(unsafe { craft_vt_set_appearance(self.0.as_ptr(), appearance.0.as_ptr(), notify,
            write_appearance_response, (&mut responses as *mut Vec<u8>).cast()) }, "Could not apply terminal appearance")?;
        Ok(responses)
    }
    fn collect_responses(
        &mut self,
        bytes: &[u8],
        writer: Writer,
        version: Option<&str>,
        geometry: bool,
        color_scheme: Option<u32>,
    ) -> Result<Vec<u8>, Error> {
        let mut responses = Vec::new();
        check(
            unsafe {
                craft_vt_feed_with_responses(
                    self.0.as_ptr(),
                    bytes.as_ptr(),
                    bytes.len(),
                    writer,
                    (&mut responses as *mut Vec<u8>).cast(),
                    version.map_or(std::ptr::null(), str::as_ptr),
                    version.map_or(0, str::len),
                    geometry,
                    color_scheme.map_or(-1, |value| value as i32),
                )
            },
            "Could not collect complete terminal protocol responses",
        )?;
        Ok(responses)
    }
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), Error> {
        check(
            unsafe { craft_vt_resize(self.0.as_ptr(), cols, rows) },
            "Could not resize Ghostty terminal",
        )
    }
    /// Apply cell and pixel geometry and collect a single mode 2048 report
    /// when enabled. Equal geometry is a no-op; pixel-only changes are not.
    /// A runtime failure may occur after the resize was applied.
    pub fn resize_geometry(&mut self, geometry: Geometry) -> Result<Vec<u8>, Error> {
        geometry.validate()?;
        let mut responses = Vec::new();
        check(
            unsafe {
                craft_vt_resize_geometry(
                    self.0.as_ptr(),
                    geometry.cols,
                    geometry.rows,
                    geometry.cell_width,
                    geometry.cell_height,
                    write_geometry_response,
                    (&mut responses as *mut Vec<u8>).cast(),
                )
            },
            "Could not apply terminal geometry or collect its size report",
        )?;
        Ok(responses)
    }
    /// Exact metrics retained in the snapshot. Legacy zero-pixel terminals
    /// have no reportable geometry and return an error.
    pub fn geometry(&mut self) -> Result<Geometry, Error> {
        let mut geometry = Geometry {
            cols: 0,
            rows: 0,
            cell_width: 0,
            cell_height: 0,
        };
        check(
            unsafe {
                craft_vt_geometry(
                    self.0.as_ptr(),
                    &mut geometry.cols,
                    &mut geometry.rows,
                    &mut geometry.cell_width,
                    &mut geometry.cell_height,
                )
            },
            "Terminal cell pixel geometry is unavailable",
        )?;
        geometry.validate()?;
        Ok(geometry)
    }
    pub fn snapshot(&mut self) -> Result<Vec<u8>, Error> {
        self.collect(
            craft_vt_snapshot,
            "Could not encode complete terminal snapshot",
        )
    }
    pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > SNAPSHOT_LIMIT {
            return Err(Error("Terminal snapshot exceeds its size limit"));
        }
        NonNull::new(unsafe { craft_vt_restore(bytes.as_ptr(), bytes.len()) })
            .map(Self)
            .ok_or(Error("Invalid or incomplete terminal snapshot"))
    }
    /// Diagnostic formatting, never used as a state-restoration format.
    pub fn formatted(&mut self) -> Result<Vec<u8>, Error> {
        self.collect(craft_vt_format, "Could not format terminal state")
    }
    pub fn cursor(&mut self) -> Result<(u16, u16), Error> {
        let (mut x, mut y) = (0, 0);
        check(
            unsafe { craft_vt_cursor(self.0.as_ptr(), &mut x, &mut y) },
            "Could not read terminal cursor",
        )?;
        Ok((x, y))
    }
    pub fn mode(&mut self, number: u16, ansi: bool) -> Result<bool, Error> {
        let mut value = false;
        check(
            unsafe { craft_vt_mode(self.0.as_ptr(), number, ansi, &mut value) },
            "Could not read terminal mode",
        )?;
        Ok(value)
    }
    fn collect(
        &mut self,
        action: unsafe extern "C" fn(*mut c_void, Writer, *mut c_void) -> i32,
        message: &'static str,
    ) -> Result<Vec<u8>, Error> {
        let mut bytes: Vec<u8> = Vec::new();
        // The C writer is synchronous and never retains userdata or the slice.
        check(
            unsafe { action(self.0.as_ptr(), write, (&mut bytes as *mut Vec<u8>).cast()) },
            message,
        )?;
        Ok(bytes)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe { craft_vt_free(self.0.as_ptr()) }
    }
}
fn check(result: i32, message: &'static str) -> Result<(), Error> {
    if result == 0 {
        Ok(())
    } else {
        Err(Error(message))
    }
}
fn validate_version(version: &str) -> Result<(), Error> {
    if version.is_empty()
        || version.len() > 256
        || !version.bytes().all(|b| (0x20..=0x7e).contains(&b))
    {
        Err(Error("Invalid terminal identity version"))
    } else {
        Ok(())
    }
}
unsafe extern "C" fn write(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    append_bounded(userdata, data, len, SNAPSHOT_LIMIT)
}
unsafe extern "C" fn write_response(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    append_bounded(userdata, data, len, RESPONSE_LIMIT)
}
// WRITE_PTY supplies a complete response per callback at the pinned revision.
// Only accept the explicitly owned packet classes; OSC clipboard/color, APC
// graphics, DA/version/terminfo, title, visibility, and geometry stay native.
fn numbers(bytes: &[u8], count: usize) -> bool {
    let mut fields = bytes.split(|b| *b == b';');
    (0..count).all(|_| {
        fields
            .next()
            .is_some_and(|part| !part.is_empty() && part.iter().all(u8::is_ascii_digit))
    }) && fields.next().is_none()
}
fn is_state_response(bytes: &[u8]) -> bool {
    if bytes == b"\x1b[0n" {
        return true;
    }
    if let Some(csi) = bytes.strip_prefix(b"\x1b[") {
        if let Some(body) = csi.strip_suffix(b"R") {
            return numbers(body, 2);
        }
        if let Some(body) = csi.strip_suffix(b"$y") {
            // Paste-event support depends on the renderer's clipboard effect.
            if body.starts_with(b"?5522;") {
                return false;
            }
            return numbers(body.strip_prefix(b"?").unwrap_or(body), 2);
        }
        if let Some(body) = csi.strip_prefix(b"?").and_then(|b| b.strip_suffix(b"u")) {
            return numbers(body, 1);
        }
    }
    (bytes.starts_with(b"\x1bP0$r") || bytes.starts_with(b"\x1bP1$r")) && bytes.ends_with(b"\x1b\\")
}
unsafe extern "C" fn write_state_response(
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) -> bool {
    if len == 0 {
        return true;
    }
    if !is_state_response(std::slice::from_raw_parts(data, len)) {
        return true;
    }
    append_bounded(userdata, data, len, RESPONSE_LIMIT)
}
unsafe extern "C" fn write_identity_response(
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) -> bool {
    if len == 0 {
        return true;
    }
    let bytes = std::slice::from_raw_parts(data, len);
    // DA3 remains silent, matching the native implementation. Clipboard,
    // geometry, colors, visibility and graphics are still UI-owned.
    if !is_identity_response(bytes) && !is_state_response(bytes) {
        return true;
    }
    append_bounded(userdata, data, len, RESPONSE_LIMIT)
}
fn is_identity_response(bytes: &[u8]) -> bool {
    bytes == b"\x1b[?62;22;52c"
        || bytes == b"\x1b[>1;10;0c"
        || ((bytes.starts_with(b"\x1bP>|") || bytes.starts_with(b"\x1bP1+r"))
            && bytes.ends_with(b"\x1b\\"))
}
fn is_graphics_response(bytes: &[u8]) -> bool {
    (bytes.starts_with(b"\x1b_G") || bytes.starts_with(b"\x1b_25a1;"))
        && bytes.ends_with(b"\x1b\\")
}
fn is_geometry_response(bytes: &[u8]) -> bool {
    let Some(body) = bytes
        .strip_prefix(b"\x1b[")
        .and_then(|b| b.strip_suffix(b"t"))
    else {
        return false;
    };
    if let Some(size) = body.strip_prefix(b"48;") {
        return numbers(size, 4);
    }
    [b"4;".as_slice(), b"6;", b"8;"].iter().any(|prefix| {
        body.strip_prefix(*prefix)
            .is_some_and(|size| numbers(size, 2))
    })
}
unsafe extern "C" fn write_geometry_response(
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) -> bool {
    if len == 0 {
        return true;
    }
    let bytes = std::slice::from_raw_parts(data, len);
    if !is_state_response(bytes) && !is_identity_response(bytes) && !is_geometry_response(bytes) && !is_graphics_response(bytes) {
        return true;
    }
    append_bounded(userdata, data, len, RESPONSE_LIMIT)
}
fn is_color_response(mut bytes: &[u8]) -> bool {
    if bytes == b"\x1b[?997;1n" || bytes == b"\x1b[?997;2n" { return true; }
    if bytes.is_empty() { return false; }
    // Ghostty batches several OSC color queries in one effect. Consume complete
    // OSC packets, never forward title or clipboard packets through this owner.
    while !bytes.is_empty() {
        let Some(body) = bytes.strip_prefix(b"\x1b]") else { return false; };
        if ![b"4;".as_slice(), b"10;", b"11;", b"12;", b"21;"].iter().any(|p| body.starts_with(p)) { return false; }
        let Some(end) = body.iter().position(|v| *v == 7 || *v == 27) else { return false; };
        let terminator = if body[end] == 7 { 1 } else if body.get(end + 1) == Some(&b'\\') { 2 } else { return false; };
        bytes = &body[end + terminator..];
    }
    true
}
unsafe extern "C" fn write_appearance_response(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    if len == 0 { return true; }
    let bytes = std::slice::from_raw_parts(data, len);
    if !is_state_response(bytes) && !is_identity_response(bytes) && !is_geometry_response(bytes)
        && !is_graphics_response(bytes) && !is_color_response(bytes) { return true; }
    append_bounded(userdata, data, len, RESPONSE_LIMIT)
}
unsafe fn append_bounded(userdata: *mut c_void, data: *const u8, len: usize, limit: usize) -> bool {
    if len == 0 {
        return true;
    }
    let bytes = &mut *userdata.cast::<Vec<u8>>();
    if len > limit.saturating_sub(bytes.len()) || bytes.try_reserve(len).is_err() {
        return false;
    }
    bytes.extend_from_slice(std::slice::from_raw_parts(data, len));
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn geometry_queries_and_pixel_only_resizes_survive_snapshots_and_reset() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        let geometry = Geometry {
            cols: 80,
            rows: 24,
            cell_width: 9,
            cell_height: 18,
        };
        assert!(terminal.resize_geometry(geometry).unwrap().is_empty());
        let query = b"\x1b[14t\x1b[16t\x1b[18t";
        let expected = b"\x1b[4;432;720t\x1b[6;18;9t\x1b[8;24;80t";
        assert_eq!(
            terminal
                .feed_geometry_responses(query, "ghostty test")
                .unwrap(),
            expected
        );
        assert_eq!(
            terminal
                .feed_geometry_responses(b"\x1b[?2048h", "ghostty test")
                .unwrap(),
            b"\x1b[48;24;80;432;720t"
        );
        // An acknowledgement/reconnect with unchanged measurements must not
        // generate another resize notification or disturb parser state.
        assert!(terminal.resize_geometry(geometry).unwrap().is_empty());
        terminal.feed(b"\x1b[16");
        let mut restored = Terminal::restore(&terminal.snapshot().unwrap()).unwrap();
        assert_eq!(restored.geometry().unwrap(), geometry);
        assert!(restored.mode(2048, false).unwrap());
        assert_eq!(
            restored
                .feed_geometry_responses(b"t", "ghostty test")
                .unwrap(),
            b"\x1b[6;18;9t"
        );
        let retina = Geometry {
            cell_width: 18,
            cell_height: 36,
            ..geometry
        };
        assert_eq!(
            restored.resize_geometry(retina).unwrap(),
            b"\x1b[48;24;80;864;1440t"
        );
        assert_eq!(restored.geometry().unwrap(), retina);
        assert!(restored.resize_geometry(retina).unwrap().is_empty());
        let bigger = Geometry {
            cols: 100,
            rows: 30,
            ..retina
        };
        assert_eq!(
            restored.resize_geometry(bigger).unwrap(),
            b"\x1b[48;30;100;1080;1800t"
        );
        assert_eq!(
            restored
                .feed_geometry_responses(query, "ghostty test")
                .unwrap(),
            b"\x1b[4;1080;1800t\x1b[6;36;18t\x1b[8;30;100t"
        );
        assert!(restored
            .feed_geometry_responses(b"\x1b[?2048l", "ghostty test")
            .unwrap()
            .is_empty());
        assert!(restored.resize_geometry(geometry).unwrap().is_empty());
        assert_eq!(
            restored
                .feed_geometry_responses(b"\x1bc\x1b[14t\x1b[16t\x1b[18t", "ghostty test")
                .unwrap(),
            expected
        );
        assert!(!restored.mode(2048, false).unwrap());
    }

    #[test]
    fn geometry_is_explicit_bounded_and_does_not_take_other_host_responses() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        assert!(terminal.geometry().is_err());
        assert!(terminal
            .feed_geometry_responses(b"NOT_PARSED", "ghostty test")
            .is_err());
        let geometry = Geometry {
            cols: 80,
            rows: 24,
            cell_width: 9,
            cell_height: 18,
        };
        terminal.resize_geometry(geometry).unwrap();
        for invalid in [
            Geometry {
                cols: 0,
                ..geometry
            },
            Geometry {
                rows: 0,
                ..geometry
            },
            Geometry {
                cell_width: 0,
                ..geometry
            },
            Geometry {
                cell_height: 0,
                ..geometry
            },
            Geometry {
                cell_width: u32::MAX,
                ..geometry
            },
            Geometry {
                cell_height: u32::MAX,
                ..geometry
            },
        ] {
            assert!(terminal.resize_geometry(invalid).is_err());
            assert_eq!(terminal.geometry().unwrap(), geometry);
        }
        assert!(terminal
            .feed_geometry_responses(b"NOT_PARSED", "bad\x1bversion")
            .is_err());
        assert_eq!(terminal.cursor().unwrap(), (0, 0));
        let mixed = b"\x1b[6n\x1b[>q\x1b[18t\x1b[21t\x1b[?5522$p\x1b]52;c;?\x07\x1b[?996n";
        assert_eq!(
            terminal
                .feed_geometry_responses(mixed, "ghostty test")
                .unwrap(),
            b"\x1b[1;1R\x1bP>|ghostty test\x1b\\\x1b[8;24;80t"
        );
        // Callbacks must be cleared after success and after collector overflow.
        assert!(terminal
            .feed_identity_responses(b"\x1b[18t", "ghostty test")
            .unwrap()
            .is_empty());
        let mut flood = b"\x1b[16t".repeat(RESPONSE_LIMIT / 4);
        flood.extend_from_slice(b"ONCE");
        assert!(terminal
            .feed_geometry_responses(&flood, "ghostty test")
            .is_err());
        assert_eq!(terminal.cursor().unwrap(), (4, 0));
        assert!(terminal
            .feed_with_responses(b"\x1b[18t")
            .unwrap()
            .is_empty());
        assert_eq!(
            terminal
                .feed_geometry_responses(b"\x1b[18t", "ghostty test")
                .unwrap(),
            b"\x1b[8;24;80t"
        );
        // Untrusted title/color/clipboard packets cannot pass the size filter.
        for packet in [
            b"\x1b]lTitle\x1b\\".as_slice(),
            b"\x1b[48;1;2;3t",
            b"\x1b[4;1;2;3t",
            b"\x1b[8;1;X t",
            b"\x1b[48;;2;3;4t",
            b"\x1b[?997;1n",
        ] {
            assert!(!is_geometry_response(packet));
        }
    }

    #[test]
    fn echoed_device_attributes_are_not_queries_and_ansi_modes_report_state() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        for query in [b"\x1b[>c".as_slice(), b"\x1b[>0c"] {
            let reply = terminal
                .feed_identity_responses(query, "ghostty test")
                .unwrap();
            assert_eq!(reply, b"\x1b[>1;10;0c");
            assert!(terminal
                .feed_identity_responses(&reply, "ghostty test")
                .unwrap()
                .is_empty());
        }
        for invalid in [
            b"\x1b[1c".as_slice(),
            b"\x1b[>1c",
            b"\x1b[=1c",
            b"\x1b[>0;0c",
        ] {
            assert!(terminal
                .feed_identity_responses(invalid, "ghostty test")
                .unwrap()
                .is_empty());
        }
        assert_eq!(
            terminal
                .feed_state_responses(b"\x1b[4$p\x1b[4h\x1b[4$p")
                .unwrap(),
            b"\x1b[4;2$y\x1b[4;1$y"
        );
    }

    #[test]
    fn identity_queries_use_the_creation_profile_across_restore_and_reset() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        let expected = b"\x1b[?62;22;52c\x1b[>1;10;0c\x1bP>|ghostty 1.2.3-test\x1b\\\x1bP1+r544E=787465726D2D67686F73747479\x1b\\";
        let query = b"\x1b[c\x1b[>c\x1b[=c\x1b[>q\x1bP+q544e\x1b\\";
        assert_eq!(
            terminal
                .feed_identity_responses(query, "ghostty 1.2.3-test")
                .unwrap(),
            expected
        );
        terminal.feed(b"\x1bP+q54");
        let mut restored = Terminal::restore(&terminal.snapshot().unwrap()).unwrap();
        assert_eq!(
            restored
                .feed_identity_responses(b"4e\x1b\\", "ghostty 1.2.3-test")
                .unwrap(),
            b"\x1bP1+r544E=787465726D2D67686F73747479\x1b\\"
        );
        restored.feed(b"\x1bc");
        assert_eq!(
            restored
                .feed_identity_responses(query, "ghostty 1.2.3-test")
                .unwrap(),
            expected
        );
        assert_eq!(
            restored
                .feed_identity_responses(b"\x1b[6n", "ghostty 1.2.3-test")
                .unwrap(),
            b"\x1b[1;1R"
        );
        assert!(restored
            .feed_identity_responses(b"\x1b[?5522$p\x1b]52;c;?\x07\x1b[21t", "ghostty 1.2.3-test")
            .unwrap()
            .is_empty());
        assert!(restored
            .feed_identity_responses(b"NOT_PARSED", "bad\x1bversion")
            .is_err());
        assert_eq!(restored.cursor().unwrap(), (0, 0));
        // Temporary identity callbacks must not leak into another feed mode.
        assert_eq!(
            restored.feed_with_responses(b"\x1b[>q").unwrap(),
            b"\x1bP>|libghostty\x1b\\"
        );
    }

    #[test]
    fn state_owner_answers_only_its_fixed_protocol_classes() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        let response = terminal
            .feed_state_responses(
                b"abc\x1b[6n\x1b[5n\x1b[?7$p\x1b[4$p\x1b[?9999$p\x1b[?u\x1bP$qm\x1b\\",
            )
            .unwrap();
        assert_eq!(
            response,
            b"\x1b[1;4R\x1b[0n\x1b[?7;1$y\x1b[4;2$y\x1b[?9999;0$y\x1b[?0u\x1bP1$r0m\x1b\\"
        );
        assert!(terminal.feed_state_responses(b"\x1b[?5522$p\x1b[c\x1b[>c\x1b[=c\x1b[>q\x1b[?996n\x1b[?997n\x1b[21t\x1bP+q544e;524742\x1b\\\x1b]52;c;?\x07").unwrap().is_empty());
        for packet in [
            b"\x1b[?997;1n".as_slice(),
            b"\x1b[8;24;80t",
            b"\x1b]5522;type=read:status=EPERM\x1b\\",
            b"\x1b_Gi=1;OK\x1b\\",
            b"\x1bP>|ghostty\x1b\\",
        ] {
            assert!(!is_state_response(packet));
        }
        assert!(terminal
            .feed_state_responses(b"\x1bP$q")
            .unwrap()
            .is_empty());
        let mut restored = Terminal::restore(&terminal.snapshot().unwrap()).unwrap();
        assert_eq!(
            restored.feed_state_responses(b"m\x1b\\").unwrap(),
            b"\x1bP1$r0m\x1b\\"
        );
    }

    #[test]
    fn captures_queries_once_across_snapshot_continuation() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        assert_eq!(
            terminal
                .feed_with_responses(b"abc\x1b[6n\x1b[5n\x1b[?7$p")
                .unwrap(),
            b"\x1b[1;4R\x1b[0n\x1b[?7;1$y"
        );
        assert!(terminal.feed_with_responses(b"\x1b[6").unwrap().is_empty());
        let snapshot = terminal.snapshot().unwrap();
        let mut restored = Terminal::restore(&snapshot).unwrap();
        assert_eq!(restored.feed_with_responses(b"n").unwrap(), b"\x1b[1;4R");
        assert!(restored.feed_with_responses(b"plain").unwrap().is_empty());
        // Silent parsing neither retains the collector nor re-emits past queries.
        restored.feed(b"\x1b[5n");
        assert_eq!(
            restored.feed_with_responses(b"\x1b[6n").unwrap(),
            b"\x1b[1;9R"
        );
    }

    #[test]
    fn response_overflow_consumes_input_once_and_does_not_retain_callback_context() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        let mut flood = b"\x1b[6n".repeat(RESPONSE_LIMIT / 4);
        flood.extend_from_slice(b"AFTER_OVERFLOW");
        assert!(terminal.feed_with_responses(&flood).is_err());
        assert_eq!(terminal.cursor().unwrap(), (14, 0));
        terminal.feed(b"x\x1b[5n");
        assert_eq!(
            terminal.feed_with_responses(b"\x1b[6n").unwrap(),
            b"\x1b[1;16R"
        );
    }
    fn equivalent(left: &mut Terminal, right: &mut Terminal) {
        assert_eq!(left.cursor().unwrap(), right.cursor().unwrap());
        assert_eq!(left.formatted().unwrap(), right.formatted().unwrap());
        for mode in [1, 6, 7, 25, 1000, 1006, 1049, 2004] {
            assert_eq!(
                left.mode(mode, false).unwrap(),
                right.mode(mode, false).unwrap(),
                "mode {mode}"
            );
        }
    }
    #[test]
    fn restores_both_screens_modes_saved_cursor_and_future_behavior_after_large_output() {
        let mut source = Terminal::new(80, 24).unwrap();
        let mut output_bytes = 0;
        for i in 0..8000 {
            let line = format!("history {i:05} styled \x1b[32m日本語🦀\x1b[0m line\r\n");
            output_bytes += line.len();
            source.feed(line.as_bytes());
        }
        assert!(output_bytes > 256 * 1024);
        source.feed(b"PRIMARY_MARKER\x1b[5;9H\x1b7\x1b[?2004h\x1b[?1h\x1b[?1000h\x1b[?1006h\x1b[?1049hALT_MARKER\x1b[3;4H\x1b[31");
        let snapshot = source.snapshot().unwrap();
        assert!(snapshot.starts_with(b"GHOSTSNP"));
        let mut restored = Terminal::restore(&snapshot).unwrap();
        equivalent(&mut source, &mut restored);
        assert!(String::from_utf8_lossy(&restored.formatted().unwrap()).contains("ALT_MARKER"));
        for suffix in [
            b"mRED\x1b[0m".as_slice(),
            b"\x1b[?1049l\x1b8AFTER_SAVED_CURSOR",
            b"\x1b[?2004l\x1b[?1000l",
        ] {
            source.feed(suffix);
            restored.feed(suffix);
            equivalent(&mut source, &mut restored);
        }
        source.resize(113, 37).unwrap();
        restored.resize(113, 37).unwrap();
        equivalent(&mut source, &mut restored);
        let text = String::from_utf8_lossy(&restored.formatted().unwrap()).into_owned();
        assert!(
            text.contains("history 00000")
                && text.contains("PRIMARY_MARKER")
                && text.contains("AFTER_SAVED_CURSOR")
        );
    }
    #[test]
    fn restores_split_utf8_and_rejects_truncated_corrupt_and_trailing_snapshots() {
        let mut source = Terminal::new(80, 24).unwrap();
        source.feed(&[0xf0, 0x9f]);
        let snapshot = source.snapshot().unwrap();
        let mut restored = Terminal::restore(&snapshot).unwrap();
        for terminal in [&mut source, &mut restored] {
            terminal.feed(&[0xa6, 0x80]);
        }
        equivalent(&mut source, &mut restored);
        assert!(String::from_utf8_lossy(&restored.formatted().unwrap()).contains("🦀"));
        for length in [0, 9, snapshot.len() / 2, snapshot.len() - 1] {
            assert!(Terminal::restore(&snapshot[..length]).is_err());
        }
        let mut corrupt = snapshot.clone();
        corrupt[30] ^= 1;
        assert!(Terminal::restore(&corrupt).is_err());
        let mut trailing = snapshot;
        trailing.push(0);
        assert!(Terminal::restore(&trailing).is_err());
    }
    #[test]
    fn resumes_unfinished_control_sequences_and_keeps_continuation_tracking() {
        for (prefix, suffix) in [
            (
                b"\x1b]8;;https://example.com".as_slice(),
                b"\x1b\\LINK\x1b]8;;\x1b\\".as_slice(),
            ),
            (b"\x1b[38;2;100;", b"120;140mCOLOR"),
            (b"\x1bP$q", b"m\x1b\\AFTER_DCS"),
        ] {
            let mut source = Terminal::new(80, 24).unwrap();
            source.feed(prefix);
            let mut restored = Terminal::restore(&source.snapshot().unwrap()).unwrap();
            source.feed(suffix);
            restored.feed(suffix);
            equivalent(&mut source, &mut restored);
            // A restored terminal can itself be checkpointed mid-sequence.
            restored.feed(b"\x1b[3");
            let mut twice = Terminal::restore(&restored.snapshot().unwrap()).unwrap();
            restored.feed(b"2mNEXT");
            twice.feed(b"2mNEXT");
            equivalent(&mut restored, &mut twice);
        }
    }
}
