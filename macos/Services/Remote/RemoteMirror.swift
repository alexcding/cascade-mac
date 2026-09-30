import AppKit
import CloudKit
import CoreGraphics
import Foundation
import Security

/// One session as the phone should list it, as the app knows it.
struct RemoteSource: Equatable, Sendable {
    var id: String
    var title: String
    var project: String?
    var cli: String
    var worktree: String
    var conversation: String?
    var state: RemoteSession.State
}

/// What the mirror needs from the app. `AppViewModel` is the one production host.
@MainActor protocol RemoteMirrorHost: AnyObject {
    /// Every session with a live agent terminal. An approval is held for the phone only for one
    /// of these, and the mirror keeps records only for these.
    func remoteSources() -> [RemoteSource]
    /// The session's transcript; only its revision when that is still `since`.
    func remoteTranscript(_ source: RemoteSource, since: String?) async throws -> AgentTranscript
    /// Looks at what runs in each live session's terminal, so an agent that exited or was replaced
    /// is known before a message is typed for it.
    func remoteWatchAgents() async
    /// Types a message into the session's agent once it is ready for one, or throws why not.
    /// It returns once the message is sent; what it returns waits for the agent to be heard
    /// starting on it, and is awaited before the next message is typed.
    func remoteDeliver(_ text: String, to sessionID: String) async throws -> RemoteDelivery.TurnStart?
    func remoteAnswer(permission id: String, allow: Bool) async throws
    /// The approvals still waiting for an answer.
    func remoteOpenPermissions() -> Set<String>
    /// The phone can no longer answer: every approval held for it goes to its terminal.
    func remoteReleaseHeld()
}

/// Why mirroring cannot start, in words Settings shows.
struct RemoteUnavailable: Error, Equatable {
    let message: String
    /// Worth trying again by itself: iCloud could not be reached, rather than not being signed in.
    var retries = false
    init(_ message: String, retries: Bool = false) { self.message = message; self.retries = retries }
}

/// Mirrors every live agent session's chat to the user's iCloud, for Cascade Remote on iPhone, and
/// carries out what an approved phone sends back: a message typed into a session, or an approval
/// answered.
///
/// It lives in the app, not the backend, because CloudKit is Apple's; the backend stays the source
/// of truth through `/api/agent/transcript`. Off unless turned on in Settings → iPhone, and inert
/// in a build that is not signed with the iCloud entitlement. Each Mac keeps to its own records
/// (`hostID`), so two Macs on one Apple Account mirror side by side.
@MainActor @Observable
final class RemoteMirror {
    enum Status: Equatable {
        case off
        /// This build cannot use CloudKit, or iCloud is not signed in or reachable.
        case unavailable(String)
        case starting
        case syncing(Date?)
        case failed(String)
    }

    /// Makes the store mirroring runs on, or throws `RemoteUnavailable`.
    typealias StoreFactory = @MainActor (_ stateURL: URL) async throws -> any RemoteStoring

    /// Away from the Mac this long, an approval waits for the phone instead of going to the terminal.
    static let awayAfter: TimeInterval = 120
    static var unsigned: String { String(localized: "This build of Cascade isn’t signed for iCloud, so it can’t sync with an iPhone.") }

    private(set) var status: Status = .off
    private(set) var enabled: Bool
    /// Phones that have introduced themselves and wait for an answer here.
    private(set) var pendingDevices: [RemoteDevice] = []
    /// Phones allowed to type into sessions and answer approvals on this Mac.
    private(set) var approvedDevices: [RemoteLocalState.Device] = []
    /// Phones turned away here. One may be asked again.
    private(set) var deniedDevices: [Denied] = []

    struct Denied: Identifiable, Equatable {
        let id: String
        let name: String
    }
    /// Whether this build carries the iCloud container entitlement at all.
    let available: Bool
    /// This Mac with its data directory, as its records name it.
    let hostID: String

