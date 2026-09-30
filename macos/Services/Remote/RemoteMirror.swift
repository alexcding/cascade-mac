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
    /// Every session with a live agent terminal.
    func remoteSources() -> [RemoteSource]
    /// The session's transcript; only its revision when that is still `since`.
    func remoteTranscript(_ source: RemoteSource, since: String?) async throws -> AgentTranscript
    /// Types a message into the session's agent once it is ready for one, or throws why not.
    func remoteDeliver(_ text: String, to sessionID: String) async throws
    func remoteAnswer(permission id: String, allow: Bool) async throws
    /// The approvals still waiting for an answer.
    func remoteOpenPermissions() -> Set<String>
    /// The phone can no longer answer: every approval held for it goes to its terminal.
    func remoteReleaseHeld()
}

/// Why mirroring cannot start, in words Settings shows.
struct RemoteUnavailable: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Mirrors every live agent session's chat to the user's iCloud, for Cascade Remote on iPhone, and
/// carries out what the phone sends back: a message typed into a session, or an approval answered.
///
/// It lives in the app, not the backend, because CloudKit is Apple's; the backend stays the source
/// of truth through `/api/agent/transcript`. Off unless turned on in Settings → iPhone, and inert
/// in a build that is not signed with the iCloud entitlement. Each Mac keeps to its own records
/// (`hostID`), so two Macs on one Apple Account mirror side by side.
@MainActor @Observable
final class RemoteMirror {
    enum Status: Equatable {
        case off
        /// This build cannot use CloudKit, or iCloud is not signed in.
        case unavailable(String)
        case starting
        case syncing(Date?)
        case failed(String)
    }

    /// Makes the store mirroring runs on, or throws `RemoteUnavailable`.
    typealias StoreFactory = @MainActor (_ stateURL: URL) async throws -> any RemoteStoring

    static let enabledKey = "remote.enabled"
    static let hostIDKey = "remote.hostID"
    static let attemptedKey = "remote.attempted"
    /// Away from the Mac this long, an approval waits for the phone instead of going to the terminal.
    static let awayAfter: TimeInterval = 120

    private(set) var status: Status = .off
    private(set) var enabled: Bool
    /// Whether this build carries the iCloud container entitlement at all.
    let available: Bool
    /// This Mac, as its records name it.
    let hostID: String

    @ObservationIgnored weak var host: (any RemoteMirrorHost)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateURL: URL
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
    /// This Mac's records, as last saved or fetched. Other Macs' are never kept here.
    @ObservationIgnored private var entries: [String: RemoteEntry] = [:]
    /// Each session's transcript revision last mirrored, so an unchanged one is not read whole.
    @ObservationIgnored private var revisions: [String: String] = [:]
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
    /// The iCloud account changed under a running mirror: only turning it off and on recovers.
    @ObservationIgnored private var accountChanged = false
    @ObservationIgnored private var lastSync: Date?

    init(defaults: UserDefaults = .standard, dataDirectory: URL,
         available: Bool = RemoteMirror.hasEntitlement(),
         idleSeconds: @escaping () -> TimeInterval = RemoteMirror.secondsSinceInput,
         hostName: String = Host.current().localizedName ?? "Mac",
         interval: Duration? = .seconds(2),
         makeStore: @escaping StoreFactory = RemoteMirror.cloudStore) {
        self.defaults = defaults
        self.stateURL = dataDirectory.appendingPathComponent("Remote/sync.json")
        self.available = available
        self.idleSeconds = idleSeconds
        self.hostName = hostName
        self.interval = interval
        self.makeStore = makeStore
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        if let id = defaults.string(forKey: Self.hostIDKey) {
            hostID = id
        } else {
            hostID = UUID().uuidString
            defaults.set(hostID, forKey: Self.hostIDKey)
        }
    }

