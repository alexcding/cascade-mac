import Foundation
import Observation

@MainActor @Observable final class GitHistoryViewModel {
    var presentation = DocumentPresentation() {
        didSet {
            guard oldValue != presentation else { return }
            if oldValue.active != presentation.active {
                if presentation.active { show() } else { hide() }
            }
            patch?.presentation = presentation
        }
    }
    let worktree: String
    var search = "" {
        didSet {
            guard oldValue != search else { return }
            if let selectedSHA, !rows.contains(where: { $0.sha == selectedSHA }) { select(rows.first?.sha) }
        }
    }
    private(set) var findRequest = UUID()
    func find() { findRequest = UUID() }
    private(set) var commits: [GitCommit] = []
    private(set) var selectedSHA: String?
    private(set) var detail: GitCommitDetail?
    private(set) var patch: DiffViewModel? {
        didSet { patch?.presentation = presentation }
    }
    private(set) var page: GitHistoryPage?
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var loadingDetail = false
    private(set) var error: String?
    private(set) var detailError: String?
    private(set) var hasMore = false
    @ObservationIgnored private var service: any GitHistoryService
    @ObservationIgnored private var baseURL: URL
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var active = false
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var detailGeneration = UUID()
    @ObservationIgnored private var nextOffset = 0
    /// Where the next older page starts, once this branch's own commits are all loaded: a first
    /// load lists only what the branch added on its base, and asking for more carries on into the
    /// history it grew from. Nil while the branch's commits are still coming.
    @ObservationIgnored private var olderOffset: Int?
    /// The revision each part of the list was loaded at, which a later page of that part must match.
    @ObservationIgnored private var branchRevision: String?
    @ObservationIgnored private var olderRevision: String?
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let copy: (String) -> Void
    @ObservationIgnored private let factory: any DocumentFeatureFactory

