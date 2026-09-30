import CryptoKit
import Foundation
import Testing

// The mirror against a store that records what it is given and a host that stands in for the app.
// No CloudKit: `RemoteMirror` is built with `available: true` and a factory that hands it the fake.

/// Records saves and deletes, and lets a test play the phone or another Mac by pushing records in.
actor FakeRemoteStore: RemoteStoring {
    nonisolated let events: AsyncStream<RemoteSyncEvent>
    private let continuation: AsyncStream<RemoteSyncEvent>.Continuation
    private(set) var saved: [String: RemoteEntry]
    /// Every change in the order it arrived: `save:<record name>` or `delete:<record name>`.
    private(set) var log: [String] = []
    private(set) var started = false
    private(set) var stopped = false
    private(set) var sends = 0
    /// What `hasUnsent()` answers: true plays a store that could not reach the server.
    private var unsent = false

    init(entries: [String: RemoteEntry] = [:]) {
        saved = entries
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() { started = true }
    func stop() { stopped = true; continuation.finish() }
    func entries() -> [String: RemoteEntry] { saved }
    func save<T: RemotePayload>(_ value: T) throws {
        guard !stopped else { return }
        saved[value.recordName] = try RemoteCodec.entry(value)
        log.append("save:\(value.recordName)")
    }
    func save(_ entry: RemoteEntry, named name: String) {
        guard !stopped else { return }
        saved[name] = entry
        log.append("save:\(name)")
    }
    func delete(_ name: String) {
        guard !stopped else { return }
        saved[name] = nil
        log.append("delete:\(name)")
    }
    func fetchNow() {}
    func sendNow() { sends += 1 }
    func hasUnsent() -> Bool { unsent }
    func setUnsent(_ value: Bool) { unsent = value }

    /// A record arriving from the server, as the phone or another Mac wrote it.
    func push<T: RemotePayload>(_ value: T) throws {
        let entry = try RemoteCodec.entry(value)
        saved[value.recordName] = entry
        continuation.yield(.changed(saved: [value.recordName: entry], deleted: []))
    }
    nonisolated func emit(_ event: RemoteSyncEvent) { continuation.yield(event) }

    func value<T: RemotePayload>(_: T.Type, _ name: String) -> T? { saved[name]?.decode(T.self) }
    func saves(of name: String) -> Int { log.filter { $0 == "save:\(name)" }.count }
    func names(_ type: RemoteRecordType) -> [String] { saved.filter { $0.value.type == type }.keys.sorted() }
    /// The log without the Mac's own host record, which every start and approval writes.
    func changes() -> [String] { log.filter { !$0.contains(":host:") } }
}

@MainActor final class FakeRemoteHost: RemoteMirrorHost {
    var sources: [RemoteSource] = []
    /// Each session's transcript, by session ID.
    var transcripts: [String: AgentTranscript] = [:]
    /// Reads that returned turns, not just an unchanged revision.
    private(set) var fullReads = 0
    private(set) var watches = 0
    private(set) var delivered: [(text: String, session: String)] = []
    private(set) var answered: [(id: String, allow: Bool)] = []
    var deliverError: (any Error)?
    /// While true a delivery waits, as it does for an agent that is busy, until `finishDeliveries()`.
    var holdsDeliveries = false
    /// While true a delivered message's turn is not heard to begin until `hearTurns()`.
    var holdsTurnStarts = false
    private(set) var turnStartsWaiting = 0
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var deliveriesWaiting = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var open: Set<String> = []
    private(set) var released = 0

    func remoteSources() -> [RemoteSource] { sources }

    func remoteTranscript(_ source: RemoteSource, since: String?) async throws -> AgentTranscript {
        guard let transcript = transcripts[source.id] else { return AgentTranscript(revision: "", turns: [], hooks: nil) }
        if transcript.revision == since { return AgentTranscript(revision: transcript.revision, turns: nil, hooks: nil) }
        fullReads += 1
        return transcript
    }

    func remoteWatchAgents() async { watches += 1 }

    func remoteDeliver(_ text: String, to sessionID: String) async throws -> RemoteDelivery.TurnStart? {
        if holdsDeliveries {
            deliveriesWaiting += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        if let deliverError { throw deliverError }
        delivered.append((text, sessionID))
        guard holdsTurnStarts else { return nil }
        return { [weak self] in
            guard let self, self.holdsTurnStarts else { return }
            self.turnStartsWaiting += 1
            await withCheckedContinuation { self.turnWaiters.append($0) }
        }
    }

    func hearTurns() {
        holdsTurnStarts = false
        let waiting = turnWaiters
        turnWaiters = []
        waiting.forEach { $0.resume() }
    }

    func finishDeliveries() {
        holdsDeliveries = false
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    func remoteAnswer(permission id: String, allow: Bool) async throws { answered.append((id, allow)) }
    func remoteOpenPermissions() -> Set<String> { open }
    func remoteReleaseHeld() { released += 1 }
}

/// A phone: its signing key, the record it introduces itself with, and the commands it signs.
struct TestPhone {
    let key = P256.Signing.PrivateKey()
    var name = "Test iPhone"
    var publicKey: Data { key.publicKey.x963Representation }
    var id: String { RemoteSigning.deviceID(for: publicKey) }

    func device(lastSeen: Date = Date()) -> RemoteDevice {
        RemoteDevice(id: id, name: name, publicKey: publicKey, lastSeen: lastSeen)
    }

    /// A command as this phone would send it: its own device ID, a whole-millisecond time, signed.
    /// `shown` is the request as this phone displayed it, for an answer.
    func command(_ id: String, _ action: RemoteCommand.Action = .message, text: String? = nil, permission: String? = nil,
                 shown: RemotePermission? = nil, session: String = "s1", host: String, age: TimeInterval = 0) throws -> RemoteCommand {
        var command = RemoteCommand(id: id, session: session, host: host, action: action, text: text, permission: permission,
                                    shown: shown.map(RemoteSigning.digest), device: self.id,
                                    createdAt: RemoteSigning.now().addingTimeInterval(-age.rounded()))
        command.signature = try RemoteSigning.sign(command, with: key)
        return command
    }
}

/// A running mirror with its fakes and, unless asked otherwise, one phone approved on it and
/// lately open. `directory` is where it persists; a second mirror built on it sees what the first
/// left, as a relaunch does.
@MainActor struct RemoteFixture {
    let mirror: RemoteMirror
    let store: FakeRemoteStore
    let host: FakeRemoteHost
    let phone: TestPhone
    let directory: URL

    init(store: FakeRemoteStore = FakeRemoteStore(), host: FakeRemoteHost = FakeRemoteHost(),
         idle: @escaping () -> TimeInterval = { 0 }, phone: TestPhone = TestPhone(), approved: Bool = true,
         directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteMirrorSyncTests-\(UUID().uuidString)")) async throws {
        self.store = store
        self.host = host
        self.phone = phone
        self.directory = directory
        mirror = RemoteFixture.mirror(in: directory, idle: idle) { store }
        mirror.host = host
        mirror.setEnabled(true)
        await mirror.settle()
        if approved { try await approve(phone) }
    }

    static func mirror(in directory: URL, idle: @escaping () -> TimeInterval = { 0 },
                       store: @escaping @MainActor () -> FakeRemoteStore) -> RemoteMirror {
        RemoteMirror(dataDirectory: directory, available: true, idleSeconds: idle, hostName: "Test Mac", interval: nil,
                     makeStore: { _ in store() })
    }

    /// The phone introduces itself, and the Mac's owner allows it.
    func approve(_ phone: TestPhone, lastSeen: Date = Date()) async throws {
        try await store.push(phone.device(lastSeen: lastSeen))
        try #require(await eventually { mirror.pendingDevices.contains { $0.id == phone.id } })
        mirror.approve(phone.id)
        await mirror.settle()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func source(_ id: String = "s1", state: RemoteSession.State = .idle) -> RemoteSource {
        RemoteSource(id: id, title: "Fix the build", project: "Cascade", cli: "claude", worktree: "/tmp/\(id)",
                     conversation: nil, state: state)
    }

    func transcript(_ revision: String, turns ids: [String]) -> AgentTranscript {
        AgentTranscript(revision: revision, turns: ids.map { id in
            TranscriptTurn(id: id, role: .assistant, timestamp: nil, ended: nil, model: nil,
                           blocks: [TranscriptBlock(type: .text, text: "turn \(id)", id: nil, name: nil, summary: nil, command: nil,
                                                    path: nil, old: nil, new: nil, output: nil, isError: nil, kind: nil)])
        }, hooks: nil)
    }

    /// A message from the approved phone, signed.
    func message(_ id: String, _ text: String = "hello", session: String = "s1", host: String? = nil,
                 age: TimeInterval = 0) throws -> RemoteCommand {
        try phone.command(id, text: text, session: session, host: host ?? mirror.hostID, age: age)
    }

    func prompt(_ id: String, old: String? = nil, new: String? = nil, truncated: Bool = false) -> AgentPermissionPrompt {
        AgentPermissionPrompt(id: id, details: .init(tool: "Bash", kind: "run", detail: "ls -la", reason: "List files",
                                                     old: old, new: new, truncated: truncated))
    }
}

/// Polls until `condition` holds, for what arrives on the mirror's event stream a moment later.
@MainActor func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Hands a mirror whichever store a test has put in it, so a restart can meet a different one.
@MainActor final class StoreBox {
    var current: FakeRemoteStore
    init(_ store: FakeRemoteStore) { current = store }
}

@MainActor @Test func remoteMirrorSavesLiveSessionsAndTheirTurnsOnce() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    fixture.host.transcripts["s1"] = fixture.transcript("r1", turns: ["a", "b"])

    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.started)
    #expect(await fixture.store.names(.session) == ["session:s1"])
    #expect(await fixture.store.names(.turn) == ["turn:s1:a", "turn:s1:b"])
    let session = try #require(await fixture.store.value(RemoteSession.self, "session:s1"))
    #expect(session.host == fixture.mirror.hostID)
    #expect(session.hostName == "Test Mac")

    // Nothing changed: nothing is read whole or saved again.
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(fixture.host.fullReads == 1)
    #expect(await fixture.store.saves(of: "turn:s1:a") == 1)
    #expect(await fixture.store.saves(of: "session:s1") == 1)
}

@MainActor @Test func remoteMessageFromThePhoneIsDeliveredOnceAndMarked() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let command = try fixture.message("c1", "run the tests")
    try await fixture.store.push(command)
    // The same record fetched again must not be typed again.
    try await fixture.store.push(command)

    #expect(await eventually { fixture.host.delivered.count == 1 })
    await fixture.mirror.settle()
    #expect(fixture.host.delivered.map(\.text) == ["run the tests"])
    #expect(fixture.host.delivered.first?.session == "s1")
    let result = try #require(await fixture.store.value(RemoteCommand.self, "command:c1"))
    #expect(result.status == .delivered)
    #expect(result.message == nil)
}

@MainActor @Test func remoteMirrorLeavesAnotherMacsRecordsAlone() async throws {
    let other = "another-mac"
    let theirs = RemoteSession(id: "x1", title: "Theirs", project: nil, cli: "codex", state: .working, host: other,
                               hostName: "Other Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let store = FakeRemoteStore(entries: [theirs.recordName: try RemoteCodec.entry(theirs)])
    let fixture = try await RemoteFixture(store: store)
    defer { fixture.remove() }
    // A message addressed to the other Mac arrives here too: it is theirs to carry out.
    try await store.push(try fixture.message("c9", session: "x1", host: other))

    await fixture.mirror.tick()
    await fixture.mirror.settle()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.host.delivered.isEmpty)
    #expect(await store.value(RemoteSession.self, "session:x1") == theirs)
    #expect(await store.value(RemoteCommand.self, "command:c9")?.status == .pending)
    #expect(await store.changes().isEmpty)
}

@MainActor @Test func remoteMirrorTakesAnEndedSessionAndItsTurnsOut() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    fixture.host.transcripts["s1"] = fixture.transcript("r1", turns: ["a", "b"])
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.session) == ["session:s1"])

    fixture.host.sources = []
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.session).isEmpty)
    #expect(await fixture.store.names(.turn).isEmpty)
    let log = await fixture.store.log
    #expect(log.contains("delete:session:s1"))
    #expect(log.contains("delete:turn:s1:a"))
    #expect(log.contains("delete:turn:s1:b"))
}

