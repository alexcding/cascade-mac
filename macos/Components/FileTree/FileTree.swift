import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A folder or file of a file tree, as the diff's changed files and the editor's worktree files
/// both list them. A folder holding one folder and nothing else shares its row, `Sources/App`, as
/// VS Code's compact folders do.
struct FileTreeNode<File>: Identifiable {
    let name: String
    /// A folder's path with a trailing slash, or the file's id.
    let id: String
    /// A file's path; nil for a folder.
    var path: String? = nil
    var children: [FileTreeNode]? = nil
    var file: File? = nil
    /// Every folder a shared row stands for, `Sources/` and `Sources/App/`: when the files change
    /// and the row splits or joins, a folder closed under one of those paths stays closed.
    var folders: [String] = []

    /// Folders first, then files, each in Finder's order.
    static func tree(_ files: [File], path: (File) -> String, id: (File) -> String) -> [FileTreeNode] {
        typealias Folder = FileTreeFolder<File>
        let root = Folder()
        for file in files {
            var folder = root
            for part in path(file).split(separator: "/").dropLast().map(String.init) {
                let next = folder.folders[part] ?? Folder()
                folder.folders[part] = next; folder = next
            }
            folder.files.append(file)
        }
        let ordered = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        func name(_ file: File) -> String { path(file).split(separator: "/").last.map(String.init) ?? path(file) }
        func nodes(_ folder: Folder, at prefix: String) -> [FileTreeNode] {
            let folders = folder.folders.keys.sorted(by: ordered).map { key -> FileTreeNode in
                var label = key, inner = folder.folders[key]!, full = prefix + key + "/", chain = [full]
                while inner.files.isEmpty, inner.folders.count == 1, let only = inner.folders.first {
                    label += "/" + only.key; full += only.key + "/"; inner = only.value; chain.append(full)
                }
                return FileTreeNode(name: label, id: full, children: nodes(inner, at: full), folders: chain)
            }
            let files = folder.files.sorted { ordered(name($0), name($1)) }
                .map { FileTreeNode(name: name($0), id: id($0), path: path($0), file: $0) }
            return folders + files
        }
        return nodes(root, at: "")
    }
}

extension FileTreeNode: Sendable where File: Sendable {}

extension FileTreeNode where File == String {
    /// A tree of paths, each its own id.
    static func tree(_ paths: [String]) -> [FileTreeNode] { tree(paths, path: { $0 }, id: { $0 }) }
}

/// A folder while a tree is being built: its folders by name, and its files.
private final class FileTreeFolder<File> {
    var folders: [String: FileTreeFolder] = [:]
    var files: [File] = []
}

/// The rows of a file tree inside a sidebar `List`: a folder is its icon and name, the whole row
/// opening and closing it; a file is its icon and name. The chosen file sits on a light fill in
/// the text's own colours — not the list's selection, which paints the row in the accent colour.
struct FileTreeRows<File>: View {
    let nodes: [FileTreeNode<File>]
    let expanded: (FileTreeNode<File>) -> Binding<Bool>
    var selected: String? = nil
    /// A click on a file, the chosen one included.
    var choose: (FileTreeNode<File>) -> Void = { _ in }
    /// A file whose name is struck through, as a deleted one is.
    var struck: (File) -> Bool = { _ in false }

    var body: some View {
        ForEach(nodes) { node in
            FileTreeNodeRow(node: node, expanded: expanded, selected: selected, choose: choose, struck: struck)
        }
    }
}

private struct FileTreeNodeRow<File>: View {
    let node: FileTreeNode<File>
    let expanded: (FileTreeNode<File>) -> Binding<Bool>
    let selected: String?
    let choose: (FileTreeNode<File>) -> Void
    let struck: (File) -> Bool

