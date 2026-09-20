import Foundation
import Observation

struct SessionRemovalPlan: Sendable {
    let record: WorkspaceSession
    let sessions: [WorkspaceSession]
    let removesWorktree: Bool
    let holders: [String]
    var pairKeys: Set<String> {
        Set(sessions.flatMap { [$0.id, "build:\($0.url)"] })
    }
    static func path(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path }
}

protocol SessionRemoving: Sendable {
    func prepare(record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession]) async throws -> SessionRemovalPlan
    func remove(_ plan: SessionRemovalPlan) async throws
}

struct SessionRemovalService: SessionRemoving {
    let api: APIClient
    let stopTerminals: @Sendable (Set<String>) async throws -> Void

    func prepare(record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession]) async throws -> SessionRemovalPlan {
        struct Worktree: Decodable, Sendable { let path: String }
        struct Holder: Decodable, Sendable { let command: String; let pid: Int }
        struct Holders: Decodable, Sendable { let holders: [Holder] }
        let hasProject = projects.contains { $0.id == record.projectId }
        let trees: [Worktree] = hasProject
            ? try await api.get(APIClient.query(Routes.WORKTREES, ["path": record.workspace])) : []
        let linked = trees.contains { SessionRemovalPlan.path($0.path) == SessionRemovalPlan.path(record.worktree) }
        let affected = linked ? sessions.filter { SessionRemovalPlan.path($0.worktree) == SessionRemovalPlan.path(record.worktree) } : [record]
        let holders: Holders = linked
            ? try await api.get(APIClient.query(Routes.WORKTREE_HOLDERS, ["path": record.worktree])) : Holders(holders: [])
        return .init(record: record, sessions: affected, removesWorktree: linked,
                     holders: holders.holders.map { "\($0.command) (PID \($0.pid))" })
    }

    func remove(_ plan: SessionRemovalPlan) async throws {
        // A new session may have attached to this checkout while confirmation was
        // open. Require a fresh preview so it is never stopped without disclosure.
        let current: [WorkspaceSession] = try await api.get(Routes.TASKS)
        if plan.removesWorktree {
            let related = current.filter { SessionRemovalPlan.path($0.worktree) == SessionRemovalPlan.path(plan.record.worktree) }
            guard Set(related.map(\.id)) == Set(plan.sessions.map(\.id)) else {
                throw BackendError.operation("Sessions using this worktree changed. Close this dialog and review removal again.")
            }
        }
        try await stopTerminals(plan.pairKeys)
        if plan.removesWorktree {
            struct Payload: Encodable, Sendable { let path: String; let worktree: String; let force: Bool }
            // Always forced, as the web app was: a dirty, locked or stale worktree must never
            // leave the session half-removed. The sheet says so before it gets here.
            let _: OperationOK = try await api.request(Routes.WORKTREE_REMOVE, method: "POST", body:
                Payload(path: plan.record.workspace, worktree: plan.record.worktree, force: true))
        }
        for session in plan.sessions {
            let _: OperationOK = try await api.request(APIClient.query(Routes.TASKS, ["id": session.id]),
                                                      method: "DELETE", body: [String: String]())
        }
    }
}

@MainActor @Observable final class SessionRemovalViewModel {
    enum Action { case removed([WorkspaceSession]) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    private(set) var plan: SessionRemovalPlan?
    private(set) var loading = true
    private(set) var removing = false
    private(set) var completed = false
    private(set) var retired = false
    private(set) var error: String?
    private var service: (any SessionRemoving)?
    private var loadGeneration = UUID()
    private var preparing = false
    private let record: WorkspaceSession
    private let projects: [Project]
    private let sessions: [WorkspaceSession]
    private let didRemove: ([WorkspaceSession]) async -> Void
    private let finished: () -> Void
    init(service: any SessionRemoving, record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession],
         didRemove: @escaping ([WorkspaceSession]) async -> Void, finished: @escaping () -> Void) {
        self.service = service; self.record = record; self.projects = projects; self.sessions = sessions; self.didRemove = didRemove
        self.finished = finished
    }
    var canRemove: Bool { !retired && !completed && !loading && !removing && plan != nil }
    /// The words the system confirmation shows. Plain: what stops, what is deleted, what survives.
    var promptTitle: String { plan?.removesWorktree == true ? "Remove this session?" : "Forget this session?" }
    var confirmLabel: String { plan?.removesWorktree == true ? "Remove Session" : "Forget Session" }
    var promptMessage: String {
        guard let plan else { return "" }
        var lines = [plan.record.worktree]
        if plan.removesWorktree {
            lines.append("The terminal stops and this folder is deleted. Your branch and its commits stay, but anything not committed here is lost.")
            if plan.sessions.count > 1 {
                let names = plan.sessions.map { $0.title.isEmpty ? $0.label : $0.title }
                lines.append("\(plan.sessions.count) sessions use this folder, so all of them go: \(names.joined(separator: ", ")).")
            }
            if !plan.holders.isEmpty {
                lines.append("Still open in \(plan.holders.joined(separator: ", ")). Xcode is asked to close it.")
            }
        } else {
            lines.append("No project here owns this folder. The terminal stops and Craft forgets the session — the folder itself stays.")
        }
        return lines.joined(separator: "\n\n")
    }
    func retire() {
        retired = true; service = nil; onAction = { _ in }
        loadGeneration = UUID(); loading = false; plan = nil
    }
    func load() async {
        guard !retired, !completed, !preparing, !removing, !Task.isCancelled, let service else { return }
        let generation = UUID(); loadGeneration = generation
        preparing = true; loading = true; error = nil; plan = nil
        defer { preparing = false; if loadGeneration == generation { loading = false } }
        do {
            let plan = try await service.prepare(record: record, projects: projects, sessions: sessions)
            guard !retired, loadGeneration == generation, !Task.isCancelled else { return }
            self.plan = plan
        } catch { if !retired && loadGeneration == generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func remove() async {
        guard canRemove, !Task.isCancelled, let plan, let service else { return }
        removing = true; error = nil
        // Once removal starts, retain cleanup even if its presentation is retired.
        let action = onAction
        defer { removing = false; finished() }
        do {
            try await service.remove(plan)
            await didRemove(plan.sessions)
            completed = true
            let shouldComplete = !retired
            retire()
            if shouldComplete { action(.removed(plan.sessions)) }
        } catch { if !retired { self.error = error.localizedDescription } }
    }
}
