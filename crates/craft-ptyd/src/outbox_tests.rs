use super::*;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;

static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
  daemon: Arc<Daemon>,
  peers: Vec<UnixStream>,
  servers: Vec<std::thread::JoinHandle<()>>,
}

impl Fixture {
  fn new() -> Self {
    let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let dir = PathBuf::from(format!("/tmp/craft-outbox-{}-{sequence}", std::process::id()));
    std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    let daemon = Arc::new(Daemon {
      dir, terms: Mutex::new(HashMap::new()), clients: Mutex::new(Vec::new()),
      seq: AtomicU64::new(0), client_seq: AtomicU64::new(0), boot: now_ms(),
      idle_since: Mutex::new(None), browser: None,
    });
    Self { daemon, peers: Vec::new(), servers: Vec::new() }
  }

  fn connect(&mut self) -> (u64, BufReader<UnixStream>) {
    let (server, peer) = UnixStream::pair().unwrap();
    let size: libc::c_int = 4096;
    assert_eq!(unsafe {
      libc::setsockopt(server.as_raw_fd(), libc::SOL_SOCKET, libc::SO_SNDBUF,
        &size as *const _ as *const libc::c_void, std::mem::size_of_val(&size) as libc::socklen_t)
    }, 0);
    peer.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    self.peers.push(peer.try_clone().unwrap());
    let id = self.daemon.client_seq.load(Ordering::SeqCst) + 1;
    let daemon = self.daemon.clone();
    self.servers.push(std::thread::spawn(move || daemon.serve_client(server)));
    wait_until(|| self.daemon.clients.lock().unwrap().iter().any(|client| client.id == id));
    (id, BufReader::new(peer))
  }

