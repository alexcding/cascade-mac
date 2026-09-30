import AppKit
import Foundation
import Observation
import WebKit

enum ReviewSection: String, Codable, CaseIterable, Identifiable {
    case changes = "Changes", history = "History"
    var id: String { rawValue }
    var title: String { self == .changes ? String(localized: "Changes") : String(localized: "History") }
}

/// `simulator` is never saved: the stream it shows belongs to this launch, so a restored
/// workspace opens on its browser instead. `term` is the browser, which holds the web pages and
/// the files alike; a snapshot saved while files had a pane of their own restores to it.
enum WorkspacePane: String, Codable, CaseIterable {
    case off, term, diff, simulator
    init?(saved: String) { self.init(rawValue: saved == "files" ? "term" : saved) }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    // Declaration order is the order of the toolbar picker: Tabs, Diff, Simulator. `browser` holds
    // the web pages and the worktree files alike.
    case browser, diff, simulator
    var id: String { rawValue }
    var pane: WorkspacePane { switch self { case .browser: .term; case .diff: .diff; case .simulator: .simulator } }
    var title: String { switch self { case .browser: String(localized: "Tabs"); case .diff: String(localized: "Diff"); case .simulator: String(localized: "Simulator") } }
    var symbol: String {
        switch self { case .browser: "rectangle.stack"; case .diff: "plus.forwardslash.minus"; case .simulator: "iphone" }
    }
    init?(pane: WorkspacePane) {
        switch pane {
        case .term: self = .browser; case .diff: self = .diff; case .simulator: self = .simulator
        default: return nil
        }
    }
}

struct ContextSnapshot: Codable, Equatable, Sendable {
    var pages: [WebPageRecord] = []
    var activeID: String?
    var history: [WebPageRecord] = []
    var pane = "term"
    /// The snapshot without its page visits; file visits stay.
    var clearingPageHistory: ContextSnapshot {
        var copy = self
        let pageIDs = Set(history.map(\.id))
        copy.history = []; copy.historyOrder?.removeAll { pageIDs.contains($0) }
        return copy
    }
    var reviewSection: ReviewSection? = nil
    var documents: [FileDocumentRecord]? = nil
    var tabOrder: [String]? = nil
    var fileHistory: [FileDocumentRecord]? = nil
    var historyOrder: [String]? = nil
    var legacyDocuments: [SavedTabContent]? = nil
    var legacyFileHistory: [SavedTabContent]? = nil

    static func importing(_ tab: SavedTab) -> Self {
        var result = Self()
        result.reviewSection = tab.reviewView == "history" ? .history : .changes
        result.documents = []; result.tabOrder = []; result.fileHistory = []; result.historyOrder = []
        result.pane = tab.paneView == "off" ? "off" : "term"
        if tab.pageClosed != true, safeWebURL(tab.url) != nil {
            let current = tab.cur.flatMap { safeWebURL($0)?.absoluteString } ?? tab.url
            let page = WebPageRecord(url: current, title: tab.title)
            result.pages.append(page); result.tabOrder?.append(page.id); result.activeID = page.id
        }
        for link in tab.links ?? [] {
            if link.kind == "file" {
                if let path = link.filePath {
                    let file = FileDocumentRecord(path: path)
                    result.documents?.append(file); result.tabOrder?.append(file.id)
                    if link.active == true { result.activeID = file.id }
                }
                continue
            }
            guard let raw = link.url, safeWebURL(raw) != nil else { continue }
            let page = WebPageRecord(url: raw, title: link.title ?? raw)
            result.pages.append(page); result.tabOrder?.append(page.id)
            if link.active == true { result.activeID = page.id }
        }
        if result.activeID == nil { result.activeID = result.tabOrder?.first }
        for link in (tab.history ?? []).suffix(100) {
            if let path = link.filePath {
                let file = FileDocumentRecord(path: path)
                result.fileHistory?.append(file); result.historyOrder?.append(file.id)
            } else if let raw = link.url, safeWebURL(raw) != nil {
                let page = WebPageRecord(url: raw, title: link.title ?? raw)
                result.history.append(page); result.historyOrder?.append(page.id)
            }
        }
        // Retain the original metadata for older clients; native documents never navigate a remote WebKit page.
        result.legacyDocuments = (tab.links ?? []).filter { $0.kind == "file" }
        result.legacyFileHistory = (tab.history ?? []).filter { $0.kind == "file" }
        return result
    }
}