    @ObservationIgnored weak var host: (any RemoteMirrorHost)?
    @ObservationIgnored private let localURL: URL
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var local: RemoteLocalState
    @ObservationIgnored private let idleSeconds: () -> TimeInterval
    @ObservationIgnored private let hostName: String
    @ObservationIgnored private let makeStore: StoreFactory
    /// How often the sessions are mirrored; nil leaves it to whoever calls `tick()`.
    @ObservationIgnored private let interval: Duration?
    @ObservationIgnored private var store: (any RemoteStoring)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var suspension: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Duration = .seconds(15)
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    /// This Mac's records, as last saved or fetched. Other Macs' are never kept here.
    @ObservationIgnored private var entries: [String: RemoteEntry] = [:]
    /// Every phone seen, by device ID, whether approved or not.
    @ObservationIgnored private var seen: [String: RemoteDevice] = [:]
    /// The requests on offer, exactly as this Mac offered them, by request ID. An Allow is judged
    /// against this and nothing fetched: a record in iCloud is only what someone last wrote.
    @ObservationIgnored private var offered: [String: RemotePermission] = [:]
    /// Each session's transcript revision last mirrored, so an unchanged one is not read whole.
    @ObservationIgnored private var revisions: [String: String] = [:]
    /// Each session's mirrored turns as they were read, by turn ID, so a revision that changed one
    /// turn maps and sends one turn.
    @ObservationIgnored private var mirrored: [String: [String: Mirrored]] = [:]
    /// Commands in hand, so one fetched twice is carried out once.
    @ObservationIgnored private var handling: Set<String> = []
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Saves and deletes reach the store one at a time, in the order they were made: a request
    /// offered and then withdrawn must not arrive the other way round.
    @ObservationIgnored private var writes: Task<Void, Never>?
    /// Changes whenever mirroring stops, so a queued command from before is dropped, not typed.
    @ObservationIgnored private var generation = UUID()
    /// Outcomes reached while mirroring was stopped, saved once it starts again.
    @ObservationIgnored private var unsavedResults: [RemoteCommand] = []
    /// The iCloud account changed under a running mirror. Mirroring stops there, and stays
    /// stopped across launches: only turning it off and on starts it under the new account.
    @ObservationIgnored private var accountChanged: Bool {
        get { local.accountChanged }
        set {
            guard local.accountChanged != newValue else { return }
            local.accountChanged = newValue
            local.save(to: localURL)
        }
    }
    static var accountChangedNotice: String { String(localized: "The iCloud account changed. Turn syncing off and on again.") }
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var ticks = 0

    private struct Mirrored {
        /// Nil for a turn known only from its record, after a relaunch.
        var turn: TranscriptTurn?
        var order: Double
    }

