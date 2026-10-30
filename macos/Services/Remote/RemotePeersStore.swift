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
    private(set) var chats: [String: [String: ChatThreadShell]] = [:]
    @ObservationIgnored private(set) var service: (any RemoteServing)?
    @ObservationIgnored private var generation = UUID()
    /// Reads under way, by peer, and the peers asked for again while theirs was: read once more after.
    @ObservationIgnored private var reading: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: Set<String> = []
    @ObservationIgnored private var peersTask: Task<Void, Never>?
    /// After the paired Macs or one Mac's lists were read: the app opens a chat selected before
    /// it was listed, and closes one whose Mac was forgotten.
    @ObservationIgnored var onRead: () -> Void = {}

    func connect(_ service: (any RemoteServing)?) {
        self.service = service
        generation = UUID()
        peersTask?.cancel(); peersTask = nil
        reading.values.forEach { $0.cancel() }; reading = [:]; again = []
        if service == nil {
            peers = []; sessions = [:]; chats = [:]
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
        let generation = self.generation
        reading[id] = Task { [weak self] in
            async let listedSessions = try? service.sessions(peer: id)
            async let listedChats = try? service.chat(peer: id).listThreads()
            let (newSessions, newChats) = await (listedSessions, listedChats)
            guard let self, self.generation == generation else { return }
            reading[id] = nil
            if peer(id) != nil {
                if let newSessions, sessions[id] != newSessions { sessions[id] = newSessions }
                if let newChats {
                    let byID = Dictionary(newChats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    if chats[id] != byID { chats[id] = byID }
                }
            }
            onRead()
            if again.remove(id) != nil { read(id) }
        }
    }

    /// Waits for the reads under way, for tests.
    func settle() async {
        await peersTask?.value
        while let next = reading.values.first { await next.value }
    }
}
