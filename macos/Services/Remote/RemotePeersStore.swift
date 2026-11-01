import Foundation
import Observation

/// The Macs this one paired with, and what each shows: its sessions and its chats, for the
/// sidebar's section per Mac. Read once connected, and kept by the backend's events: `remote-peers`
/// (a Mac paired or forgotten), `remote-peer` (whether one answers), and `remote` (what one told,
/// relayed: its sessions or a chat changed). A Mac's lists are read when it comes online and when
/// it says they changed; one that stops answering keeps what was read, its section says it is
/// offline.
@MainActor @Observable final class RemotePeersStore {
    private(set) var peers: [RemotePeer] = []
    private(set) var sessions: [String: [WorkspaceSession]] = [:]
    private(set) var projects: [String: [RemoteProject]] = [:]
    /// Each Mac's sessions' agent states, by session id; none for a Mac that does not report them
    /// (an older Cascade: its read fails, as one that cannot be reached does, and nothing is kept).
    private(set) var states: [String: [String: RemoteSessionStatus]] = [:]
    private(set) var chats: [String: [String: ChatThreadShell]] = [:]
    @ObservationIgnored private(set) var service: (any RemoteServing)?
    @ObservationIgnored private var generation = UUID()
    /// Reads under way, by peer, and the peers asked for again while theirs was: read once more after.
    @ObservationIgnored private var reading: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: Set<String> = []
    @ObservationIgnored private var peersTask: Task<Void, Never>?
    /// Commands handed to a Mac's app, waiting on its answer; and answers heard before their
    /// command's own answer came back, which can happen when the app is quick. A Mac tells every
    /// Mac paired with it each answer, so one nobody here waits on is kept only for a minute.
    @ObservationIgnored private var commandWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    @ObservationIgnored private var commandsDone: [String: (outcome: Result<JSONValue, Error>, at: Date)] = [:]
    @ObservationIgnored private var readingStates: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statesAgain: Set<String> = []
    /// After the paired Macs or one Mac's lists were read: the app opens a chat selected before
    /// it was listed, and closes one whose Mac was forgotten.
    @ObservationIgnored var onRead: () -> Void = {}

    func connect(_ service: (any RemoteServing)?) {
        self.service = service
        generation = UUID()
        peersTask?.cancel(); peersTask = nil
        reading.values.forEach { $0.cancel() }; reading = [:]; again = []
        readingStates.values.forEach { $0.cancel() }; readingStates = [:]; statesAgain = []
        let waiters = commandWaiters; commandWaiters = [:]; commandsDone = [:]
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        if service == nil {
            peers = []; sessions = [:]; projects = [:]; states = [:]; chats = [:]
            return
        }
        reload()
    }

    /// Reads the paired Macs, then the lists of each one that answers.
    func reload() {
        guard let service else { return }
        let generation = self.generation
        peersTask?.cancel()
        peersTask = Task { [weak self] in
            let listed = try? await service.peers()
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            peersTask = nil
            guard let listed else { return }
            if peers != listed { peers = listed }
            let ids = Set(listed.map(\.id))
            sessions = sessions.filter { ids.contains($0.key) }
            projects = projects.filter { ids.contains($0.key) }
            states = states.filter { ids.contains($0.key) }
            chats = chats.filter { ids.contains($0.key) }
            for peer in listed where peer.reach == .online { read(peer.id) }
            onRead()
        }
    }

    func peer(_ id: String) -> RemotePeer? { peers.first { $0.id == id } }
    func chat(peer: String, thread: String) -> ChatThreadShell? { chats[peer]?[thread] }