    var body: some View {
        if let children = node.children {
            let isExpanded = expanded(node)
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { FileTreeNodeRow(node: $0, expanded: expanded, selected: selected, choose: choose, struck: struck) }
            } label: {
                // Not a Label: a sidebar list paints a label's icon in the accent colour.
                HStack(spacing: 6) {
                    SystemFileIcon(type: .folder)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                }
                // The whole row opens and closes the folder, not only its arrow.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { isExpanded.wrappedValue.toggle() } }
            }
        } else if let file = node.file {
            HStack(spacing: 6) {
                SystemFileIcon(type: SystemFileIcon.type(of: node.name))
                Text(node.name).lineLimit(1).truncationMode(.middle).strikethrough(struck(file))
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { choose(node) }
            .listRowBackground(node.id == selected ? RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHover).padding(.horizontal, 6) : nil)
            .help(node.path ?? node.name)
            .accessibilityAddTraits(node.id == selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// Which folders of a tree are open. A tree that starts open keeps a folder open until it is closed
/// by hand; one that starts closed, shut until opened. While the filter holds text every folder
/// of a match is open, as the matches are few, unless closed by hand. A row that joins folders
/// follows all of them.
struct FileTreeExpansion: Equatable {
    let startsOpen: Bool
    /// The folders turned the other way from `startsOpen` by hand.
    private var turned: Set<String> = []
    private var closedWhileFiltering: Set<String> = []

    init(startsOpen: Bool) { self.startsOpen = startsOpen }

    func isOpen(_ folders: [String], filtering: Bool) -> Bool {
        if filtering { return !folders.contains(where: closedWhileFiltering.contains) }
        return startsOpen ? !folders.contains(where: turned.contains) : folders.allSatisfy(turned.contains)
    }

    mutating func set(_ folders: [String], open: Bool, filtering: Bool) {
        if filtering {
            if open { closedWhileFiltering.subtract(folders) } else { closedWhileFiltering.formUnion(folders) }
        } else if open == startsOpen {
            turned.subtract(folders)
        } else {
            turned.formUnion(folders)
        }
    }

    /// Opens the folders down to a file, so it can be seen where it is.
    mutating func reveal(_ path: String) {
        var folder = ""
        for part in path.split(separator: "/").dropLast() {
            folder += part + "/"
            set([folder], open: true, filtering: false)
        }
    }

    /// A new filter starts with every folder of its matches open.
    mutating func filterChanged() { closedWhileFiltering = [] }
}

/// What a panel has to show in place of its tree.
enum FileTreeStatus {
    case ready
    case loading
    case failed(String, retry: () -> Void)
}

/// A file tree under a field that narrows it: the diff's changed files and the editor's worktree
/// files are both this panel, with only their files and their messages told apart.
struct FileTreePanel<File>: View {
    @Binding var query: String
    let nodes: [FileTreeNode<File>]
    @Binding var selection: String?
    /// What the panel says when it has no files and no filter.
    let empty: String
    var status: FileTreeStatus
    /// A file whose folders are opened, so it can be seen: the one shown beside the panel.
    var reveal: String?
    /// A line under the tree, when it lists fewer files than there are.
    var footer: String?
    var submit: () -> Void
    var tapped: (File) -> Void
    var struck: (File) -> Bool
    @State private var expansion: FileTreeExpansion
    /// The list takes the arrow keys once a file is chosen in it, or Down is pressed in the field.
    @FocusState private var listFocused: Bool

    init(query: Binding<String>, nodes: [FileTreeNode<File>], selection: Binding<String?>, empty: String,
         startsOpen: Bool = false, status: FileTreeStatus = .ready, reveal: String? = nil, footer: String? = nil,
         submit: @escaping () -> Void = {}, tapped: @escaping (File) -> Void = { _ in }, struck: @escaping (File) -> Bool = { _ in false }) {
        _query = query; self.nodes = nodes; _selection = selection; self.empty = empty
        self.status = status; self.reveal = reveal; self.footer = footer
        self.submit = submit; self.tapped = tapped; self.struck = struck
        _expansion = State(initialValue: FileTreeExpansion(startsOpen: startsOpen))
    }

    private var filtering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            FileTreeFilterField(text: $query, submit: submit)
                .onKeyPress(.downArrow) { listFocused = true; return step(1) }
                .padding(.horizontal, 10).padding(.vertical, 8)
            content
        }
        .onAppear { if let reveal { expansion.reveal(reveal) } }
        .onChange(of: reveal) { _, value in if let value { expansion.reveal(value) } }
        .onChange(of: query) { _, _ in expansion.filterChanged() }
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let text, let retry):
            message(text, action: String(localized: "Try Again"), perform: retry)
        case .ready where nodes.isEmpty:
            message(filtering ? String(localized: "No files match") : empty)
        case .ready:
            List {
                FileTreeRows(nodes: nodes, expanded: expanded, selected: selection,
                             choose: { node in listFocused = true; choose(node) }, struck: struck)
                if let footer { Text(footer).font(.caption).foregroundStyle(Theme.textTertiary) }
            }
            .listStyle(.sidebar)
            // The arrow keys step through the files on show, as a list's selection would, keeping
            // the chosen row's light fill rather than the selection's accent.
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1) }
            .onKeyPress(.upArrow) { step(-1) }
        }
    }

    private func choose(_ node: FileTreeNode<File>) {
        selection = node.id
        node.file.map(tapped)
    }

    /// The files on show, in order: those under an open folder, and the top level's.
    private var visibleFiles: [FileTreeNode<File>] {
        func walk(_ nodes: [FileTreeNode<File>]) -> [FileTreeNode<File>] {
            nodes.flatMap { node -> [FileTreeNode<File>] in
                guard let children = node.children else { return [node] }
                return expansion.isOpen(node.folders, filtering: filtering) ? walk(children) : []
            }
        }
        return walk(nodes)
    }

    /// Chooses the file `delta` rows on from the chosen one, or the first or last with none chosen.
    private func step(_ delta: Int) -> KeyPress.Result {
        let files = visibleFiles
        guard !files.isEmpty else { return .ignored }
        let index = files.firstIndex { $0.id == selection }.map { $0 + delta } ?? (delta > 0 ? 0 : files.count - 1)
        choose(files[min(max(index, 0), files.count - 1)])
        return .handled
    }

    private func expanded(_ node: FileTreeNode<File>) -> Binding<Bool> {
        let folders = node.folders, filtering = filtering
        return Binding(get: { expansion.isOpen(folders, filtering: filtering) },
                       set: { expansion.set(folders, open: $0, filtering: filtering) })
    }

    private func message(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.callout).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            if let action { Button(action, action: perform) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A folder or file of a tree as Finder draws it, as a Git client's trees do: the icon macOS keeps
/// for its type, which needs no file on disk, so a deleted file has one too. Every file tree — the
/// worktree's and the diff's changed files — draws its rows with it. 16 pt; the image carries
/// every size and AppKit draws the sharpest.
struct SystemFileIcon: View {
    let type: UTType

    /// A file's type by its extension; a file without one is plain data. An extension nothing claims
    /// still has a type, one the system makes up for it, and draws as a plain document.
    static func type(of name: String) -> UTType {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
    }

    /// One image per type: a tree redraws its rows on every keystroke in its filter, and the
    /// workspace hands out a new image each time it is asked.
    @MainActor private static var icons: [UTType: NSImage] = [:]

    @MainActor private static func icon(for type: UTType) -> NSImage {
        if let hit = icons[type] { return hit }
        let image = NSWorkspace.shared.icon(for: type)
        icons[type] = image
        return image
    }

    var body: some View {
        Image(nsImage: Self.icon(for: type)).resizable().frame(width: 16, height: 16)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

/// The field over a file tree that narrows it. Return picks the first file it leaves.
struct FileTreeFilterField: View {
    @Binding var text: String
    var submit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField(String(localized: "Filter files…"), text: $text)
                .textFieldStyle(.plain)
                .onSubmit(submit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary)
                    .help(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

extension FileTreeNode {
    /// The first file in the tree's order, folders first: what Return in the filter opens.
    static func firstFile(_ nodes: [FileTreeNode]) -> File? {
        for node in nodes {
            if let children = node.children { if let file = firstFile(children) { return file } } else if let file = node.file { return file }
        }
        return nil
    }
}

/// The button that shows or hides a file tree beside what it lists, its folder filled — in the
/// same grey — while the tree is shown: the editor's worktree files and the diff's changed files alike.
struct FileTreeToggle: View {
    @Binding var shown: Bool
    var enabled = true
    /// Inside a segmented pill (`GlassSegmentedPicker`'s accessory), drawn as its segments are rather
    /// than as a circle of its own, which would stand taller than the pill.
    var inPill = false

    var body: some View {
        let title = shown ? String(localized: "Hide Files") : String(localized: "Show Files")
        let symbol = shown ? "folder.fill" : "folder"
        Group {
            if inPill {
                Button { shown.toggle() } label: {
                    Label(title, systemImage: symbol).labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            } else {
                HoverCircleButton(title, systemImage: symbol, enabled: enabled) { shown.toggle() }
            }
        }
        .help(shown ? String(localized: "Hide the files") : String(localized: "Show the files"))
        .accessibilityIdentifier("toggle-file-tree")
    }
}
