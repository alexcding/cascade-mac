import SwiftUI

/// Safari's compact tab layout: every tab — web pages and worktree files alike, in one order —
/// sits inside one pill, and the selected page is a raised glass capsule that doubles as the
/// address bar. Its close button is at the leading edge, the site icon and host are centred,
/// Reload and the bookmark sit after it in a capsule of their own; clicking the host edits the address. The address field also searches the
/// session's worktree, and a file picked from it opens as a tab of its own. There is no second
/// row: back/forward lead the pill, New Tab and Recently Closed trail it. In its own row, or at the
/// top of a pane's column, the bar hangs its suggestions under itself.
struct BrowserCompactTabBar: View {
    /// Which of the bar's two jobs this one does: the tabs with the selected one as the address
    /// field (a panel's own row); the tabs alone, each its title, with New Tab
    /// (the context pane's, in its title-bar zone, as ChatGPT's tab strip is); or the address alone,
    /// navigation leading it, with its suggestions (the row at the top of the pane).
    enum Part { case all, tabs, address }

    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel
    var placement: CompactTabBarPlacement = .row
    var part: Part = .all
    @FocusState private var editingAddress: Bool

    private var highlighted: Int? {
        get { model.addressHighlight }
        nonmutating set { model.addressHighlight = newValue }
    }

    private var pages: [BrowserPage] { context.pages }
    private var active: BrowserPage? { context.activePage }
    private var root: String? { model.session?.worktree }
    private var fillerIsBlank: Bool { pages.first { $0.id == context.fillerPageID }?.controls.isBlank == true }
    private var suggestions: [AddressSuggestion] { BrowserAddressSuggestions(context: context).items }

    var body: some View {
        CompactTabBar(newTabTitle: String(localized: "New Tab"),
                      newTabHelp: String(localized: "Open a new web tab"),
                      newTab: model.newTab,
                      // Not while a tab is still New Tab or Files: that one is where to go next.
                      showsNewTab: part != .address && context.section == .browser && !context.hasUnfilledTab,
                      placement: placement) {
            if part != .tabs { NavigationCluster(controls: active?.controls) }
        } pill: { available in
            tabPill(available)
        } trailing: {
            // Over the pages only: a file or a tool has no page for them to act on.
            if part != .tabs, context.section == .browser, context.activeDocument == nil, context.activeTool == nil {
                PageActionsCluster(page: active, bookmarks: context.bookmarks)
            }
        } suggestions: {
            if part != .tabs { BrowserAddressSuggestionList(context: context, model: model) }
        }
        // The tabs alone are ChatGPT's flat strip; the pane's address row, the pill's shapes with no
        // glass; with the address among the tabs, Safari's glass pill.
        .environment(\.compactTabStyle, part == .tabs ? .flat : part == .address ? .outlined : .capsule)
        .onChange(of: suggestions.map(\.id)) { _, _ in highlighted = nil }
        // Fetching is driven from here, once per keystroke, never from the body.
        .onChange(of: active?.controls.address) { _, text in
            guard part != .tabs, editingAddress, let text else { return }
            // Every change, cleared text included, so no earlier query's files sit under new text.
            context.fileSearch.query = active?.controls.addressEdited == true ? text : ""
            context.fileSearch.search(in: root)
            if active?.controls.addressEdited == true, webAddress(text) == nil { SearchSuggestionStore.shared.prefetch(text) }
        }
        // On the whole row, so the pill's re-centring animates with its contents: opening a tab
        // moves the existing tabs left as the new one slides in from the right. Keyed on tabs
        // opened and closed only: selecting a tab or restoring the saved ones does not glide.
        // Another session's tabs arriving is not an edit. Inside the animation, so it wins.
        .transaction(value: context.id) { $0.animation = nil }
        .animation(.snappy(duration: 0.3), value: context.tabEdits)
        // A browser panel always has a page to type into: a blank tab showing this panel's history
        // is the empty state, never a pill with nothing in it. Keyed on presentability too, so a
        // refusal while a sheet is up is retried once the sheet goes away.
        // The tabs keep the filler, not the address row: the row is there only over a page.
        .onChange(of: part != .address && needsBlankTab, initial: true) { _, needed in
            if needed { model.newTab(); context.fillerPageID = context.activePage?.id }
        }
        .onChange(of: fillerIsBlank) { _, blank in if !blank { context.fillerPageID = nil } }
        // The tabs alone have no field: the address row's editing state is not theirs to change.
        .onAppear { synchronizeEditing() }
        .onChange(of: context.activeID) { _, _ in synchronizeEditing() }
        // New Tab over the pane's own blank page makes it a tab without selecting anything new.
        .onChange(of: context.fillerPageID) { _, _ in synchronizeEditing() }
        // The pane shutting releases the field, so the terminal keeps the keyboard; showing it
        // again on a blank tab hands it back.
        .onChange(of: model.showsPage) { _, shown in if shown { synchronizeEditing() } else if part != .tabs { editingAddress = false } }
        .onChange(of: editingAddress) { _, value in
            guard part != .tabs else { return }
            active?.controls.setEditingAddress(value)
            if !value { highlighted = nil; context.fileSearch.reset() }
        }
        // The reverse: a model that ends editing (the start page opening a site) releases the field,
        // and one that starts it takes the keyboard to it.
        .onChange(of: active?.controls.editingAddress) { _, value in if part != .tabs, let value { editingAddress = value } }
        // A hidden workspace stays mounted, and opacity does not drop first responder: release the
        // field when this workspace leaves the screen, or the terminal shown instead loses keystrokes.
        .onChange(of: model.isActive) { _, visible in if !visible, part != .tabs { editingAddress = false } }
        .onDisappear { if part != .tabs { active?.controls.setEditingAddress(false); context.fileSearch.reset() } }
    }

