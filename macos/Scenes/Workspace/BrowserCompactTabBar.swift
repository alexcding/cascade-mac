import SwiftUI

/// Safari's compact tab layout: every web tab sits inside one pill, and the selected tab is a
/// raised glass capsule that doubles as the address bar. Its close button is at the leading edge,
/// the site icon and host are centred, reload is trailing; clicking the host edits the address.
/// There is no second row for the browser: back/forward lead the pill, New Tab and Recently
/// Closed trail it.
struct BrowserCompactTabBar: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel
    @FocusState private var editingAddress: Bool
    /// Keyboard highlight in the suggestion list; nil means Enter submits the typed text.
    @State private var highlighted: Int?
    private var searchSuggestions = SearchSuggestionStore.shared

    private var pages: [BrowserPage] { context.pageTabs.compactMap { if case .page(let page) = $0 { page } else { nil } } }
    private var active: BrowserPage? { context.activePage }
    private var fillerIsBlank: Bool { pages.first { $0.id == context.fillerPageID }?.controls.isBlank == true }

    var body: some View {
        CompactTabBar(newTabTitle: "New Tab", newTabHelp: "Open a new web tab", newTab: model.newTab,
                      showsNewTab: model.offersNewTab) {
            NavigationCluster(controls: active?.controls)
        } pill: { available in
            tabPill(available)
        } trailing: {
            // Create Session takes the end of the row, where New Tab sits in a panel that has one.
            // A sidebar tab offers the session and no New Tab; a session's panel, the other way round.
            if model.offersPageSession, model.fillsTitleBar {
                CreateSessionButton(model: model)
                    .disabled(!model.canCreateSession)
                    .help("Start an agent session for this page in its project")
                    .padding(.horizontal, 12)
                    .barGlass(iconOnly: false)
            }
        } suggestions: {
            if let controls = active?.controls, editingAddress, !suggestions.isEmpty {
                CompactSuggestionList(items: suggestions, highlighted: highlighted, accessibilityLabel: "Address suggestions",
                                      heading: \.heading, title: \.title,
                                      detail: { $0.isSearch || $0.detail == $0.title ? "" : $0.detail },
                                      pick: { pick($0, controls) }) { item in
                    if item.isSearch { CompactSuggestionSymbol(systemImage: "magnifyingglass") }
                    else { FaviconImage(url: item.url, size: 28, fallbackSize: 15) }
                }
            }
        }
        .onChange(of: suggestions.map(\.id)) { _, _ in highlighted = nil }
        // Fetching is driven from here, once per keystroke, never from the body.
        .onChange(of: active?.controls.address) { _, text in
            if editingAddress, let text, webAddress(text) == nil { searchSuggestions.prefetch(text) }
        }
        // On the whole row, so the pill's re-centring animates with its contents: opening a tab
        // moves the existing tabs left as the new one slides in from the right. Keyed on tabs
        // opened and closed only: selecting a tab or restoring the saved ones does not glide.
        // Another session's tabs arriving is not an edit. Inside the animation, so it wins.
        .transaction(value: context.id) { $0.animation = nil }
        .animation(.snappy(duration: 0.3), value: context.pageEdits)
        // A browser panel always has a page to type into: a blank tab showing this panel's history
        // is the empty state, never a pill with nothing in it. Keyed on presentability too, so a
        // refusal while a sheet is up is retried once the sheet goes away.
        .onChange(of: needsBlankTab, initial: true) { _, needed in
            if needed { model.newTab(); context.fillerPageID = context.activePage?.id }
        }
        .onChange(of: fillerIsBlank) { _, blank in if !blank { context.fillerPageID = nil } }
        .onAppear { synchronizeEditing() }
        .onChange(of: context.activeID) { _, _ in synchronizeEditing() }
        .onChange(of: editingAddress) { _, value in
            active?.controls.setEditingAddress(value)
            if !value { highlighted = nil }
        }
        // The reverse: a model that ends editing (the start page opening a site) releases the field.
        .onChange(of: active?.controls.editingAddress) { _, value in if value == false { editingAddress = false } }
        // A hidden workspace stays mounted, and opacity does not drop first responder: release the
        // field when this workspace leaves the screen, or the terminal shown instead loses keystrokes.
        .onChange(of: model.isActive) { _, visible in if !visible { editingAddress = false } }
        .onDisappear { active?.controls.setEditingAddress(false) }
    }

    private func tabPill(_ available: CGFloat) -> some View {
        CompactTabPill(ids: pages.map(\.id), activeID: context.activeID, available: available, maxTabWidth: CompactTabMetrics.maxWebTabWidth,
                       select: { id in pages.first { $0.id == id }.map { model.selectTab(.page($0)) } }, move: model.moveTab,
                       // A drag in the address field selects its text: the tab being edited stays put.
                       canMove: { !(editingAddress && $0 == context.activeID) }) { id, iconOnly in
            if let page = pages.first(where: { $0.id == id }) {
                CompactTab(page: page, bookmarks: context.bookmarks, active: page.id == context.activeID, workspaceActive: model.isActive,
                           autoFocus: page.id != context.fillerPageID,
                           moveHighlight: moveHighlight, submitHighlighted: { submitHighlighted(page.controls) },
                           closable: model.offersClose(page), iconOnly: iconOnly, editing: $editingAddress,
                           select: { model.selectTab(.page(page)) }, close: { model.closeTab(.page(page)) })
            }
        }
    }

    /// Leaving a tab drops any address focus so it does not carry over. A blank tab takes focus
    /// itself when its address field appears in `CompactTab`, once that field exists: a focus binding set before
    /// the bound view is mounted is silently reset.
    /// One list: a suggested site, the typed text and Google's phrase completions as searches, then
    /// the bookmarks and the pages visited in any panel that match the text.
    private var suggestions: [AddressSuggestion] {
        // Focusing the field selects the page's own address; offering that page back is noise.
        guard let controls = active?.controls, controls.addressEdited else { return [] }
        let text = controls.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
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
        let completions = searchSuggestions.cached(text)
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

    private func pick(_ item: AddressSuggestion, _ controls: BrowserControlsViewModel) {
        controls.address = item.url
        if controls.submitAddress() { editingAddress = false }
    }

    /// Down/Up move the highlight; Enter on a highlight opens it. Returns whether the key was used.
    func moveHighlight(_ delta: Int) -> Bool {
        guard !suggestions.isEmpty else { return false }
        highlighted = compactHighlight(highlighted, moving: delta, count: suggestions.count)
        return true
    }
    func submitHighlighted(_ controls: BrowserControlsViewModel) -> Bool {
        guard let index = highlighted, suggestions.indices.contains(index) else { return false }
        pick(suggestions[index], controls); return true
    }

    // Not while restoring: a blank tab opened before the saved snapshot lands would mark the
    // context edited and the saved tabs would be skipped.
    /// Only while the browser panel is on screen. This bar stays mounted behind a hidden panel, and
    /// a blank tab is never saved, so on every launch the filler opened, selected itself and
    /// showed a panel the user had hidden. Showing the panel flips this and the filler arrives then.
    private var needsBlankTab: Bool { pages.isEmpty && model.showsBrowser && model.canOpenTab && !context.restoring }

    private func synchronizeEditing() {
        if active?.controls.isBlank != true { editingAddress = false }
    }
}