@MainActor @Observable final class WorkspaceContext: @MainActor Identifiable {
    /// What a panel is, which decides what it can hold. Read from the id where the id is minted and
    /// again where promotion rewrites it, so nothing else has to know how an id is spelled.
    enum Kind: Equatable {
        case tab, session, scratch
        init(id: String) {
            if id.hasPrefix("tab:") { self = .tab } else if id.hasPrefix("task:") { self = .session } else { self = .scratch }
        }
    }
    fileprivate(set) var id: String { didSet { kind = Kind(id: id) } }
    private(set) var kind: Kind
    /// A sidebar tab's panel *is* that one tab: its row in the sidebar is the tab, so the panel
    /// offers no New Tab of its own. A session's workspace and the scratch terminal hold as many
    /// pages as they are asked for. The blank filler page is not a New Tab and is unaffected.
    var holdsOnePage: Bool { kind == .tab }
    let sourceURL: String
    private(set) var pages: [BrowserPage] = []
    private(set) var documents: [EditorDocumentViewModel] = []
    private(set) var tabOrder: [String] = []
    private(set) var fileHistory: [FileDocumentRecord] = []
    private(set) var historyOrder: [String] = []
    private(set) var activeID: String? {
        didSet { if oldValue != activeID { workspaceViewModel?.documentStateChanged() } }
    }
    private(set) var history: [WebPageRecord] = []
    private(set) var pane: WorkspacePane = .term {
        didSet {
            if let mode = WorkspaceMode(pane: pane) { lastMode = mode }
            if oldValue != pane { workspaceViewModel?.reviewStateChanged() }
        }
    }
    private(set) var lastMode: WorkspaceMode = .browser
    private(set) var reviewSection: ReviewSection = .changes {
        didSet { if oldValue != reviewSection { workspaceViewModel?.reviewStateChanged() } }
    }
    var findVisible = false
    var findText = ""
    var error: String?
    private(set) var legacyDocuments: [SavedTabContent] = []
    private(set) var legacyFileHistory: [SavedTabContent] = []
    @ObservationIgnored var changed: () -> Void = {}
    /// The app-wide history every visit is also recorded in. Nil in a bare context (tests).
    @ObservationIgnored var globalHistory: BrowserHistoryStore?
    /// Shared by every context, as the history is; nil in a bare context.
    @ObservationIgnored var bookmarks: BrowserBookmarkStore?
    /// Forgets the shared history and every context's page visits; a bare context clears its own.
    @ObservationIgnored lazy var clearBrowsingHistory: () -> Void = { [weak self] in
        self?.clearPageHistory(); self?.globalHistory?.clear()
    }
    /// Where a link that asked for a new window goes when this panel holds one page: the sidebar's
    /// Tabs list, as a tab of its own. The second argument keeps the link in this panel instead,
    /// for when the list cannot take it. Nil in a bare context (tests), which keeps the link here.
    @ObservationIgnored var openSidebarTab: ((String, @escaping () -> Void) -> Void)?
    @ObservationIgnored var activateDocument: (EditorDocumentViewModel) -> Void = { _ in }
    @ObservationIgnored var activatePage: (BrowserPage) -> Void = { _ in }
    /// Called when one of its pages creates its web view.
    @ObservationIgnored var pageMaterialized: (BrowserPage) -> Void = { _ in }
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored private let closeCoordinator: EditorCloseCoordinator
    @ObservationIgnored private let pageFactory: BrowserPageFactory
    @ObservationIgnored private let documentFactory: any DocumentFeatureFactory
    /// The address field's worktree search; opening a result is this context's own `openFile`.
    @ObservationIgnored private(set) lazy var fileSearch: FileSearchViewModel = {
        let model = documentFactory.fileSearch()
        model.onAction = { [weak self] action in
            switch action { case .open(let path): self?.openFile(path) }
        }
        return model
    }()
    private(set) var workspaceViewModel: SessionWorkspaceViewModel?

    func configureWorkspace(factory: any WorkspaceFeatureFactory, service: any WorkspaceServing) {
        guard workspaceViewModel == nil else { return }
        workspaceViewModel = factory.workspace(context: self, service: service)
    }

