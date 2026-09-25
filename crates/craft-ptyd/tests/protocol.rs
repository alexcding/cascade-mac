use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use serde_json::{json, Value};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use std::os::unix::fs::PermissionsExt;

struct Fixture { child: Child, directory: std::path::PathBuf }
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

struct Peer { reader: BufReader<UnixStream>, events: Vec<Value>, next: u64 }
impl Peer {
    fn connect(socket: &std::path::Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        Self { reader: BufReader::new(stream), events: Vec::new(), next: 0 }
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        assert!(self.reader.read_line(&mut line).unwrap() > 0, "peer disconnected");
        serde_json::from_str(&line).unwrap()
    }

    fn request(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let value = self.read();
            if value["id"] == self.next { return value; }
            self.events.push(value);
        }
    }

    fn data(&mut self) -> Value {
        loop {
            if let Some(index) = self.events.iter().position(|v| v["ev"] == "data") {
                return self.events.remove(index);
            }
            let value = self.read();
            self.events.push(value);
        }
    }
}

#[test]
fn native_bytes_and_legacy_text_coexist_on_the_same_terminal() {
    let directory = std::path::PathBuf::from(format!("/tmp/craft-ptyd-bytes-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let shell = directory.join("echo-shell");
    std::fs::write(&shell, "#!/bin/sh\n/bin/stty raw -echo || exit 1\nprintf READY\nexec /bin/cat\n").unwrap();
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
    let socket = directory.join("ptyd.sock");
    let child = Command::new(env!("CARGO_BIN_EXE_craft-ptyd"))
        .arg(&directory).env("CRAFT_PTYD_SOCK", &socket)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
    let mut fixture = Fixture { child, directory };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline);
        assert!(fixture.child.try_wait().unwrap().is_none());
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut legacy = Peer::connect(&socket);
    assert_eq!(legacy.request(json!({"op":"hello"}))["ok"]["dataEncoding"], "utf8");
    let mut native = Peer::connect(&socket);
    assert_eq!(native.request(json!({"op":"hello","dataEncoding":"base64"}))["ok"]["dataEncoding"], "base64");
    // Identity probes must not reset an established byte connection.
    assert_eq!(native.request(json!({"op":"hello"}))["ok"]["dataEncoding"], "base64");
    assert!(native.request(json!({"op":"hello","dataEncoding":"unsupported"}))["err"].is_string());
    #[cfg(not(feature = "terminal-snapshots"))]
    {
        assert!(native.request(json!({"op":"hello"}))["ok"]["geometryResponseOwner"].is_null());
        assert!(native.request(json!({"op":"create","opts":{
            "geometryResponseOwner":"daemon-geometry-v1",
            "geometry":{"cols":80,"rows":24,"cellWidthPixels":9,"cellHeightPixels":18}
        }}))["err"].is_string());
    }
    let created = native.request(json!({"op":"create","opts":{"cwd":fixture.directory,"shell":shell}}));
    let id = created["ok"]["id"].as_str().unwrap();
    assert_eq!(native.data()["bytes"], BASE64.encode(b"READY"));
    assert_eq!(legacy.data()["chunk"], "READY");
    assert!(native.request(json!({"op":"resize","term":id,"cols":90,"rows":30}))["ok"].is_null());
    assert!(native.request(json!({"op":"resize","term":id,"cols":0,"rows":30}))["err"].is_string());
    assert!(native.request(json!({"op":"resize","term":id,"cols":90,"rows":30,
        "geometry":{"cols":90,"rows":30,"cellWidthPixels":9,"cellHeightPixels":18}
    }))["err"].is_string());
    assert!(native.request(json!({"op":"write","term":id,"bytes":"?invalid"}))["err"].is_string());
    assert!(native.request(json!({"op":"write","term":id,"bytes":"QQ==","data":"B"}))["err"].is_string());
    let first = b"A\xff\xf0\x9f";
    assert!(native.request(json!({"op":"write","term":id,"bytes":BASE64.encode(first)}))["ok"].is_null());
    let native_first = native.data();
    let legacy_first = legacy.data();
    assert_eq!(native_first["bytes"], BASE64.encode(first));
    assert_eq!(legacy_first["chunk"], "A\u{fffd}");
    assert_eq!(native_first["seq"], legacy_first["seq"]);
    // Resize participates in state ordering without creating a gap in legacy
    // output sequences. Its acknowledgement follows the kernel size change.
    assert_eq!(native_first["seq"], 2);
    assert_eq!(native_first["stateSeq"], 3);
    let resized = native.events.iter().find(|event| event["ev"] == "resize").unwrap();
    assert_eq!(resized["cols"], 90);
    assert_eq!(resized["rows"], 30);
    assert_eq!(resized["stateSeq"], 2);
    assert!(resized.get("geometry").is_none());
    // The native attachment includes the incomplete UTF-8 suffix atomically;
    // the legacy decoder holds that suffix until a later read completes it.
    let attached = native.request(json!({"op":"attach","term":id}));
    assert_eq!(attached["ok"]["bytes"], BASE64.encode(b"READYA\xff\xf0\x9f"));
    assert_eq!(attached["ok"]["seq"], native_first["seq"]);
    let second = b"\xa6\x80Z";
    native.request(json!({"op":"write","term":id,"bytes":BASE64.encode(second)}));
    let native_second = native.data();
    let legacy_second = legacy.data();
    assert_eq!(native_second["bytes"], BASE64.encode(second));
    assert_eq!(legacy_second["chunk"], "🦀Z");
    assert_eq!(native_second["seq"], legacy_second["seq"]);
    assert_eq!(legacy.request(json!({"op":"attach","term":id}))["ok"]["buf"], "READYA\u{fffd}🦀Z");
    // Legacy string input remains supported on the same PTY.
    legacy.request(json!({"op":"write","term":id,"data":"LEGACY"}));
    assert_eq!(native.data()["bytes"], BASE64.encode(b"LEGACY"));
    assert_eq!(legacy.data()["chunk"], "LEGACY");
    assert_eq!(native.request(json!({"op":"kill","term":id}))["ok"], true);
    loop { if native.read()["ev"] == "exit" { break; } }
}

#[test]
fn standalone_helper_preserves_protocol_and_reconnects() {
    let directory = std::path::PathBuf::from(format!("/tmp/craft-ptyd-test-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let socket = directory.join("ptyd.sock");
    let child = Command::new(env!("CARGO_BIN_EXE_craft-ptyd"))
        .arg(&directory).env("CRAFT_PTYD_SOCK", &socket)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
    let mut fixture = Fixture { child, directory };
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) { break stream; }
        assert!(Instant::now() < deadline, "daemon did not bind");
        assert!(fixture.child.try_wait().unwrap().is_none(), "daemon exited");
        std::thread::sleep(Duration::from_millis(20));
    };
    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    // Fragment one request and coalesce its end with the next request.
    stream.write_all(b"{\"id\":1,\"op\":").unwrap();
    stream.write_all(b"\"hello\"}\n{\"id\":2,\"op\":\"list\"}\n").unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["id"], 1);
    assert_eq!(response["ok"]["protocol"], craft_ptyd::PROTOCOL);
    assert_eq!(response["ok"]["pid"], fixture.child.id());
    line.clear();
    reader.read_line(&mut line).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&line).unwrap(), json!({"id":2,"ok":[]}));
    drop(reader);
    let mut stream = UnixStream::connect(&socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    stream.write_all(b"{\"id\":3,\"op\":\"hello\"}\n").unwrap();
    line.clear();
    BufReader::new(stream).read_line(&mut line).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["ok"]["pid"], fixture.child.id());
}

