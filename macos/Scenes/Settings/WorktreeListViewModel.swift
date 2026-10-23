import Foundation
import Observation

/// Settings → Worktrees' list of what the worktree folder holds now: each project's worktrees, and
/// what a project removed from Cascade or a deleted checkout left there. Deleting a project never
/// touches its files; this is where its worktrees are deleted.
@MainActor @Observable final class WorktreeListViewModel {
    private(set) var groups: [ExistingWorktreeGroup] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var error: String?
    /// The worktree being deleted now.
    private(set) var removing: String?
    private(set) var retired = false
    @ObservationIgnored private weak var manager: (any ExistingWorktreeManaging)?
    /// Changes with each connection; a deletion that outlives one reports nothing.
    @ObservationIgnored private var connection = UUID()
    /// The newest read: an older one still running lands nothing, so a deleted row never returns.
    @ObservationIgnored private var readToken = UUID()
    @ObservationIgnored private var read: Task<Void, Never>?

    var isEmpty: Bool { groups.allSatisfy(\.worktrees.isEmpty) }

    func connect(_ manager: (any ExistingWorktreeManaging)?) {
        guard !retired else { return }
        self.manager = manager; connection = UUID(); readToken = UUID(); read?.cancel(); removing = nil; error = nil; loading = false
        if manager == nil { groups = []; loaded = false }
    }

    func refresh() {
        guard !retired, let manager else { return }
        read?.cancel()
        let token = UUID()
        readToken = token
        loading = true
        read = Task { [weak self] in
            do {
                let value = try await manager.existingWorktrees()
                guard let self, !Task.isCancelled, !self.retired, self.readToken == token else { return }
                self.groups = value; self.loaded = true; self.error = nil; self.loading = false
            } catch {
                guard let self, !Task.isCancelled, !self.retired, self.readToken == token else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }

    /// Deletes at once, as the row's caption says: no confirmation.
    func remove(_ worktree: ExistingWorktree) async {
        guard !retired, removing == nil, let manager else { return }
        let token = connection
        removing = worktree.path; error = nil
        do {
            try await manager.removeWorktree(worktree)
            guard !retired, connection == token else { return }
            removing = nil
            refresh()
        } catch is CancellationError {
            if !retired, connection == token { removing = nil }
        } catch {
            guard !retired, connection == token else { return }
            removing = nil; self.error = error.localizedDescription
            refresh()
        }
    }

    func disconnect() { connection = UUID(); readToken = UUID(); read?.cancel(); read = nil; manager = nil; removing = nil; loading = false }
    func retire() { retired = true; disconnect() }
}