    init(id: String, sourceURL: String, title: String, snapshot: ContextSnapshot? = nil,
         pageFactory: BrowserPageFactory = BrowserPageFactory(),
         documentFactory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         closeCoordinator: EditorCloseCoordinator? = nil) {
        self.id = id; self.kind = Kind(id: id); self.sourceURL = sourceURL
        self.pageFactory = pageFactory
        self.documentFactory = documentFactory
        self.closeCoordinator = closeCoordinator ?? EditorCloseCoordinator(factory: documentFactory)
        if let snapshot {
            legacyDocuments = snapshot.legacyDocuments ?? []
            legacyFileHistory = snapshot.legacyFileHistory ?? []
            var ids: Set<String> = []
            pages = snapshot.pages.filter { safeWebURL($0.url) != nil && ids.insert($0.id).inserted }.map(pageFactory.make)
            history = Array(snapshot.history.filter { safeWebURL($0.url) != nil }.suffix(100))
            let records = snapshot.documents ?? legacyDocuments.compactMap { entry in
                entry.filePath.map { FileDocumentRecord(path: $0) }
            }
            documents = records.filter { $0.path.hasPrefix("/") && ids.insert($0.id).inserted }.map { documentFactory.editor(record: $0) }
            tabOrder = Self.order(snapshot.tabOrder, ids: pages.map(\.id) + documents.map(\.id))
            fileHistory = snapshot.fileHistory ?? legacyFileHistory.compactMap { entry in
                entry.filePath.map { FileDocumentRecord(path: $0) }
            }
            historyOrder = Self.order(snapshot.historyOrder, ids: history.map(\.id) + fileHistory.map(\.id))
            activeID = tabOrder.contains(snapshot.activeID ?? "") ? snapshot.activeID : tabOrder.first
            pane = WorkspacePane(saved: snapshot.pane) ?? .term
            reviewSection = snapshot.reviewSection ?? .changes
            lastMode = WorkspaceMode(pane: pane) ?? .browser
        } else if safeWebURL(sourceURL) != nil {
            let page = pageFactory.make(.init(url: sourceURL, title: title))
            pages = [page]; tabOrder = [page.id]; activeID = page.id
        } else {
            // Nothing to show beside the terminal: a session started from no page, and the scratch
            // Terminal, open on the shell alone rather than on an empty browser. Toggling the
            // context back, or opening any page or file, brings the pane in — `lastMode` still
            // says Browser.
            pane = .off
        }
        pages.forEach(wire)
        documents.forEach(wire)
    }