@MainActor @Test func remoteMirrorReplacesTurnsThatLeftTheTranscript() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    fixture.host.transcripts["s1"] = fixture.transcript("r1", turns: ["a", "b"])
    await fixture.mirror.tick()
    await fixture.mirror.settle()

    fixture.host.transcripts["s1"] = fixture.transcript("r2", turns: ["b", "c"])
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.turn) == ["turn:s1:b", "turn:s1:c"])
    let log = await fixture.store.log
    #expect(log.contains("delete:turn:s1:a"))
    #expect(log.contains("save:turn:s1:c"))
    #expect(await fixture.store.saves(of: "turn:s1:b") == 1)
}

@MainActor @Test func remoteExpiredMessageIsNeverDelivered() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    try await fixture.store.push(try fixture.message("c1", age: RemoteSchema.commandLifetime + 30))

    #expect(await eventually { await fixture.store.value(RemoteCommand.self, "command:c1")?.status == .failed })
    await fixture.mirror.settle()
    #expect(fixture.host.delivered.isEmpty)
    let result = try #require(await fixture.store.value(RemoteCommand.self, "command:c1"))
    #expect(!(result.message ?? "").isEmpty)
}

@MainActor @Test func remoteMessagesAreDeliveredInOrderOneAtATime() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.holdsDeliveries = true
    try await fixture.store.push(try fixture.message("c1", "first"))
    try await fixture.store.push(try fixture.message("c2", "second"))

    #expect(await eventually { fixture.host.deliveriesWaiting == 1 })
    #expect(fixture.host.delivered.isEmpty)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.host.deliveriesWaiting == 1)
    #expect(fixture.host.delivered.isEmpty)

    fixture.host.finishDeliveries()
    #expect(await eventually { fixture.host.delivered.count == 2 })
    await fixture.mirror.settle()
    #expect(fixture.host.delivered.map(\.text) == ["first", "second"])
    #expect(await fixture.store.value(RemoteCommand.self, "command:c1")?.status == .delivered)
    #expect(await fixture.store.value(RemoteCommand.self, "command:c2")?.status == .delivered)
}

