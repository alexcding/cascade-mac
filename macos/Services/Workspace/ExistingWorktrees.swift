import Foundation

/// A worktree in the worktree folder, as Settings → Worktrees lists it: a project's, or one left
/// there that no project claims (`crates/cascade-backend/src/local/worktree.rs` `shared_worktrees`).
struct ExistingWorktree: Identifiable, Equatable, Sendable {
    let path: String
    let branch: String
    /// The project whose checkout lists it, as the backend says; nil for a leftover.
    let projectID: String?
    /// That project's checkout, which removes it.
    var workspace = ""
    /// A leftover's checkout, empty once that is gone too.
    var repo = ""
    /// The sessions working in it, by name: removing it removes them.
    var sessions: [String] = []
    var id: String { path }
    var name: String { branch.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : branch }
}

/// A project's worktrees, or the leftovers, under one heading.
struct ExistingWorktreeGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let worktrees: [ExistingWorktree]
}

/// The app answers this, not the backend alone: a worktree a session works in goes through that
/// session's removal, which stops its terminals and forgets the session with it.
@MainActor protocol ExistingWorktreeManaging: AnyObject {
    func existingWorktrees() async throws -> [ExistingWorktreeGroup]
    func removeWorktree(_ worktree: ExistingWorktree) async throws
}
