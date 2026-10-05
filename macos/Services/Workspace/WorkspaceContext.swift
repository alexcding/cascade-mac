import AppKit
import Foundation
import Observation
import WebKit

enum ReviewSection: String, Codable, CaseIterable, Identifiable {
    case changes = "Changes", history = "History"
    var id: String { rawValue }
    var title: String { self == .changes ? String(localized: "Changes") : String(localized: "History") }
}

/// What the pane shows, which its active tab decides: `term` for pages, files and the Files
/// picker, `diff` for the Changes tab, `simulator` for the Simulator's. `off` is the pane shut. A
/// snapshot saved while files had a pane of their own restores to `term`.
enum WorkspacePane: String, Codable, CaseIterable {
    case off, term, diff, simulator
    init?(saved: String) { self.init(rawValue: saved == "files" ? "term" : saved) }
}

/// A file or page an earlier version kept in a snapshot, before documents had records of their own.
struct SavedTabContent: Codable, Equatable, Sendable {
    var kind: String? = nil
    var url: String? = nil
    var title: String? = nil
    var path: String? = nil
    var active: Bool? = nil

    var filePath: String? {
        guard kind == "file" else { return nil }
        if let path, path.hasPrefix("/"), !path.contains("\0") { return (path as NSString).standardizingPath }
        guard let url, let value = URL(string: url), value.isFileURL,
              value.host == nil || value.host == "" || value.host == "localhost",
              !value.path.contains("\0") else { return nil }
        return value.path
    }
}

/// A tool the pane holds as a tab beside its pages and files, at most one of each: the worktree's
/// changes, the Simulator, the worktree's files to pick one from, and the agent's live diagram.
enum WorkspaceTool: String, Codable, CaseIterable {
    case changes, simulator, files, live
    private static let prefix = "tool:"
    var id: String { Self.prefix + rawValue }
    init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(id.dropFirst(Self.prefix.count)))
    }
    /// The pane its tab shows.
    var pane: WorkspacePane {
        switch self { case .changes: .diff; case .simulator: .simulator; case .files, .live: .term }
    }
    var title: String {
        switch self {
        case .changes: String(localized: "Diff")
        case .simulator: String(localized: "Simulator")
        case .files: String(localized: "Open file")
        case .live: String(localized: "Live Monitor")
        }
    }
    var symbol: String {
        switch self { case .changes: "plus.forwardslash.minus"; case .simulator: "iphone"; case .files: "doc"; case .live: "flowchart" }
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
    /// The tool tabs open, by `WorkspaceTool` raw value; their places are in `tabOrder`.
    var tools: [String]? = nil
    var fileHistory: [FileDocumentRecord]? = nil
    var historyOrder: [String]? = nil
    var legacyDocuments: [SavedTabContent]? = nil
    var legacyFileHistory: [SavedTabContent]? = nil
}

@MainActor @Observable final class WorkspaceContext: @MainActor Identifiable {
    let id: String
    let sourceURL: String
    private(set) var pages: [BrowserPage] = []
    private(set) var documents: [EditorDocumentViewModel] = []
    private(set) var tools: [WorkspaceTool] = []
    private(set) var tabOrder: [String] = []
    private(set) var fileHistory: [FileDocumentRecord] = []
    private(set) var historyOrder: [String] = []
    private(set) var activeID: String? {
        didSet { if oldValue != activeID { remember(); workspaceViewModel?.documentStateChanged() } }
    }
    private(set) var history: [WebPageRecord] = []
    private(set) var pane: WorkspacePane = .term {
        didSet {
            if pane != .off { lastPane = pane }
            if oldValue != pane { workspaceViewModel?.reviewStateChanged() }
        }
    }
    /// The pane last shown, never `off`: what toggling the context back brings in.
    private(set) var lastPane: WorkspacePane = .term
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
    @ObservationIgnored var activateDocument: (EditorDocumentViewModel) -> Void = { _ in }
    @ObservationIgnored var activatePage: (BrowserPage) -> Void = { _ in }
    /// Called when one of its pages creates its web view.
    @ObservationIgnored var pageMaterialized: (BrowserPage) -> Void = { _ in }
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored private let closeCoordinator: EditorCloseCoordinator
    @ObservationIgnored private let pageFactory: BrowserPageFactory
    @ObservationIgnored private let documentFactory: any DocumentFeatureFactory
    /// The address field's worktree search. Made when first asked for, so a context that never
    /// searches has none to retire.
    var fileSearch: FileSearchViewModel {
        if let searchModel { return searchModel }
        let model = documentFactory.fileSearch()
        searchModel = model
        return model
    }
    @ObservationIgnored private var searchModel: FileSearchViewModel?
    /// The Files tab's tree; it lists through the same service as the address field's search.
    /// Made when first asked for, so a context that never shows it has none to retire.
    var worktreeFiles: WorktreeFilesViewModel {
        if let filesModel { return filesModel }
        let model = WorktreeFilesViewModel()
        model.service = { [weak self] in self?.fileSearch.service() }
        model.onAction = { [weak self] action in
            switch action { case .open(let path): self?.openFromTree(path) }
        }
        filesModel = model
        return model
    }
    @ObservationIgnored private var filesModel: WorktreeFilesViewModel?
    /// The worktree's tree and search go with the context: a listing still running must not land.
    func retireWorktreeFiles() { filesModel?.retire(); searchModel?.retire() }
    /// A file picked from the tree opens in a tab of its own beside the one it was picked from, or
    /// selects the tab it already has; the explorer stays open for the next pick.
    func openFromTree(_ path: String) { openFile(path) }

