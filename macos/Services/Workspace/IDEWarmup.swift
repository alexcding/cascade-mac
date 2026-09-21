import Foundation

// The IDE-neutral half of warm-up. `crates/craft-backend/src/warmup.rs` owns which IDEs have a
// preparation at all; nothing here knows what Xcode is.

/// What a worktree's IDE still has to prepare before a build can start. A worktree nobody has
/// warmed up reads as `ready`: nothing is in the way of a build either way.
struct IDEWarmupState: Decodable, Sendable, Equatable {
    var worktree = ""
    var status = "ready"
    /// What the preparation is, for the indicator: "Resolving Swift packages".
    var label = ""
    var message = ""

    var running: Bool { status == "running" }
    var failed: Bool { status == "failed" }
    static func ready(_ worktree: String) -> Self { .init(worktree: worktree, status: "ready") }
}

/// A warm-up never throws into a caller: a session that could not be prepared still opens, and
/// the build it blocks is the one that reports the failure.
protocol IDEWarmupServing: Sendable {
    func start(worktree: String, ide: String, target: String) async -> IDEWarmupState
    func state(worktree: String) async -> IDEWarmupState
}

struct APIIDEWarmupService: IDEWarmupServing {
    let api: APIClient
    func start(worktree: String, ide: String, target: String) async -> IDEWarmupState {
        struct Request: Encodable, Sendable { let path: String; let rel: String; let ide: String }
        guard !worktree.isEmpty, !ide.isEmpty else { return .ready(worktree) }
        let body = Request(path: worktree, rel: target, ide: ide)
        let state: IDEWarmupState? = try? await api.request(Routes.IDE_WARMUP, method: "POST", body: body)
        return state ?? .ready(worktree)
    }
    func state(worktree: String) async -> IDEWarmupState {
        guard !worktree.isEmpty else { return .ready(worktree) }
        let state: IDEWarmupState? = try? await api.get(APIClient.query(Routes.IDE_WARMUP, ["path": worktree]))
        return state ?? .ready(worktree)
    }
}

/// Every worktree's warm-up, as one observable. The backend coalesces, so asking twice for the
/// same worktree — created, then resumed, then resumed again after a reconnect — costs nothing.
@MainActor @Observable final class IDEWarmupStore {
    private(set) var states: [String: IDEWarmupState] = [:]
    @ObservationIgnored private var service: (any IDEWarmupServing)?
    /// Worktrees with a request in the air. The reply is what puts a worktree into `running`,
    /// so without this every refresh that lands inside one round trip would send its own.
    @ObservationIgnored private var asking: Set<String> = []

    /// Follows the backend connection: nothing is warm across a restart of it, and a state left
    /// from the old one would claim a run that is no longer happening.
    func connect(_ service: (any IDEWarmupServing)?) {
        self.service = service
        states.removeAll()
        asking.removeAll()
    }

    func state(for worktree: String) -> IDEWarmupState { states[worktree] ?? .ready(worktree) }

    /// Called when a session is created and whenever one is resumed. Both are the same act to
    /// the backend: prepare this checkout if it is not prepared.
    func warm(worktree: String, ide: String, target: String) {
        guard let service, !worktree.isEmpty, !ide.isEmpty, !state(for: worktree).running,
              asking.insert(worktree).inserted else { return }
        Task {
            let state = await service.start(worktree: worktree, ide: ide, target: target)
            asking.remove(worktree)
            apply(state)
        }
    }

    /// The backend's own report wins over anything inferred here — it is the only thing that
    /// knows whether the command is still running.
    func receive(_ event: ServerEvent) {
        guard event.type == "ide-warmup", let worktree = event.worktree, !worktree.isEmpty else { return }
        apply(IDEWarmupState(worktree: worktree, status: event.status ?? "ready",
                             label: event.label ?? "", message: event.message ?? ""))
    }

    /// After a reconnect the app has missed whatever happened while it was away.
    func resync(worktrees: [String]) {
        guard let service else { return }
        for worktree in worktrees where !worktree.isEmpty {
            Task { apply(await service.state(worktree: worktree)) }
        }
    }

    private func apply(_ state: IDEWarmupState) {
        guard !state.worktree.isEmpty else { return }
        if state.status == "ready" && state.label.isEmpty { states[state.worktree] = nil; return }
        states[state.worktree] = state
    }
}
