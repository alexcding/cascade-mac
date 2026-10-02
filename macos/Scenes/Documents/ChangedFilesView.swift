import AppKit
import SwiftUI

/// A file the working changes touch, as the list beside the diff shows it. `index` is its place
/// among the diff page's files, or among the untracked files, which is how the page finds it.
struct ChangedFile: Equatable, Identifiable {
    enum Status: String { case modified, added, deleted, renamed, untracked }
    let path: String
    let status: Status
    let adds: Int
    let dels: Int
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
                  let status = (item["status"] as? String).flatMap(Status.init), status != .untracked,
                  let adds = item["adds"] as? Int, let dels = item["dels"] as? Int, adds >= 0, dels >= 0 else { return nil }
            return .init(path: path, status: status, adds: adds, dels: dels, index: index)
        }
        let loose = paths.enumerated().compactMap { index, path in
            valid(path) ? ChangedFile(path: path, status: .untracked, adds: 0, dels: 0, index: index) : nil
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
/// them: the same panel as the editor's worktree files (`FileTreePanel`). Choosing one scrolls
/// the diff to it; choosing it again goes back to it.
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
                      struck: { $0.status == .deleted }) { file in
            Group {
                if file.adds > 0 { Text(verbatim: "+\(file.adds)").foregroundStyle(Theme.success) }
                if file.dels > 0 { Text(verbatim: "−\(file.dels)").foregroundStyle(Theme.danger) }
            }.font(.caption.monospacedDigit())
            Text(verbatim: file.status.letter).font(.caption.weight(.semibold)).foregroundStyle(file.status.color).frame(width: 12)
        }
        .accessibilityLabel(String(localized: "Changed files"))
        .accessibilityIdentifier("changed-files")
    }
}

private extension ChangedFile.Status {
    /// Git's letter for the change, as the diff's own badges and VS Code show it.
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        }
    }
    var color: Color {
        switch self {
        case .modified: Theme.warn
        case .added, .untracked: Theme.success
        case .deleted: Theme.danger
        case .renamed: Theme.accent
        }
    }
}
