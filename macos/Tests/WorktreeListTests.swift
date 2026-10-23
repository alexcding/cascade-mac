import Foundation
import Testing

@MainActor final class WorktreeManagerFixture: ExistingWorktreeManaging {
    var worktrees: [ExistingWorktree] = []
    var sizes: [String: Int64] = [:]
    var removed: [String] = []
    var failure: String?
    func existingWorktrees() async throws -> [ExistingWorktree] { worktrees }
    func worktreeSizes() async throws -> [String: Int64] { sizes }
    func removeWorktree(_ worktree: ExistingWorktree) async throws {
        if let failure { throw BackendError.operation(failure) }
        removed.append(worktree.path)
        worktrees.removeAll { $0.path == worktree.path }
    }
}

@MainActor @Test func worktreeListDeletesAtOnceAndReadsTheFolderAgain() async {
    let fixture = WorktreeManagerFixture()
    let mine = ExistingWorktree(path: "/w/app-1/feat", branch: "feat", projectID: "p", project: "App")
    let left = ExistingWorktree(path: "/w/gone-2/fix", branch: "", projectID: nil)
    fixture.worktrees = [mine, left]
    fixture.sizes = [mine.path: 2_000, left.path: 500]
    let model = WorktreeListViewModel()
    model.connect(fixture)
    model.refresh()
    while !model.loaded || model.loading { await Task.yield() }
    #expect(model.worktrees.map(\.path) == [mine.path, left.path])
    #expect(model.sizes[mine.path] == 2_000 && model.total == 2_500, "each size, and the total once all are read")
    #expect(model.total(of: [mine]) == 2_000, "a project's own total")
    #expect(left.name == "fix", "a worktree with no branch goes by its folder")

    fixture.sizes = [:]
    await model.remove(left)
    #expect(fixture.removed == [left.path])
    while model.loading { await Task.yield() }
    #expect(!model.measuring, "a deletion measures nothing again")
    #expect(model.worktrees.map(\.path) == [mine.path] && model.removing == nil && model.error == nil)
    #expect(model.total == 2_000)

    fixture.failure = "busy"
    await model.remove(mine)
    #expect(model.error?.contains("busy") == true && model.removing == nil)

    model.retire()
    fixture.failure = nil
    await model.remove(mine)
    #expect(fixture.removed == [left.path], "a retired list deletes nothing")
}

/// A worktree moved into Cascade's folder: the file tabs and file visits saved for its session
/// follow it, and nothing outside it or of another session changes.
@MainActor @Test func savedFileTabsFollowAMovedWorktree() throws {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("page-tabs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cache) }
    struct Cache: Codable { let snapshots: [String: ContextSnapshot]; let pending: Set<String> }
    var moved = ContextSnapshot()
    moved.documents = [.init(id: "a", path: "/code/app.worktrees/fix/Sources/App.swift"), .init(id: "b", path: "/elsewhere/notes.md")]
    moved.fileHistory = [.init(id: "c", path: "/code/app.worktrees/fix/README.md"), .init(id: "d", path: "/code/app.worktrees/fixed/x")]
    var untouched = ContextSnapshot()
    untouched.documents = [.init(id: "e", path: "/code/app.worktrees/fix/Other.swift")]
    try JSONEncoder().encode(Cache(snapshots: ["task:one": moved, "task:two": untouched], pending: [])).write(to: cache)

    ViewerStore(cacheURL: cache).moveFiles(contextIDs: ["task:one"], from: "/code/app.worktrees/fix/", to: "/w/app-1234abcd/fix")
    let written = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cache))
    #expect(written.snapshots["task:one"]?.documents?.map(\.path) == ["/w/app-1234abcd/fix/Sources/App.swift", "/elsewhere/notes.md"])
    #expect(written.snapshots["task:one"]?.documents?.map(\.id) == ["a", "b"], "the tabs keep their identity")
    #expect(written.snapshots["task:one"]?.fileHistory?.map(\.path) == ["/w/app-1234abcd/fix/README.md", "/code/app.worktrees/fixed/x"])
    #expect(written.snapshots["task:two"]?.documents?.map(\.path) == ["/code/app.worktrees/fix/Other.swift"])
}