    private(set) var workspaceViewModel: SessionWorkspaceViewModel?

    func configureWorkspace(factory: any WorkspaceFeatureFactory, service: any WorkspaceServing) {
        guard workspaceViewModel == nil else { return }
        workspaceViewModel = factory.workspace(context: self, service: service)
    }

    init(id: String, sourceURL: String, title: String, snapshot: ContextSnapshot? = nil,
         pageFactory: BrowserPageFactory = BrowserPageFactory(),
         documentFactory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         closeCoordinator: EditorCloseCoordinator? = nil) {
        self.id = id; self.sourceURL = sourceURL
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
            tools = (snapshot.tools ?? []).compactMap(WorkspaceTool.init(rawValue:)).filter { ids.insert($0.id).inserted }
            tabOrder = Self.order(snapshot.tabOrder, ids: pages.map(\.id) + documents.map(\.id) + tools.map(\.id))
            fileHistory = snapshot.fileHistory ?? legacyFileHistory.compactMap { entry in
                entry.filePath.map { FileDocumentRecord(path: $0) }
            }
            historyOrder = Self.order(snapshot.historyOrder, ids: history.map(\.id) + fileHistory.map(\.id))
            activeID = tabOrder.contains(snapshot.activeID ?? "") ? snapshot.activeID : tabOrder.first
            // The active tab decides the pane. A snapshot from before tools were tabs said Diff with
            // its pane alone: it gets a Changes tab.
            pane = WorkspacePane(saved: snapshot.pane) ?? .term
            if snapshot.tools == nil, pane == .diff {
                tools = [.changes]; tabOrder.append(WorkspaceTool.changes.id); activeID = WorkspaceTool.changes.id
            }
            if pane != .off { pane = activeTool?.pane ?? .term }
            reviewSection = snapshot.reviewSection ?? .changes
            lastPane = pane == .off ? .term : pane
        } else if safeWebURL(sourceURL) != nil {
            let page = pageFactory.make(.init(url: sourceURL, title: title))
            pages = [page]; tabOrder = [page.id]; activeID = page.id
        } else {
            // Nothing to show beside the terminal: a session started from no page, and the scratch
            // Terminal, open on the shell alone rather than on an empty browser. Toggling the
            // context back, or opening any page or file, brings the pane in — `lastPane` still
            // says the pages and files.
            pane = .off
        }
        pages.forEach(wire)
        documents.forEach(wire)
        remember()
    }

    var activeDocument: EditorDocumentViewModel? { documents.first { $0.id == activeID } }
    /// The tool whose tab is active, if the active tab is a tool's.
    var activeTool: WorkspaceTool? { activeID.flatMap(WorkspaceTool.init(id:)).flatMap { tools.contains($0) ? $0 : nil } }
    /// Counts tabs opened, closed and moved by hand, never a restore: what the tab bar animates on.
    private(set) var tabEdits = 0
    /// The empty-state page the bar opened itself: unlike Cmd-T it must not take the keyboard.
    var fillerPageID: String?
    /// The tabs the strip shows and cycling walks: every tab — pages, files and tools — in their
    /// order. A blank page — the pane's own included — is a New Tab there until what is typed or
    /// picked in it takes its place.
    var tabs: [WorkspaceTab] { tabOrder.compactMap(tab) }
    /// The tool last in the order other than Diff — the explorer, the Simulator or Live — which
    /// leaving Diff goes back to when there is no page or file.
    private var lastToolBesidesDiff: WorkspaceTab? {
        tabOrder.reversed().lazy.compactMap(tab).first { if case .tool(let tool) = $0 { tool != .changes } else { false } }
    }
    /// The page or file last shown, which the tabs go back to and a save on the Simulator keeps.
    /// Noted whenever the active tab changes, and on restore.
    private var lastShownID: String?
    private func remember() {
        guard let id = activeID else { return }
        if pages.contains(where: { $0.id == id }) || documents.contains(where: { $0.id == id }) { lastShownID = id }
    }
    var visits: [WorkspaceVisit] { historyOrder.compactMap { id in
        if let page = history.first(where: { $0.id == id }) { return .page(page) }
        return fileHistory.first(where: { $0.id == id }).map(WorkspaceVisit.file)
    } }
    var fileVisits: [WorkspaceVisit] { visits.filter { if case .file = $0 { true } else { false } } }
    func tab(_ id: String) -> WorkspaceTab? {
        if let page = pages.first(where: { $0.id == id }) { return .page(page) }
        if let tool = WorkspaceTool(id: id), tools.contains(tool) { return .tool(tool) }
        return documents.first(where: { $0.id == id }).map(WorkspaceTab.file)
    }
    private static func order(_ preferred: [String]?, ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ((preferred ?? []) + ids).filter { ids.contains($0) && seen.insert($0).inserted }
    }
    var activePage: BrowserPage? { pages.first { $0.id == activeID } }
    /// The Simulator's tab is never saved: the stream it shows belongs to this launch, so a
    /// restored workspace opens on the page or file last shown instead, never on another tool.
    var snapshot: ContextSnapshot {
        let simulator = WorkspaceTool.simulator.id
        let saved = activeID == simulator ? lastShownID.flatMap { tabOrder.contains($0) ? $0 : nil }
            ?? tabOrder.last(where: { WorkspaceTool(id: $0) == nil }) : activeID
        return .init(pages: pages.map(\.record), activeID: saved, history: history,
                     pane: pane == .simulator ? WorkspacePane.term.rawValue : pane.rawValue,
                     reviewSection: reviewSection, documents: documents.map(\.record), tabOrder: tabOrder.filter { $0 != simulator },
                     tools: tools.filter { $0 != .simulator }.map(\.rawValue), fileHistory: fileHistory, historyOrder: historyOrder,
                     legacyDocuments: legacyDocuments, legacyFileHistory: legacyFileHistory)
    }
    func setReviewSection(_ value: ReviewSection) { reviewSection = value; changed() }
    /// Diff and Simulator are tabs: asking for either opens its tab, or selects it. The pages and
    /// files leave a tool's tab for the last page or file.
    func setPane(_ value: WorkspacePane) {
        switch value {
        case .diff: openTool(.changes)
        case .simulator: openTool(.simulator)
        case .term:
            // The page or file shown last, else the last in the order. Selected as a click would
            // select it, so a page the pool suspended is loaded again.
            if activeID == nil || (activeTool.map { $0.pane != .term } ?? false),
               let id = lastShownID.flatMap({ tabOrder.contains($0) ? $0 : nil }) ?? tabOrder.last(where: { WorkspaceTool(id: $0) == nil }),
               let tab = tab(id) {
                select(tab)
            } else {
                pane = .term; changed()
            }
        case .off: pane = .off; changed()
        }
    }
    /// A tool's tab, opened after the active tab or selected where it already is. A blank tab being
    /// typed in is left alone.
    /// `replacingBlank`: picked from a blank tab's start page, the tool takes that tab's place.
    func openTool(_ tool: WorkspaceTool, replacingBlank: Bool = false) {
        let blank = replacingBlank ? replaceableBlank : nil
        if !tools.contains(tool) { tools.append(tool); insert(tool.id) }
        select(.tool(tool))
        if let blank { close(blank) }
    }
    /// The blank tab a pick from its start page replaces.
    var replaceableBlank: BrowserPage? { activePage.flatMap { $0.controls.isBlank ? $0 : nil } }
    /// The pages and files, as asked for by leaving a tool or bringing the pane in. With only tools
    /// open there is no page to show: a new tab, its start page, rather than a tool's tab over
    /// nothing. Not for a caller about to open a page itself, as Cmd-T does.
    /// Leaving Diff with no page or file, a tool of the strip is shown rather than a new tab beside it.
    func showPages() {
        setPane(.term)
        guard let tool = activeTool, tool.pane != .term else { return }
        if tool == .changes, let strip = lastToolBesidesDiff { select(strip) } else { openBlankPage() }
    }
    /// The pane last shown, unless this workspace can no longer show it (`presentable`).
    func present() {
        guard pane == .off else { return }
        let shown = workspaceViewModel?.presentable(lastPane) ?? lastPane
        if shown == .term { showPages() } else { setPane(shown) }
    }
    func select(_ page: BrowserPage) {
        activeID = page.id; pane = .term; activatePage(page); changed()
    }
    func select(_ tab: WorkspaceTab) {
        switch tab { case .page(let page): select(page)
        case .file(let file): activeID = file.id; pane = .term; activateDocument(file); changed()
        case .tool(let tool): activeID = tool.id; pane = tool.pane; changed() }
    }
    func cycle(_ direction: Int) {
        let order = tabs.map(\.id)
        guard !order.isEmpty else { return }
        // From no tab at all, the first tab is next and the last previous, as from just before
        // the strip.
        let index = order.firstIndex(of: activeID ?? "") ?? (direction > 0 ? -1 : order.count)
        if let tab = tab(order[(index + direction + order.count) % order.count]) { select(tab) }
    }
    @discardableResult func openFile(_ path: String, line: Int = 1, column: Int = 1) -> EditorDocumentViewModel? {
        guard path.hasPrefix("/"), !path.contains("\0") else { error = String(localized: "Choose an absolute file path."); return nil }
        let path = (path as NSString).standardizingPath
        // A file opened from a blank tab — its address field, or its start page — takes its place.
        let blank = replaceableBlank
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
        case .tool(let tool):
            guard tools.contains(tool) else { return }
            tools.removeAll { $0 == tool }; removeTab(tool.id)
        }
    }
    func remove(_ file: EditorDocumentViewModel) {
        guard documents.contains(where: { $0 === file }) else { return }
        noteHistory(file.record); file.dispose(); documents.removeAll { $0 === file }; removeTab(file.id)
    }
    /// A tab closed while shown gives way to its nearest neighbour. The last one gone leaves the
    /// tabs' pane, where the bar opens a blank page.
    private func removeTab(_ id: String) {
        let index = tabOrder.firstIndex(of: id) ?? 0
        tabOrder.removeAll { $0 == id }; tabEdits += 1
        if activeID == id {
            let candidates = Array(tabOrder.enumerated())
            // The tab that took the closed one's place, else the one before it.
            let next = candidates.first { $0.offset >= index } ?? candidates.last
            activeID = next?.element
            if let activeID, let tab = tab(activeID) { select(tab) }
            else if pane != .off { pane = .term }
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
        // The blank page the pane opened for itself becomes the new tab, not a second one behind it.
        if let id = fillerPageID, let filler = pages.first(where: { $0.id == id }), filler.controls.isBlank {
            fillerPageID = nil
            tabOrder.removeAll { $0 == id }; insert(id, atEnd: true)
            error = nil
            select(filler)
            return filler
        }
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
        lastPane = restored.lastPane; tools = restored.tools
        reviewSection = restored.reviewSection
        documents = restored.documents; tabOrder = restored.tabOrder; fileHistory = restored.fileHistory; historyOrder = restored.historyOrder
        documents.forEach(wire)
        legacyDocuments = restored.legacyDocuments; legacyFileHistory = restored.legacyFileHistory
        pages.forEach(wire)
        remember()
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
            // The user opening a link into a new window is a page they asked for: it opens as
            // another of this panel's pages.
            open(url.absoluteString, allowDuplicate: true)
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
    /// Why the last write failed, for the app to show; nil while writes succeed.
    @ObservationIgnored private(set) var lastError: String?
    /// What happened to a saved file that could not be read, told once at startup. Unlike
    /// `lastError`, a later successful write does not clear it.
    @ObservationIgnored private var recoveryNotice: String?
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
        guard let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) else {
            // No file: nothing saved on this Mac yet, and what the backend kept is adopted on connect.
            needsImport = cacheURL != nil
            readFromDisk = true
            return
        }
        guard let data = try? Data(contentsOf: cacheURL) else {
            // Unread (an I/O error): set aside before the first write.
            recoveryNotice = String(localized: "The saved page tabs could not be read; they start empty.")
            return
        }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            // A file this build wrote that no longer reads: set aside now, for a look. The backend's
            // old snapshots are not adopted over it; that import happened when the file was first written.
            recoveryNotice = setAside(cacheURL)
                ? String(localized: "The saved page tabs could not be read and were set aside.")
                : String(localized: "The saved page tabs could not be read; they start empty.")
            return
        }
        // Sidebar tabs are gone: their snapshots (`tab:<id>`) have no context to restore into, and
        // are dropped rather than seeding history; the next write leaves them out of the file.
        saved = cache.snapshots.filter { !$0.key.hasPrefix("tab:") }
        readFromDisk = true
        // Pages visited in a context not opened this launch still belong in the address bar.
        for snapshot in saved.values { browserHistory.seed(snapshot.history) }
    }

    /// The notice, once: nil after it is taken.
    func takeRecoveryNotice() -> String? {
        defer { recoveryNotice = nil }
        return recoveryNotice
    }

    /// Moves the file out of the way as `page-tabs.json.broken`, for a look, and frees the path.
    /// `false` when it could not be moved, in which case the path is still not the store's to write.
    private func setAside(_ cacheURL: URL) -> Bool {
        guard FileManager.default.setAsideBroken(cacheURL) else { return false }
        readFromDisk = true
        return true
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
    /// Whether any document is open in these contexts, or on a file under these worktrees: what
    /// `closeDocuments` would have to close, and could ask about.
    func hasDocuments(contextIDs: Set<String>, worktrees: [String]) -> Bool {
        contexts.values.contains { context in
            context.documents.contains { Self.affects($0, context: context, contextIDs: contextIDs, worktrees: worktrees) }
        }
    }

    private static func affects(_ document: EditorDocumentViewModel, context: WorkspaceContext,
                                contextIDs: Set<String>?, worktrees: [String]) -> Bool {
        if contextIDs == nil || contextIDs!.contains(context.id) { return true }
        let path = URL(fileURLWithPath: document.record.path).resolvingSymlinksInPath().path
        return worktrees.contains { root in
            let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    func closeDocuments(contextIDs: Set<String>? = nil, worktrees: [String] = []) async -> Bool {
        fileOpen.cancel()
        func affected(_ document: EditorDocumentViewModel, context: WorkspaceContext) -> Bool {
            Self.affects(document, context: context, contextIDs: contextIDs, worktrees: worktrees)
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
    private func workspace(id: String, url: String, title: String) -> WorkspaceContext {
        // An open context is already wired. Writing `contexts` or its observed properties again
        // would invalidate every view of the workspace on screen, on every sidebar switch.
        if let existing = contexts[id] { prepareContext(existing); return existing }
        let context = WorkspaceContext(id: id, sourceURL: url, title: title,
                                       snapshot: saved[id], pageFactory: pageFactory, documentFactory: documentFactory, closeCoordinator: closeCoordinator)
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
        context.activateDocument = { [weak self] in self?.configure($0) }
        context.documents.forEach(configure)
        return context
    }
    @discardableResult func restore(id: String, url: String, title: String) -> WorkspaceContext {
        workspace(id: id, url: url, title: title)
    }
    @discardableResult func select(id: String, url: String, title: String) -> WorkspaceContext {
        let context = workspace(id: id, url: url, title: title)
        activeContextID = id
        if let page = context.activePage { activate(page) }
        return context
    }
    func deactivate() { activeContextID = nil }
    func remove(id: String) async {
        if fileOpen.request?.contextID == id { fileOpen.cancel() }
        let context = contexts.removeValue(forKey: id)
        context?.workspaceViewModel?.setActive(false)
        if let context { contextRemoved(context) }
        context?.changed = {}
        context?.pages.forEach { $0.evict() }
        context?.documents.forEach { $0.dispose() }
        context?.retireWorktreeFiles()
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
        saved[context.id] = context.snapshot
        cache()
    }
    private func cache() {
        guard let cacheURL else { return }
        if !readFromDisk, FileManager.default.fileExists(atPath: cacheURL.path) {
            // Unread at startup (an I/O error), still here now: set aside, never written over.
            guard setAside(cacheURL) else {
                writeFailed(String(localized: "Could not save page tabs: the unread saved file could not be set aside."))
                return
            }
        }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(snapshots: saved, pending: [])).write(to: cacheURL, options: .atomic)
            readFromDisk = true
            lastError = nil
        } catch { writeFailed(String(localized: "Could not save page tabs: \(error.localizedDescription)")) }
    }
    /// Told to the context on screen at once, and kept for the app to show when none is.
    private func writeFailed(_ message: String) {
        lastError = message
        active?.error = message
    }
    func stop() async {
        fileOpenCoordinator.enabled = false
        api = nil
    }
}
