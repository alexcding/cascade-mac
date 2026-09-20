#![cfg(feature = "terminal-snapshots")]

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

struct Connection {
    reader: BufReader<UnixStream>,
    events: VecDeque<Value>,
    next_id: u64,
}

impl Connection {
    fn connect(path: &PathBuf) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        Self {
            reader: BufReader::new(stream),
            events: VecDeque::new(),
            next_id: 0,
        }
    }
    fn frame(&mut self) -> Value {
        let mut line = String::new();
        assert!(self.reader.read_line(&mut line).unwrap() > 0);
        assert!(line.len() < 2 * 1024 * 1024);
        serde_json::from_str(&line).unwrap()
    }
    fn request(&mut self, mut value: Value) -> Result<Value, String> {
        self.next_id += 1;
        value["id"] = json!(self.next_id);
        writeln!(self.reader.get_mut(), "{value}").unwrap();
        loop {
            let response = self.frame();
            if response["id"].as_u64() == Some(self.next_id) {
                return if let Some(error) = response["err"].as_str() {
                    Err(error.to_string())
                } else {
                    Ok(response["ok"].clone())
                };
            }
            self.events.push_back(response);
        }
    }
    fn event(&mut self) -> Value {
        self.events.pop_front().unwrap_or_else(|| self.frame())
    }
    fn hello(&mut self) {
        let hello = self
            .request(json!({"op":"hello", "dataEncoding":"base64",
            "snapshotRevision":craft_vt::GHOSTTY_REVISION}))
            .unwrap();
        assert_eq!(hello["snapshotRevision"], craft_vt::GHOSTTY_REVISION);
    }
    fn snapshot(&mut self, term: &str) -> (Value, Vec<u8>) {
        let header = self
            .request(json!({"op":"snapshotBegin", "term":term}))
            .unwrap();
        let mut bytes = Vec::new();
        while bytes.len() < header["size"].as_u64().unwrap() as usize {
            let chunk = self
                .request(
                    json!({"op":"snapshotRead", "token":header["token"], "offset":bytes.len()}),
                )
                .unwrap();
            let part = BASE64.decode(chunk["bytes"].as_str().unwrap()).unwrap();
            assert!(part.len() <= 128 * 1024);
            bytes.extend(part);
        }
        assert_eq!(bytes.len(), header["size"].as_u64().unwrap() as usize);
        (header, bytes)
    }
}

