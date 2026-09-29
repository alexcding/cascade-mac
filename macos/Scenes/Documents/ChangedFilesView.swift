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

/// A folder or file of the list. A folder holding one folder and nothing else shares its row,
/// `Sources/App`, as VS Code's compact folders do.
struct ChangedFileNode: Identifiable {
    let name: String
    /// A folder's path with a trailing slash, or the file's id.
    let id: String
    var children: [ChangedFileNode]? = nil
    var file: ChangedFile? = nil
    /// Every folder a shared row stands for, `Sources/` and `Sources/App/`: when the files change
    /// and the row splits or joins, a folder closed under one of those paths stays closed.
    var folders: [String] = []

    static func tree(_ files: [ChangedFile]) -> [ChangedFileNode] {
        final class Folder { var folders: [String: Folder] = [:]; var files: [ChangedFile] = [] }
        let root = Folder()
        for file in files {
            var folder = root
            for part in file.path.split(separator: "/").dropLast().map(String.init) {
                let next = folder.folders[part] ?? Folder()
                folder.folders[part] = next; folder = next
            }
            folder.files.append(file)
        }
        let ordered = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        func nodes(_ folder: Folder, path: String) -> [ChangedFileNode] {
            let folders = folder.folders.keys.sorted(by: ordered).map { key -> ChangedFileNode in
                var name = key, inner = folder.folders[key]!, full = path + key + "/", chain = [full]
                while inner.files.isEmpty, inner.folders.count == 1, let only = inner.folders.first {
                    name += "/" + only.key; full += only.key + "/"; inner = only.value; chain.append(full)
                }
                return ChangedFileNode(name: name, id: full, children: nodes(inner, path: full), folders: chain)
            }
            let files = folder.files.sorted { ordered($0.name, $1.name) }.map { ChangedFileNode(name: $0.name, id: $0.id, file: $0) }
            return folders + files
        }
        return nodes(root, path: "")
    }
}

/// The changed files beside the diff, in the tree of their folders. Choosing one scrolls the diff
/// to it; choosing it again goes back to it.
struct ChangedFilesView: View {
    let files: [ChangedFile]
    let reveal: (ChangedFile) -> Void
    @State private var selection: String?
    @State private var collapsed: Set<String> = []
    /// The file a click has just chosen. A click both changes the selection and taps the row: the
    /// change scrolls, and the tap that follows leaves it be. A click on the file already chosen
    /// changes nothing, so its tap is what scrolls back.
    @State private var chosenByClick: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(ChangedFileNode.tree(files)) { ChangedFileNodeRow(node: $0, collapsed: $collapsed, reveal: tapped) }
        }
        .listStyle(.sidebar)
        .overlay {
            if files.isEmpty {
                Text(String(localized: "No changed files")).font(.callout).foregroundStyle(Theme.textTertiary)
            }
        }
        .onChange(of: selection) { _, id in
            guard let file = files.first(where: { $0.id == id }) else { return }
            reveal(file)
            // The arrow keys move the selection with no tap to follow.
            chosenByClick = NSApp.currentEvent?.type == .keyDown ? nil : file.id
        }
        .accessibilityLabel(String(localized: "Changed files"))
        .accessibilityIdentifier("changed-files")
    }

    private func tapped(_ file: ChangedFile) {
        if chosenByClick == file.id { chosenByClick = nil } else { reveal(file) }
    }
}

private struct ChangedFileNodeRow: View {
    let node: ChangedFileNode
    @Binding var collapsed: Set<String>
    let reveal: (ChangedFile) -> Void

    var body: some View {
        if let children = node.children {
            let expanded = Binding(get: { !node.folders.contains(where: collapsed.contains) },
                                   set: { if $0 { collapsed.subtract(node.folders) } else { collapsed.insert(node.id) } })
            DisclosureGroup(isExpanded: expanded) {
                ForEach(children) { ChangedFileNodeRow(node: $0, collapsed: $collapsed, reveal: reveal) }
            } label: {
                // Not a Label: a sidebar list paints a label's icon in the accent colour.
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(Theme.textTertiary).frame(width: 16)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                }
                // The whole row opens and closes the folder, not only its arrow.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded.wrappedValue.toggle() } }
                // A folder is never chosen, so it never takes the selection's highlight. On the
                // label, not the group: the files inside stay selectable.
                .selectionDisabled()
            }
        } else if let file = node.file {
            ChangedFileRow(file: file)
                .tag(file.id)
                // Selection only reports a change; a click on the chosen row still goes back to it.
                .simultaneousGesture(TapGesture().onEnded { reveal(file) })
        }
    }
}

private struct ChangedFileRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: file.name) { Image(systemName: "doc").foregroundStyle(Theme.textTertiary) }
            Text(file.name).lineLimit(1).truncationMode(.middle).strikethrough(file.status == .deleted)
            Spacer(minLength: 4)
            Group {
                if file.adds > 0 { Text(verbatim: "+\(file.adds)").foregroundStyle(Theme.success) }
                if file.dels > 0 { Text(verbatim: "−\(file.dels)").foregroundStyle(Theme.danger) }
            }.font(.caption.monospacedDigit())
            Text(verbatim: file.status.letter).font(.caption.weight(.semibold)).foregroundStyle(file.status.color).frame(width: 12)
        }
        .contentShape(Rectangle())
        .help(file.path)
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