/// Safari's history cluster: Back alone, widening to Back, a hairline and Forward only while
/// there is a page to go forward to. One glass capsule around both, drawn with the same
/// `barGlass` as New Tab so the two read as the same material. Always present, disabled with no
/// page, so the row never shifts.
private struct NavigationCluster: View {
    let controls: BrowserControlsViewModel?

    private var showsForward: Bool { controls?.canGoForward == true }

    var body: some View {
        HStack(spacing: 0) {
            HoverCircleButton("Back", systemImage: "chevron.left", enabled: controls?.canGoBack == true) { controls?.back() }
            if showsForward {
                Divider().frame(height: 16)
                HoverCircleButton("Forward", systemImage: "chevron.right", enabled: true) { controls?.forward() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // Alone, Back is exactly its 32pt circle; the inset only appears once Forward joins.
        .padding(.horizontal, showsForward ? 2 : 0)
        .barGlass()
    }
}

/// One tab in the pill. Unselected: icon and title, a close button on hover. Selected: close,
/// icon and host, reload, and the address field over the label while editing. Both states share
/// the same slots, so the label never moves; only what fills the slots crossfades.
private struct CompactTab: View {
    let page: BrowserPage
    let bookmarks: BrowserBookmarkStore?
    let active: Bool
    /// Hidden workspaces stay mounted; opacity does not stop a field from taking first responder.
    let workspaceActive: Bool
    let autoFocus: Bool
    let moveHighlight: (Int) -> Bool
    let submitHighlighted: () -> Bool
    let closable: Bool
    let iconOnly: Bool
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
    private var bookmarked: Bool { bookmarks?.contains(page.url) == true }
    /// Always on the selected tab, hovered or not and loading or not, for a page a bookmark could
    /// come back to.
    private var showsBookmark: Bool { active && bookmarks?.canBookmark(page.url) == true }
    /// Safari shows the page title on an unselected tab and the host on the selected one.
    private var label: String {
        if controls.isBlank { return active ? "" : "New Tab" }
        if active { return Self.displayHost(page.url) ?? (page.title.isEmpty ? page.url : page.title) }
        return page.title.isEmpty ? (Self.displayHost(page.url) ?? page.url) : page.title
    }

    var body: some View {
        @Bindable var controls = controls
        CompactTabShell(label: label, placeholder: "Search or enter website name", closeTitle: "Close \(page.title)", help: page.url,
                        active: active, workspaceActive: workspaceActive, blank: controls.isBlank, autoFocus: autoFocus,
                        closable: closable, iconOnly: iconOnly, text: $controls.address, editing: $editing, moveHighlight: moveHighlight,
                        submit: { submitHighlighted() || controls.submitAddress() }, select: select, close: close,
                        searching: controls.isBlank || FaviconStore.host(of: page.url) == nil) {
            if FaviconStore.host(of: page.url) != nil { FaviconImage(url: page.url, size: 16) }
            // An icon-only tab must still be something to click.
            else if iconOnly { Image(systemName: "globe").font(.system(size: 14)).foregroundStyle(Theme.textTertiary) }
        } accessories: { hovering in
            let speaker = controls.playingAudio || controls.muted
            // Safari packs a tab's trailing buttons about half as far apart as the bar's own gap.
            HStack(spacing: 0) {
                // Reload appears only while the pointer is over the selected tab. Stop, the same button
                // while a page loads, stays visible: a slow load must always have a way to be stopped.
                if active {
                    CompactTabAccessory(title: controls.loading ? "Stop Loading" : "Reload Page",
                                        systemImage: controls.loading ? "xmark" : "arrow.clockwise", width: Self.slotWidth,
                                        visible: !controls.isBlank && (hovering || controls.loading),
                                        accessible: !controls.isBlank, action: controls.toggleLoading)
                }
                // As in Safari, a speaker sits on any tab making sound, and stays while muted so the
                // tab can be unmuted after the page has gone quiet.
                if speaker {
                    CompactTabAccessory(title: controls.muted ? "Unmute Tab" : "Mute Tab",
                                        systemImage: controls.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13,
                                        tint: controls.muted ? Theme.textTertiary : Theme.textSecondary, width: Self.slotWidth,
                                        visible: true, action: controls.toggleMute)
                        .help(controls.muted ? "Unmute this tab" : "Mute this tab")
                        .accessibilityIdentifier("mute-tab")
                }
                if active {
                    CompactTabAccessory(title: bookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: bookmarked ? "star.fill" : "star",
                                        size: 14, tint: bookmarked ? Theme.accent : Theme.textSecondary, width: Self.slotWidth,
                                        visible: showsBookmark) {
                        bookmarks?.toggle(url: page.url, title: page.title)
                    }
                    .help(bookmarked ? "Remove this page from your bookmarks" : "Bookmark this page")
                    .accessibilityIdentifier("bookmark-page")
                }
            }
        }
    }
}

struct AddressSuggestion: Identifiable, Equatable {
    enum Kind { case typed, history, site, google }
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
        case .typed, .google: "Google Suggestions"
        case .history: "Bookmarks and History"
        }
    }
}