    private func tabPill(_ available: CGFloat) -> some View {
        // The address alone is the selected page, as wide as the row.
        let ids = part == .address ? (active.map { [$0.id] } ?? []) : context.stripTabs.map(\.id)
        return CompactTabPill(ids: ids, activeID: context.activeID, available: available,
                       maxTabWidth: part == .address ? CompactTabMetrics.maxToolbarBarWidth
                           : part == .tabs ? CompactTabMetrics.maxStripTabWidth : CompactTabMetrics.maxWebTabWidth,
                       select: { id in context.tab(id).map(model.selectTab) }, move: model.moveTab,
                       // A drag in the address field selects its text: the tab being edited stays put.
                       canMove: { part != .address && !(editingAddress && $0 == context.activeID) }) { id, iconOnly in
            if let page = pages.first(where: { $0.id == id }) {
                CompactTab(page: page, bookmarks: context.bookmarks, active: page.id == context.activeID,
                           searchesFiles: root != nil,
                           moveHighlight: moveHighlight, submitHighlighted: { submitHighlighted(page.controls) },
                           submitTyped: { submitTyped(page.controls) },
                           closable: part != .address && model.offersClose(page), iconOnly: iconOnly,
                           editable: part != .tabs, editing: $editingAddress,
                           select: { model.selectTab(.page(page)) }, close: { model.closeTab(.page(page)) })
            } else if let file = context.documents.first(where: { $0.id == id }) {
                CompactFileTab(file: file, active: id == context.activeID,
                               iconOnly: iconOnly, editing: $editingAddress,
                               select: { model.selectTab(.file(file)) }, close: { model.closeTab(.file(file)) })
            } else if id == WorkspaceTool.files.id {
                CompactExplorerTab(active: id == context.activeID, iconOnly: iconOnly, editing: $editingAddress,
                                   select: { model.selectTab(.tool(.files)) }, close: { model.closeTab(.tool(.files)) })
            }
        }
    }

    /// Down/Up move the highlight; Enter on a highlight opens it. Returns whether the key was used.
    func moveHighlight(_ delta: Int) -> Bool {
        guard !suggestions.isEmpty else { return false }
        highlighted = compactHighlight(highlighted, moving: delta, count: suggestions.count)
        return true
    }
    func submitHighlighted(_ controls: BrowserControlsViewModel) -> Bool {
        let items = suggestions
        guard let index = highlighted, items.indices.contains(index) else { return false }
        if BrowserAddressSuggestions.open(items[index], in: controls, context: context) { editingAddress = false }
        return true
    }
    /// Enter with nothing highlighted: the absolute path of a file that exists opens it; anything
    /// else, `/r/swift` included, is an address or a search.
    func submitTyped(_ controls: BrowserControlsViewModel) -> Bool {
        let text = controls.address.trimmingCharacters(in: .whitespacesAndNewlines)
        var directory: ObjCBool = false
        if root != nil, text.hasPrefix("/"), FileManager.default.fileExists(atPath: text, isDirectory: &directory), !directory.boolValue {
            return context.openFile(text) != nil
        }
        return controls.submitAddress()
    }