    var activeDocument: EditorDocumentViewModel? { documents.first { $0.id == activeID } }
    /// Counts tabs opened, closed and moved by hand, never a restore: what the tab bar animates on.
    private(set) var tabEdits = 0
    /// The empty-state page the bar opened itself: unlike Cmd-T it must not take the keyboard.
    var fillerPageID: String?
    var tabs: [WorkspaceTab] { tabOrder.compactMap(tab) }
    var visits: [WorkspaceVisit] { historyOrder.compactMap { id in
        if let page = history.first(where: { $0.id == id }) { return .page(page) }
        return fileHistory.first(where: { $0.id == id }).map(WorkspaceVisit.file)
    } }
    var pageVisits: [WorkspaceVisit] { visits.filter { if case .page = $0 { true } else { false } } }
    var fileVisits: [WorkspaceVisit] { visits.filter { if case .file = $0 { true } else { false } } }
    func tab(_ id: String) -> WorkspaceTab? {
        if let page = pages.first(where: { $0.id == id }) { return .page(page) }
        return documents.first(where: { $0.id == id }).map(WorkspaceTab.file)
    }
    private static func order(_ preferred: [String]?, ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ((preferred ?? []) + ids).filter { ids.contains($0) && seen.insert($0).inserted }
    }
    var activePage: BrowserPage? { pages.first { $0.id == activeID } }
    var snapshot: ContextSnapshot {
        .init(pages: pages.map(\.record), activeID: activeID, history: history,
              pane: pane == .simulator ? WorkspacePane.term.rawValue : pane.rawValue,
              reviewSection: reviewSection, documents: documents.map(\.record), tabOrder: tabOrder, fileHistory: fileHistory, historyOrder: historyOrder,
              legacyDocuments: legacyDocuments, legacyFileHistory: legacyFileHistory)
    }
    func setReviewSection(_ value: ReviewSection) { reviewSection = value; changed() }
    func setPane(_ value: WorkspacePane) {
        if value == .term, activeID == nil { activeID = tabOrder.last }
        pane = value; changed()
    }
    func present() { if pane == .off { setPane(lastMode.pane) } }
    fileprivate func absorb(_ source: WorkspaceContext) {
        let pageIDs = Set(pages.map(\.id)), documentIDs = Set(documents.map(\.id))
        let incomingPages = source.pages.filter { !pageIDs.contains($0.id) }
        let incomingDocuments = source.documents.filter { !documentIDs.contains($0.id) }
        pages += incomingPages; documents += incomingDocuments
        incomingPages.forEach(wire); incomingDocuments.forEach(wire)
        tabOrder = Self.order(tabOrder + source.tabOrder, ids: pages.map(\.id) + documents.map(\.id))
        history += source.history.filter { value in !history.contains { $0.id == value.id } }
        fileHistory += source.fileHistory.filter { value in !fileHistory.contains { $0.id == value.id } }
        historyOrder = Self.order(historyOrder + source.historyOrder, ids: history.map(\.id) + fileHistory.map(\.id))
        trimHistory()
        if let selected = source.activeID, tabOrder.contains(selected) { activeID = selected }
        source.changed = {}; source.activatePage = { _ in }; source.activateDocument = { _ in }
        source.pages = []; source.documents = []; source.tabOrder = []; source.activeID = nil
    }
    func select(_ page: BrowserPage) {
        activeID = page.id; pane = .term; activatePage(page); changed()
    }
    func select(_ tab: WorkspaceTab) {
        switch tab { case .page(let page): select(page)
        case .file(let file): activeID = file.id; pane = .term; activateDocument(file); changed() }
    }
    func cycle(_ direction: Int) {
        let order = tabOrder
        guard !order.isEmpty else { return }
        let index = order.firstIndex(of: activeID ?? "") ?? 0
        if let tab = tab(order[(index + direction + order.count) % order.count]) { select(tab) }
    }
    @discardableResult func openFile(_ path: String, line: Int = 1, column: Int = 1) -> EditorDocumentViewModel? {
        guard path.hasPrefix("/"), !path.contains("\0") else { error = String(localized: "Choose an absolute file path."); return nil }
        let path = (path as NSString).standardizingPath
        // A file opened from a blank tab — its address field, or its start page — takes its place.
        // Not in a sidebar tab: its one page is its only address field, and it offers no New Tab.
        let blank = holdsOnePage ? nil : activePage.flatMap { $0.controls.isBlank ? $0 : nil }
        fileSearch.reset()
        defer { if let blank { close(blank) } }
        if let file = documents.first(where: { $0.record.path == path }) { select(.file(file)); file.focus(line: line, column: column); return file }
        let file = documentFactory.editor(record: .init(path: path))
        documents.append(file); wire(file); insert(file.id); noteHistory(file.record)
        select(.file(file)); file.focus(line: line, column: column)
        return file
    }
    private func insert(_ id: String, atEnd: Bool = false) {
        let index = atEnd ? tabOrder.endIndex : tabOrder.firstIndex(of: activeID ?? "").map { $0 + 1 } ?? tabOrder.endIndex
        tabOrder.insert(id, at: index); tabEdits += 1
        pages.sort { tabOrder.firstIndex(of: $0.id)! < tabOrder.firstIndex(of: $1.id)! }
    }
    /// Moves a tab before another, or to the end for nil. Pages and files share one order and one bar.
    func moveTab(_ id: String, before target: String?) {
        guard id != target, let from = tabOrder.firstIndex(of: id) else { return }
        var order = tabOrder
        order.remove(at: from)
        order.insert(id, at: target.flatMap(order.firstIndex(of:)) ?? order.endIndex)
        guard order != tabOrder else { return }
        tabOrder = order; tabEdits += 1
        pages.sort { tabOrder.firstIndex(of: $0.id)! < tabOrder.firstIndex(of: $1.id)! }
        changed()
    }
    func close(_ tab: WorkspaceTab) {
        switch tab { case .page(let page): close(page)
        case .file(let file):
            closeCoordinator.requestClose([file], isOwned: { [weak self, weak file] in
                guard let self, let file else { return false }
                return isOwned() && documents.contains { $0 === file }
            }, commit: { [weak self, weak file] in
                if let file { self?.remove(file) }
            })
        }
    }
    func remove(_ file: EditorDocumentViewModel) {
        guard documents.contains(where: { $0 === file }) else { return }
        noteHistory(file.record); file.dispose(); documents.removeAll { $0 === file }; removeTab(file.id)
    }
    private func removeTab(_ id: String) {
        let index = tabOrder.firstIndex(of: id) ?? 0
        tabOrder.removeAll { $0 == id }; tabEdits += 1
        if activeID == id {
            activeID = tabOrder.isEmpty ? nil : tabOrder[min(index, tabOrder.count - 1)]
            if let activeID, let tab = tab(activeID) { select(tab) }
        }
        changed()
    }
    /// `allowDuplicate` opens another tab even when the address is already open, as a link that
    /// asked for a new window must; otherwise the open page is selected instead.
    @discardableResult func open(_ url: String, title: String = "", configuration: WKWebViewConfiguration? = nil,
                                 allowDuplicate: Bool = false) -> BrowserPage? {
        guard safeWebURL(url) != nil || (configuration != nil && url == "about:blank") else {
            error = String(localized: "Enter an HTTP or HTTPS address."); return nil
        }
        if configuration == nil, !allowDuplicate, let existing = pages.first(where: { $0.url == url }) { select(existing); return existing }
        let page = pageFactory.make(.init(url: url, title: title.isEmpty ? (URL(string: url)?.host ?? url) : title))
        wire(page)
        pages.append(page); insert(page.id)
        if let configuration { page.materialize(configuration: configuration, load: false) }
        error = nil
        select(page)
        noteHistory(page.record)
        return page
    }
    /// The address a new, still-empty page carries until the user enters one.
    static let blankPageURL = "about:blank"
    static func isBlankAddress(_ url: String) -> Bool { url.hasPrefix(blankPageURL) }