@MainActor @Test func remoteFailedDeliveryMarksTheCommandWithItsReason() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.deliverError = RemoteCommandError("The agent stayed busy")
    try await fixture.store.push(try fixture.message("c1"))

    #expect(await eventually { await fixture.store.value(RemoteCommand.self, "command:c1")?.status == .failed })
    await fixture.mirror.settle()
    let result = try #require(await fixture.store.value(RemoteCommand.self, "command:c1"))
    #expect(result.message == "The agent stayed busy")
    #expect(fixture.host.delivered.isEmpty)
}

@MainActor @Test func remoteAllowAndDenyAnswerTheRequest() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.open = ["p1"]
    fixture.mirror.offer(fixture.prompt("p1"), session: "s1")
    await fixture.mirror.settle()
    // The phone answers what it was shown: the request as the Mac offered it.
    let shown = try #require(await fixture.store.value(RemotePermission.self, "permission:p1"))
    for (id, action) in [("a1", RemoteCommand.Action.allow), ("d1", .deny)] {
        try await fixture.store.push(try fixture.phone.command(id, action, permission: "p1", shown: shown, host: fixture.mirror.hostID))
    }

    #expect(await eventually { fixture.host.answered.count == 2 })
    await fixture.mirror.settle()
    #expect(fixture.host.answered.map(\.id) == ["p1", "p1"])
    #expect(fixture.host.answered.map(\.allow) == [true, false])
    #expect(await fixture.store.value(RemoteCommand.self, "command:a1")?.status == .delivered)
    #expect(await fixture.store.value(RemoteCommand.self, "command:d1")?.status == .delivered)
}