    /// Only while the browser panel is on screen. This bar stays mounted behind a hidden panel, and
    /// a blank tab is never saved, so on every launch the filler opened, selected itself and
    /// showed a panel the user had hidden. Showing the panel flips this and the filler arrives then.
    /// It is no tab selected, not no tabs: leaving the Changes tab for the pages when no page or
    /// file is open selects nothing, and the tools' tabs stay.
    private var needsBlankTab: Bool { context.activeID == nil && model.showsBrowser && model.canOpenTab }

    /// Leaving a tab drops any address focus so it does not carry over. A blank tab's keyboard goes
    /// to the address field: its start page has no field of its own.
    private func synchronizeEditing() {
        guard part != .tabs else { return }
        if active?.controls.isBlank != true { editingAddress = false }
        // A new tab's keyboard goes to the address, never the filler's, which must not take it. Only
        // while the pane is shown: a shut pane stays mounted, and its field would take the
        // keyboard from the terminal.
        else if model.isActive, model.showsPage, active?.id != context.fillerPageID { editingAddress = true }
    }
}

/// The address suggestions under the field, hung from the bar in its own row or the pane's address
/// row. Picking one lets go of the field
/// through the model, which the bar follows wherever it is drawn.
struct BrowserAddressSuggestionList: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        if let controls = context.activePage?.controls, controls.editingAddress {
            let items = BrowserAddressSuggestions(context: context).items
            if !items.isEmpty {
                CompactSuggestionList(items: items, highlighted: model.addressHighlight, accessibilityLabel: String(localized: "Address suggestions"),
                                      heading: \.heading, title: \.title,
                                      detail: { $0.isSearch || $0.detail == $0.title ? "" : $0.detail },
                                      pick: { if BrowserAddressSuggestions.open($0, in: controls, context: context) { controls.setEditingAddress(false) } }) { item in
                    if item.kind == .file {
                        FileIcon(name: item.title, size: 22) { CompactSuggestionSymbol(systemImage: "doc.text") }.frame(width: 28, height: 28)
                    }
                    else if item.isSearch { CompactSuggestionSymbol(systemImage: "magnifyingglass") }
                    else { FaviconImage(url: item.url, size: 28, fallbackSize: 15) }
                }
            }
        }
    }
}

/// What the address field offers for the active tab's typed text. One list: a suggested site, the
/// session's worktree files that match, the typed text and Google's phrase completions as
/// searches, then the bookmarks and the pages visited in any panel that match the text.
@MainActor struct BrowserAddressSuggestions {
    let context: WorkspaceContext

    var items: [AddressSuggestion] {
        // Focusing the field selects the page's own address; offering that page back is noise.
        let controls = context.activePage?.controls
        guard let typed = controls?.addressEdited == true ? controls?.address : nil else { return [] }
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let files = context.fileSearch.results.prefix(Self.fileLimit).map { result in
            AddressSuggestion(id: "file:" + result.path, title: result.name, detail: result.folder, url: result.path, kind: .file)
        }
        // Under the suggested site, which leads the list with no heading of its own.
        var items = web(text)
        items.insert(contentsOf: files, at: items.first?.kind == .site ? 1 : 0)
        return items
    }
    static let fileLimit = 5