    /// A new empty tab. It is never persisted or noted in history until it has a web address.
    @discardableResult func openBlankPage() -> BrowserPage {
        let page = pageFactory.make(.init(url: Self.blankPageURL, title: ""))
        wire(page)
        // At the end, as Safari's New Tab: the tabs already open keep their places.
        pages.append(page); insert(page.id, atEnd: true)
        error = nil
        select(page)
        return page
    }

    func close(_ page: BrowserPage) {
        guard let index = pages.firstIndex(where: { $0 === page }) else { return }
        noteHistory(page.record)
        page.evict()
        pages.remove(at: index)
        removeTab(page.id)
    }
    func apply(_ snapshot: ContextSnapshot) {
        // Used only for the first backend load, before the user edits this context.
        pages.forEach { $0.evict() }; documents.forEach { $0.dispose() }
        let restored = WorkspaceContext(id: id, sourceURL: sourceURL, title: "", snapshot: snapshot, pageFactory: pageFactory, documentFactory: documentFactory, closeCoordinator: closeCoordinator)
        pages = restored.pages; activeID = restored.activeID; history = restored.history; pane = restored.pane
        lastMode = restored.lastMode
        reviewSection = restored.reviewSection
        documents = restored.documents; tabOrder = restored.tabOrder; fileHistory = restored.fileHistory; historyOrder = restored.historyOrder
        documents.forEach(wire)
        legacyDocuments = restored.legacyDocuments; legacyFileHistory = restored.legacyFileHistory
        pages.forEach(wire)
    }
    private func noteHistory(_ page: WebPageRecord) {
        guard safeWebURL(page.url) != nil else { return }
        globalHistory?.note(page)
        history.removeAll { $0.url == page.url }
        history.append(page)
        historyOrder.removeAll { id in !history.contains { $0.id == id } && !fileHistory.contains { $0.id == id } }
        historyOrder.removeAll { $0 == page.id }; historyOrder.append(page.id)
        trimHistory()
    }
    private func noteHistory(_ file: FileDocumentRecord) {
        fileHistory.removeAll { $0.path == file.path }; fileHistory.append(file)
        historyOrder.removeAll { id in !history.contains { $0.id == id } && !fileHistory.contains { $0.id == id } }
        historyOrder.removeAll { $0 == file.id }; historyOrder.append(file.id); trimHistory()
    }
    /// Forgets every page visit in this context, keeping file visits. Saved so the snapshot
    /// cannot re-seed the shared history on the next launch.
    func clearPageHistory() {
        guard !history.isEmpty else { return }
        let pageIDs = Set(history.map(\.id))
        historyOrder.removeAll { pageIDs.contains($0) }
        history.removeAll()
        changed()
    }
    private func trimHistory() {
        historyOrder = Array(historyOrder.suffix(100))
        history.removeAll { !historyOrder.contains($0.id) }; fileHistory.removeAll { !historyOrder.contains($0.id) }
    }
    private func wire(_ file: EditorDocumentViewModel) { file.changed = { [weak self] in self?.changed() } }
    private func wire(_ page: BrowserPage) {
        page.isOwned = { [weak self, weak page] in
            guard let self, let page else { return false }
            return isOwned() && pages.contains { $0 === page }
        }
        page.materialized = { [weak self, weak page] in
            guard let self, let page else { return }
            pageMaterialized(page)
        }
        page.changed = { [weak self, weak page] in
            guard let self, let page else { return }
            noteHistory(page.record); changed()
        }
        page.openPopup = { [weak self, weak page] url, configuration, openedLink in
            guard let self else { return nil }
            // Scripted popups (window.open, OAuth and payment flows, about:blank) need the child
            // web view back so the opener handshake completes, whatever panel they are in.
            guard openedLink, url.absoluteString != "about:blank" else {
                let popup = open(url.absoluteString, configuration: configuration)
                popup?.opener = page
                return popup?.webView
            }
            // The user opening a link into a new window is a page they asked for. A panel that
            // holds one page — a sidebar tab, pinned or not — has nowhere to put it, so it becomes
            // its own tab under Tabs; a session's second panel opens it as another of its pages.
            // Where the sidebar cannot take it, it opens here rather than nowhere.
            if holdsOnePage, let openSidebarTab {
                openSidebarTab(url.absoluteString) { [weak self] in self?.open(url.absoluteString, allowDuplicate: true) }
            } else {
                open(url.absoluteString, allowDuplicate: true)
            }
            return nil
        }
    }
}

