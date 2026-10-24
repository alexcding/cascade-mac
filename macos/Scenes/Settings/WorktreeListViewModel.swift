import Foundation
import Observation

/// Settings → Worktrees' list of the worktrees in the worktree folder no session works in: each
/// project's, and what a project removed from Cascade or a deleted checkout left there. Deleting a project removes
/// its sessions' worktrees but never one no session works in; this is where those are deleted.
@MainActor @Observable final class WorktreeListViewModel {
    private(set) var worktrees: [ExistingWorktree] = []
    /// Each worktree's size by path, once read; the list shows before them.
    private(set) var sizes: [String: Int64] = [:]
    private(set) var loaded = false
    /// The list is being read; Refresh waits for it.
    private(set) var loading = false
    /// Sizes are being measured behind the list, which never waits for them.
    private(set) var measuring = false
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

    var isEmpty: Bool { worktrees.isEmpty }
    /// What they all take together, once every size is read.
    var total: Int64? { total(of: worktrees) }
    /// What these take together, once each of their sizes is read.
    func total(of some: [ExistingWorktree]) -> Int64? {
        !some.isEmpty && some.allSatisfy { sizes[$0.path] != nil } ? some.reduce(0) { $0 + (sizes[$1.path] ?? 0) } : nil
    }

    func connect(_ manager: (any ExistingWorktreeManaging)?) {
        guard !retired else { return }
        self.manager = manager; connection = UUID(); readToken = UUID(); read?.cancel(); removing = nil; error = nil
        loading = false; measuring = false
        if manager == nil { worktrees = []; sizes = [:]; loaded = false }
    }

    /// Reads the list, then the sizes behind it: all of them when `measure`, else only those not
    /// known yet. Sizes already known stay shown meanwhile, and Refresh is free again once the list
    /// is in. After a deletion the rows that stay keep the sizes they had, and one whose size had
    /// not come in yet (the deletion cut its measuring short) is measured then.
    func refresh(measure: Bool = true) {
        guard !retired, let manager else { return }
        read?.cancel()
        let token = UUID()
        readToken = token
        loading = true; measuring = false
        read = Task { [weak self] in
            do {
                let value = try await manager.existingWorktrees()
                guard let self, !Task.isCancelled, !self.retired, self.readToken == token else { return }
                self.worktrees = value; self.loaded = true; self.error = nil; self.loading = false
                self.sizes = self.sizes.filter { size in value.contains { $0.path == size.key } }
                let wanted = value.map(\.path).filter { measure || self.sizes[$0] == nil }
                guard !wanted.isEmpty else { return }
                self.measuring = true
                let sizes = (try? await manager.worktreeSizes(of: wanted)) ?? [:]
                guard !Task.isCancelled, !self.retired, self.readToken == token else { return }
                self.sizes.merge(sizes) { _, new in new }; self.measuring = false
            } catch {
                guard let self, !Task.isCancelled, !self.retired, self.readToken == token else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }

    /// Deletes at once, without asking.
    func remove(_ worktree: ExistingWorktree) async {
        guard !retired, removing == nil, let manager else { return }
        let token = connection
        removing = worktree.path; error = nil
        do {
            try await manager.removeWorktree(worktree)
            guard !retired, connection == token else { return }
            removing = nil
            refresh(measure: false)
        } catch is CancellationError {
            if !retired, connection == token { removing = nil }
        } catch {
            guard !retired, connection == token else { return }
            removing = nil; self.error = error.localizedDescription
            refresh(measure: false)
        }
    }

    func disconnect() {
        connection = UUID(); readToken = UUID(); read?.cancel(); read = nil; manager = nil; removing = nil
        loading = false; measuring = false
    }
    func retire() { retired = true; disconnect() }
}