    private func web(_ text: String) -> [AddressSuggestion] {
        let searching = webAddress(text) == nil
        var history: [AddressSuggestion] = []
        // Bookmarks lead the section, then the one history shared by every panel. A bookmarked page
        // is excluded from the visits before they are capped, so it never costs a history row.
        let marks = context.bookmarks?.matching(text, limit: 3) ?? []
        history += marks.map { .init(id: $0.url, title: $0.displayTitle, detail: $0.host, url: $0.url, kind: .history) }
        for entry in context.globalHistory?.matching(text, excluding: Set(marks.map(\.url)), limit: 4) ?? [] {
            history.append(.init(id: entry.url, title: entry.displayTitle, detail: entry.host, url: entry.url, kind: .history))
        }
        guard searching else { return history }
        // Safari's order: one suggested site, then four searches led by the typed text, then history.
        var items: [AddressSuggestion] = []
        let completions = SearchSuggestionStore.shared.cached(text)
        if let site = completions.first(where: \.isSite), let url = webAddress(site.text), let host = url.host {
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            items.append(.init(id: "site:" + site.text, title: site.title.isEmpty ? name : site.title,
                               detail: site.title.isEmpty ? "" : name, url: url.absoluteString, kind: .site))
            history.removeAll { $0.url == url.absoluteString }
        }
        if let url = BrowserControlsViewModel.searchURL(for: text) {
            items.append(.init(id: "search", title: text, detail: "", url: url.absoluteString, kind: .typed))
        }
        for phrase in completions.lazy.filter({ !$0.isSite }).map(\.text).filter({ $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(3) {
            guard let url = BrowserControlsViewModel.searchURL(for: phrase) else { continue }
            items.append(.init(id: "google:" + phrase, title: phrase, detail: "", url: url.absoluteString, kind: .google))
        }
        items += history
        return items
    }

    /// Opens a suggestion: a page in the active tab, a file as its own tab. Whether it was taken,
    /// so the field can let go.
    static func open(_ item: AddressSuggestion, in controls: BrowserControlsViewModel, context: WorkspaceContext) -> Bool {
        if item.kind == .file { return context.openFile(item.url) != nil }
        controls.address = item.url
        return controls.submitAddress()
    }
}

/// The history cluster: Back, a hairline and Forward, both always there and each disabled with no
/// page to go to, so the row never shifts. One glass capsule around both, drawn with the same
/// `barGlass` as New Tab so the two read as the same material. A file tab's row has it too.
struct NavigationCluster: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    init(canGoBack: Bool, canGoForward: Bool, back: @escaping () -> Void, forward: @escaping () -> Void) {
        self.canGoBack = canGoBack; self.canGoForward = canGoForward; self.back = back; self.forward = forward
    }

    init(controls: BrowserControlsViewModel?) {
        self.init(canGoBack: controls?.canGoBack == true, canGoForward: controls?.canGoForward == true,
                  back: { controls?.back() }, forward: { controls?.forward() })
    }

    var body: some View {
        HStack(spacing: 0) {
            HoverCircleButton(String(localized: "Back"), systemImage: "chevron.left", enabled: canGoBack, action: back)
            Divider().frame(height: 16)
            HoverCircleButton(String(localized: "Forward"), systemImage: "chevron.right", enabled: canGoForward, action: forward)
        }
        .padding(.horizontal, 2)
        .barGlass()
    }
}

/// The page's own buttons after the address, in a capsule of their own as Back and Forward are
/// before it: Reload — Stop while the page loads — and the bookmark star, filled once bookmarked.
/// Both always there, as Back and Forward are, and each disabled with no page to act on — a blank
/// tab, or an address that cannot be bookmarked — so the row never shifts.
private struct PageActionsCluster: View {
    let page: BrowserPage?
    let bookmarks: BrowserBookmarkStore?

    var body: some View {
        // The page they act on: none on a blank tab.
        let shown = page.flatMap { $0.controls.isBlank ? nil : $0 }
        let loading = shown?.controls.loading == true
        let bookmarked = shown.map { bookmarks?.contains($0.url) == true } == true
        let canBookmark = shown.map { bookmarks?.canBookmark($0.url) == true } == true
        HStack(spacing: 0) {
            HoverCircleButton(loading ? String(localized: "Stop") : String(localized: "Reload Page"),
                              systemImage: loading ? "xmark" : "arrow.clockwise", enabled: shown != nil) { shown?.controls.toggleLoading() }
                .help(loading ? String(localized: "Stop loading this page") : String(localized: "Reload this page"))
            Divider().frame(height: 16)
            HoverCircleButton(bookmarked ? String(localized: "Remove Bookmark") : String(localized: "Add Bookmark"),
                              systemImage: bookmarked ? "star.fill" : "star", enabled: canBookmark,
                              tint: bookmarked ? Theme.accent : nil) {
                if let shown { bookmarks?.toggle(url: shown.url, title: shown.title) }
            }
                .help(bookmarked ? String(localized: "Remove this page from your bookmarks") : String(localized: "Bookmark this page"))
                .accessibilityIdentifier("bookmark-page")
        }
        .padding(.horizontal, 2)
        .barGlass()
    }
}

/// One tab in the pill. Unselected: icon and title, a close button on hover. Selected: close,
/// icon and host, and the address field over the label while editing; Reload and the bookmark
/// are outside it (`PageActionsCluster`). Both states share
/// the same slots, so the label never moves; only what fills the slots crossfades.
private struct CompactTab: View {
    let page: BrowserPage
    let bookmarks: BrowserBookmarkStore?
    let active: Bool
    let searchesFiles: Bool
    let moveHighlight: (Int) -> Bool
    let submitHighlighted: () -> Bool
    let submitTyped: () -> Bool
    let closable: Bool
    let iconOnly: Bool
    /// False for a tab in the strip whose address is edited in a row of its own: it shows its
    /// title, selected or not, and none of the address's buttons.
    var editable = true
    @FocusState.Binding var editing: Bool
    let select: () -> Void
    let close: () -> Void