@MainActor @Observable final class ViewerStore {
    let closeCoordinator: EditorCloseCoordinator
    let fileOpen: FileOpenViewModel
    let fileOpenCoordinator: FileOpenCoordinator
    private(set) var contexts: [String: WorkspaceContext] = [:]
    private(set) var activeContextID: String? {
        didSet {
            guard oldValue != activeContextID else { return }
            fileOpen.cancel()
            oldValue.flatMap { contexts[$0] }?.workspaceViewModel?.setActive(false)
            active?.workspaceViewModel?.setActive(true)
            activeContextChanged()
        }
    }
    @ObservationIgnored var prepareContext: (WorkspaceContext) -> Void = { _ in }
    /// Called after a context leaves `contexts`, so owners can drop what they hold for it.
    @ObservationIgnored var contextRemoved: (WorkspaceContext) -> Void = { _ in }
    /// Called after `active` changes: the context a selection shows is now a different one, or none.
    @ObservationIgnored var activeContextChanged: () -> Void = {}
    /// Called whenever a context's snapshot changes: a page navigated, a tab opened or closed.
    @ObservationIgnored var contextChanged: (WorkspaceContext) -> Void = { _ in }
    /// Opens a link as a new tab in the sidebar's Tabs list, for the panels that hold one page.
    /// Calls `keepInPanel` instead where the list cannot take it, so the link still opens.
    @ObservationIgnored var openSidebarTab: (String, @escaping () -> Void) -> Void = { _, _ in }
    @ObservationIgnored private var api: APIClient?
    /// Every context's last snapshot, open or not: what `cacheURL` holds between launches.
    @ObservationIgnored private var saved: [String: ContextSnapshot] = [:]
    /// True until the page-tab snapshots an earlier version kept in the backend have been looked
    /// at. Only a Mac with no page-tabs.json of its own has anything to adopt (a data directory
    /// carried over, a file lost): the Mac they were written on rewrote the file after every
    /// restore, so it already holds them.
    @ObservationIgnored private(set) var needsImport = false
    /// Whether the file's contents are in `saved`, or there was no file. A file that was not read
    /// is never written over: it is set aside first.
    @ObservationIgnored private var readFromDisk = false
    @ObservationIgnored private let pageFactory: BrowserPageFactory
    @ObservationIgnored private let documentFactory: any DocumentFeatureFactory
    @ObservationIgnored private let pagePool: PagePool
    /// Settings → Browser: what the pages may hold before hidden, idle ones are suspended.
    var pageMemoryLimit: MemoryLimit {
        get { pagePool.limit }
        set { pagePool.limit = newValue }
    }
    /// Shared by every context: pages visited anywhere, for the start page and address bar.
    let browserHistory: BrowserHistoryStore
    /// Shared by every context: the pages bookmarked from any panel.
    let browserBookmarks: BrowserBookmarkStore
    private let cacheURL: URL?
    /// `pending` named the snapshots not yet mirrored to the backend; nothing is mirrored now, and
    /// the field stays so files written before that still decode.
    private struct Cache: Codable { let snapshots: [String: ContextSnapshot]; let pending: Set<String> }
    init(cacheURL: URL? = nil,
         browserHistory: BrowserHistoryStore = BrowserHistoryStore(),
         browserBookmarks: BrowserBookmarkStore = BrowserBookmarkStore(),
         pageFactory: BrowserPageFactory = BrowserPageFactory(),
         documentFactory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         closeCoordinator: EditorCloseCoordinator? = nil,
         memory: any ProcessSampling = NativeProcessResourceSampler()) {
        self.cacheURL = cacheURL
        pagePool = PagePool(memory: memory)
        self.browserHistory = browserHistory
        self.browserBookmarks = browserBookmarks
        self.pageFactory = pageFactory
        self.documentFactory = documentFactory
        self.closeCoordinator = closeCoordinator ?? EditorCloseCoordinator(factory: documentFactory)
        fileOpen = documentFactory.fileOpen()
        fileOpenCoordinator = documentFactory.fileOpenCoordinator()
        fileOpenCoordinator.bind(fileOpen, activeContext: { [weak self] in self?.active })
        pagePool.pages = { [weak self] in self?.contexts.values.flatMap(\.pages) ?? [] }
        pagePool.shown = { [weak self] in self?.active?.activePage }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            saved = cache.snapshots
            readFromDisk = true
            // Pages visited in a context not opened this launch still belong in the address bar.
            for snapshot in saved.values { browserHistory.seed(snapshot.history) }
        } else if let cacheURL, !FileManager.default.fileExists(atPath: cacheURL.path) {
            needsImport = true
            readFromDisk = true
        } else if cacheURL == nil {
            readFromDisk = true
        }
        // Otherwise a file this build could not read: it is set aside before the first write.
    }

    /// Takes over, once, the snapshots an earlier version kept in the backend as
    /// `native.context.<id>`, for every context `keeping` still knows and this Mac has nothing
    /// saved for. Contexts already open take theirs at once. The file is written either way, so
    /// the next launch finds it and asks no more.
    func importLegacySnapshots(_ settings: [String: String?], keeping: (String) -> Bool = { _ in true }) {
        guard needsImport else { return }
        needsImport = false
        for (key, value) in settings where key.hasPrefix("native.context.") {
            let id = String(key.dropFirst("native.context.".count))
            guard keeping(id), saved[id] == nil, let value, let data = value.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(ContextSnapshot.self, from: data) else { continue }
            saved[id] = snapshot
            contexts[id]?.apply(snapshot)
            contexts[id]?.documents.forEach(configure)
            browserHistory.seed(snapshot.history)
        }
        cache()
    }
    var active: WorkspaceContext? { activeContextID.flatMap { contexts[$0] } }
    func configure(_ document: EditorDocumentViewModel) {
        guard let api else { return }
        document.connect(service: documentFactory.editorService(api: api), makeSurface: { [documentFactory] in documentFactory.editorSurface(baseURL: api.baseURL) })
    }
    /// `directory` is where the panel starts: the session's worktree, so a file is picked from it.
    func openFile(in context: WorkspaceContext, directory: String? = nil) {
        guard active === context, !closeCoordinator.isPresenting else { return }
        fileOpen.begin(contextID: context.id, directory: directory)
    }
    func closeDocuments(contextIDs: Set<String>? = nil, worktrees: [String] = []) async -> Bool {
        fileOpen.cancel()
        func affected(_ document: EditorDocumentViewModel, context: WorkspaceContext) -> Bool {
            if contextIDs == nil || contextIDs!.contains(context.id) { return true }
            let path = URL(fileURLWithPath: document.record.path).resolvingSymlinksInPath().path
            return worktrees.contains { root in
                let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                return path == root || path.hasPrefix(root + "/")
            }
        }
        while true {
            let targets = contexts.values.flatMap { context in
                context.documents.filter { affected($0, context: context) }.map { (context, $0) }
            }
            if targets.isEmpty { return true }
            guard await closeCoordinator.close(targets.map { $0.1 }, isOwned: {
                targets.allSatisfy { context, document in
                    contexts[context.id] === context && context.documents.contains { $0 === document }
                }
            }, commit: {
                for (context, document) in targets { context.remove(document) }
            }) else { return false }
            // Include documents opened by other routes while a save awaits.
        }
    }
    /// Contexts are restored from `cacheURL` when the store is made; connecting only gives the
    /// documents their editor service.
    func connect(_ api: APIClient) {
        fileOpenCoordinator.enabled = true
        self.api = api
        contexts.values.flatMap(\.documents).forEach(configure)
    }
    private func workspace(id: String, url: String, title: String, legacy: SavedTab?) -> WorkspaceContext {
        // An open context is already wired. Writing `contexts` or its observed properties again
        // would invalidate every view of the workspace on screen, on every sidebar switch.
        if let existing = contexts[id] { prepareContext(existing); return existing }
        let context = WorkspaceContext(id: id, sourceURL: url, title: title,
                                       snapshot: saved[id] ?? legacy.map(ContextSnapshot.importing), pageFactory: pageFactory, documentFactory: documentFactory, closeCoordinator: closeCoordinator)
        contexts[id] = context
        context.globalHistory = browserHistory
        context.bookmarks = browserBookmarks
        context.clearBrowsingHistory = { [weak self] in self?.clearBrowsingHistory() }
        context.fileSearch.service = { [weak self] in
            guard let self, let api else { return nil }
            return documentFactory.fileSearchService(api: api)
        }
        browserHistory.seed(context.history)
        context.isOwned = { [weak self, weak context] in
            guard let self, let context else { return false }
            return contexts[context.id] === context
        }
        prepareContext(context)
        context.changed = { [weak self, weak context] in
            if let context { self?.save(context) }
        }
        context.activatePage = { [weak self] in self?.activate($0) }
        context.pageMaterialized = { [weak self] page in
            guard let self else { return }
            pagePool.used(page)
            pagePool.trim()
        }
        context.openSidebarTab = { [weak self] url, keepInPanel in self?.openSidebarTab(url, keepInPanel) }
        context.activateDocument = { [weak self] in self?.configure($0) }
        context.documents.forEach(configure)
        return context
    }
    @discardableResult func restore(id: String, url: String, title: String, legacy: SavedTab? = nil) -> WorkspaceContext {
        workspace(id: id, url: url, title: title, legacy: legacy)
    }
    @discardableResult func select(id: String, url: String, title: String, legacy: SavedTab? = nil) -> WorkspaceContext {
        let context = workspace(id: id, url: url, title: title, legacy: legacy)
        activeContextID = id
        if let page = context.activePage { activate(page) }
        return context
    }
    func deactivate() { activeContextID = nil }
    func promoteContext(from sourceID: String, to destinationID: String) throws {
        guard sourceID != destinationID, let source = contexts[sourceID] else {
            throw BackendError.operation(String(localized: "The source page is no longer available. Open its session to continue."))
        }
        // Move the actual objects, including dirty documents and live WebKit
        // pages. Recreating them from a snapshot would discard unsaved buffers.
        fileOpen.cancel()
        contexts.removeValue(forKey: sourceID)
        let context: WorkspaceContext
        if let existing = contexts[destinationID] {
            source.workspaceViewModel?.setActive(false)
            existing.absorb(source); context = existing
        } else {
            source.id = destinationID; contexts[destinationID] = source; context = source
        }
        if activeContextID == sourceID { activeContextID = destinationID }
        context.setPane(.term)
        // Keep the old persisted snapshot as history for reopening the page.
        // Outstanding writes under its old key cannot overwrite this context.
    }
    func remove(id: String) async {
        if fileOpen.request?.contextID == id { fileOpen.cancel() }
        let context = contexts.removeValue(forKey: id)
        context?.workspaceViewModel?.setActive(false)
        if let context { contextRemoved(context) }
        context?.changed = {}
        context?.pages.forEach { $0.evict() }
        context?.documents.forEach { $0.dispose() }
        if activeContextID == id { activeContextID = nil }
        saved.removeValue(forKey: id)
        cache()
    }
    // Each page is its own content process. With no memory limit, the default, macOS alone
    // reclaims them under pressure; with one, the page pool suspends the least recently used.
    private func activate(_ page: BrowserPage) {
        page.materialize()
        pagePool.used(page)
    }
    /// Clears the shared history and every context's page visits, live or only saved, so no
    /// snapshot can seed the cleared entries back on restore.
    func clearBrowsingHistory() {
        for context in contexts.values { context.clearPageHistory() }
        for (id, snapshot) in saved where contexts[id] == nil && !snapshot.history.isEmpty {
            saved[id] = snapshot.clearingPageHistory
        }
        cache()
        browserHistory.clear()
    }
    /// Reloads every materialized page so a cleared cookie jar takes effect on screen instead of
    /// leaving the old authenticated session running in memory.
    func reloadLivePages() {
        for context in contexts.values {
            for page in context.pages where page.webView != nil { page.reload() }
        }
    }
    private func save(_ context: WorkspaceContext) {
        contextChanged(context)
        saved[context.id] = context.snapshot
        cache()
    }
    private func cache() {
        guard let cacheURL else { return }
        if !readFromDisk, FileManager.default.fileExists(atPath: cacheURL.path) {
            // Unread at startup, still here now: kept beside the file for a look, never written over.
            var aside = cacheURL.appendingPathExtension("broken")
            var attempt = 1
            while FileManager.default.fileExists(atPath: aside.path) {
                attempt += 1
                aside = cacheURL.appendingPathExtension("broken-\(attempt)")
            }
            guard (try? FileManager.default.moveItem(at: cacheURL, to: aside)) != nil else {
                active?.error = String(localized: "Could not save page tabs: the unread saved file could not be set aside.")
                return
            }
            active?.error = String(localized: "The saved page tabs could not be read and were set aside.")
        }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(snapshots: saved, pending: [])).write(to: cacheURL, options: .atomic)
            readFromDisk = true
        } catch { active?.error = String(localized: "Could not save page tabs: \(error.localizedDescription)") }
    }
    func stop() async {
        fileOpenCoordinator.enabled = false
        api = nil
    }
}
