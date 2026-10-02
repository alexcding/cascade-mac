import AppKit
import SwiftUI

/// A file the working changes touch, as the list beside the diff shows it. `index` is its place
/// among the diff page's files, or among the untracked files, which is how the page finds it.
struct ChangedFile: Equatable, Identifiable {
    enum Status: String { case modified, added, deleted, renamed, untracked }
    let path: String
    let status: Status
    let index: Int
    /// By path, not place: a list redrawn after a commit keeps its selection on the same file.
    var id: String { "\(status == .untracked ? "u" : "f"):\(path)" }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// A bound on what a message may carry, well past what the page draws; the page decides how
    /// many it lists.
    static let maxEntries = 1000

    /// The page's `files` message — the files it drew, then the untracked ones it listed — or nil for
    /// anything that is not one. An entry the list cannot show, a path the page could not read, is
    /// left out, and the rest keep their places.
    static func decode(files: Any?, untracked: Any?) -> [ChangedFile]? {
        guard let items = files as? [[String: Any]], items.count <= maxEntries,
              let paths = untracked as? [String], paths.count <= maxEntries else { return nil }
        let valid = { (path: String) in !path.isEmpty && path.utf8.count <= 4096 }
        let tracked = items.enumerated().compactMap { index, item -> ChangedFile? in
            guard let path = item["path"] as? String, valid(path),
                  let status = (item["status"] as? String).flatMap(Status.init), status != .untracked else { return nil }
            return .init(path: path, status: status, index: index)
        }
        let loose = paths.enumerated().compactMap { index, path in
            valid(path) ? ChangedFile(path: path, status: .untracked, index: index) : nil
        }
        return tracked + loose
    }
}

/// A folder or file of the list beside the diff (`FileTreeNode`).
typealias ChangedFileNode = FileTreeNode<ChangedFile>

extension FileTreeNode where File == ChangedFile {
    static func tree(_ files: [ChangedFile]) -> [ChangedFileNode] { tree(files, path: \.path, id: \.id) }
}

/// The changed files beside the diff, in the tree of their folders, under a field that narrows
/// them: the same panel, rows and icons as the editor's worktree files (`FileTreePanel`). Each row
/// is its icon and name alone, with no counts or status letter, so the narrow column keeps its
/// width for names; a deleted file is struck through. Choosing one scrolls the diff to it;
/// choosing it again goes back to it.
struct ChangedFilesView: View {
    let files: [ChangedFile]
    let reveal: (ChangedFile) -> Void
    @State private var query = ""
    @State private var selection: String?

    private var shown: [ChangedFile] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let nodes = ChangedFileNode.tree(shown)
        FileTreePanel(query: $query, nodes: nodes, selection: $selection, empty: String(localized: "No changed files"),
                      startsOpen: true, submit: { ChangedFileNode.firstFile(nodes).map(reveal) }, tapped: reveal,
                      struck: { $0.status == .deleted })
        .accessibilityLabel(String(localized: "Changed files"))
        .accessibilityIdentifier("changed-files")
    }
}
