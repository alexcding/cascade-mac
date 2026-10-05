import SwiftUI

/// A file tab, or the Files tab with no file yet, as ChatGPT's file viewer is: a row on top with
/// the file's path as a breadcrumb, Save, and the button that shows the worktree's tree; under it
/// the file — or, in the Files tab, what to do — with the tree beside it on the trailing side.
struct WorkspaceFileBrowser: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel
    /// Nil in the Files tab.
    let document: EditorDocumentViewModel?
    /// The Files tab shown, whose tree this is; nil for a file tab.
    var filesTab: WorkspaceToolTab? = nil

    /// The crumb whose folder is dropped down, and where its card hangs.
    private struct CrumbMenu: Equatable { let index: Int; let entry: String; let x: CGFloat }
    @State private var menu: CrumbMenu?
    @State private var width: CGFloat = 0

    private var files: WorktreeFilesViewModel { context.worktreeFiles(for: filesTab) }
    private var root: String? { model.session?.worktree }

    /// The shown file relative to the worktree, when it is inside it.
    private var relative: String? {
        guard let path = document?.record.path, let root, !root.isEmpty else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// The project's folder name, then the folders down to the file, each with its place in the
    /// tree — "" for the worktree, `Scenes/` for a folder, the file's own path — so it can drop
    /// down its folder. A file outside the worktree shows its last folders, none of them a place
    /// in the tree. The Files tab shows the root alone.
    private var crumbs: [FileCrumb] {
        guard let root else {
            guard let document else { return [FileCrumb(name: "/", entry: nil)] }
            return document.record.path.split(separator: "/").suffix(4).map { FileCrumb(name: String($0), entry: nil) }
        }
        // The project's folder, not the worktree's: a worktree is named after its branch, which is
        // long and says nothing about where the file is.
        let folder = model.session.map(\.workspace).flatMap { $0.isEmpty ? nil : $0 } ?? root
        let rootCrumb = FileCrumb(name: (folder as NSString).lastPathComponent, entry: "")
        guard let document else { return [rootCrumb] }
        guard let relative else {
            return document.record.path.split(separator: "/").suffix(4).map { FileCrumb(name: String($0), entry: nil) }
        }
        let parts = relative.split(separator: "/").map(String.init)
        return [rootCrumb] + parts.indices.map { index in
            FileCrumb(name: parts[index], entry: parts[...index].joined(separator: "/") + (index < parts.count - 1 ? "/" : ""))
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            if let menu {
                // A click anywhere else closes the card, and goes no further.
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { self.menu = nil }
                WorktreeFolderMenu(model: files, root: root, entry: menu.entry, selected: relative) { self.menu = nil }
                    .offset(x: max(8, min(menu.x, width - WorktreeFolderMenu.width - 8)), y: CompactTabMetrics.barHeight - 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .coordinateSpace(.named(FileBreadcrumb.space))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onExitCommand { menu = nil }
        .animation(.easeOut(duration: 0.12), value: menu)
        // Another file or tab: the card was for the last one.
        .onChange(of: document?.id) { _, _ in menu = nil }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if files.treeShown, root != nil {
                // The tree keeps its width as the pane is resized, and its divider can be dragged. The
                // two minimums fit the narrowest pane.
                ThinSplitView(leading: .init(min: 140), trailing: .init(min: 120, ideal: 240, max: 400)) {
                    FileBrowserMain(document: document, hasRoot: true)
                } trailingContent: {
                    WorktreeFilesTree(model: files, root: root, selected: relative)
                }
            } else {
                FileBrowserMain(document: document, hasRoot: root != nil)
            }
        }
        // Not into the safe area, as a background goes by default: the pane draws its tab strip
        // there, above this view, and the background would paint over it.
        .paneSurface(ignoresSafeAreaEdges: [])
    }

    /// The browser's address row, drawn the same way (`BrowserCompactTabBar`, part `address`): the
    /// path in the address's pill, and the file's buttons after it in a capsule of their own, as
    /// Reload and the bookmark are — one height and one look for both.
    private var header: some View {
        HStack(spacing: 8) {
            FileBreadcrumb(crumbs: crumbs) { index, entry, x in
                menu = menu?.index == index ? nil : CrumbMenu(index: index, entry: entry, x: x)
            }
            if let document {
                if document.readOnly { Text(String(localized: "Read Only")).font(.callout).foregroundStyle(Theme.textSecondary) }
                if document.loading || document.saving { ProgressView().controlSize(.small) }
            }
            if document != nil || root != nil { actions }
        }
        .padding(.horizontal, 12)
        .frame(height: CompactTabMetrics.barHeight)
        .environment(\.compactTabStyle, .outlined)
    }

    /// Save, then the button that shows the tree, filled while it is shown.
    private var actions: some View {
        HStack(spacing: 0) {
            if let document {
                let canSave = document.loaded && !document.readOnly && !document.saving && !document.closing
                HoverCircleButton(String(localized: "Save"), asset: "FloppyDisk", enabled: canSave) {
                    Task { await document.save() }
                }
                // Unsaved edits: a dot on Save, the one place the file's state shows.
                .overlay(alignment: .topTrailing) {
                    if document.dirty {
                        Circle().fill(Theme.warn).frame(width: 7, height: 7).offset(x: -6, y: 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .help(document.dirty ? String(localized: "Save this file's changes") : String(localized: "Save this file"))
                .accessibilityValue(document.dirty ? String(localized: "Unsaved changes") : "")
                .accessibilityIdentifier("save-file")
            }
            if document != nil, root != nil { Divider().frame(height: 16) }
            if root != nil {
                FileTreeToggle(shown: Binding(get: { files.treeShown }, set: { files.treeShown = $0 }))
            }
        }
        .padding(.horizontal, document != nil && root != nil ? 2 : 0)
        .barGlass()
    }

}

/// The file, or in the Files tab what to do. Its own view, so a split's pane reads it in its body.
private struct FileBrowserMain: View {
    let document: EditorDocumentViewModel?
    let hasRoot: Bool

    var body: some View {
        if let document {
            EditorDocumentView(model: document).id(document.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(Theme.textSecondary)
                Text(String(localized: "Open file")).font(Theme.Typography.emptyTitle)
                Text(hasRoot ? String(localized: "Select a file from the workspace tree")
                             : String(localized: "This workspace has no worktree to open files from."))
                    .font(Theme.Typography.emptyHint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The file's path as a row of folders, the file itself a little bolder at the end. Clicking a crumb
/// drops down the folder it is in, as ChatGPT's does (`WorktreeFolderMenu`), hung under the crumb.
/// One crumb: its name, and its place in the worktree's tree if it has one.
private struct FileCrumb {
    let name: String
    let entry: String?
}

private struct FileBreadcrumb: View {
    static let space = "file-browser"
    let crumbs: [FileCrumb]
    /// The crumb clicked, its place in the tree, and its leading edge in the browser.
    let open: (Int, String, CGFloat) -> Void
    @State private var edges: [Int: CGFloat] = [:]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary) }
                let last = index == crumbs.count - 1
                let entry = crumb.entry
                Button { if let entry { open(index, entry, (edges[index] ?? 0) - 8) } } label: {
                    Text(crumb.name).lineLimit(1)
                        .foregroundStyle(last ? .primary : Theme.textSecondary)
                        .fontWeight(last ? .medium : .regular)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry == nil)
                // The file's name gives way last.
                .layoutPriority(last ? 1 : 0)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minX } action: { edges[index] = $0 }
            }
        }
        .truncationMode(.middle)
        // The strip's size: the file stands out by its weight, not by being larger.
        .font(CompactTabMetrics.stripTabFont)
        // The address's shapes: a raised capsule inside the bordered pill, filling the row.
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CompactTabMetrics.tabHeight)
        .background(ActiveTabCapsule())
        .padding(CompactTabMetrics.pillInset)
        .frame(height: CompactTabMetrics.pillHeight)
        .background(Theme.surfaceHover, in: Capsule())
        .pixelOutline(Capsule())
        // Each crumb stays its own button: merged, VoiceOver could not open a folder.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Path"))
    }
}
