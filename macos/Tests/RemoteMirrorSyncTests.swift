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
    func delete(_ name: String) {
        guard !stopped else { return }
        saved[name] = nil
        log.append("delete:\(name)")
    }
    func fetchNow() {}
    func sendNow() { sends += 1 }

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
}

@MainActor final class FakeRemoteHost: RemoteMirrorHost {
    var sources: [RemoteSource] = []
    /// Each session's transcript, by session ID.
    var transcripts: [String: AgentTranscript] = [:]
    /// Reads that returned turns, not just an unchanged revision.
    private(set) var fullReads = 0
    private(set) var delivered: [(text: String, session: String)] = []
    private(set) var answered: [(id: String, allow: Bool)] = []
    var deliverError: (any Error)?
    /// While true a delivery waits, as it does for an agent that is busy, until `finishDeliveries()`.
    var holdsDeliveries = false
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

    func remoteDeliver(_ text: String, to sessionID: String) async throws {
        if holdsDeliveries {
            deliveriesWaiting += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        if let deliverError { throw deliverError }
        delivered.append((text, sessionID))
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

/// A running mirror with its fakes. `defaults` is the suite it persists in; a test that builds a
/// second mirror on it sees what the first one left.
@MainActor struct RemoteFixture {
    let mirror: RemoteMirror
    let store: FakeRemoteStore
    let host: FakeRemoteHost
    let defaults: UserDefaults
    let suite: String

    init(store: FakeRemoteStore = FakeRemoteStore(), host: FakeRemoteHost = FakeRemoteHost(),
         idle: @escaping () -> TimeInterval = { 0 }, suite: String = "RemoteMirrorSyncTests-\(UUID().uuidString)") async throws {
        self.store = store
        self.host = host
        self.suite = suite
        defaults = try #require(UserDefaults(suiteName: suite))
        mirror = RemoteMirror(defaults: defaults, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
                              available: true, idleSeconds: idle, hostName: "Test Mac", interval: nil,
                              makeStore: { _ in store })
        mirror.host = host
        mirror.setEnabled(true)
        await mirror.settle()
    }

    func remove() { defaults.removePersistentDomain(forName: suite) }

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

    func message(_ id: String, _ text: String = "hello", session: String = "s1", host: String? = nil,
                 age: TimeInterval = 0) -> RemoteCommand {
        RemoteCommand(id: id, session: session, host: host ?? mirror.hostID, action: .message, text: text,
                      device: "iPhone", createdAt: Date().addingTimeInterval(-age))
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
    let command = fixture.message("c1", "run the tests")
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
    try await store.push(fixture.message("c9", session: "x1", host: other))

    await fixture.mirror.tick()
    await fixture.mirror.settle()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.host.delivered.isEmpty)
    #expect(await store.value(RemoteSession.self, "session:x1") == theirs)
    #expect(await store.value(RemoteCommand.self, "command:c9")?.status == .pending)
    #expect(await store.log.isEmpty)
}

/// Hands a mirror whichever store a test has put in it, so a restart can meet a different one.
@MainActor final class StoreBox {
    var current: FakeRemoteStore
    init(_ store: FakeRemoteStore) { current = store }
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
    try await fixture.store.push(fixture.message("c1", age: RemoteSchema.commandLifetime + 30))

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
    try await fixture.store.push(fixture.message("c1", "first"))
    try await fixture.store.push(fixture.message("c2", "second"))

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
    try await fixture.store.push(fixture.message("c1"))

    #expect(await eventually { await fixture.store.value(RemoteCommand.self, "command:c1")?.status == .failed })
    await fixture.mirror.settle()
    let result = try #require(await fixture.store.value(RemoteCommand.self, "command:c1"))
    #expect(result.message == "The agent stayed busy")
    #expect(fixture.host.delivered.isEmpty)
}

@MainActor @Test func remoteAllowAndDenyAnswerTheRequest() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    for (id, action) in [("a1", RemoteCommand.Action.allow), ("d1", .deny)] {
        let command = RemoteCommand(id: id, session: "s1", host: fixture.mirror.hostID, action: action, permission: "p1",
                                    device: "iPhone", createdAt: Date())
        try await fixture.store.push(command)
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
    #expect(await fixture.store.log == ["save:permission:p1", "delete:permission:p1", "save:permission:p2", "delete:permission:p2"])
}

@MainActor @Test func remoteMirrorDropsRequestsThatAreNoLongerOpen() async throws {
    let fixture = try await RemoteFixture()
    defer { fixture.remove() }
    fixture.host.sources = [fixture.source()]
    fixture.host.open = ["p1"]
    for id in ["p1", "p2"] {
        try await fixture.store.push(RemotePermission(id: id, session: "s1", host: fixture.mirror.hostID, tool: "Bash", kind: nil,
                                                      detail: "ls", reason: "List", truncated: false, createdAt: Date()))
    }
    // Events arrive in order: once this message is delivered both requests have been received.
    try await fixture.store.push(fixture.message("c1"))
    #expect(await eventually { fixture.host.delivered.count == 1 })

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
    guard case .failed = fixture.mirror.status else {
        Issue.record("Expected .failed, got \(fixture.mirror.status)")
        return
    }
    #expect(!fixture.mirror.holdsApprovals)

    fixture.store.emit(.synced(Date()))
    // Events arrive in order: once this message is delivered the sync has been received.
    try await fixture.store.push(fixture.message("c1"))
    #expect(await eventually { fixture.host.delivered.count == 1 })
    guard case .failed = fixture.mirror.status else {
        Issue.record("A sync after an account change must not clear it, got \(fixture.mirror.status)")
        return
    }
    #expect(!fixture.mirror.holdsApprovals)
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
    let suite = "RemoteMirrorSyncTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = FakeRemoteStore()
    let box = StoreBox(first)
    let host = FakeRemoteHost()
    let mirror = RemoteMirror(defaults: defaults, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
                              available: true, idleSeconds: { 0 }, hostName: "Test Mac", interval: nil,
                              makeStore: { _ in box.current })
    mirror.host = host
    host.holdsDeliveries = true
    mirror.setEnabled(true)
    await mirror.settle()

    let command = RemoteCommand(id: "c1", session: "s1", host: mirror.hostID, action: .message, text: "run the tests",
                                device: "iPhone", createdAt: Date())
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
    let command = fixture.message("c1", "run the tests")
    try await fixture.store.push(command)
    #expect(await eventually { fixture.host.deliveriesWaiting == 1 })

    let store = FakeRemoteStore(entries: [command.recordName: try RemoteCodec.entry(command)])
    let host = FakeRemoteHost()
    let relaunched = RemoteMirror(defaults: fixture.defaults,
                                  dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(fixture.suite),
                                  available: true, idleSeconds: { 0 }, hostName: "Test Mac", interval: nil,
                                  makeStore: { _ in store })
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