@MainActor @Test func remoteOfferedRequestIsSavedAndWithdrawnInOrder() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let prompt = AgentPermissionPrompt(id: "p1", details: .init(tool: "Bash", kind: "run", detail: "ls -la", reason: "List files",
                                                                old: nil, new: nil, truncated: false))
    fixture.mirror.offer(prompt, session: "s1")
    await fixture.mirror.settle()
    let saved = try #require(await fixture.store.value(RemotePermission.self, "permission:p1"))
    #expect(saved.id == "p1")
    #expect(saved.session == "s1")
    #expect(saved.host == fixture.mirror.hostID)
    #expect(saved.tool == "Bash")
    #expect(saved.kind == "run")
    #expect(saved.detail == "ls -la")
    #expect(saved.reason == "List files")
    #expect(!saved.truncated)

    fixture.mirror.withdraw("p1")
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.permission).isEmpty)

    // Withdrawn at once, it still arrives after it was offered.
    let quick = AgentPermissionPrompt(id: "p2", details: .init(tool: "Bash", detail: "pwd", reason: "Where am I"))
    fixture.mirror.offer(quick, session: "s1")
    fixture.mirror.withdraw("p2")
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.permission).isEmpty)
    #expect(await fixture.store.changes().filter { $0.contains(":permission:") } == ["save:permission:p1", "delete:permission:p1", "save:permission:p2", "delete:permission:p2"])
}

@MainActor @Test func remoteMirrorDropsRequestsThatAreNoLongerOpen() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    fixture.host.open = ["p1", "p2"]
    for id in ["p1", "p2"] { fixture.mirror.offer(fixture.prompt(id), session: "s1") }
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.permission) == ["permission:p1", "permission:p2"])

    // The second was answered, or lost with a restart the app never heard end.
    fixture.host.open = ["p1"]
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.permission) == ["permission:p1"])
    #expect(await fixture.store.log.contains("delete:permission:p2"))
    #expect(!(await fixture.store.log.contains("delete:permission:p1")))
}

@MainActor @Test func remoteApprovalsAreHeldOnlyWhileAwayAndSyncing() async throws {
    let present = try await RemoteFixture(idle: { 0 })
    defer { present.remove() }
    #expect(!present.mirror.holdsApprovals)

    let away = try await RemoteFixture(idle: { 10_000 })
    defer { away.remove() }
    #expect(away.mirror.holdsApprovals)

    away.store.emit(.failed("x"))
    #expect(await eventually { away.mirror.status == .failed("x") })
    #expect(!away.mirror.holdsApprovals)

    away.store.emit(.synced(Date()))
    #expect(await eventually { away.mirror.holdsApprovals })
}

@MainActor @Test func remoteAccountResetReleasesApprovalsAndStaysFailed() async throws {
    let fixture = try await RemoteFixture(idle: { 10_000 })
    defer { fixture.remove() }
    #expect(fixture.mirror.holdsApprovals)

    fixture.store.emit(.reset)
    #expect(await eventually { fixture.host.released >= 1 })
    await fixture.mirror.settle()
    guard case .failed = fixture.mirror.status else {
        Issue.record("Expected .failed, got \(fixture.mirror.status)")
        return
    }
    #expect(!fixture.mirror.holdsApprovals)
    #expect(await fixture.store.stopped)

    fixture.mirror.resume()
    await fixture.mirror.settle()
    guard case .failed = fixture.mirror.status else {
        Issue.record("An account change must not restart by itself, got \(fixture.mirror.status)")
        return
    }

    fixture.mirror.setEnabled(false)
    await fixture.mirror.settle()
    #expect(fixture.mirror.status == .off)
}

@MainActor @Test func remoteTurningOffTakesOnlyThisMacsRecordsOut() async throws {
    let theirs = RemoteSession(id: "x1", title: "Theirs", project: nil, cli: "codex", state: .working, host: "another-mac",
                               hostName: "Other Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let store = FakeRemoteStore(entries: [theirs.recordName: try RemoteCodec.entry(theirs)])
    let fixture = try await RemoteFixture(store: store)
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    fixture.host.transcripts["s1"] = fixture.transcript("r1", turns: ["a"])
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await store.names(.session) == ["session:s1", "session:x1"])

    fixture.mirror.setEnabled(false)
    await fixture.mirror.settle()
    #expect(await store.names(.session) == ["session:x1"])
    #expect(await store.names(.turn).isEmpty)
    #expect(await store.value(RemoteSession.self, "session:x1") == theirs)
    #expect(await store.stopped)
    #expect(fixture.mirror.status == .off)
    #expect(fixture.host.released >= 1)
}

