import Foundation

/// Keeps the sessions' agents within Settings → Terminal's memory limit. Past it, the least
/// recently shown agent that is idle is stopped: hidden, between turns by its own hooks, with
/// nothing in progress on it. One mid-turn keeps running and goes once its turn ends, if the pool
/// is still over. A stopped session keeps its conversation, and opening it starts the agent again,
/// resuming it.
///
/// The app owns the terminals, so it says what each session is doing and does the stopping; the
/// pool decides which go, and when.
@MainActor final class SessionPool {
    /// One session as the app sees it when the pool runs.
    struct Session: Equatable {
        let id: String
        /// Runs an agent, whose conversation survives a stop. A plain shell's state would not.
        let agent: Bool
        let shown: Bool
        /// May be stopped now: an agent, hidden, between turns, with nothing in progress on it.
        let idle: Bool
    }

    /// What an agent the pool has not measured is taken to hold: a Claude Code session holds
    /// 200–250 MB.
    static let agentEstimate: UInt64 = 256 << 20

    var limit: MemoryLimit { didSet { if oldValue != limit { trim() } } }
    /// The sessions as they are now.
    var sessions: () -> [Session] = { [] }
    /// Stops one session's agent; false when it could not be stopped.
    var stop: (String) async -> Bool = { _ in false }
    /// Sessions the pool stopped. They stay stopped until something starts them again.
    private(set) var stopped: Set<String> = []

    /// Most recently shown first.
    private var recency: [String] = []
    private var pass: Task<Void, Never>?
    private var passPending = false
    private let control: any TerminalRuntimeControlling
    private let memory: any ProcessSampling

    init(control: any TerminalRuntimeControlling, memory: any ProcessSampling, limit: MemoryLimit) {
        self.control = control; self.memory = memory; self.limit = limit
    }

    func shown(_ id: String) {
        guard recency.first != id else { return }
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
    }

    /// The session has a terminal again, so its agent is starting.
    func started(_ id: String) { stopped.remove(id) }

    /// Forgets sessions that no longer exist.
    func retain(_ ids: Set<String>) {
        recency.removeAll { !ids.contains($0) }
        stopped.formIntersection(ids)
    }

    /// Stops what the limit no longer holds. Passes never overlap: one asked for while another
    /// runs follows it and measures again. Returns the pass for a caller that waits on it.
    @discardableResult func trim() -> Task<Void, Never>? {
        guard limit != .unlimited else { return pass }
        passPending = true
        if let pass { return pass }
        let task = Task { [weak self] in
            while let self, self.passPending {
                self.passPending = false
                await self.trimOnce()
            }
            self?.pass = nil
        }
        pass = task
        return task
    }

    private func trimOnce() async {
        guard let shells = try? await control.pairedShells(), !shells.isEmpty else { return }
        let known = Set(sessions().map(\.id))
        let measured = await memory.footprints(of: shells.filter { known.contains($0.key) })
        // Measuring takes a moment, and what each session is doing may have changed meanwhile.
        let current = sessions()
        let agents = current.filter(\.agent).compactMap { measured[$0.id] }
        let estimate = agents.isEmpty ? Self.agentEstimate : agents.reduce(0, +) / UInt64(agents.count)
        let starting = current.contains { $0.shown && $0.agent && shells[$0.id] == nil }
        let members = leastRecentFirst(current).compactMap { session in
            measured[session.id].map { MemoryPool.Member(id: session.id, bytes: $0, idle: session.idle) }
        }
        let used = members.reduce(0) { $0 + $1.bytes }
        for id in MemoryPool.evictions(members, used: used, incoming: starting ? estimate : 0, limit: limit) {
            // Each stop takes a moment too: a session opened or busy since is left running.
            guard sessions().first(where: { $0.id == id })?.idle == true else { continue }
            stopped.insert(id)
            if await !stop(id) { stopped.remove(id) }
        }
    }

    /// Those never shown go first, then the rest by when they were last on screen.
    private func leastRecentFirst(_ sessions: [Session]) -> [Session] {
        let rank = Dictionary(uniqueKeysWithValues: recency.enumerated().map { ($1, $0) })
        let seen = sessions.compactMap { session in rank[session.id].map { (session, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        return sessions.filter { rank[$0.id] == nil } + seen
    }
}