    /// The chats a Mac's section lists, newest first, as the Chats section orders this Mac's: not a
    /// subagent's (its parent's page opens it) nor one started in a session's pane.
    func visibleChats(_ peer: String) -> [ChatThreadShell] {
        (chats[peer].map { Array($0.values) } ?? []).filter { !$0.subagent && ($0.worktreePath ?? "").isEmpty }.sorted {
            if ($0.createdAt ?? "") != ($1.createdAt ?? "") { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
    }

    /// A backend event; true when it was one of the remote ones.
    @discardableResult func receive(_ event: ServerEvent) -> Bool {
        switch event.type {
        case "remote-peers":
            reload()
        case "remote-peer":
            // One not listed yet, or heard of while the list is on its way, which may say otherwise:
            // the list is read again, with each Mac's state as it is now.
            guard let id = event.peer, peersTask == nil, let index = peers.firstIndex(where: { $0.id == id }) else {
                reload()
                return true
            }
            let reach = event.reach.flatMap(RemotePeer.Reach.init(rawValue:)) ?? .offline
            if peers[index].reach != reach { peers[index].reach = reach }
            if reach == .online { read(id) }
        case "remote":
            guard let id = event.peer, let relayed = event.relayed, peer(id) != nil else { return true }
            switch relayed["type"]?.string {
            case "tasks", "reload":
                read(id)
            case "session-status":
                readStates(id)
            case "session-command-done":
                guard let key = relayed["key"]?.string else { return true }
                let outcome: Result<JSONValue, Error> = relayed["ok"]?.bool == true
                    ? .success(relayed["data"] ?? .null)
                    : .failure(BackendError.operation(relayed["error"]?.string ?? String(localized: "\(peer(id)?.name ?? "The other Mac") could not do it.")))
                if let waiter = commandWaiters.removeValue(forKey: key) { waiter.resume(with: outcome) }
                else {
                    let now = Date()
                    commandsDone = commandsDone.filter { now.timeIntervalSince($0.value.at) < 60 }
                    commandsDone[key] = (outcome, now)
                }
            case "chat-shell":
                guard let shell = relayed["shell"].flatMap({ try? $0.decode(ChatThreadShell.self) }) else { return true }
                if chats[id]?[shell.id] != shell { chats[id, default: [:]][shell.id] = shell }
            case "chat-removed":
                guard let thread = relayed["threadId"]?.string else { return true }
                if chats[id]?[thread] != nil { chats[id]?[thread] = nil }
            default: break
            }
        default:
            return false
        }
        return true
    }

    /// Reads a Mac's sessions and chats; a read asked for while one is under way follows it.
    private func read(_ id: String) {
        guard let service else { return }
        if reading[id] != nil { again.insert(id); return }
        // The states by their own reads, one at a time: answered with the lists, a slow list
        // could set an older answer over a newer one.
        readStates(id)
        let generation = self.generation
        reading[id] = Task { [weak self] in
            async let listedSessions = try? service.sessions(peer: id)
            async let listedProjects = try? service.projects(peer: id)
            async let listedChats = try? service.chat(peer: id).listThreads()
            let (newSessions, newProjects, newChats) = await (listedSessions, listedProjects, listedChats)
            guard let self, self.generation == generation else { return }
            reading[id] = nil
            if peer(id) != nil {
                if let newSessions, sessions[id] != newSessions { sessions[id] = newSessions }
                if let newProjects, projects[id] != newProjects { projects[id] = newProjects }
                if let newChats {
                    let byID = Dictionary(newChats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    if chats[id] != byID { chats[id] = byID }
                }
            }
            onRead()
            if again.remove(id) != nil { read(id) }
        }
    }

    /// Reads a Mac's sessions' agent states again, as it said they changed; a change heard while
    /// one is read is read once more after it.
    private func readStates(_ id: String) {
        guard let service else { return }
        if readingStates[id] != nil { statesAgain.insert(id); return }
        let generation = self.generation
        readingStates[id] = Task { [weak self] in
            let listed = try? await service.sessionStatus(peer: id)
            guard let self, self.generation == generation else { return }
            readingStates[id] = nil
            if peer(id) != nil, let listed, states[id] != listed { states[id] = listed }
            if statesAgain.remove(id) != nil { readStates(id) }
        }
    }

    /// Asks a Mac to do something with a session or a project there, and waits until it did: at
    /// once for a rename, or until its app answers, for as long as `wait` at most.
    func perform(peer id: String, _ command: RemoteCommand, wait: Duration = .seconds(180)) async throws -> JSONValue {
        guard let service else { throw BackendError.operation(String(localized: "Connect to the backend first.")) }
        let accepted = try await service.command(peer: id, command)
        guard let key = accepted.key else { return .null }
        if let early = commandsDone.removeValue(forKey: key) { return try early.outcome.get() }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.endWait(key, BackendError.operation(String(localized: "\(self?.peer(id)?.name ?? "The other Mac") did not answer.")))
        }
        defer { timeout.cancel() }
        // Cancelled, the wait ends; what the Mac does goes on there.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { commandWaiters[key] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endWait(key, CancellationError()) }
        }
    }

    private func endWait(_ key: String, _ error: Error) {
        commandWaiters.removeValue(forKey: key)?.resume(throwing: error)
    }

    /// Waits for the reads under way, for tests.
    func settle() async {
        await peersTask?.value
        while let next = reading.values.first { await next.value }
        while let next = readingStates.values.first { await next.value }
    }
}