@MainActor @Test func remoteRestartDuringDeliveryTypesTheMessageOnce() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteMirrorSyncTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = FakeRemoteStore()
    let box = StoreBox(first)
    let host = FakeRemoteHost()
    let mirror = RemoteFixture.mirror(in: directory) { box.current }
    mirror.host = host
    host.holdsDeliveries = true
    mirror.setEnabled(true)
    await mirror.settle()

    let phone = TestPhone()
    try await first.push(phone.device())
    try #require(await eventually { mirror.pendingDevices.contains { $0.id == phone.id } })
    mirror.approve(phone.id)
    await mirror.settle()

    let command = try phone.command("c1", text: "run the tests", host: mirror.hostID)
    try await first.push(command)
    #expect(await eventually { host.deliveriesWaiting == 1 })

    await mirror.stop()
    let second = FakeRemoteStore(entries: [command.recordName: try RemoteCodec.entry(command)])
    box.current = second
    mirror.resume()
    // Not `settle()`: that waits for the delivery still held, which is what this test finishes next.
    #expect(await eventually { await second.started })
    #expect(host.deliveriesWaiting == 1)

    host.finishDeliveries()
    #expect(await eventually { host.delivered.count == 1 })
    await mirror.settle()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(host.delivered.map(\.text) == ["run the tests"])
    #expect(host.deliveriesWaiting == 1)
    #expect(await second.value(RemoteCommand.self, "command:c1")?.status == .delivered)
    await mirror.stop()
}

@MainActor @Test func remoteCommandBegunBeforeARelaunchIsNotTypedAgain() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.holdsDeliveries = true
    let command = try fixture.message("c1", "run the tests")
    try await fixture.store.push(command)
    #expect(await eventually { fixture.host.deliveriesWaiting == 1 })

    let store = FakeRemoteStore(entries: [command.recordName: try RemoteCodec.entry(command)])
    let host = FakeRemoteHost()
    let relaunched = RemoteFixture.mirror(in: fixture.directory) { store }
    relaunched.host = host
    #expect(relaunched.hostID == fixture.mirror.hostID)
    // The first mirror left it turned on, so the relaunch starts on its own account of that.
    relaunched.resume()
    await relaunched.settle()

    #expect(host.delivered.isEmpty)
    let result = try #require(await store.value(RemoteCommand.self, "command:c1"))
    #expect(result.status == .failed)
    #expect(!(result.message ?? "").isEmpty)

    fixture.host.finishDeliveries()
    await fixture.mirror.settle()
    await relaunched.stop()
}

/// Waits for the command to be marked failed with a reason, and checks nothing was typed or answered.
@MainActor private func expectRefused(_ id: String, in fixture: RemoteFixture) async throws {
    #expect(await eventually { await fixture.store.value(RemoteCommand.self, "command:\(id)")?.status == .failed })
    await fixture.mirror.settle()
    #expect(fixture.host.delivered.isEmpty)
    #expect(fixture.host.answered.isEmpty)
    let result = try #require(await fixture.store.value(RemoteCommand.self, "command:\(id)"))
    #expect(result.status == .failed)
    #expect(!(result.message ?? "").isEmpty)
}

@MainActor @Test func remoteMessageFromAPhoneThatIsNotApprovedIsRefused() async throws {
    let fixture = try await RemoteFixture(approved: false)
    defer { fixture.remove() }
    try await fixture.store.push(fixture.phone.device())
    try await fixture.store.push(try fixture.message("c1"))
    try await expectRefused("c1", in: fixture)
}

@MainActor @Test func remoteMessageChangedAfterSigningIsRefused() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    var command = try fixture.message("c1", "hello")
    command.text = "rm -rf"
    try await fixture.store.push(command)
    try await expectRefused("c1", in: fixture)
}

@MainActor @Test func remoteCommandSignedByAnotherKeyIsRefused() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let impostor = TestPhone()
    var command = try impostor.command("c1", text: "hello", host: fixture.mirror.hostID)
    command.device = fixture.phone.id
    command.signature = try RemoteSigning.sign(command, with: impostor.key)
    try await fixture.store.push(command)
    try await expectRefused("c1", in: fixture)
}

@MainActor @Test func remoteDeviceRecordNotMatchingItsKeyIsNeverOffered() async throws {
    let fixture = try await RemoteFixture(approved: false)
    defer { fixture.remove() }
    let other = TestPhone()
    try await fixture.store.push(RemoteDevice(id: "bogus", name: "Bogus", publicKey: fixture.phone.publicKey, lastSeen: Date()))
    // Events arrive in order: once this one is pending the bogus record has been received.
    try await fixture.store.push(other.device())
    #expect(await eventually { fixture.mirror.pendingDevices.contains { $0.id == other.id } })
    #expect(!fixture.mirror.pendingDevices.contains { $0.id == "bogus" })
}

