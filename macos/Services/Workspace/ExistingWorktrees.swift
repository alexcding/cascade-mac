import Foundation

/// A worktree in the worktree folder, as Settings → Worktrees lists it: a project's, or one left
/// there that no project claims (`crates/cascade-backend/src/local/worktree.rs` `shared_worktrees`).
struct ExistingWorktree: Identifiable, Equatable, Sendable {
    let path: String
    let branch: String
    /// The project whose checkout lists it, as the backend says; nil for a leftover.
    let projectID: String?
    /// That project's name, which the list shows beside it; empty for a leftover.
    var project = ""
    /// That project's checkout, which removes it.
    var workspace = ""
    /// A leftover's checkout, empty once that is gone too.
    var repo = ""
    var id: String { path }
    var name: String { branch.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : branch }
}

/// The app answers this, not the backend alone: only the app knows which worktrees a session works
/// in, and those are left out.
@MainActor protocol ExistingWorktreeManaging: AnyObject {
    func existingWorktrees() async throws -> [ExistingWorktree]
    /// The disk each of `paths` takes, in bytes, by path: slower than the list, so asked for after it.
    func worktreeSizes(of paths: [String]) async throws -> [String: Int64]
    func removeWorktree(_ worktree: ExistingWorktree) async throws
}