  // A terminal whose shell prints READY, then echoes its input raw. `creator` hears it.
  fn echo_terminal(&self, creator: Option<u64>) -> TermInfo {
    let shell = self.daemon.dir.join("echo-shell");
    if !shell.exists() {
      std::fs::write(&shell, "#!/bin/sh\n/bin/stty raw -echo || exit 1\nprintf READY\nexec /bin/cat\n").unwrap();
      std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let opts = serde_json::from_value(json!({"cwd":self.daemon.dir,"shell":shell})).unwrap();
    self.daemon.create(opts, creator).unwrap()
  }
}

impl Drop for Fixture {
  fn drop(&mut self) {
    self.daemon.kill_all();
    for peer in &self.peers { let _ = peer.shutdown(std::net::Shutdown::Both); }
    for server in self.servers.drain(..) { let _ = server.join(); }
    let deadline = Instant::now() + Duration::from_secs(3);
    while !self.daemon.list().is_empty() && Instant::now() < deadline {
      std::thread::sleep(Duration::from_millis(10));
    }
    let _ = std::fs::remove_dir_all(&self.daemon.dir);
  }
}

fn wait_until(mut predicate: impl FnMut() -> bool) {
  let deadline = Instant::now() + Duration::from_secs(3);
  while !predicate() {
    assert!(Instant::now() < deadline, "outbox condition timed out");
    std::thread::sleep(Duration::from_millis(10));
  }
}

fn read(peer: &mut BufReader<UnixStream>) -> Value {
  let mut line = String::new();
  assert!(peer.read_line(&mut line).unwrap() > 0, "healthy peer disconnected");
  serde_json::from_str(&line).unwrap()
}

// Every frame up to and including the first that matches.
fn read_until(peer: &mut BufReader<UnixStream>, matches: impl Fn(&Value) -> bool) -> Vec<Value> {
  let mut frames = vec![read(peer)];
  while !matches(frames.last().unwrap()) { frames.push(read(peer)); }
  frames
}

fn output_of(id: &str, text: &str) -> impl Fn(&Value) -> bool {
  let (id, text) = (id.to_string(), text.to_string());
  move |frame| frame["ev"] == "data" && frame["id"] == id.as_str() && frame["chunk"] == text.as_str()
}

fn negotiate(peer: &mut BufReader<UnixStream>, request: Value) -> Value {
  writeln!(peer.get_mut(), "{request}").unwrap();
  read(peer)["ok"].clone()
}

// Reads until `peer` has seen READY from `count` terminals.
fn read_ready(peer: &mut BufReader<UnixStream>, count: usize) {
  let mut ready = HashSet::new();
  while ready.len() < count {
    let frame = read(peer);
    if frame["chunk"] == "READY" { ready.insert(frame["id"].as_str().unwrap().to_string()); }
  }
}

#[test]
fn idle_socket_starts_its_delivery_deadline_with_new_work() {
  let fixture = Fixture::new();
  let (sock, _peer) = UnixStream::pair().unwrap();
  let (tx, rx) = mpsc::channel();
  // Hold the receiver without a writer: a fast socket must not conceal a
  // missing idle-clock reset by delivering the first frame between offers.
  fixture.daemon.clients.lock().unwrap().push(Client {
    id: 1, byte_transport: false, hears_all: true, terminals: HashSet::new(), tx, sock,
    owed: Arc::new(AtomicUsize::new(0)),
    progress: Arc::new(Mutex::new(Instant::now() - STALL_DROP - Duration::from_secs(1))),
  });
  fixture.daemon.reap_stalled_clients(None);
  assert_eq!(fixture.daemon.clients.lock().unwrap().len(), 1, "idle clients have no delivery debt");
  fixture.daemon.broadcast("fixture", &json!({"ev":"idle-ended"}));
  fixture.daemon.broadcast("fixture", &json!({"ev":"second-frame"}));
  assert_eq!(serde_json::from_str::<Value>(&rx.try_recv().unwrap()).unwrap()["ev"], "idle-ended");
  assert_eq!(serde_json::from_str::<Value>(&rx.try_recv().unwrap()).unwrap()["ev"], "second-frame");
  assert_eq!(fixture.daemon.clients.lock().unwrap().len(), 1);
}

#[test]
fn unread_legacy_socket_expires_during_backlog_pause_and_original_pty_resumes() {
  unread_socket_expires(false);
}

#[test]
fn unread_native_socket_expires_during_backlog_pause_and_original_pty_resumes() {
  unread_socket_expires(true);
}

fn unread_socket_expires(native: bool) {
  let mut fixture = Fixture::new();
  let (_, mut healthy) = fixture.connect();
  let (slow_id, mut unread) = fixture.connect();
  if native {
    for peer in [&mut healthy, &mut unread] {
      writeln!(peer.get_mut(), "{}", json!({"id":1,"op":"hello","dataEncoding":"base64"})).unwrap();
      assert_eq!(read(peer)["ok"]["dataEncoding"], "base64");
    }
  }
  let output = |event: &Value| -> Vec<u8> {
    if native { BASE64.decode(event["bytes"].as_str().unwrap()).unwrap() }
    else { event["chunk"].as_str().unwrap().as_bytes().to_vec() }
  };
  let terminal = fixture.echo_terminal(None);
  assert_eq!(output(&read(&mut healthy)), b"READY");
  let ring = fixture.daemon.terms.lock().unwrap()[&terminal.id].ring.clone();

  // Exercise the production broadcaster and socket writer with complete JSON
  // frames. The healthy socket consumes each frame; the second never reads.
  // Synthetic flood frames isolate socket backpressure from parser throughput.
  let chunk = "x".repeat(BATCH_MAX_BYTES);
  let mut sequence = 0;
  while fixture.daemon.backlog("fixture-flood") <= BACKLOG_HIGH {
    sequence += 1;
    assert!(sequence < 100, "unread socket must accumulate bounded delivery debt");
    fixture.daemon.broadcast_output("fixture-flood", sequence, sequence, chunk.as_bytes(), &chunk);
    let event = read(&mut healthy);
    assert_eq!(event["id"], "fixture-flood");
    assert_eq!(event["seq"], sequence);
    assert_eq!(output(&event).len(), BATCH_MAX_BYTES);
  }
  assert!(fixture.daemon.backlog("fixture-flood") <= OUTBOX_MAX);
  // Wake the real terminal so it observes the backlog of a client that hears it, then queue input.
  // The old implementation could stay in this state indefinitely: no output
  // means offer() never gets another chance to expire the unread client.
  fixture.daemon.flow(slow_id, &terminal.id, true);
  let before = ring.lock().unwrap().seq;
  fixture.daemon.write(&terminal.id, b"AFTER-BACKLOG").unwrap();
  std::thread::sleep(Duration::from_millis(100));
  fixture.daemon.flow(slow_id, &terminal.id, false);
  std::thread::sleep(Duration::from_millis(100));
  assert_eq!(ring.lock().unwrap().seq, before, "socket debt must actually suspend PTY reads");

  // Advance only this fixture client's delivery clock, not the production
  // deadline. There is no 60-second sleep and no test-only daemon option.
  {
    let clients = fixture.daemon.clients.lock().unwrap();
    let client = clients.iter().find(|client| client.id == slow_id).unwrap();
    assert!(client.owed.load(Ordering::Relaxed) > BACKLOG_HIGH);
    *client.progress.lock().unwrap() = Instant::now() - STALL_DROP - Duration::from_secs(1);
  }
  // No broadcast, reply, new input, or disconnect is needed to release the
  // backlog. The production PTY poll loop performs the expiry itself.
  wait_until(|| ring.lock().unwrap().seq > before);
  let event = read(&mut healthy);
  assert_eq!(event["id"], terminal.id);
  assert_eq!(output(&event), b"AFTER-BACKLOG");
  assert_eq!(fixture.daemon.list()[0].pid, terminal.pid);
  assert_eq!(fixture.daemon.list()[0].id, terminal.id);
  assert!(fixture.daemon.clients.lock().unwrap().iter().all(|client| client.id != slow_id));

  // The surviving socket still carries ordered control replies and live output.
  writeln!(healthy.get_mut(), "{}", json!({"id":1,"op":"hello"})).unwrap();
  assert_eq!(read(&mut healthy)["ok"]["protocol"], PROTOCOL);
  fixture.daemon.write(&terminal.id, b"STILL-ALIVE").unwrap();
  assert_eq!(output(&read(&mut healthy)), b"STILL-ALIVE");
}

#[test]
fn a_scoped_client_hears_only_the_terminals_it_created_or_attached() {
  let mut fixture = Fixture::new();
  let (scoped_id, mut scoped) = fixture.connect();
  let (_, mut everything) = fixture.connect();
  assert_eq!(negotiate(&mut scoped, json!({"id":1,"op":"hello","eventScope":"attached"}))["eventScope"], "attached");
  assert_eq!(negotiate(&mut everything, json!({"id":1,"op":"hello"}))["eventScope"], "all");
  let own = fixture.echo_terminal(Some(scoped_id));
  let other = fixture.echo_terminal(None);

  // Once the other terminal's output has gone out, the scoped client's next frames show whether
  // it was sent any: it hears only its own.
  read_ready(&mut everything, 2);
  fixture.daemon.write(&own.id, b"OWN").unwrap();
  let heard = read_until(&mut scoped, output_of(&own.id, "OWN"));
  assert!(heard.iter().all(|frame| frame["id"] == own.id.as_str()), "{heard:?}");

  // Attaching adds a terminal, and its exit takes it away again.
  writeln!(scoped.get_mut(), "{}", json!({"id":2,"op":"attach","term":other.id})).unwrap();
  let attached = read_until(&mut scoped, |frame| frame["id"] == 2);
  assert_eq!(attached.last().unwrap()["ok"]["buf"], "READY");
  fixture.daemon.write(&other.id, b"OTHER").unwrap();
  read_until(&mut scoped, output_of(&other.id, "OTHER"));
  assert!(fixture.daemon.kill(&other.id));
  read_until(&mut scoped, |frame| frame["ev"] == "exit" && frame["id"] == other.id.as_str());
  wait_until(|| {
    let clients = fixture.daemon.clients.lock().unwrap();
    let client = clients.iter().find(|client| client.id == scoped_id).unwrap();
    client.terminals == HashSet::from([own.id.clone()])
  });
}

#[test]
fn narrowing_keeps_the_terminals_a_client_already_has() {
  let mut fixture = Fixture::new();
  let (id, mut narrowed) = fixture.connect();
  let (_, mut everything) = fixture.connect();
  let kept = fixture.echo_terminal(Some(id));
  let other = fixture.echo_terminal(None);
  read_ready(&mut everything, 2);

  // It hears every terminal up to the hello's reply, and from there on only the one it created.
  writeln!(narrowed.get_mut(), "{}", json!({"id":1,"op":"hello","eventScope":"attached"})).unwrap();
  let reply = read_until(&mut narrowed, |frame| frame["id"] == 1);
  assert_eq!(reply.last().unwrap()["ok"]["eventScope"], "attached");
  fixture.daemon.write(&other.id, b"OTHER").unwrap();
  read_until(&mut everything, output_of(&other.id, "OTHER"));
  fixture.daemon.write(&kept.id, b"KEPT").unwrap();
  let heard = read_until(&mut narrowed, output_of(&kept.id, "KEPT"));
  assert!(heard.iter().all(|frame| frame["id"] == kept.id.as_str()), "{heard:?}");
}

#[test]
fn a_scoped_client_that_stops_reading_holds_up_only_what_it_hears() {
  let mut fixture = Fixture::new();
  let (_, mut healthy) = fixture.connect();
  let (slow_id, mut slow) = fixture.connect();
  assert_eq!(negotiate(&mut slow, json!({"id":1,"op":"hello","eventScope":"attached"}))["eventScope"], "attached");
  let held = fixture.echo_terminal(Some(slow_id));
  let free = fixture.echo_terminal(None);
  read_ready(&mut healthy, 2);

  // The slow client, which never reads again, falls behind on the terminal it hears.
  let chunk = "x".repeat(BATCH_MAX_BYTES);
  let mut sequence = 0;
  while fixture.daemon.backlog(&held.id) <= BACKLOG_HIGH {
    sequence += 1;
    assert!(sequence < 100, "unread socket must accumulate bounded delivery debt");
    fixture.daemon.broadcast_output(&held.id, sequence, sequence, chunk.as_bytes(), &chunk);
    assert_eq!(read(&mut healthy)["seq"], sequence);
  }
  assert!(fixture.daemon.backlog(&free.id) < BACKLOG_LOW, "a client does not owe what it does not hear");

  // Wake both terminals so each weighs its own viewers' backlog before the input comes back.
  let rings = [&held, &free].map(|terminal| fixture.daemon.terms.lock().unwrap()[&terminal.id].ring.clone());
  let before = rings[0].lock().unwrap().seq;
  for terminal in [&held, &free] { fixture.daemon.flow(slow_id, &terminal.id, true); }
  fixture.daemon.write(&held.id, b"HELD").unwrap();
  fixture.daemon.write(&free.id, b"FREE").unwrap();
  std::thread::sleep(Duration::from_millis(100));
  for terminal in [&held, &free] { fixture.daemon.flow(slow_id, &terminal.id, false); }
  read_until(&mut healthy, output_of(&free.id, "FREE"));
  std::thread::sleep(Duration::from_millis(100));
  assert_eq!(rings[0].lock().unwrap().seq, before, "the slow client's debt pauses what it hears");
}