@MainActor @Test func remoteApprovalIsPublishedAndTakenBack() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let name = RemoteHost.recordName(fixture.mirror.hostID)
    #expect(await fixture.store.value(RemoteHost.self, name)?.approved == [fixture.phone.id])

    fixture.mirror.remove(fixture.phone.id)
    await fixture.mirror.settle()
    #expect(await fixture.store.value(RemoteHost.self, name)?.approved == [])

    try await fixture.store.push(try fixture.message("c1"))
    try await expectRefused("c1", in: fixture)
}

@MainActor @Test func remoteConversationsStayOnTheMacWithNoPhoneLatelyOpen() async throws {
    let fixture = try await RemoteFixture(approved: false)
    defer { fixture.remove() }
    try await fixture.approve(fixture.phone, lastSeen: Date().addingTimeInterval(-2 * RemoteSchema.phoneActive))
    fixture.host.sources = [fixture.source()]
    fixture.host.transcripts["s1"] = fixture.transcript("r1", turns: ["a", "b"])

    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.names(.session) == ["session:s1"])
    #expect(await fixture.store.names(.turn).isEmpty)
    #expect(fixture.host.fullReads == 0)

    try await fixture.store.push(fixture.phone.device())
    #expect(await eventually {
        await fixture.mirror.tick()
        await fixture.mirror.settle()
        return await fixture.store.names(.turn) == ["turn:s1:a", "turn:s1:b"]
    })
}

@MainActor @Test func remoteOfferedFileChangeIsSavedWholeOrMarkedTooLong() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.mirror.offer(fixture.prompt("p1", old: "before", new: "after"), session: "s1")
    await fixture.mirror.settle()
    let whole = try #require(await fixture.store.value(RemotePermission.self, "permission:p1"))
    #expect(whole.old == "before")
    #expect(whole.new == "after")
    #expect(!whole.truncated)

    fixture.mirror.offer(fixture.prompt("p2", old: "before", new: String(repeating: "x", count: RemoteSchema.maxChange + 1)), session: "s1")
    await fixture.mirror.settle()
    let cut = try #require(await fixture.store.value(RemotePermission.self, "permission:p2"))
    #expect(cut.old == nil)
    #expect(cut.new == nil)
    #expect(cut.truncated)
}

@MainActor @Test func remoteAllowForATruncatedRequestIsRefusedButDenyIsCarriedOut() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.open = ["p1"]
    fixture.mirror.offer(fixture.prompt("p1", truncated: true), session: "s1")
    await fixture.mirror.settle()

    try await fixture.store.push(try fixture.phone.command("a1", .allow, permission: "p1", host: fixture.mirror.hostID))
    try await expectRefused("a1", in: fixture)

    try await fixture.store.push(try fixture.phone.command("d1", .deny, permission: "p1", host: fixture.mirror.hostID))
    #expect(await eventually { fixture.host.answered.count == 1 })
    await fixture.mirror.settle()
    #expect(fixture.host.answered.first?.id == "p1")
    #expect(fixture.host.answered.first?.allow == false)
    #expect(await fixture.store.value(RemoteCommand.self, "command:d1")?.status == .delivered)
}

@MainActor @Test func remoteApprovalsAreNotHeldWithNoApprovedPhone() async throws {
    let fixture = try await RemoteFixture(idle: { 10_000 }, approved: false)
    defer { fixture.remove() }
    #expect(!fixture.mirror.holdsApprovals)
}

@MainActor @Test func remoteHostIDBelongsToTheDataDirectory() async throws {
    let first = try await RemoteFixture()
    defer { first.remove() }
    let second = try await RemoteFixture()
    defer { second.remove() }
    #expect(first.mirror.hostID != second.mirror.hostID)

    let again = RemoteFixture.mirror(in: first.directory) { first.store }
    #expect(again.hostID == first.mirror.hostID)
}

@MainActor @Test func remoteTurningOffWithUnsentChangesLeavesTheDebtForNextTime() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let mine = RemoteSession(id: "s1", title: "Fix the build", project: nil, cli: "claude", state: .idle,
                             host: fixture.mirror.hostID, hostName: "Test Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    await fixture.store.setUnsent(true)
    fixture.mirror.setEnabled(false)
    await fixture.mirror.settle()
    #expect(fixture.mirror.status == .off)

    let next = FakeRemoteStore(entries: [mine.recordName: try RemoteCodec.entry(mine)])
    let relaunched = RemoteFixture.mirror(in: fixture.directory) { next }
    relaunched.resume()
    await relaunched.settle()
    #expect(await next.names(.session).isEmpty)
    #expect(await next.log.contains("delete:session:s1"))
    #expect(relaunched.status == .off)
}

@MainActor @Test func remoteEveryTickWatchesTheAgents() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let before = fixture.host.watches
    await fixture.mirror.tick()
    #expect(fixture.host.watches == before + 1)
    await fixture.mirror.tick()
    #expect(fixture.host.watches == before + 2)
}

/// Whether the fake iCloud can be reached.
@MainActor private final class Reach {
    var up = false
}