struct Fixture {
    child: Child,
    root: PathBuf,
    socket: PathBuf,
}
impl Fixture {
    fn start() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let serial = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = PathBuf::from(format!(
            "/tmp/th-snapshot-{}-{nonce}-{serial}",
            std::process::id()
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = root.join("pty.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_craft-ptyd"))
            .arg(&root)
            .env("CRAFT_PTYD_SOCK", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let fixture = Self {
            child,
            root,
            socket,
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !fixture.socket.exists() {
            assert!(Instant::now() < deadline, "isolated daemon did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        fixture
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        // Only this fixture's private socket/process/directory are touched.
        if let Ok(mut stream) = UnixStream::connect(&self.socket) {
            let _ = writeln!(stream, "{{\"id\":1,\"op\":\"killAll\"}}");
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            let _ = BufReader::new(stream).read_line(&mut String::new());
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn geometry_matches_kernel_winsize_without_views_and_across_ordered_resizes() {
    let fixture = Fixture::start();
    let script = fixture.root.join("geometry.py");
    std::fs::write(&script, br#"#!/usr/bin/python3
import fcntl, json, os, pathlib, select, struct, termios, time, tty
tty.setraw(0)
root = pathlib.Path.cwd()
for stage in range(6):
    while not (root / ('go' + str(stage))).exists():
        time.sleep(0.01)
    if stage == 4:
        os.write(1, b'\x1b[?2048l')
    os.write(1, b'\x1b[14t\x1b[16t\x1b[18t')
    if stage == 0:
        os.write(1, b'\x1b[?2048h')
    result = b''
    deadline = time.monotonic() + 0.3
    while time.monotonic() < deadline:
        if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
            result += os.read(0, 65536)
    size = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
    pending = root / 'pending'
    pending.write_text(json.dumps({'reply': result.hex(), 'size': size}))
    pending.rename(root / ('result' + str(stage)))
while True:
    time.sleep(1)
"#).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    // Identity copying is separately tested with the actual bundled entry by
    // the native app suite. This program does not interpret terminfo contents.
    let terminfo = fixture.root.join("source-terminfo");
    std::fs::create_dir_all(terminfo.join("78")).unwrap();
    std::fs::write(terminfo.join("78/xterm-ghostty"), [0x1a, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).unwrap();
    let geometry = |cols, rows, width, height| json!({"cols":cols,"rows":rows,
        "cellWidthPixels":width,"cellHeightPixels":height});
    let initial = geometry(80, 24, 9, 18);
    let mut connection = Connection::connect(&fixture.socket);
    let hello = connection.request(json!({"op":"hello"})).unwrap();
    assert_eq!(hello["geometryResponseOwner"], craft_vt::GEOMETRY_RESPONSE_OWNER);
    let mut opts = json!({"cwd":fixture.root,"shell":script,
        "stateResponseOwner":craft_vt::IDENTITY_RESPONSE_OWNER,
        "terminalProfile":{"version":"test","terminfoDirectory":terminfo},
        "geometryResponseOwner":craft_vt::GEOMETRY_RESPONSE_OWNER,"geometry":initial});
    for (field, value) in [
        ("geometryResponseOwner", json!("future-owner")),
        ("geometryResponseOwner", Value::Null),
        ("stateResponseOwner", json!(craft_vt::STATE_RESPONSE_OWNER)),
        ("geometry", Value::Null),
        ("geometry", geometry(80, 24, 0, 18)),
        ("geometry", geometry(80, 24, u32::MAX, 18)),
        ("geometry", geometry(80, 24, 9, 65536)),
    ] {
        let original = opts[field].clone();
        opts[field] = value;
        assert!(connection.request(json!({"op":"create","opts":opts})).is_err());
        opts[field] = original;
    }
    assert_eq!(connection.request(json!({"op":"list"})).unwrap(), json!([]));
    let term = connection.request(json!({"op":"create","opts":opts})).unwrap();
    let id = term["id"].as_str().unwrap();
    assert_eq!(term["geometryResponseOwner"], craft_vt::GEOMETRY_RESPONSE_OWNER);
    drop(connection);
    let stage = |index: usize, cols, rows, width, height, before: &str, after: &str| {
        std::fs::write(fixture.root.join(format!("go{index}")), b"go").unwrap();
        let path = fixture.root.join(format!("result{index}"));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(Instant::now() < deadline, "geometry program did not finish stage {index}");
            std::thread::sleep(Duration::from_millis(10));
        }
        let result: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        let expected = format!("{before}\x1b[4;{};{}t\x1b[6;{height};{width}t\x1b[8;{rows};{cols}t{after}", rows * height, cols * width);
        let expected: String = expected.bytes().map(|byte| format!("{byte:02x}")).collect();
        assert_eq!(result["reply"], expected, "reply at stage {index}");
        assert_eq!(result["size"], json!([rows, cols, cols * width, rows * height]), "kernel at stage {index}");
    };
    stage(0, 80, 24, 9, 18, "", "\x1b[48;24;80;432;720t");
    let mut first = Connection::connect(&fixture.socket);
    let mut second = Connection::connect(&fixture.socket);
    first.hello(); second.hello();
    let (_, bytes) = first.snapshot(id);
    let mut restored = craft_vt::Terminal::restore(&bytes).unwrap();
    assert_eq!(restored.geometry().unwrap(), craft_vt::Geometry { cols:80, rows:24, cell_width:9, cell_height:18 });
    assert!(restored.mode(2048, false).unwrap());
    let resize = |connection: &mut Connection, size: &Value| {
        connection.request(json!({"op":"resize","term":id,"cols":size["cols"],"rows":size["rows"],"geometry":size})).unwrap();
    };
    let retina = geometry(80, 24, 18, 36);
    // Reject partial, inconsistent, and overflowing updates before kernel/state mutation.
    let (before, _) = second.snapshot(id);
    for request in [
        json!({"op":"resize","term":id,"cols":80,"rows":24}),
        json!({"op":"resize","term":id,"cols":81,"rows":24,"geometry":retina}),
        json!({"op":"resize","term":id,"cols":80,"rows":24,"geometry":geometry(80,24,819,2731)}),
    ] {
        assert!(first.request(request).is_err());
    }
    let (unchanged, _) = second.snapshot(id);
    assert_eq!(before["stateSeq"], unchanged["stateSeq"]);
    resize(&mut first, &retina);
    let (header, bytes) = second.snapshot(id);
    assert_eq!(header["geometry"], retina);
    assert_eq!(header["stateSeq"].as_u64().unwrap(), before["stateSeq"].as_u64().unwrap() + 1);
    let event = loop { let event = first.event(); if event["ev"] == "resize" { break event; } };
    assert_eq!(event["geometry"], retina);
    assert_eq!(event["stateSeq"], header["stateSeq"]);
    restored = craft_vt::Terminal::restore(&bytes).unwrap();
    assert_eq!(restored.geometry().unwrap().cell_width, 18);
    stage(1, 80, 24, 18, 36, "\x1b[48;24;80;864;1440t", "");
    let bigger = geometry(100, 30, 18, 36);
    resize(&mut first, &bigger);
    drop(first); drop(second);
    stage(2, 100, 30, 18, 36, "\x1b[48;30;100;1080;1800t", "");
    let mut connection = Connection::connect(&fixture.socket);
    connection.hello();
    let (before, _) = connection.snapshot(id);
    resize(&mut connection, &bigger);
    let (same, _) = connection.snapshot(id);
    assert_eq!(before["stateSeq"], same["stateSeq"], "identical resize has no ordered event");
    stage(3, 100, 30, 18, 36, "", "");
    stage(4, 100, 30, 18, 36, "", "");
    resize(&mut connection, &initial);
    stage(5, 80, 24, 9, 18, "", "");
    let list = connection.request(json!({"op":"list"})).unwrap();
    assert_eq!(list[0]["pid"], term["pid"]);
    assert_eq!(list[0]["hasContext"], false);
    assert_eq!(list[0]["geometryResponseOwner"], craft_vt::GEOMETRY_RESPONSE_OWNER);
}

#[test]
fn real_shell_snapshot_survives_tail_truncation_resize_and_client_reconnect() {
    let fixture = Fixture::start();
    let script = fixture.root.join("shell.sh");
    std::fs::write(
        &script,
        br#"#!/bin/sh
stty -echo
i=0
while [ "$i" -lt 8000 ]; do
  printf 'history %05d styled \033[32mJapanese and crab text\033[0m line\r\n' "$i"
  i=$((i+1))
done
printf 'PRIMARY_MARKER\033[5;9H\0337\033[?2004h\033[?1049hALT_MARKER\033[31'
IFS= read -r next
printf 'mRED\033[0m\033[?1049l\0338AFTER_SAVED_CURSOR'
IFS= read -r next
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut connection = Connection::connect(&fixture.socket);
    assert!(connection
        .request(json!({"op":"snapshotBegin", "term":"unknown"}))
        .is_err());
    assert!(connection
        .request(json!({"op":"hello", "dataEncoding":"base64", "snapshotRevision":"wrong"}))
        .is_err());
    connection.hello();
    let term = connection
        .request(json!({"op":"create", "opts":{"cwd":fixture.root, "shell":script}}))
        .unwrap();
    let id = term["id"].as_str().unwrap();
    let mut output = Vec::new();
    while !output.ends_with(b"ALT_MARKER\x1b[31") {
        let event = connection.event();
        if event["ev"] == "data" {
            output.extend(BASE64.decode(event["bytes"].as_str().unwrap()).unwrap());
        }
    }
    assert!(output.len() > 256 * 1024);
    let tail = connection
        .request(json!({"op":"attach", "term":id}))
        .unwrap();
    assert_eq!(tail["truncated"], true);
    let (header, bytes) = connection.snapshot(id);
    assert_eq!(header["seq"], tail["seq"]);
    assert!(
        bytes.len() > 128 * 1024,
        "exercise more than one transport chunk"
    );
    let mut restored = craft_vt::Terminal::restore(&bytes).unwrap();
    assert!(String::from_utf8_lossy(&restored.formatted().unwrap()).contains("ALT_MARKER"));
    assert!(restored.mode(2004, false).unwrap());

    let mut other = Connection::connect(&fixture.socket);
    other.hello();
    assert!(other
        .request(json!({"op":"snapshotRead", "token":header["token"], "offset":0}))
        .is_err());
    assert!(connection
        .request(json!({"op":"resize", "term":id, "cols":65536, "rows":30}))
        .is_err());
    assert!(connection
        .request(json!({"op":"resize", "term":id, "cols":65535, "rows":65535}))
        .is_err());
    assert!(connection
        .request(json!({"op":"resize", "term":id, "cols":90, "rows":0}))
        .is_err());
    connection
        .request(json!({"op":"resize", "term":id, "cols":113, "rows":37}))
        .unwrap();
    restored.resize(113, 37).unwrap();
    let resized = connection.event();
    assert_eq!(resized["ev"], "resize");
    assert_eq!(
        resized["stateSeq"].as_u64().unwrap(),
        header["stateSeq"].as_u64().unwrap() + 1
    );
    connection
        .request(json!({"op":"write", "term":id, "data":"continue\n"}))
        .unwrap();
    let mut suffix = Vec::new();
    while !suffix.ends_with(b"AFTER_SAVED_CURSOR") {
        let event = connection.event();
        if event["ev"] == "data" {
            let bytes = BASE64.decode(event["bytes"].as_str().unwrap()).unwrap();
            restored.feed(&bytes);
            suffix.extend(bytes);
        }
    }
    drop(connection); // the shell and its authoritative state must survive
    let list = other.request(json!({"op":"list"})).unwrap();
    assert_eq!(list[0]["pid"], term["pid"]);
    let (new_header, new_bytes) = other.snapshot(id);
    assert_eq!(new_header["cols"], 113);
    assert_eq!(new_header["rows"], 37);
    let mut current = craft_vt::Terminal::restore(&new_bytes).unwrap();
    assert_eq!(current.formatted().unwrap(), restored.formatted().unwrap());
    assert_eq!(current.cursor().unwrap(), restored.cursor().unwrap());
    let text = String::from_utf8_lossy(&current.formatted().unwrap()).into_owned();
    assert!(
        text.contains("history 00000")
            && text.contains("PRIMARY_MARKER")
            && text.contains("AFTER_SAVED_CURSOR")
    );
    other
        .request(json!({"op":"snapshotEnd", "token":new_header["token"]}))
        .unwrap();
    assert!(other
        .request(json!({"op":"snapshotRead", "token":new_header["token"], "offset":0}))
        .is_err());
    other.request(json!({"op":"kill", "term":id})).unwrap();
}

#[test]
fn state_queries_have_one_owner_without_viewers_and_across_reconnects() {
    let fixture = Fixture::start();
    let script = fixture.root.join("queries.py");
    std::fs::write(
        &script,
        br#"#!/usr/bin/python3
import os, pathlib, select, time, tty
tty.setraw(0)
root = pathlib.Path.cwd()
for stage in range(3):
    while not (root / ('go' + str(stage))).exists():
        time.sleep(0.01)
    os.write(1, b'\x1b[2J\x1b[Habc\x1b[6n\x1b[5n\x1b[?7$p\x1b[?9999$p\x1b[?u\x1bP$qm\x1b\\')
    result = b''
    deadline = time.monotonic() + 0.5
    while time.monotonic() < deadline:
        if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
            result += os.read(0, 65536)
    (root / ('result' + str(stage))).write_text(result.hex())
while True:
    time.sleep(1)
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut connection = Connection::connect(&fixture.socket);
    let hello = connection.request(json!({"op":"hello"})).unwrap();
    assert_eq!(
        hello["stateResponseOwner"],
        craft_vt::STATE_RESPONSE_OWNER
    );
    assert!(connection
        .request(json!({"op":"create", "opts":{"stateResponseOwner":"future-owner"}}))
        .is_err());
    for opts in [
        json!({"stateResponseOwner":craft_vt::IDENTITY_RESPONSE_OWNER}),
        json!({"terminalProfile":{"version":"1.0","terminfoDirectory":"/tmp"}}),
        json!({"stateResponseOwner":craft_vt::IDENTITY_RESPONSE_OWNER,"terminalProfile":{"version":"bad\u{1b}version","terminfoDirectory":"/tmp"}}),
        json!({"stateResponseOwner":craft_vt::IDENTITY_RESPONSE_OWNER,"terminalProfile":{"version":"1.0","terminfoDirectory":"relative"}}),
    ] {
        assert!(connection
            .request(json!({"op":"create","opts":opts}))
            .is_err());
    }
    assert_eq!(connection.request(json!({"op":"list"})).unwrap(), json!([]));
    let term = connection.request(json!({"op":"create", "opts":{
        "cwd":fixture.root, "shell":script, "stateResponseOwner":craft_vt::STATE_RESPONSE_OWNER
    }})).unwrap();
    let id = term["id"].as_str().unwrap();
    assert_eq!(term["stateResponseOwner"], craft_vt::STATE_RESPONSE_OWNER);
    drop(connection);
    let expected = b"\x1b[1;4R\x1b[0n\x1b[?7;1$y\x1b[?9999;0$y\x1b[?0u\x1bP1$r0m\x1b\\";
    let expected: String = expected.iter().map(|b| format!("{b:02x}")).collect();
    let query = |root: &PathBuf, stage: usize, expected: &str| {
        std::fs::write(root.join(format!("go{stage}")), b"go").unwrap();
        let path = root.join(format!("result{stage}"));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(
                Instant::now() < deadline,
                "query program did not finish stage {stage}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            std::fs::read_to_string(path).unwrap(),
            expected,
            "stage {stage}"
        );
    };
    query(&fixture.root, 0, &expected); // no connected client
    let mut first = Connection::connect(&fixture.socket);
    let mut second = Connection::connect(&fixture.socket);
    first.hello();
    second.hello();
    let _ = first.snapshot(id);
    let _ = second.snapshot(id);
    query(&fixture.root, 1, &expected); // two snapshot observers
    drop(first);
    drop(second);
    query(&fixture.root, 2, &expected); // observers disconnected again
    let mut connection = Connection::connect(&fixture.socket);
    let list = connection.request(json!({"op":"list"})).unwrap();
    assert_eq!(list[0]["pid"], term["pid"]);
    assert_eq!(
        list[0]["hasContext"], false,
        "protocol traffic is not user input"
    );
    assert_eq!(
        list[0]["stateResponseOwner"],
        craft_vt::STATE_RESPONSE_OWNER
    );
    // Legacy/Tauri shells remain silent even in the snapshot-enabled helper.
    let legacy_root = fixture.root.join("legacy");
    std::fs::create_dir(&legacy_root).unwrap();
    let legacy = connection
        .request(json!({"op":"create", "opts":{"cwd":legacy_root, "shell":script}}))
        .unwrap();
    assert!(legacy["stateResponseOwner"].is_null());
    query(&legacy_root, 0, "");
}