    init(worktree: String, baseURL: URL, base: String = "", service: any GitHistoryService,
         pageSize: Int = 200, factory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(), copy: @escaping (String) -> Void = { _ in }) {
        self.worktree = worktree; self.baseURL = baseURL; self.base = base
        self.service = service; self.pageSize = pageSize; self.copy = copy
        self.factory = factory
    }
    var rows: [GitCommit] { commits.filter { search.isEmpty || $0.searchText.localizedStandardContains(search) } }
    var contextLabel: String {
        if let base = page?.base, !base.isEmpty, olderRevision == nil { return String(localized: "Commits ahead of \(base)") }
        return page?.branch.map { String(localized: "History of \($0)") } ?? String(localized: "Commit history")
    }
    var emptyLabel: String {
        if !search.isEmpty { return String(localized: "No loaded commits match this search.") }
        if let base = page?.base, !base.isEmpty { return String(localized: "No commits ahead of \(base).") }
        return String(localized: "No commits on this branch yet.")
    }
    func connect(baseURL: URL, service: any GitHistoryService) {
        hide(); self.baseURL = baseURL; self.service = service
        if presentation.active { show() }
    }
    func updateBase(_ value: String) {
        guard value != base else { return }
        base = value
        if active { refresh() }
    }
    func show() { active = true; reload(preserveLoadedPages: true) }
    func refresh() { reload(preserveLoadedPages: false) }
    private func reload(preserveLoadedPages: Bool) {
        listTask?.cancel(); generation = UUID(); loadingMore = false; loading = false
        loadPage(reset: true, preserveLoadedPages: preserveLoadedPages)
    }
    func loadMore() { guard hasMore, !loading, !loadingMore else { return }; loadPage(reset: false) }
    private func loadPage(reset: Bool, preserveLoadedPages: Bool = false) {
        guard active else { return }
        let generation = generation
        let older = reset ? nil : olderOffset
        let query = older == nil ? GitHistoryQuery(aheadOnly: true, base: base) : GitHistoryQuery(aheadOnly: false)
        let offset = reset ? 0 : older ?? nextOffset
        if reset { loading = true } else { loadingMore = true }
        error = nil
        listTask = Task {
            defer {
                if self.generation == generation { loading = false; loadingMore = false; listTask = nil }
            }
            do {
                var value = try await service.log(worktree: worktree, query: query, skip: offset, limit: pageSize)
                try Task.checkCancellation()
                guard self.generation == generation, active else { return }
                // The first older page begins a new list, with nothing loaded yet to compare against.
                if !reset, offset > 0 {
                    guard let revision = older == nil ? branchRevision : olderRevision, revision == value.historyRevision else {
                        hasMore = false
                        throw BackendError.operation(String(localized: "History changed while loading older commits. Refresh history to continue."))
                    }
                }
                var seen = Set(reset ? [] : commits.map(\.sha))
                // The older list repeats the branch's own commits, which are already here: a page of
                // nothing else is passed over rather than shown as a click that added nothing.
                var skipped = 0
                let revision = value.historyRevision
                while older != nil, value.commits.count == pageSize, value.commits.allSatisfy({ seen.contains($0.sha) }) {
                    skipped += value.commits.count
                    value = try await service.log(worktree: worktree, query: query, skip: offset + skipped, limit: pageSize)
                    try Task.checkCancellation()
                    guard self.generation == generation, active else { return }
                    // Each page passed over must be of the same list as the first.
                    guard value.historyRevision == revision else {
                        hasMore = false
                        throw BackendError.operation(String(localized: "History changed while loading older commits. Refresh history to continue."))
                    }
                }
                let added = value.commits.filter { seen.insert($0.sha).inserted }
                // Showing again keeps what was loaded, older commits included, while the branch is unchanged.
                if reset, preserveLoadedPages, value.historyRevision != nil, value.historyRevision == branchRevision,
                   nextOffset > value.commits.count || olderRevision != nil {
                    let firstIDs = Set(added.map(\.sha))
                    commits = added + commits.filter { !firstIDs.contains($0.sha) }
                } else if let older {
                    commits += added
                    olderOffset = older + skipped + value.commits.count
                    olderRevision = value.historyRevision
                    hasMore = value.commits.count == pageSize
                } else {
                    commits = reset ? added : commits + added
                    nextOffset = offset + value.commits.count
                    branchRevision = value.historyRevision
                    if reset { olderRevision = nil }
                    let full = value.commits.count == pageSize
                    if value.base?.isEmpty == false, !full {
                        // The branch's commits are all here; older history comes next, if there is any.
                        let older = value.older != false
                        olderOffset = older ? 0 : nil; hasMore = older
                    } else {
                        olderOffset = nil; hasMore = full && !added.isEmpty
                    }
                }
                page = value
                if let selectedSHA, rows.contains(where: { $0.sha == selectedSHA }) {
                    if patch == nil { select(selectedSHA) }
                } else { select(rows.first?.sha) }
            } catch {
                if self.generation == generation, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    /// The commit on screen stays there until the next one has loaded, and its diff page is reused
    /// rather than rebuilt: tearing both down per selection made the whole pane blink.
    func select(_ sha: String?) {
        guard let sha, commits.contains(where: { $0.sha == sha }) else { clearDetail(); return }
        detailTask?.cancel(); detailTask = nil; detailGeneration = UUID(); detailError = nil
        selectedSHA = sha; loadingDetail = true
        let generation = detailGeneration
        detailTask = Task {
            defer { if detailGeneration == generation { loadingDetail = false; detailTask = nil } }
            do {
                let value = try await service.detail(worktree: worktree, sha: sha)
                try Task.checkCancellation()
                guard detailGeneration == generation, selectedSHA == sha, active else { return }
                detail = value
                if let patch { patch.connect(baseURL: baseURL, service: HistoricalPatchService(diff: value.diff)) }
                else { patch = factory.patch(worktree: worktree, baseURL: baseURL, diff: value.diff) }
            } catch { if detailGeneration == generation, !Task.isCancelled { detailError = error.localizedDescription } }
        }
    }
    func retryDetail() { select(selectedSHA) }
    func copySHA() { if let selectedSHA { copy(selectedSHA) } }
    private func clearDetail() {
        detailTask?.cancel(); detailTask = nil; detailGeneration = UUID()
        patch?.disconnect(); patch = nil; detail = nil; detailError = nil; loadingDetail = false; selectedSHA = nil
    }
    func hide() {
        active = false; listTask?.cancel(); listTask = nil; generation = UUID(); loading = false; loadingMore = false
        let selection = selectedSHA
        clearDetail(); selectedSHA = selection
    }
    func waitForList() async { await listTask?.value }
    func waitForDetail() async { await detailTask?.value }
}