    // MARK: Lifetime

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value {
            resume()
        } else {
            let previous = suspension
            suspension = Task { [weak self] in
                await previous?.value
                await self?.suspend(clearing: true)
            }
        }
    }

    /// Starts mirroring if it is turned on. Called once the backend is connected.
    func resume() {
        guard enabled else { status = .off; return }
        guard available else {
            status = .unavailable(String(localized: "This build of Cascade isn’t signed for iCloud."))
            return
        }
        // Already running: a reconnect of the backend changes nothing here.
        guard store == nil else { return }
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
        guard enabled, store == nil else { return }
        let store: any RemoteStoring
        do {
            store = try await makeStore(stateURL)
        } catch {
            if enabled, self.store == nil {
                status = .unavailable((error as? RemoteUnavailable)?.message ?? error.localizedDescription)
            }
            return
        }
        guard enabled, self.store == nil else { return }
        self.store = store
        generation = UUID()
        let run = generation
        accountChanged = false
        let mine = await store.entries().filter { $0.value.host == hostID }
        await store.start()
        // Turned off while the store was starting: that stop owns the store now.
        guard run == generation else { return }
        entries = mine
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
                    // Messages from the phone arrive by push; this catches one a push missed.
                    if tick % 5 == 0 { await store.fetchNow() }
                    tick += 1
                    try? await Task.sleep(for: interval)
                }
            }
        }
        // Commands left from before a relaunch are judged as they stand.
        for (name, entry) in Self.inOrder(entries) { consider(name, entry) }
    }

    /// Stops syncing. Turned off by hand, this Mac's records are taken out of iCloud too.
    private func suspend(clearing: Bool) async {
        loop?.cancel(); loop = nil
        listener?.cancel(); listener = nil
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
            }
            await store.stop()
        }
        entries = [:]
        revisions = [:]
        if !enabled { status = .off }
    }

    // MARK: Approvals

    /// Whether an approval with no chat on screen should wait for the phone rather than go
    /// straight to the terminal: mirroring is working and nobody has touched the Mac for a while.
    var holdsApprovals: Bool {
        guard store != nil, case .syncing = status else { return false }
        return idleSeconds() >= Self.awayAfter
    }

    func offer(_ prompt: AgentPermissionPrompt, session: String) {
        guard let store else { return }
        put(RemotePermission(id: prompt.id, session: session, host: hostID, tool: prompt.tool, kind: prompt.kind,
                             detail: prompt.detail, reason: prompt.reason, truncated: prompt.truncated, createdAt: Date()),
            store: store, sendingNow: true)
    }

    func withdraw(_ id: String) {
        guard let store else { return }
        forget(RemotePermission.recordName(id), store: store)
    }

    // MARK: Mirroring

    /// One pass: every live session's record and turns brought up to date, and what is over
    /// taken out.
    func tick() async {
        guard let host, let store else { return }
        let run = generation
        let sources = host.remoteSources()
        let live = Set(sources.map(\.id))
        for source in sources {
            await mirror(source, host: host, store: store, run: run)
        }
        // The pass may have been overtaken by a stop, or a stop and a start, while it read
        // transcripts: what it holds is the old run's store.
        guard run == generation else { return }
        let open = host.remoteOpenPermissions()
        for (name, entry) in entries {
            switch entry.type {
            case .session:
                // A session that ended takes its turns and requests with it.
                if let id = entry.decode(RemoteSession.self)?.id, !live.contains(id) { forget(name, store: store) }
            case .turn:
                if let session = RemoteTurn.session(ofRecordName: name), !live.contains(session) { forget(name, store: store) }
            case .permission:
                // Answered, or lost with a restart the app never heard end.
                if let permission = entry.decode(RemotePermission.self),
                   !live.contains(permission.session) || !open.contains(permission.id) {
                    forget(name, store: store)
                }
            case .command:
                if let command = entry.decode(RemoteCommand.self), command.status != .pending,
                   -command.createdAt.timeIntervalSinceNow > RemoteSchema.commandRetention {
                    forget(name, store: store)
                }
            }
        }
        for id in revisions.keys where !live.contains(id) { revisions[id] = nil }
        forgetOldAttempts()
    }

    private func mirror(_ source: RemoteSource, host: any RemoteMirrorHost, store: any RemoteStoring, run: UUID) async {
        guard run == generation else { return }
        let current = entries[RemoteSession.recordName(source.id)]?.decode(RemoteSession.self)
        var session = RemoteSession(id: source.id, title: source.title, project: source.project, cli: source.cli,
                                    state: source.state, host: hostID, hostName: hostName, updatedAt: current?.updatedAt ?? Date())
        if session != current {
            session.updatedAt = Date()
            put(session, store: store)
        }
        guard let transcript = try? await host.remoteTranscript(source, since: revisions[source.id]),
              run == generation, transcript.revision != revisions[source.id] else { return }
        // A read that found nothing new carries no turns: keep what is mirrored.
        guard let turns = transcript.turns else { revisions[source.id] = transcript.revision; return }
        revisions[source.id] = transcript.revision
        let known = Dictionary(uniqueKeysWithValues: entries.compactMap { name, entry -> (String, Double)? in
            guard RemoteTurn.session(ofRecordName: name) == source.id, let turn = entry.decode(RemoteTurn.self) else { return nil }
            return (turn.id, turn.order)
        })
        let mapped = RemoteTurnMapper.turns(turns, session: source.id, host: hostID, known: known)
        let keep = Set(mapped.map(\.recordName))
        for turn in mapped { put(turn, store: store) }
        for name in entries.keys where RemoteTurn.session(ofRecordName: name) == source.id && !keep.contains(name) {
            forget(name, store: store)
        }
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
            for name in deleted { entries[name] = nil }
            let mine = saved.filter { $0.value.host == hostID }
            for (name, entry) in mine { entries[name] = entry }
            for (name, entry) in Self.inOrder(mine) { consider(name, entry) }
        case .reset:
            entries = [:]
            revisions = [:]
            accountChanged = true
            status = .failed(String(localized: "The iCloud account changed. Turn syncing off and on again."))
            host?.remoteReleaseHeld()
        case .synced(let date):
            lastSync = date
            // A passing failure clears with the next sync that works; a changed account does not.
            if !accountChanged { status = .syncing(date) }
        case .failed(let message):
            status = .failed(message)
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
        do {
            // Begun before and never finished, by a quit or a crash: it may have been typed
            // already, so it is never typed again.
            guard attempts[command.id] == nil else {
                throw RemoteCommandError(String(localized: "Cascade quit while handling it. Check the session before sending it again."))
            }
            guard -command.createdAt.timeIntervalSinceNow <= RemoteSchema.commandLifetime else {
                throw RemoteCommandError(String(localized: "Expired before your Mac received it."))
            }
            guard let host else { throw RemoteCommandError(String(localized: "Cascade isn’t ready.")) }
            attempts[command.id] = Date().timeIntervalSince1970
            switch command.action {
            case .message:
                guard let text = command.text, !text.isEmpty else { throw RemoteCommandError(String(localized: "The message is empty.")) }
                try await host.remoteDeliver(text, to: command.session)
            case .allow, .deny:
                guard let id = command.permission else { throw RemoteCommandError(String(localized: "No request to answer.")) }
                try await host.remoteAnswer(permission: id, allow: command.action == .allow)
            }
            result.status = .delivered
        } catch {
            result.status = .failed
            result.message = (error as? RemoteCommandError)?.message ?? error.localizedDescription
        }
        // Saved to whichever store is running now; mirroring may have restarted meanwhile.
        guard let store else { unsavedResults.append(result); return }
        put(result, store: store, sendingNow: true)
    }

    /// When each command was begun, kept across launches until its record is long gone.
    private var attempts: [String: TimeInterval] {
        get { defaults.dictionary(forKey: Self.attemptedKey) as? [String: TimeInterval] ?? [:] }
        set { defaults.set(newValue, forKey: Self.attemptedKey) }
    }

    private func forgetOldAttempts() {
        let cutoff = Date().timeIntervalSince1970 - 2 * RemoteSchema.commandRetention
        let kept = attempts.filter { $0.value >= cutoff }
        if kept.count != attempts.count { attempts = kept }
    }

    // MARK: Platform

    /// The store production runs on: CloudKit, once the iCloud account is there.
    static func cloudStore(_ stateURL: URL) async throws -> any RemoteStoring {
        let container = CKContainer(identifier: RemoteSchema.container)
        let account = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard account == .available else {
            throw RemoteUnavailable(String(localized: "Sign in to iCloud in System Settings to sync with your iPhone."))
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
