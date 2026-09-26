import SwiftUI

/// The Files panel's tab bar: the browser's compact layout over files. A folder button leads the
/// pill and opens the worktree in a file panel; the selected tab's field searches the worktree and
/// lists matching files beneath it; ＋ opens another empty tab to search from. In its own row the bar
/// hangs its results under itself; in the toolbar the pane draws them (`FileSearchResultList`), from
/// the editing state and highlight the bar keeps on the model.
struct FilesCompactTabBar: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel
    var placement: CompactTabBarPlacement = .row
    @FocusState private var editing: Bool

    private var highlighted: Int? {
        get { model.fileSearchHighlight }
        nonmutating set { model.fileSearchHighlight = newValue }
    }

    private var search: FileSearchViewModel { context.fileSearch }
    private var root: String? { model.session?.worktree }
    private var documents: [EditorDocumentViewModel] { context.fileTabs.compactMap { if case .file(let file) = $0 { file } else { nil } } }
    private var ids: [String] { documents.map(\.id) + (context.hasBlankFileTab ? [WorkspaceContext.blankFileID] : []) }
    private var results: [FileSearchViewModel.Result] { editing ? search.results : [] }
    private var placeholder: String {
        root.map { String(localized: "Search files in \(($0 as NSString).lastPathComponent)") } ?? String(localized: "Enter a file path")
    }

    var body: some View {
        CompactTabBar(newTabTitle: String(localized: "New Tab"), newTabHelp: String(localized: "Open a new file tab"), newTab: { context.fillerFileTab = false; model.newFileTab() },
                      placement: placement) {
            HoverCircleButton(String(localized: "Open File…"), systemImage: "folder", enabled: model.canOpenTab, action: model.openFile)
                .help(root == nil ? String(localized: "Choose a file to open") : String(localized: "Choose a file from this worktree"))
                .barGlass()
        } pill: { available in
            CompactTabPill(ids: ids, activeID: context.activeID, available: available,
                           select: { id in documents.first { $0.id == id }.map { model.selectTab(.file($0)) } }, move: model.moveTab,
                           // The blank tab is not a saved tab: it always trails the files and has no place to move to.
                           canMove: { $0 != WorkspaceContext.blankFileID }) { id, iconOnly in
                if let file = documents.first(where: { $0.id == id }) {
                    tab(label: file.title, help: file.record.path, id: id, blank: false, dirty: file.dirty, closable: true, iconOnly: iconOnly,
                        select: { model.selectTab(.file(file)) }, close: { model.closeTab(.file(file)) })
                } else {
                    // A lone blank tab has nothing to close: closing it would only make another.
                    tab(label: context.blankFileActive ? "" : String(localized: "New Tab"), help: placeholder, id: id, blank: true, dirty: false,
                        closable: !documents.isEmpty, iconOnly: iconOnly, select: model.selectBlankFileTab, close: model.closeBlankFileTab)
                }
            }
        } suggestions: {
            FileSearchResultList(context: context, model: model)
        }
        .onChange(of: results.map(\.id)) { _, _ in highlighted = nil }
        // Searching is driven from here, once per keystroke, never from the body.
        .onChange(of: search.query) { _, _ in search.search(in: root) }
        .transaction(value: context.id) { $0.animation = nil }
        .animation(.snappy(duration: 0.3), value: context.fileEdits)
        // A files panel always has a field to search from, as the browser always has an address.
        .onChange(of: needsBlankTab, initial: true) { _, needed in
            if needed { context.fillerFileTab = true; model.newFileTab() }
        }
        // The flag describes one blank tab only: once that tab is used or closed, the next blank is
        // one the user asked for, and takes the keyboard.
        .onChange(of: context.hasBlankFileTab) { _, exists in if !exists { context.fillerFileTab = false } }
        // Leaving a tab, or the field, drops the text: a file tab shows its file, not a stale query.
        .onChange(of: context.activeID) { _, _ in editing = false; search.reset() }
        .onChange(of: editing) { _, value in
            model.setSearchingFiles(value)
            if !value { highlighted = nil; search.reset() }
        }
        // The reverse: a result picked from the list, drawn apart from the bar, releases the field.
        .onChange(of: model.searchingFiles) { _, value in if !value { editing = false } }
        // A hidden workspace stays mounted, and opacity does not drop first responder: release the
        // field when this workspace leaves the screen, or the terminal shown instead loses keystrokes.
        .onChange(of: model.isActive) { _, visible in if !visible { editing = false } }
        // A bar taken down — the inspector closing, or rebuilt for another session — sees no change
        // to `editing` on the way out: drop the text here, or the field comes back with it.
        .onDisappear { search.reset(); model.setSearchingFiles(false) }
    }

    private func tab(label: String, help: String, id: String, blank: Bool, dirty: Bool, closable: Bool, iconOnly: Bool,
                     select: @escaping () -> Void, close: @escaping () -> Void) -> some View {
        @Bindable var search = search
        return CompactTabShell(label: label, placeholder: placeholder, closeTitle: label.isEmpty ? String(localized: "Close Tab") : String(localized: "Close \(label)"), help: help,
                               active: id == context.activeID, workspaceActive: model.isActive, blank: blank, autoFocus: !context.fillerFileTab,
                               closable: closable, iconOnly: iconOnly, editable: blank, text: $search.query, editing: $editing, moveHighlight: moveHighlight,
                               submit: submit, select: select, close: close) {
            if !blank { Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Theme.textTertiary) }
            // An icon-only tab must still be something to click.
            else if iconOnly { Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.textTertiary) }
        } accessories: { _ in
            // Unsaved edits, where the browser shows reload.
            Circle().fill(Theme.textSecondary).frame(width: 7, height: 7).frame(width: 24, height: 24)
                .opacity(dirty ? 1 : 0)
                .accessibilityLabel(String(localized: "Unsaved changes")).accessibilityHidden(!dirty)
        }
    }

    private func moveHighlight(_ delta: Int) -> Bool {
        guard !results.isEmpty else { return false }
        highlighted = compactHighlight(highlighted, moving: delta, count: results.count)
        return true
    }

    private func submit() -> Bool {
        if let index = highlighted, results.indices.contains(index) { search.open(results[index].path); return true }
        return search.submit()
    }

    // Not while restoring: the saved file tabs have not landed yet.
    private var needsBlankTab: Bool { ids.isEmpty && model.canOpenTab && !context.restoring }
}

/// The files matching the search field: hung from the bar in its own row, or from the top of the
/// pane while the bar is in the toolbar. Picking one lets go of the field through the model, which
/// the bar follows wherever it is drawn.
struct FileSearchResultList: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        let search = context.fileSearch
        if model.searchingFiles, !search.results.isEmpty {
            CompactSuggestionList(items: search.results, highlighted: model.fileSearchHighlight, accessibilityLabel: String(localized: "Matching files"),
                                  heading: { _ in nil }, title: \.name, detail: \.folder,
                                  pick: { search.open($0.path); model.setSearchingFiles(false) }) { _ in
                CompactSuggestionSymbol(systemImage: "doc.text")
            }
        }
    }
}
