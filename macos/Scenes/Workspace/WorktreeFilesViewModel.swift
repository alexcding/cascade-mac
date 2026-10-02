import Foundation
import Observation

/// A folder or file of the Files tab's tree, every folder on a row of its own, as ChatGPT's is.
struct WorktreeFileNode: Identifiable, Equatable, Sendable {
    let name: String
    /// A folder's worktree-relative path with a trailing slash, or the file's.
    let id: String
    var children: [WorktreeFileNode]? = nil

    static func tree(_ paths: [String]) -> [WorktreeFileNode] {
        final class Folder { var folders: [String: Folder] = [:]; var files: [String] = [] }
        let root = Folder()
        for path in paths {
            var folder = root
            for part in path.split(separator: "/").dropLast().map(String.init) {
                let next = folder.folders[part] ?? Folder()
                folder.folders[part] = next; folder = next
            }
            folder.files.append(path)
        }
        let ordered = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        func nodes(_ folder: Folder, path: String) -> [WorktreeFileNode] {
            let folders = folder.folders.keys.sorted(by: ordered).map { key -> WorktreeFileNode in
                let full = path + key + "/"
                return WorktreeFileNode(name: key, id: full, children: nodes(folder.folders[key]!, path: full))
            }
            let files = folder.files.map { (($0 as NSString).lastPathComponent, $0) }
                .sorted { ordered($0.0, $1.0) }
                .map { WorktreeFileNode(name: $0.0, id: $0.1) }
            return folders + files
        }
        return nodes(root, path: "")
    }
}

/// The Files tab: the worktree's files as git lists them, in the tree of their folders, and a
/// field that narrows them. One per workspace context; the list is fetched when the tab shows a
/// worktree it has not listed, and again on `reload`.
@MainActor @Observable final class WorktreeFilesViewModel {
    enum Action: Equatable { case open(String) }
    enum Phase: Equatable { case idle, loading, loaded, failed }

    /// Matches past this many are not drawn: a query of one letter in a large worktree would
    /// otherwise lay out thousands of rows.
    static let matchLimit = 500

    var query = "" { didSet { if oldValue != query { refilter() } } }
    /// Whether the tree shows beside a file and in the Files tab; one choice for the context.
    var treeShown = true { didSet { if retired { treeShown = oldValue } } }
    private(set) var phase = Phase.idle
    /// Worktree-relative, in path order.
    private(set) var files: [String] = []
    /// The backend left some files out of a very large worktree.
    private(set) var truncated = false
    /// The files the query leaves, as the shared tree draws them (`FileTreePanel`), lone folders
    /// joined onto one row: built off the main thread, never by the view as it draws.
    private(set) var nodes: [FileTreeNode<String>] = []
    /// The whole worktree's, for an empty query.
    @ObservationIgnored private var fullList: [FileTreeNode<String>] = []
    /// The whole worktree's tree, built once per listing: what an empty query shows, and what a
    /// breadcrumb's folder card reads its folder from.
    private(set) var fullTree: [WorktreeFileNode] = []
    /// More files match the query than are drawn.
    private(set) var limited = false
    private(set) var root: String?
    private(set) var retired = false
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    /// Resolved per load, so a reconnect is picked up without rebuilding the model.
    @ObservationIgnored var service: () -> (any FileSearchService)? = { nil }
    @ObservationIgnored private var task: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private var filtering: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    /// When the shown worktree was last listed.
    @ObservationIgnored private var listedAt = Date.distantPast
    /// A listing this recent is shown again as it is: the tree, a file beside it and a breadcrumb's
    /// card all ask as they appear, and the agent's new files need only show up on the next look.
    static let freshness: TimeInterval = 5

    /// Lists `root` again unless it is the worktree being listed, or listed moments ago. The files
    /// already listed stay on show while it does.
    func show(root: String?) {
        guard !retired, let root, !root.isEmpty else { return }
        if root == self.root, phase == .loading || (phase == .loaded && Date().timeIntervalSince(listedAt) < Self.freshness) { return }
        load(root)
    }

    func reload() { if !retired, let root { load(root) } }

    private func load(_ root: String) {
        // Before the service: with none yet, Try Again reloads this root once there is one.
        // Another worktree: nothing of the last one's may land after this, its filter included.
        if root != self.root { filtering = nil; files = []; fullTree = []; nodes = []; fullList = [] }
        self.root = root
        guard let service = service() else { phase = .failed; return }
        phase = .loading
        task = Task { [weak self] in
            let listed = try? await service.allFiles(in: root)
            guard !Task.isCancelled, let self, !retired, self.root == root else { return }
            listedAt = Date()
            guard let listed else { phase = .failed; return }
            truncated = listed.truncated
            // The same list again — a look moments after the last — leaves the tree as it is, so
            // its rows are not built and drawn anew.
            guard listed.files != files || fullTree.isEmpty else { phase = .loaded; return }
            // Built off the main thread: sorting every folder of a large worktree takes a while.
            let (tree, list) = await Task.detached(priority: .userInitiated) {
                (WorktreeFileNode.tree(listed.files), FileTreeNode<String>.tree(listed.files))
            }.value
            guard !Task.isCancelled, !retired, self.root == root else { return }
            files = listed.files; fullTree = tree; fullList = list
            phase = .loaded
            refilter()
        }
    }

    /// Absolute, so it opens as is.
    private func path(of relative: String) -> String? {
        root.map { ($0 as NSString).appendingPathComponent(relative) }
    }

    func open(_ relative: String) {
        guard !retired, let path = path(of: relative) else { return }
        onAction(.open(path))
    }

    /// Typing settles for `filterDelay`, then the matches are found and their tree built off the
    /// main thread; a keystroke meanwhile starts over.
    static let filterDelay: Duration = .milliseconds(60)

    private func refilter() {
        guard !retired else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { filtering = nil; limited = false; nodes = fullList; return }
        let files = files, limit = Self.matchLimit
        filtering = Task { [weak self] in
            try? await Task.sleep(for: Self.filterDelay)
            guard !Task.isCancelled else { return }
            let (list, more) = await Task.detached(priority: .userInitiated) {
                // Stops one past the limit: a common query need not scan the whole worktree.
                let matches = Array(files.lazy.filter { $0.localizedCaseInsensitiveContains(text) }.prefix(limit + 1))
                return (FileTreeNode<String>.tree(Array(matches.prefix(limit))), matches.count > limit)
            }.value
            guard !Task.isCancelled, let self, !retired, files == self.files else { return }
            limited = more; nodes = list
        }
    }

    func retire() { retired = true; task = nil; filtering = nil }
}
