import AppKit
import Foundation
import Observation
import WebKit

enum ReviewSection: String, Codable, CaseIterable, Identifiable {
    case changes = "Changes", history = "History"
    var id: String { rawValue }
}

/// `simulator` is never saved: the stream it shows belongs to this launch, so a restored
/// workspace opens on its browser instead.
enum WorkspacePane: String, Codable, CaseIterable { case off, term, diff, files, simulator }

enum WorkspaceMode: String, CaseIterable, Identifiable {
    // Declaration order is the order of the toolbar picker: Browser, Files, Diff, Simulator.
    case browser, files, diff, simulator
    var id: String { rawValue }
    var pane: WorkspacePane { switch self { case .browser: .term; case .diff: .diff; case .files: .files; case .simulator: .simulator } }
    var title: String { switch self { case .browser: "Browser"; case .diff: "Diff"; case .files: "Files"; case .simulator: "Simulator" } }
    var symbol: String {
        switch self { case .browser: "globe"; case .diff: "plus.forwardslash.minus"; case .files: "doc.text"; case .simulator: "iphone" }
    }
    init?(pane: WorkspacePane) {
        switch pane {
        case .term: self = .browser; case .diff: self = .diff; case .files: self = .files; case .simulator: self = .simulator
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
    var paneFraction: Double? = nil

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
    @ObservationIgnored private var lastPageID: String?
    @ObservationIgnored private var lastDocumentID: String?
    private(set) var paneFraction: Double?
    private(set) var reviewSection: ReviewSection = .changes {
        didSet { if oldValue != reviewSection { workspaceViewModel?.reviewStateChanged() } }
    }
    var restoring = false {
        didSet {
            guard oldValue != restoring else { return }
            workspaceViewModel?.documentStateChanged()
            if !restoring, let value = pendingFraction { pendingFraction = nil; setPaneFraction(value) }
        }
    }
    /// A divider drag made while restoring, kept until saving it can no longer turn the restore away.
    @ObservationIgnored private var pendingFraction: Double?
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
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored private let closeCoordinator: EditorCloseCoordinator
    @ObservationIgnored private let pageFactory: BrowserPageFactory
    @ObservationIgnored private let documentFactory: any DocumentFeatureFactory
    /// The Files tab bar's search; opening a result is this context's own `openFile`.
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
            pane = WorkspacePane(rawValue: snapshot.pane) ?? .term
            reviewSection = snapshot.reviewSection ?? .changes
            paneFraction = snapshot.paneFraction
            if pane == .term, activeDocument != nil { pane = .files }
            if pane == .files, activeDocument == nil, activePage != nil { pane = .term }
            lastPageID = activePage?.id; lastDocumentID = activeDocument?.id
            lastMode = WorkspaceMode(pane: pane) ?? (activeDocument != nil ? .files : .browser)
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
    /// The Files panel's empty tab: a field to search the worktree from, holding no file yet. It
    /// trails the file tabs, is never saved, and gives its slot to the file it opens.
    static let blankFileID = "blank-file"
    private(set) var hasBlankFileTab = false { didSet { if oldValue != hasBlankFileTab { fileEdits += 1 } } }
    /// Count tabs opened, closed and moved by hand, never a restore: what each tab bar animates on.
    private(set) var pageEdits = 0
    private(set) var fileEdits = 0
    private func noteEdit(page: Bool) { if page { pageEdits += 1 } else { fileEdits += 1 } }
    /// The empty-state tabs the bars opened themselves: unlike Cmd-T they must not take the keyboard.
    var fillerPageID: String?
    var fillerFileTab = false
    var blankFileActive: Bool { hasBlankFileTab && activeID == Self.blankFileID }
    func newFileTab() {
        hasBlankFileTab = true; activeID = Self.blankFileID; pane = .files; changed()
    }
    func closeBlankFileTab() {
        guard hasBlankFileTab else { return }
        hasBlankFileTab = false; fileSearch.reset()
        guard activeID == Self.blankFileID else { return }
        activeID = nil
        if let file = documents.first(where: { $0.id == lastDocumentID }) ?? documents.last { select(.file(file)) } else { changed() }
    }
    var tabs: [WorkspaceTab] { tabOrder.compactMap(tab) }
    var pageTabs: [WorkspaceTab] { tabs.filter { if case .page = $0 { true } else { false } } }
    var fileTabs: [WorkspaceTab] { tabs.filter { if case .file = $0 { true } else { false } } }
    var visits: [WorkspaceVisit] { historyOrder.compactMap { id in
        if let page = history.first(where: { $0.id == id }) { return .page(page) }
        return fileHistory.first(where: { $0.id == id }).map(WorkspaceVisit.file)
    } }
    var pageVisits: [WorkspaceVisit] { visits.filter { if case .page = $0 { true } else { false } } }
    var fileVisits: [WorkspaceVisit] { visits.filter { if case .file = $0 { true } else { false } } }
    var modeTabs: [WorkspaceTab] { pane == .files ? fileTabs : pageTabs }
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
              legacyDocuments: legacyDocuments, legacyFileHistory: legacyFileHistory,
              paneFraction: paneFraction)
    }
    func setPaneFraction(_ value: Double) {
        guard !restoring else { pendingFraction = value; return }
        guard paneFraction.map({ abs($0 - value) > 0.001 }) ?? true else { return }
        paneFraction = value; changed()
    }
    func setReviewSection(_ value: ReviewSection) { reviewSection = value; changed() }
    func setPane(_ value: WorkspacePane) {
        switch value {
        case .term where activePage == nil:
            activeID = pages.first { $0.id == lastPageID }?.id ?? pageTabs.last?.id
        case .files where activeDocument == nil:
            activeID = documents.first { $0.id == lastDocumentID }?.id ?? fileTabs.last?.id
                ?? (hasBlankFileTab ? Self.blankFileID : nil)
        default: break
        }
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
        if let selected = source.activeID, tabOrder.contains(selected) {
            activeID = selected
            if activeDocument != nil { lastDocumentID = selected; pane = .files }
            else { lastPageID = selected; if pane == .files { pane = .term } }
        }
        source.changed = {}; source.activatePage = { _ in }; source.activateDocument = { _ in }
        source.pages = []; source.documents = []; source.tabOrder = []; source.activeID = nil
    }
    func select(_ page: BrowserPage) {
        activeID = page.id; lastPageID = page.id; pane = .term; activatePage(page); changed()
    }
    func select(_ tab: WorkspaceTab) {
        switch tab { case .page(let page): select(page)
        case .file(let file): activeID = file.id; lastDocumentID = file.id; pane = .files; activateDocument(file); changed() }
    }
    func cycle(_ direction: Int) {
        let order = modeTabs.map(\.id)
        guard !order.isEmpty else { return }
        let index = order.firstIndex(of: activeID ?? "") ?? 0
        if let tab = tab(order[(index + direction + order.count) % order.count]) { select(tab) }
    }
    @discardableResult func openFile(_ path: String, line: Int = 1, column: Int = 1) -> EditorDocumentViewModel? {
        guard path.hasPrefix("/"), !path.contains("\0") else { error = "Choose an absolute file path."; return nil }
        let path = (path as NSString).standardizingPath
        if let file = documents.first(where: { $0.record.path == path }) { select(.file(file)); file.focus(line: line, column: column); return file }
        let file = documentFactory.editor(record: .init(path: path))
        // A file opened from the blank tab takes its place: the blank trails the tabs, and so does
        // an insert with no active tab to follow.
        if blankFileActive { hasBlankFileTab = false; fileSearch.reset() }
        documents.append(file); wire(file); insert(file.id, page: false); noteHistory(file.record)
        select(.file(file)); file.focus(line: line, column: column); return file
    }
    private func insert(_ id: String, page: Bool = true, atEnd: Bool = false) {
        let index = atEnd ? tabOrder.endIndex : tabOrder.firstIndex(of: activeID ?? "").map { $0 + 1 } ?? tabOrder.endIndex
        tabOrder.insert(id, at: index); noteEdit(page: page)
        pages.sort { tabOrder.firstIndex(of: $0.id)! < tabOrder.firstIndex(of: $1.id)! }
    }
    /// Moves a tab before another, or to the end for nil. Pages and files share one order, and each
    /// panel shows its own kind in it, so a move among one kind leaves the other where it was.
    func moveTab(_ id: String, before target: String?) {
        guard id != target, let from = tabOrder.firstIndex(of: id) else { return }
        var order = tabOrder
        order.remove(at: from)
        order.insert(id, at: target.flatMap(order.firstIndex(of:)) ?? order.endIndex)
        guard order != tabOrder else { return }
        tabOrder = order; noteEdit(page: pages.contains { $0.id == id })
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
        noteHistory(file.record); file.dispose(); documents.removeAll { $0 === file }; removeTab(file.id, page: false)
    }
    private func removeTab(_ id: String, page: Bool) {
        let kin = Set((page ? pages.map(\.id) : documents.map(\.id)) + [id])
        let siblings = tabOrder.filter(kin.contains)
        let index = siblings.firstIndex(of: id) ?? 0
        tabOrder.removeAll { $0 == id }; noteEdit(page: page)
        if lastPageID == id { lastPageID = nil }
        if lastDocumentID == id { lastDocumentID = nil }
        if activeID == id {
            let remaining = siblings.filter { $0 != id }
            activeID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
            // The blank file tab is not in `tabOrder`; with no file left it is what remains selected.
            if activeID == nil, !page, hasBlankFileTab { activeID = Self.blankFileID }
            if let activeID, let tab = tab(activeID) { select(tab) }
        }
        changed()
    }
    /// `allowDuplicate` opens another tab even when the address is already open, as a link that
    /// asked for a new window must; otherwise the open page is selected instead.
    @discardableResult func open(_ url: String, title: String = "", configuration: WKWebViewConfiguration? = nil,
                                 allowDuplicate: Bool = false) -> BrowserPage? {
        guard safeWebURL(url) != nil || (configuration != nil && url == "about:blank") else {
            error = "Enter an HTTP or HTTPS address."; return nil
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
        let page = pageFactory.make(.init(url: Self.blankPageURL, title: "New Tab"))
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
        removeTab(page.id, page: true)
    }
    func apply(_ snapshot: ContextSnapshot) {
        // Used only for the first backend load, before the user edits this context.
        pages.forEach { $0.evict() }; documents.forEach { $0.dispose() }
        let restored = WorkspaceContext(id: id, sourceURL: sourceURL, title: "", snapshot: snapshot, pageFactory: pageFactory, documentFactory: documentFactory, closeCoordinator: closeCoordinator)
        pages = restored.pages; activeID = restored.activeID; history = restored.history; pane = restored.pane
        lastPageID = restored.activePage?.id; lastDocumentID = restored.activeDocument?.id
        lastMode = restored.lastMode
        reviewSection = restored.reviewSection
        paneFraction = restored.paneFraction
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
        page.changed = { [weak self, weak page] in
            guard let self, let page else { return }
            noteHistory(page.record); changed()
        }
        page.openPopup = { [weak self] url, configuration, openedLink in
            guard let self else { return nil }
            // Scripted popups (window.open, OAuth and payment flows, about:blank) need the child
            // web view back so the opener handshake completes, whatever panel they are in.
            guard openedLink, url.absoluteString != "about:blank" else {
                return open(url.absoluteString, configuration: configuration)?.webView
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
    /// When the user last cleared history, so a restore already in flight cannot seed it back.
    @ObservationIgnored private var clearedHistoryAt: Date?
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
    @ObservationIgnored private var saved: [String: ContextSnapshot] = [:]
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var edited: Set<String> = []
    @ObservationIgnored private var writes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var restoreGeneration = UUID()
    @ObservationIgnored private let pageFactory: BrowserPageFactory
    @ObservationIgnored private let documentFactory: any DocumentFeatureFactory
    /// Shared by every context: pages visited anywhere, for the start page and address bar.
    let browserHistory: BrowserHistoryStore
    /// Shared by every context: the pages bookmarked from any panel.
    let browserBookmarks: BrowserBookmarkStore
    private let cacheURL: URL?
    private struct Cache: Codable { let snapshots: [String: ContextSnapshot]; let pending: Set<String> }
    init(cacheURL: URL? = nil,
         browserHistory: BrowserHistoryStore = BrowserHistoryStore(),
         browserBookmarks: BrowserBookmarkStore = BrowserBookmarkStore(),
         pageFactory: BrowserPageFactory = BrowserPageFactory(),
         documentFactory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         closeCoordinator: EditorCloseCoordinator? = nil) {
        self.cacheURL = cacheURL
        self.browserHistory = browserHistory
        self.browserBookmarks = browserBookmarks
        self.pageFactory = pageFactory
        self.documentFactory = documentFactory
        self.closeCoordinator = closeCoordinator ?? EditorCloseCoordinator(factory: documentFactory)
        fileOpen = documentFactory.fileOpen()
        fileOpenCoordinator = documentFactory.fileOpenCoordinator()
        fileOpenCoordinator.bind(fileOpen, activeContext: { [weak self] in self?.active })
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            saved = cache.snapshots; dirty = cache.pending; edited = cache.pending
        }
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
    func connect(_ api: APIClient) {
        fileOpenCoordinator.enabled = true
        self.api = api
        loading?.cancel()
        restoring = true
        contexts.values.forEach { $0.restoring = true }
        contexts.values.flatMap(\.documents).forEach(configure)
        let generation = UUID(); restoreGeneration = generation
        let startedAt = Date()
        loading = Task {
            defer {
                if restoreGeneration == generation {
                    restoring = false
                    contexts.values.forEach { $0.restoring = false }
                    if !Task.isCancelled, let page = active?.activePage { activate(page) }
                }
            }
            do {
                let values: [String: String?] = try await api.get(Routes.SETTINGS)
                try Task.checkCancellation()
                for (key, value) in values where key.hasPrefix("native.context.") {
                    guard let value, let data = value.data(using: .utf8),
                          let snapshot = try? JSONDecoder().decode(ContextSnapshot.self, from: data) else { continue }
                    let id = String(key.dropFirst("native.context.".count))
                    guard !edited.contains(id) else { continue }
                    // A restore that started before a clear carries the visits the user just
                    // removed, so it lands without its page history and seeds nothing.
                    let restored = clearedHistoryAt.map { $0 > startedAt } == true ? snapshot.clearingPageHistory : snapshot
                    saved[id] = restored
                    contexts[id]?.apply(restored)
                    contexts[id]?.documents.forEach(configure)
                    browserHistory.seed(restored.history)
                }
                cache()
                for id in dirty { if let snapshot = saved[id] { enqueue(id: id, snapshot: snapshot, api: api) } }
            } catch { if !Task.isCancelled { active?.error = "Could not restore page tabs: \(error.localizedDescription)" } }
        }
    }
    private func workspace(id: String, url: String, title: String, legacy: SavedTab?) -> WorkspaceContext {
        let context = contexts[id] ?? WorkspaceContext(id: id, sourceURL: url, title: title,
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
        context.restoring = restoring
        context.changed = { [weak self, weak context] in
            if let context { self?.save(context) }
        }
        context.activatePage = { [weak self] in self?.activate($0) }
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
        if !restoring, let page = context.activePage { activate(page) }
        return context
    }
    func deactivate() { activeContextID = nil }
    func promoteContext(from sourceID: String, to destinationID: String) throws {
        guard sourceID != destinationID, let source = contexts[sourceID] else {
            throw BackendError.operation("The source page is no longer available. Open its session to continue.")
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
        context.setPane(context.activeDocument != nil ? .files : .term)
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
        await writes[id]?.value
        writes[id] = nil
        saved.removeValue(forKey: id); dirty.remove(id); edited.remove(id)
        cache()
        if let api { try? await api.setSetting("native.context.\(id)", value: "") }
    }
    // WKWebView owns its own memory: each page is a separate content process that macOS
    // reclaims under pressure. The app used to evict pages itself on an LRU with a page-count
    // budget, inherited from the web renderer where every page shared one process.
    private func activate(_ page: BrowserPage) {
        page.materialize()
    }
    /// Clears the shared history and every context's page visits, live or only saved, so no
    /// snapshot can seed the cleared entries back on restore.
    func clearBrowsingHistory() {
        clearedHistoryAt = Date()
        for context in contexts.values { context.clearPageHistory() }
        for (id, snapshot) in saved where contexts[id] == nil && !snapshot.history.isEmpty {
            let cleared = snapshot.clearingPageHistory
            saved[id] = cleared; edited.insert(id); dirty.insert(id)
            if let api { enqueue(id: id, snapshot: cleared, api: api) }
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
        edited.insert(context.id)
        dirty.insert(context.id)
        saved[context.id] = context.snapshot
        cache()
        guard let api else { return }
        enqueue(id: context.id, snapshot: context.snapshot, api: api)
    }
    private func enqueue(id: String, snapshot: ContextSnapshot, api: APIClient) {
        let previous = writes[id]
        writes[id] = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
                try await api.setSetting("native.context.\(id)", value: json)
                guard let self else { return }
                if saved[id] == snapshot { dirty.remove(id); cache() }
            } catch { if !Task.isCancelled { self?.contexts[id]?.error = "Page tabs saved locally; backend sync failed: \(error.localizedDescription)" } }
        }
    }
    private func cache() {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(snapshots: saved, pending: dirty)).write(to: cacheURL, options: .atomic)
        } catch { active?.error = "Could not save page tabs locally: \(error.localizedDescription)" }
    }
    func stop() async {
        fileOpenCoordinator.enabled = false
        loading?.cancel(); await loading?.value; loading = nil
        for task in writes.values { await task.value }
        writes.removeAll(); api = nil
    }
}