@MainActor @Test func remoteMirrorSaysICloudIsUnreachableAndStartsWhenItIsBack() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteMirrorSyncTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FakeRemoteStore()
    let reach = Reach()
    let mirror = RemoteMirror(dataDirectory: directory, available: true, idleSeconds: { 0 }, hostName: "Test Mac", interval: nil,
                              makeStore: { _ in
                                  guard reach.up else { throw RemoteUnavailable("iCloud can’t be reached.", retries: true) }
                                  return store
                              })
    mirror.setEnabled(true)
    await mirror.settle()
    #expect(mirror.status == .unavailable("iCloud can’t be reached."))
    #expect(!(await store.started))

    // What the retry timer and the account-change notice both do.
    reach.up = true
    mirror.resume()
    await mirror.settle()
    #expect(await store.started)
    guard case .syncing = mirror.status else {
        Issue.record("Expected syncing once iCloud is back, got \(mirror.status)")
        return
    }
    await mirror.stop()
}

@MainActor @Test func remoteTurningOffWithNothingRunningOwesTheClearing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteMirrorSyncTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let reach = Reach()
    let store = FakeRemoteStore()
    let mirror = RemoteMirror(dataDirectory: directory, available: true, idleSeconds: { 0 }, hostName: "Test Mac", interval: nil,
                              makeStore: { _ in
                                  guard reach.up else { throw RemoteUnavailable("Sign in to iCloud.") }
                                  return store
                              })
    let mine = RemoteSession(id: "s1", title: "Left behind", project: nil, cli: "claude", state: .idle, host: mirror.hostID,
                             hostName: "Test Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await store.push(mine)

    // On, but signed out: nothing runs, so turning it off cannot take the records out.
    mirror.setEnabled(true)
    await mirror.settle()
    mirror.setEnabled(false)
    await mirror.settle()
    #expect(mirror.status == .off)
    #expect(await store.names(.session) == ["session:s1"])

    // Signed in again, still off: the next chance clears what was owed.
    reach.up = true
    mirror.resume()
    await mirror.settle()
    #expect(await store.names(.session).isEmpty)
    #expect(mirror.status == .off)
    #expect(!mirror.enabled)
}

@MainActor @Test func remoteAllowIsJudgedByWhatTheMacOfferedNotWhatICloudHolds() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.open = ["p1"]
    fixture.mirror.offer(fixture.prompt("p1", old: "let a = 1", new: "try! FileManager.default.removeItem(atPath: home)"), session: "s1")
    await fixture.mirror.settle()
    let real = try #require(await fixture.store.value(RemotePermission.self, "permission:p1"))

    // Something else on the account writes over the request, so the phone shows a harmless one.
    var forged = real
    forged.detail = "ls"
    forged.old = nil
    forged.new = nil
    try await fixture.store.push(forged)
    // The Mac puts its own back.
    #expect(await eventually { await fixture.store.value(RemotePermission.self, "permission:p1") == real })

    // An Allow given on the forged card is for something the Mac never asked.
    try await fixture.store.push(try fixture.phone.command("a1", .allow, permission: "p1", shown: forged, host: fixture.mirror.hostID))
    try await expectRefused("a1", in: fixture)
    // And one that names no card at all.
    try await fixture.store.push(try fixture.phone.command("a2", .allow, permission: "p1", host: fixture.mirror.hostID))
    try await expectRefused("a2", in: fixture)
    #expect(fixture.host.answered.isEmpty)

    try await fixture.store.push(try fixture.phone.command("a3", .allow, permission: "p1", shown: real, host: fixture.mirror.hostID))
    #expect(await eventually { fixture.host.answered.count == 1 })
    #expect(fixture.host.answered.first?.allow == true)
}

@MainActor @Test func remoteForgedTruncationCannotBeUndoneFromICloud() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.open = ["p1"]
    fixture.mirror.offer(fixture.prompt("p1", new: String(repeating: "x", count: RemoteSchema.maxChange + 1)), session: "s1")
    await fixture.mirror.settle()
    let real = try #require(await fixture.store.value(RemotePermission.self, "permission:p1"))
    #expect(real.truncated)

    var forged = real
    forged.truncated = false
    try await fixture.store.push(forged)
    try await fixture.store.push(try fixture.phone.command("a1", .allow, permission: "p1", shown: forged, host: fixture.mirror.hostID))
    try await expectRefused("a1", in: fixture)
    #expect(fixture.host.answered.isEmpty)
    #expect(await eventually { await fixture.store.value(RemotePermission.self, "permission:p1") == real })
}

@MainActor @Test func remoteRecordsWrittenUnderThisMacsNameAreTakenOutAgain() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    let real = try #require(await fixture.store.value(RemoteSession.self, "session:s1"))

    // A session this Mac never had, and its own session renamed.
    let planted = RemoteSession(id: "ghost", title: "Not mine", project: nil, cli: "claude", state: .idle,
                                host: fixture.mirror.hostID, hostName: "Test Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    var renamed = real
    renamed.title = "Renamed by someone else"
    try await fixture.store.push(planted)
    try await fixture.store.push(renamed)

    #expect(await eventually { await fixture.store.names(.session) == ["session:s1"] })
    #expect(await eventually { await fixture.store.value(RemoteSession.self, "session:s1") == real })
    // And one deleted from under it comes back.
    fixture.store.emit(.changed(saved: [:], deleted: ["session:s1"]))
    #expect(await eventually { await fixture.store.saves(of: "session:s1") >= 3 })
}

