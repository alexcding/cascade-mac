import SwiftUI

/// The worktree's files beside a file or the Files tab, under a field that narrows them: the same
/// panel as the diff's changed files (`FileTreePanel`). Folders start closed, but for the ones
/// down to the shown file, which is the list's selection. Choosing a file opens it.
struct WorktreeFilesTree: View {
    let model: WorktreeFilesViewModel
    let root: String?
    /// The shown file, worktree-relative, if it is in this worktree.
    var selected: String? = nil

    private var status: FileTreeStatus {
        switch model.phase {
        case .idle where model.files.isEmpty, .loading where model.files.isEmpty: .loading
        case .failed: .failed(String(localized: "Couldn't list this worktree's files."), retry: model.reload)
        default: .ready
        }
    }

    private var footer: String? {
        if model.limited { return String(localized: "Showing the first \(WorktreeFilesViewModel.matchLimit) matches") }
        return model.truncated ? String(localized: "This worktree has more files than are listed") : nil
    }

    var body: some View {
        let nodes = model.nodes
        FileTreePanel(query: Binding(get: { model.query }, set: { model.query = $0 }), nodes: nodes,
                      selection: Binding(get: { selected }, set: { id in if let id, !id.hasSuffix("/") { model.open(id) } }),
                      empty: String(localized: "No files in this worktree"), status: status, reveal: selected, footer: footer,
                      submit: { FileTreeNode.firstFile(nodes).map(model.open) }) { _ in EmptyView() }
            .onAppear { model.show(root: root) }
            .onChange(of: root) { _, value in model.show(root: value) }
            .accessibilityIdentifier("worktree-files")
    }
}

/// A breadcrumb's folder card, as ChatGPT's: the folder holding `entry` — the worktree for its root
/// crumb — as a tree on a raised card, `entry` and the folders down to the shown file open and the
/// entry marked. Its own rows, not a list's: a chevron and a name, a grey fill under the pointer.
/// Choosing a file opens it and closes the card.
struct WorktreeFolderMenu: View {
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 30
    static let maxHeight: CGFloat = 288

    let model: WorktreeFilesViewModel
    let root: String?
    /// "" for the worktree, `Scenes/` for a folder, or a file's path.
    let entry: String
    let selected: String?
    let dismiss: () -> Void
    @State private var opened: Set<String> = []

    /// The folder the entry is in; the worktree's own crumb lists the worktree.
    private var folder: String {
        guard !entry.isEmpty else { return "" }
        let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent + "/"
    }

    private var nodes: [WorktreeFileNode] {
        func find(_ nodes: [WorktreeFileNode]) -> [WorktreeFileNode]? {
            for node in nodes {
                if node.id == folder { return node.children ?? [] }
                if let children = node.children, folder.hasPrefix(node.id), let found = find(children) { return found }
            }
            return nil
        }
        return folder.isEmpty ? model.fullTree : find(model.fullTree) ?? []
    }

    /// The rows on show, each with its depth: a folder's children follow it while it is open.
    private func rows(_ nodes: [WorktreeFileNode], depth: Int = 0) -> [(node: WorktreeFileNode, depth: Int)] {
        nodes.flatMap { node -> [(node: WorktreeFileNode, depth: Int)] in
            [(node, depth)] + ((opened.contains(node.id) ? node.children : nil).map { rows($0, depth: depth + 1) } ?? [])
        }
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle where model.files.isEmpty, .loading where model.files.isEmpty:
                message(String(localized: "Loading…"))
            case .failed:
                message(String(localized: "Couldn't load folder contents"))
            default:
                let rows = rows(nodes)
                if rows.isEmpty {
                    message(String(localized: "This folder is empty"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.node.id) { row in
                                FolderMenuRow(node: row.node, depth: row.depth, open: opened.contains(row.node.id),
                                              marked: row.node.id == entry || row.node.id == selected,
                                              outlined: row.node.id == entry) {
                                    if row.node.children != nil {
                                        if opened.contains(row.node.id) { opened.remove(row.node.id) } else { opened.insert(row.node.id) }
                                    } else {
                                        model.open(row.node.id); dismiss()
                                    }
                                }
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(Self.maxHeight, CGFloat(rows.count) * Self.rowHeight + 8))
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        // The shadow is the card's shape's alone: on the whole card it reached the scroll view's own
        // layer, and every highlighted row cast one.
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paneBackground)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
        .onAppear {
            model.show(root: root)
            // The entry and every folder down to the shown file start open.
            var path = ""
            for part in (selected ?? entry).split(separator: "/").dropLast() { path += part + "/"; opened.insert(path) }
            if entry.hasSuffix("/") { opened.insert(entry) }
        }
        .accessibilityIdentifier("folder-menu")
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// One row of the folder card: a folder's chevron or a file's icon, and the name. The marked row is
/// Codex's: a grey fill inside a crisp accent hairline, never the system's blurred focus ring.
private struct FolderMenuRow: View {
    let node: WorktreeFileNode
    let depth: Int
    let open: Bool
    let marked: Bool
    /// The crumb's own entry, which the card was opened on.
    let outlined: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if node.children != nil {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 14)
                } else {
                    FileIcon(name: node.name) { Image(systemName: "doc").foregroundStyle(Theme.textTertiary) }
                        .frame(width: 16)
                }
                Text(node.name).font(.body).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + CGFloat(depth) * 16).padding(.trailing, 8)
            .frame(height: WorktreeFolderMenu.rowHeight)
            .background(marked || hovering ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { if outlined { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(node.id)
    }
}