#[test]
fn startup_command_runs_after_zsh_startup_and_leaves_an_interactive_shell() {
    let directory = std::path::PathBuf::from(format!("/tmp/craft-ptyd-startup-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    // The startup file runs before the command; the command sees what it set.
    std::fs::write(directory.join(".zshrc"), "export CRAFT_STARTUP_ORDER=loaded\n").unwrap();
    let socket = directory.join("ptyd.sock");
    let child = Command::new(env!("CARGO_BIN_EXE_craft-ptyd"))
        .arg(&directory).env("CRAFT_PTYD_SOCK", &socket)
        .env("HOME", &directory).env_remove("ZDOTDIR")
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
    let mut fixture = Fixture { child, directory };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline);
        assert!(fixture.child.try_wait().unwrap().is_none());
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut peer = Peer::connect(&socket);
    assert_eq!(peer.request(json!({"op":"hello","dataEncoding":"base64"}))["ok"]["startupCommand"], true);
    let marker = fixture.directory.join("started");
    let created = peer.request(json!({"op":"create","opts":{
        "cwd":fixture.directory,"shell":"/bin/zsh",
        "startupCommand":format!("printf %s \"$CRAFT_STARTUP_ORDER\" > '{}'; /bin/sleep 30", marker.display())
    }}));
    let id = created["ok"]["id"].as_str().unwrap().to_string();
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::fs::read_to_string(&marker).unwrap_or_default() != "loaded" {
        assert!(Instant::now() < deadline, "the startup command did not run after .zshrc");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(peer.request(json!({"op":"foreground","term":id}))["ok"]["atShell"], false);
    // Ctrl-C ends the command, not the shell: it is still there, interactive, and takes input.
    peer.request(json!({"op":"write","term":id,"data":"\u{3}"}));
    let typed = fixture.directory.join("typed");
    let deadline = Instant::now() + Duration::from_secs(10);
    peer.request(json!({"op":"write","term":id,"data":format!("touch '{}'\r", typed.display())}));
    while !typed.exists() {
        assert!(Instant::now() < deadline, "the shell after the startup command did not take input");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(peer.request(json!({"op":"foreground","term":id}))["ok"]["atShell"], true);
    // Any other shell refuses the command, and starts nothing.
    let refused = peer.request(json!({"op":"create","opts":{
        "cwd":fixture.directory,"shell":"/bin/sh","startupCommand":"true"
    }}));
    assert!(refused["err"].is_string());
    assert_eq!(peer.request(json!({"op":"list"}))["ok"].as_array().unwrap().len(), 1);
    assert_eq!(peer.request(json!({"op":"kill","term":id}))["ok"], true);
}