@MainActor @Test func remoteAccountChangeStaysStoppedAcrossARelaunch() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.store.emit(.reset)
    #expect(await eventually { fixture.host.released >= 1 })
    await fixture.mirror.settle()

    let next = FakeRemoteStore()
    let relaunched = RemoteFixture.mirror(in: fixture.directory) { next }
    guard case .failed = relaunched.status else {
        Issue.record("A relaunch must still say the account changed, got \(relaunched.status)")
        return
    }
    relaunched.resume()
    await relaunched.settle()
    #expect(!(await next.started))
    guard case .failed = relaunched.status else {
        Issue.record("Expected .failed after resume, got \(relaunched.status)")
        return
    }

    // Turned off and on: the owner has now asked for the account signed in.
    relaunched.setEnabled(false)
    await relaunched.settle()
    relaunched.setEnabled(true)
    await relaunched.settle()
    #expect(await next.started)
    await relaunched.stop()
}

@MainActor @Test func remoteMirrorCarriesOnAfterItsZoneIsDeleted() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.saves(of: "session:s1") == 1)

    let host = RemoteHost.recordName(fixture.mirror.hostID)
    let published = await fixture.store.saves(of: host)
    fixture.store.emit(.cleared)
    // The Mac says again who it is and which phones it allows: the clearing has been received.
    #expect(await eventually { await fixture.store.saves(of: host) == published + 1 })
    await fixture.mirror.tick()
    await fixture.mirror.settle()
    #expect(await fixture.store.saves(of: "session:s1") == 2)
    guard case .syncing = fixture.mirror.status else {
        Issue.record("A deleted zone is not an account change, got \(fixture.mirror.status)")
        return
    }
}

@MainActor @Test func remoteDeniedPhoneCanBeAskedAgain() async throws {
    let fixture = try await RemoteFixture(approved: false)
    defer { fixture.remove() }
    try await fixture.store.push(fixture.phone.device())
    #expect(await eventually { fixture.mirror.pendingDevices.count == 1 })

    fixture.mirror.deny(fixture.phone.id)
    await fixture.mirror.settle()
    #expect(fixture.mirror.pendingDevices.isEmpty)
    #expect(fixture.mirror.deniedDevices.map(\.id) == [fixture.phone.id])
    let host = try #require(await fixture.store.value(RemoteHost.self, RemoteHost.recordName(fixture.mirror.hostID)))
    #expect(host.denied == [fixture.phone.id])
    #expect(host.approved.isEmpty)

    fixture.mirror.askAgain(fixture.phone.id)
    await fixture.mirror.settle()
    #expect(fixture.mirror.deniedDevices.isEmpty)
    #expect(fixture.mirror.pendingDevices.map(\.id) == [fixture.phone.id])
    #expect(RemoteSettingsViewModel(mirror: fixture.mirror).waiting.first?.code == RemoteSigning.code(for: fixture.phone.id))
}

@MainActor @Test func remoteResultIsWrittenBeforeTheNextMessageWaitsForTheTurn() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.holdsTurnStarts = true
    try await fixture.store.push(try fixture.message("c1", "first"))
    try await fixture.store.push(try fixture.message("c2", "second"))

    // The first is sent and says so, while its turn has not been heard to begin.
    #expect(await eventually { await fixture.store.value(RemoteCommand.self, "command:c1")?.status == .delivered })
    #expect(await eventually { fixture.host.turnStartsWaiting == 1 })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.host.delivered.map(\.text) == ["first"])
    #expect(await fixture.store.value(RemoteCommand.self, "command:c2")?.status == .pending)

    fixture.host.hearTurns()
    #expect(await eventually { fixture.host.delivered.count == 2 })
    await fixture.mirror.settle()
    #expect(await fixture.store.value(RemoteCommand.self, "command:c2")?.status == .delivered)
}

@MainActor @Test func remoteSettingsWillNotAllowAPhoneWhoseCodeAnotherShows() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    let model = RemoteSettingsViewModel(mirror: fixture.mirror)
    let allowed = try #require(model.approved.first)
    #expect(!model.clashes(allowed))
    // Codes are the start of the ID, so two phones with one code are two IDs with one start.
    let twin = RemoteSettingsViewModel.Phone(id: String(allowed.id.prefix(12)) + "ffffffffffffffffffff", name: allowed.name)
    #expect(twin.code == allowed.code)
    #expect(model.clashes(twin))
    model.approve(twin)
    await fixture.mirror.settle()
    #expect(fixture.mirror.approvedDevices.map(\.id) == [fixture.phone.id])
}

@MainActor @Test func remoteCommandUnderAnotherRecordsNameIsNotTakenForOne() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.open = ["p1"]
    fixture.mirror.offer(fixture.prompt("p1"), session: "s1")
    await fixture.mirror.settle()
    let real = try #require(await fixture.store.value(RemotePermission.self, "permission:p1"))

    // Something writes a command where the request is, to take the card off the phone.
    let planted = try RemoteCodec.entry(try fixture.message("c1", "hello"))
    fixture.store.emit(.changed(saved: ["permission:p1": planted], deleted: []))
    #expect(await eventually { await fixture.store.saves(of: "permission:p1") == 2 })
    #expect(await fixture.store.value(RemotePermission.self, "permission:p1") == real)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.host.delivered.isEmpty)
}