    private static let slotWidth: CGFloat = 22
    /// The host as Safari shows it: without a leading "www.".
    private static func displayHost(_ url: String) -> String? {
        guard let host = URL(string: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private var controls: BrowserControlsViewModel { page.controls }
    /// Safari shows the page title on an unselected tab and the host on the selected one.
    private var label: String {
        if controls.isBlank { return active && editable ? "" : String(localized: "New Tab") }
        if active && editable { return Self.displayHost(page.url) ?? (page.title.isEmpty ? page.url : page.title) }
        return page.title.isEmpty ? (Self.displayHost(page.url) ?? page.url) : page.title
    }

    var body: some View {
        @Bindable var controls = controls
        CompactTabShell(label: label, placeholder: searchesFiles ? String(localized: "Search files or the web, or enter website name") : String(localized: "Search or enter website name"), closeTitle: controls.isBlank ? String(localized: "Close Tab") : String(localized: "Close \(page.title)"), help: page.url,
                        active: active,
                        closable: closable, iconOnly: iconOnly, editable: editable, text: $controls.address, editing: $editing, moveHighlight: moveHighlight,
                        submit: { submitHighlighted() || submitTyped() }, select: select, close: close,
                        searching: controls.isBlank || FaviconStore.host(of: page.url) == nil) {
            if FaviconStore.host(of: page.url) != nil { FaviconImage(url: page.url, size: 16) }
            // An icon-only tab must still be something to click.
            else if iconOnly { Image(systemName: "globe").font(.system(size: 14)).foregroundStyle(Theme.textTertiary) }
        } accessories: { hovering in
            let speaker = controls.playingAudio || controls.muted
            // Safari packs a tab's trailing buttons about half as far apart as the bar's own gap.
            HStack(spacing: 0) {
                // As in Safari, a speaker sits on any tab making sound, and stays while muted so the
                // tab can be unmuted after the page has gone quiet.
                if speaker {
                    CompactTabAccessory(title: controls.muted ? String(localized: "Unmute this tab") : String(localized: "Mute this tab"),
                                        systemImage: controls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13,
                                        tint: controls.muted ? Theme.textTertiary : Theme.textSecondary, width: Self.slotWidth,
                                        visible: true, action: controls.toggleMute)
                        .help(controls.muted ? String(localized: "Unmute this tab") : String(localized: "Mute this tab"))
                        .accessibilityIdentifier("mute-tab")
                }
            }
        }
    }
}

/// A worktree file's tab: its name and a document icon. Its title is fixed: selecting it shows
/// the file, never an address field.
private struct CompactFileTab: View {
    let file: EditorDocumentViewModel
    let active: Bool
    let iconOnly: Bool
    @FocusState.Binding var editing: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        CompactTabShell(label: file.title, placeholder: "", closeTitle: String(localized: "Close \(file.title)"), help: file.record.path,
                        active: active,
                        closable: true, iconOnly: iconOnly, editable: false, text: .constant(""), editing: $editing,
                        moveHighlight: { _ in false }, submit: { false }, select: select, close: close) {
            FileIcon(name: file.record.path) { Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Theme.textTertiary) }
        } accessories: { _ in EmptyView() }
    }
}

/// The Files explorer's tab: a New Tab that browses the worktree, until a file picked in it takes
/// its place.
private struct CompactExplorerTab: View {
    let active: Bool
    let iconOnly: Bool
    @FocusState.Binding var editing: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        let title = String(localized: "Files")
        CompactTabShell(label: title, placeholder: "", closeTitle: String(localized: "Close \(title)"), help: title,
                        active: active,
                        closable: true, iconOnly: iconOnly, editable: false, text: .constant(""), editing: $editing,
                        moveHighlight: { _ in false }, submit: { false }, select: select, close: close) {
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
        } accessories: { _ in EmptyView() }
    }
}

struct AddressSuggestion: Identifiable, Equatable {
    enum Kind { case file, typed, history, site, google }
    let id: String
    let title: String
    let detail: String
    let url: String
    let kind: Kind
    var isSearch: Bool { kind == .typed || kind == .google }
    /// The section a row sits under; the suggested site leads the list with none.
    var heading: String? {
        switch kind {
        case .site: nil
        case .file: String(localized: "Files")
        case .typed, .google: String(localized: "Google suggestions")
        case .history: String(localized: "Bookmarks and history")
        }
    }
}