    init(dataDirectory: URL,
         available: Bool = RemoteMirror.hasEntitlement(),
         idleSeconds: @escaping () -> TimeInterval = RemoteMirror.secondsSinceInput,
         hostName: String = Host.current().localizedName ?? "Mac",
         hostID: String? = nil,
         interval: Duration? = .seconds(2),
         makeStore: @escaping StoreFactory = RemoteMirror.cloudStore) {
        localURL = dataDirectory.appendingPathComponent("Remote/mirror.json")
        stateURL = dataDirectory.appendingPathComponent("Remote/sync.json")
        var local = RemoteLocalState.load(from: localURL)
        if let id = hostID ?? RemoteLocalState.hostID(dataDirectory: dataDirectory) ?? local.fallbackHostID {
            self.hostID = id
        } else {
            self.hostID = UUID().uuidString
            local.fallbackHostID = self.hostID
            local.save(to: localURL)
        }
        self.local = local
        self.available = available
        self.idleSeconds = idleSeconds
        self.hostName = hostName
        self.interval = interval
        self.makeStore = makeStore
        enabled = local.enabled
        status = !available ? .unavailable(Self.unsigned)
            : local.enabled && local.accountChanged ? .failed(Self.accountChangedNotice) : .off
        approvedDevices = Self.sorted(local.approved)
        deniedDevices = Self.sorted(local.denied)
        if available {
            // iCloud signed in, or came back: what could not start may start now.
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            }
        }
    }

    isolated deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    // MARK: Lifetime

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        local.enabled = value
        local.save(to: localURL)
        if value {
            resume()
        } else {
            let previous = suspension
            let starting = startup
            suspension = Task { [weak self] in
                await previous?.value
                // A start under way finishes first, so there is a store to clear.
                await starting?.value
                await self?.suspend(clearing: true)
            }
        }
    }

    /// Starts mirroring if it is turned on. Called once the backend is connected, and whenever
    /// iCloud may have become available.
    func resume() {
        guard available else { status = .unavailable(Self.unsigned); return }
        guard enabled else {
            status = .off
            if local.needsClear {
                let previous = suspension
                suspension = Task { [weak self] in
                    await previous?.value
                    await self?.clearLeftovers()
                }
            }
            return
        }
        // Already running, or stopped by an account change: neither starts by itself.
        guard store == nil else { return }
        guard !accountChanged else { status = .failed(Self.accountChangedNotice); return }
        status = .starting
        // Turned back on while turning off: start once the turning off is done.
        let pending = suspension
        let previous = startup
        startup = Task { [weak self] in
            await previous?.value
            await pending?.value
            await self?.start()
        }
    }

    func stop() async {
        await startup?.value
        await suspension?.value
        await suspend(clearing: false)
    }

    /// Waits until everything begun so far has reached the store: a start or a stop under way,
    /// the commands in hand, and the saves and deletes behind them.
    func settle() async {
        await startup?.value
        await suspension?.value
        await queue?.value
        await writes?.value
    }

    private func start() async {
        guard enabled, store == nil, !accountChanged else { return }
        retry?.cancel(); retry = nil
        let store: any RemoteStoring
        do {
            store = try await makeStore(stateURL)
        } catch {
            guard enabled, self.store == nil else { return }
            let reason = error as? RemoteUnavailable
            status = .unavailable(reason?.message ?? error.localizedDescription)
            if reason?.retries != false { retryLater() }
            return
        }
        // Everything is loaded before the store is published: a request offered meanwhile finds
        // no store, and is not lost under the records loaded after it.
        let all = await store.entries()
        await store.start()
        guard self.store == nil else { await store.stop(); return }
        self.store = store
        generation = UUID()
        retryDelay = .seconds(15)
        entries = all.filter { $0.value.host == hostID && $0.value.type != .device }
        seen = [:]
        for entry in all.values { see(entry) }
        refreshDevices()
        publishHost(store)
        for result in unsavedResults { put(result, store: store) }
        unsavedResults = []
        status = .syncing(lastSync)
        listener = Task { [weak self] in
            for await event in store.events { self?.received(event) }
        }
        if let interval {
            loop = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    await self?.tick()
                    // What a phone writes arrives by push; this catches what a push missed.
                    if tick % 15 == 0 { await store.fetchNow() }
                    tick += 1
                    try? await Task.sleep(for: interval)
                }
            }
        }
        // Commands left from before a relaunch are judged as they stand.
        for (name, entry) in Self.inOrder(entries) { consider(name, entry) }
    }

    /// iCloud could not be reached: tried again, further apart each time, until it can.
    private func retryLater() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(300))
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    /// Stops syncing. Turned off by hand, this Mac's records are taken out of iCloud too.
    private func suspend(clearing: Bool) async {
        loop?.cancel(); loop = nil
        listener?.cancel(); listener = nil
        retry?.cancel(); retry = nil
        // A message being typed finishes; one still queued is dropped by the new generation. The
        // queue and the commands in hand are kept, so a restart neither types one twice nor
        // types beside the one still going.
        generation = UUID()
        let store = self.store
        self.store = nil
        host?.remoteReleaseHeld()
        if let store {
            await writes?.value
            if clearing {
                for name in entries.keys { await store.delete(name) }
                await store.sendNow()
                setNeedsClear(await store.hasUnsent())
            }
            await store.stop()
        } else if clearing {
            // Nothing running to clear with, offline or signed out: owed until it can be done.
            setNeedsClear(true)
        }
        entries = [:]
        revisions = [:]
        mirrored = [:]
        offered = [:]
        if !enabled {
            accountChanged = false
            status = available ? .off : .unavailable(Self.unsigned)
            if local.needsClear { await clearLeftovers() }
        }
    }

    /// Takes this Mac's records out of iCloud while mirroring is off, when turning it off could not.
    private func clearLeftovers() async {
        guard available, !enabled, store == nil, local.needsClear,
              let store = try? await makeStore(stateURL) else { return }
        let mine = await store.entries().filter { $0.value.host == hostID && $0.value.type != .device }
        await store.start()
        for name in mine.keys { await store.delete(name) }
        await store.sendNow()
        let owed = await store.hasUnsent()
        await store.stop()
        setNeedsClear(owed)
    }

    private func setNeedsClear(_ value: Bool) {
        guard local.needsClear != value else { return }
        local.needsClear = value
        local.save(to: localURL)
    }

    // MARK: Phones

    /// Lets a phone that introduced itself act on this Mac, under the key it shows now.
    func approve(_ id: String) {
        guard let device = seen[id] else { return }
        local.denied[id] = nil
        local.approved[id] = .init(id: id, name: device.name, publicKey: device.publicKey, approvedAt: Date())
        devicesChanged()
    }

    func deny(_ id: String) {
        local.denied[id] = seen[id]?.name ?? local.approved[id]?.name ?? "iPhone"
        local.approved[id] = nil
        devicesChanged()
    }

    /// Lets a phone that was turned away ask again: it goes back to waiting, if it is still there.
    func askAgain(_ id: String) {
        local.denied[id] = nil
        devicesChanged()
    }

    /// Takes a phone's approval back. It may ask again.
    func remove(_ id: String) {
        local.approved[id] = nil
        devicesChanged()
    }

    private func devicesChanged() {
        local.save(to: localURL)
        refreshDevices()
        if let store { publishHost(store) }
    }

    private func refreshDevices() {
        approvedDevices = Self.sorted(local.approved)
        deniedDevices = Self.sorted(local.denied)
        pendingDevices = seen.values
            .filter { local.approved[$0.id]?.publicKey != $0.publicKey && local.denied[$0.id] == nil }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func sorted(_ denied: [String: String]) -> [Denied] {
        denied.map { Denied(id: $0.key, name: $0.value) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func sorted(_ devices: [String: RemoteLocalState.Device]) -> [RemoteLocalState.Device] {
        devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// A device record counts only if its ID is its key's: no record speaks for another phone.
    private func see(_ entry: RemoteEntry) {
        guard let device = entry.decode(RemoteDevice.self), device.id == RemoteSigning.deviceID(for: device.publicKey) else { return }
        seen[device.id] = device
    }

    private func publishHost(_ store: any RemoteStoring) {
        // Sent at once: a phone waiting to be allowed is looking at this.
        put(RemoteHost(host: hostID, name: hostName, approved: local.approved.keys.sorted(), denied: local.denied.keys.sorted()),
            store: store, sendingNow: true)
    }

    /// An approved phone has been open lately. With none, conversations stay on the Mac.
    private var phoneActive: Bool {
        local.approved.values.contains { device in
            guard let seen = seen[device.id], seen.publicKey == device.publicKey else { return false }
            return -seen.lastSeen.timeIntervalSinceNow < RemoteSchema.phoneActive
        }
    }

    // MARK: Approvals

    /// Whether an approval with no chat on screen should wait for the phone rather than go
    /// straight to the terminal: mirroring is working, a phone is approved to answer, and nobody
    /// has touched the Mac for a while.
    var holdsApprovals: Bool {
        guard store != nil, case .syncing = status, !local.approved.isEmpty else { return false }
        return idleSeconds() >= Self.awayAfter
    }

    func offer(_ prompt: AgentPermissionPrompt, session: String) {
        guard let store else { return }
        // A file change is approved on what it changes. Sides too long to send leave the request
        // marked, and the phone may only deny it.
        let fits = (prompt.old?.count ?? 0) <= RemoteSchema.maxChange && (prompt.new?.count ?? 0) <= RemoteSchema.maxChange
        let permission = RemotePermission(id: prompt.id, session: session, host: hostID, tool: prompt.tool, kind: prompt.kind,
                                          detail: prompt.detail, reason: prompt.reason, old: fits ? prompt.old : nil,
                                          new: fits ? prompt.new : nil, truncated: prompt.truncated || !fits, createdAt: Date())
        offered[prompt.id] = permission
        put(permission, store: store, sendingNow: true)
    }

    func withdraw(_ id: String) {
        offered[id] = nil
        guard let store else { return }
        forget(RemotePermission.recordName(id), store: store)
    }

    // MARK: Mirroring

    /// One pass: every live session's record, and its turns while a phone is around, brought up to
    /// date, and what is over taken out.
    func tick() async {
        guard let host, let store else { return }
        let run = generation
        ticks += 1
        await host.remoteWatchAgents()
        guard run == generation else { return }
        let conversations = phoneActive
        for source in host.remoteSources() {
            await mirror(source, conversation: conversations, host: host, store: store, run: run)
        }
        // The pass may have been overtaken by a stop, or a stop and a start, while it read
        // transcripts: what it holds is the old run's store.
        guard run == generation else { return }
        // Asked again, now: a session that appeared or ended during the pass is judged as it is.
        let live = Set(host.remoteSources().map(\.id))
        let open = host.remoteOpenPermissions()
        for (name, entry) in entries {
            switch entry.type {
            case .session:
                // A session that ended takes its turns with it.
                if let id = entry.decode(RemoteSession.self)?.id, !live.contains(id) { forget(name, store: store) }
            case .turn:
                if let session = RemoteTurn.session(ofRecordName: name), !live.contains(session) { forget(name, store: store) }
            case .permission:
                // Answered, or lost with a restart the app never heard end. Only the app's own
                // list of open requests decides: it is what holds one for the phone.
                if let permission = entry.decode(RemotePermission.self), !open.contains(permission.id) {
                    offered[permission.id] = nil
                    forget(name, store: store)
                }
            case .command:
                if let command = entry.decode(RemoteCommand.self), command.status != .pending,
                   -command.createdAt.timeIntervalSinceNow > RemoteSchema.commandRetention {
                    forget(name, store: store)
                }
            case .host, .device:
                break
            }
        }
        for id in revisions.keys where !live.contains(id) { revisions[id] = nil; mirrored[id] = nil }
        if ticks % 30 == 0 { forgetOldAttempts() }
    }

    private func mirror(_ source: RemoteSource, conversation: Bool, host: any RemoteMirrorHost, store: any RemoteStoring,
                        run: UUID) async {
        guard run == generation else { return }
        let current = entries[RemoteSession.recordName(source.id)]?.decode(RemoteSession.self)
        var session = RemoteSession(id: source.id, title: source.title, project: source.project, cli: source.cli,
                                    state: source.state, host: hostID, hostName: hostName, updatedAt: current?.updatedAt ?? Date())
        if session != current {
            session.updatedAt = Date()
            put(session, store: store)
        }
        guard conversation else { return }
        guard let transcript = try? await host.remoteTranscript(source, since: revisions[source.id]),
              run == generation, transcript.revision != revisions[source.id] else { return }
        // A read that found nothing new carries no turns: keep what is mirrored.
        guard let turns = transcript.turns else { revisions[source.id] = transcript.revision; return }
        revisions[source.id] = transcript.revision
        let had = mirrored[source.id] ?? known(source.id)
        let window = RemoteTurnMapper.window(turns)
        let orders = RemoteTurnMapper.orders(window, known: had.mapValues(\.order))
        var now: [String: Mirrored] = [:]
        for (turn, order) in zip(window, orders) {
            // Only a turn that changed is mapped and sent: while an agent works that is the last one.
            if let before = had[turn.id], before.turn == turn, before.order == order {
                now[turn.id] = before
            } else {
                put(RemoteTurnMapper.turn(turn, session: source.id, host: hostID, order: order), store: store)
                now[turn.id] = Mirrored(turn: turn, order: order)
            }
        }
        mirrored[source.id] = now
        for name in entries.keys where RemoteTurn.session(ofRecordName: name) == source.id {
            if let id = entries[name]?.decode(RemoteTurn.self)?.id, now[id] == nil { forget(name, store: store) }
        }
    }

    /// The orders a session's turns were mirrored under before this launch, read from their records.
    private func known(_ session: String) -> [String: Mirrored] {
        Dictionary(entries.compactMap { name, entry -> (String, Mirrored)? in
            guard RemoteTurn.session(ofRecordName: name) == session, let turn = entry.decode(RemoteTurn.self) else { return nil }
            return (turn.id, Mirrored(turn: nil, order: turn.order))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func put<T: RemotePayload>(_ value: T, store: any RemoteStoring, sendingNow: Bool = false) {
        guard let entry = try? RemoteCodec.entry(value), entries[value.recordName]?.payload != entry.payload else { return }
        entries[value.recordName] = entry
        write {
            try? await store.save(value)
            // Not waited for: a send can take as long as the network does.
            if sendingNow { Task { await store.sendNow() } }
        }
    }

    private func forget(_ name: String, store: any RemoteStoring) {
        guard entries.removeValue(forKey: name) != nil else { return }
        write { await store.delete(name) }
    }

    private func write(_ change: @escaping @Sendable () async -> Void) {
        let previous = writes
        writes = Task {
            await previous?.value
            await change()
        }
    }

    // MARK: Commands

    private func received(_ event: RemoteSyncEvent) {
        switch event {
        case .changed(let saved, let deleted):
            for name in deleted {
                if name.hasPrefix("command:") { entries[name] = nil }
                if name.hasPrefix("device:") { seen[String(name.dropFirst("device:".count))] = nil }
            }
            for entry in saved.values where entry.type == .device { see(entry) }
            if deleted.contains(where: { $0.hasPrefix("device:") }) || saved.values.contains(where: { $0.type == .device }) {
                refreshDevices()
            }
            // Of this Mac's records only a command is ever written by anything else, so only a
            // command is taken from a fetch. Any other that comes back changed or deleted was
            // written over by something on the account that is not this Mac: ours goes back, and
            // what the mirror holds, and judges an Allow by, is never what was fetched.
            let mine = saved.filter { $0.value.host == hostID && $0.value.type != .device }
            // A command under its own name; one written under another record's name is not one.
            let commands = mine.filter { name, entry in entry.decode(RemoteCommand.self)?.recordName == name }
            for (name, entry) in commands { entries[name] = entry }
            for (name, entry) in mine where commands[name] == nil { reassert(name, against: entry.payload) }
            for name in deleted where entries[name] != nil && !name.hasPrefix("command:") { reassert(name, against: nil) }
            for (name, entry) in Self.inOrder(commands) { consider(name, entry) }
        case .cleared:
            // The zone was deleted under the same account. Everything is mirrored again from
            // nothing, and the phones introduce themselves again.
            entries = [:]
            revisions = [:]
            mirrored = [:]
            seen = [:]
            refreshDevices()
            if let store {
                publishHost(store)
                for permission in offered.values { put(permission, store: store, sendingNow: true) }
            }
        case .reset:
            // The account went or changed. Nothing more is read, typed or sent until the mirror is
            // turned off and on: whatever account is signed in now was never asked.
            accountChanged = true
            status = .failed(Self.accountChangedNotice)
            let previous = suspension
            suspension = Task { [weak self] in
                await previous?.value
                await self?.suspend(clearing: false)
            }
        case .signedIn:
            break
        case .synced(let date):
            lastSync = date
            // A passing failure clears with the next sync that works; a changed account does not.
            if !accountChanged, store != nil { status = .syncing(date) }
        case .failed(let message):
            if !accountChanged { status = .failed(message) }
        }
    }

    /// Puts this Mac's own record back as the mirror holds it, or takes it out again if the
    /// mirror no longer holds it, when iCloud's copy is `fetched` instead.
    private func reassert(_ name: String, against fetched: Data?) {
        guard let store else { return }
        if let ours = entries[name] {
            guard ours.payload != fetched else { return }
            write { try? await store.save(ours, named: name) }
        } else if fetched != nil {
            write { await store.delete(name) }
        }
    }

    /// The commands among `entries`, oldest first: two messages that arrive together are typed in
    /// the order they were sent.
    private static func inOrder(_ entries: [String: RemoteEntry]) -> [(String, RemoteEntry)] {
        entries.compactMap { name, entry in entry.decode(RemoteCommand.self).map { (name, entry, $0.createdAt) } }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
            .map { ($0.0, $0.1) }
    }

    private func consider(_ name: String, _ entry: RemoteEntry) {
        guard entry.type == .command, entry.host == hostID, let command = entry.decode(RemoteCommand.self),
              command.status == .pending, !handling.contains(command.id) else { return }
        handling.insert(command.id)
        let previous = queue
        let generation = generation
        // One at a time, in the order they came: two messages must not type over each other.
        queue = Task { [weak self] in
            await previous?.value
            await self?.carryOut(command, generation: generation)
        }
    }

    private func carryOut(_ command: RemoteCommand, generation: UUID) async {
        // Mirroring stopped since this was queued: it is not typed under the old run. It is
        // judged again now if mirroring has restarted, or by `start()` when it does.
        guard generation == self.generation, store != nil else {
            handling.remove(command.id)
            if store != nil, let entry = entries[command.recordName] { consider(command.recordName, entry) }
            return
        }
        var result = command
        var turnStart: RemoteDelivery.TurnStart?
        do {
            // Anything on the Apple Account can write a command. Only one signed by a phone
            // approved on this Mac is carried out.
            guard let device = local.approved[command.device] else {
                throw RemoteCommandError(String(localized: "This iPhone isn’t approved on your Mac. Allow it in Cascade → Settings → iPhone."))
            }
            guard RemoteSigning.verify(command, publicKey: device.publicKey) else {
                throw RemoteCommandError(String(localized: "Your Mac couldn’t verify this came from your iPhone, so it did nothing."))
            }
            // Begun before and never finished, by a quit or a crash: it may have been typed
            // already, so it is never typed again.
            guard local.attempts[command.id] == nil else {
                throw RemoteCommandError(String(localized: "Cascade quit while handling it. Check the session before sending it again."))
            }
            guard -command.createdAt.timeIntervalSinceNow <= RemoteSchema.commandLifetime else {
                throw RemoteCommandError(String(localized: "Expired before your Mac received it."))
            }
            guard let host else { throw RemoteCommandError(String(localized: "Cascade isn’t ready.")) }
            switch command.action {
            case .message:
                guard let text = command.text, !text.isEmpty else { throw RemoteCommandError(String(localized: "The message is empty.")) }
                begin(command)
                turnStart = try await host.remoteDeliver(text, to: command.session)
            case .allow, .deny:
                guard let id = command.permission else { throw RemoteCommandError(String(localized: "No request to answer.")) }
                // Allowed only as this Mac offered it: whole, still on offer, and the very thing
                // the phone says it was showing when Allow was tapped.
                if command.action == .allow {
                    guard let ours = offered[id] else {
                        throw RemoteCommandError(String(localized: "That request was already answered."))
                    }
                    guard !ours.truncated else {
                        throw RemoteCommandError(String(localized: "Too long to review on iPhone. Answer it on your Mac."))
                    }
                    guard command.shown == RemoteSigning.digest(of: ours) else {
                        throw RemoteCommandError(String(localized: "The request your iPhone showed isn’t the one your Mac is asking about. Look at it again."))
                    }
                }
                begin(command)
                try await host.remoteAnswer(permission: id, allow: command.action == .allow)
            }
            result.status = .delivered
        } catch {
            result.status = .failed
            result.message = (error as? RemoteCommandError)?.message ?? error.localizedDescription
        }
        // Saved to whichever store is running now; mirroring may have restarted meanwhile.
        if let store { put(result, store: store, sendingNow: true) } else { unsavedResults.append(result) }
        // The phone has its answer. The next message still waits for this one's turn to begin.
        await turnStart?()
    }

    /// Written down before anything is typed or answered.
    private func begin(_ command: RemoteCommand) {
        local.attempts[command.id] = Date().timeIntervalSince1970
        local.save(to: localURL)
    }

    private func forgetOldAttempts() {
        let cutoff = Date().timeIntervalSince1970 - 2 * RemoteSchema.commandRetention
        let kept = local.attempts.filter { $0.value >= cutoff }
        guard kept.count != local.attempts.count else { return }
        local.attempts = kept
        local.save(to: localURL)
    }

    // MARK: Platform

    /// The store production runs on: CloudKit, once the iCloud account is there.
    static func cloudStore(_ stateURL: URL) async throws -> any RemoteStoring {
        let container = CKContainer(identifier: RemoteSchema.container)
        let account: CKAccountStatus
        do {
            account = try await container.accountStatus()
        } catch {
            throw RemoteUnavailable(String(localized: "iCloud can’t be reached. Cascade will keep trying."), retries: true)
        }
        switch account {
        case .available:
            break
        case .noAccount:
            throw RemoteUnavailable(String(localized: "Sign in to iCloud in System Settings to sync with your iPhone."))
        case .restricted:
            throw RemoteUnavailable(String(localized: "iCloud is restricted on this Mac."))
        default:
            throw RemoteUnavailable(String(localized: "iCloud isn’t ready yet. Cascade will keep trying."), retries: true)
        }
        // CloudKit's pushes reach the sync engine only in an app registered for them.
        NSApplication.shared.registerForRemoteNotifications()
        return RemoteSyncStore(fileURL: stateURL, container: container)
    }

    /// Whether the running app was signed with the iCloud container, without which `CKContainer`
    /// traps.
    nonisolated static func hasEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(RemoteSchema.container) == true
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere in the session.
    nonisolated static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

struct RemoteCommandError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
