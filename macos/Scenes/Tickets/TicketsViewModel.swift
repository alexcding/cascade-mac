import Foundation
import Observation

/// One project's tickets from one source — Jira or GitHub issues. The list, search, filters and
/// status menu behave the same for both; what differs comes from `TicketSource` and the provider.
@MainActor @Observable final class TicketsViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: `open` already carries the
    /// resolved request, and the coordinator never calls back into this model to resolve one.
    enum Action: Equatable { case open(OpenPageRequest) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let navigation: PageActionViewModel
    let source: TicketSource
    private(set) var retired = false
    private(set) var project: Project
    var query = ""
    private(set) var filterText = ""
    private(set) var filters: [String: String] = [:]
    private(set) var snapshot: TicketSnapshot?
    private(set) var searchResult: TicketSnapshot?
    private(set) var searchedQuery: String?
    private(set) var loading = false
    private(set) var searching = false
    private(set) var busy: Set<String> = []
    private(set) var error: String?
    private(set) var snapshotError: String?
    private(set) var preferenceError: String?
    private(set) var siteError: String?
    private(set) var baseURL: URL?
    private var statuses: Set<String> = []
    private var pendingMoves: [String: PendingMove] = [:]
    private struct PendingMove { let status: String; let at: Date }
    @ObservationIgnored private var provider: (any TicketProvider)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncPending = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var preferencesDirty = false
    @ObservationIgnored private var filterRevision = 0
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private let now: () -> Date

    init(project: Project, provider: any TicketProvider, pageActions: any PageActionServing, now: @escaping () -> Date = Date.init) {
        self.project = project; self.provider = provider; self.source = provider.source; self.now = now
        navigation = PageActionViewModel(service: pageActions)
    }
    convenience init(project: Project, service: any JiraService, pageActions: any PageActionServing, now: @escaping () -> Date = Date.init) {
        self.init(project: project, provider: JiraTicketProvider(service: service), pageActions: pageActions, now: now)
    }
    func update(_ project: Project) {
        guard !retired else { return }
        if Self.query(of: self.project, source: source) != Self.query(of: project, source: source) { cancelActions() }
        self.project = project
    }
    /// What decides this source's tickets for a project; a change cancels actions on the old rows.
    private static func query(of project: Project, source: TicketSource) -> [String?] {
        switch source {
        case .jira: [project.jiraProjectKey, project.jql]
        case .github: [project.repo, project.issueQuery, project.issuesEnabled.map { "\($0)" }]
        }
    }
    func invalidateSite() async {
        cancelActions()
        discoveryTask?.cancel(); await discoveryTask?.value
        baseURL = nil
    }
    func connect(_ provider: any TicketProvider) {
        guard !retired, provider.source == source else { return }
        self.provider = provider; persistFilters()
    }
    func connect(_ service: any JiraService) { connect(JiraTicketProvider(service: service)) }
    func connect(_ service: any IssueService) { connect(IssueTicketProvider(service: service)) }
    var shown: TicketSnapshot? { searchResult ?? snapshot }
    private(set) var items: [Ticket] = []
    private(set) var rows: [Ticket] = []
    private var facetOptions: [TicketFacet: [String]] = [:]
    private var facetCounts: [TicketFacet: [String: Int]] = [:]

    private func rebuildItems() {
        let items = (shown?.items ?? []).map { ticket in
            var result = ticket
            if let move = pendingMoves[ticket.id] { result.status = move.status }
            return result
        }
        guard self.items != items else { return }
        self.items = items
        rebuildFilters()
    }

    /// Count every facet in one pass. Each facet ignores its own selection, but respects
    /// the text filter and all other selections. View updates then only read the results.
    private func rebuildFilters() {
        var rows: [Ticket] = []
        var counts: [TicketFacet: [String: Int]] = [:]
        for ticket in items {
            guard filterText.isEmpty || "\(ticket.key) \(ticket.summary ?? "") \(ticket.assignee ?? "")".localizedStandardContains(filterText) else { continue }
            let values = TicketFacet.allCases.map { (facet: $0, value: $0.value(ticket)) }
            let mismatches = values.filter {
                let selected = filters[$0.facet.rawValue] ?? ""
                return !selected.isEmpty && selected != $0.value
            }
            if mismatches.isEmpty { rows.append(ticket) }
            for (facet, value) in values where mismatches.isEmpty || (mismatches.count == 1 && mismatches[0].facet == facet) {
                counts[facet, default: [:]][value, default: 0] += 1
            }
        }
        var options: [TicketFacet: [String]] = [:]
        for facet in TicketFacet.allCases {
            var values = Set((counts[facet] ?? [:]).keys.filter { !$0.isEmpty })
            if let selected = filters[facet.rawValue], !selected.isEmpty { values.insert(selected) }
            options[facet] = values.sorted()
        }
        if self.rows != rows { self.rows = rows }
        if facetOptions != options { facetOptions = options }
        if facetCounts != counts { facetCounts = counts }
    }
    var emptyMessage: String {
        if !items.isEmpty { return String(localized: "No tickets match these filters.") }
        if searchResult != nil { return String(localized: "No tickets match this search.") }
        switch source {
        case .jira:
            if (snapshot?.jql ?? project.jql ?? "").isEmpty && (project.jiraProjectKey ?? "").isEmpty {
                return String(localized: "Set a Jira project key or JQL in this project's Settings.")
            }
            return String(localized: "No Jira tickets found.")
        case .github:
            if !project.hasIssues { return String(localized: "Set a GitHub repository and turn on issues in this project's Settings.") }
            return String(localized: "No GitHub issues found.")
        }
    }
    func options(_ facet: TicketFacet) -> [String] { facetOptions[facet] ?? [] }
    func count(_ value: String, facet: TicketFacet) -> Int { facetCounts[facet]?[value] ?? 0 }
    func setFilterText(_ value: String) {
        guard !retired, filterText != value else { return }
        filterText = value
        rebuildFilters(); cancelActions()
    }
    func setFilter(_ facet: TicketFacet, _ value: String) {
        guard !retired else { return }
        cancelActions()
        let selected = value.isEmpty ? nil : value
        if filters[facet.rawValue] != selected {
            filters[facet.rawValue] = selected
            rebuildFilters()
        }
        filterRevision += 1; preferencesDirty = true; persistFilters()
    }
    func refresh() {
        guard !retired else { return }
        discover()
        refreshPending = true
        guard refreshTask == nil, let provider else { return }
        loading = true
        refreshTask = Task {
            defer { refreshTask = nil; loading = false }
            while refreshPending && !Task.isCancelled {
                refreshPending = false
                do {
                    try await load(from: provider)
                } catch { if !Task.isCancelled { snapshotError = error.localizedDescription } }
            }
        }
    }
    /// Await source data, then apply status overlays and set the stored display lists.
    private func load(from provider: any TicketProvider, search: (query: String, generation: UUID)? = nil) async throws {
        let connection = connectionGeneration
        let result: TicketSnapshot
        if let search {
            result = try await provider.search(search.query, project: project)
        } else {
            result = try await provider.snapshot(projectID: project.id)
        }
        try Task.checkCancellation()
        guard !retired, connection == connectionGeneration else { return }
        if let search {
            guard searchGeneration == search.generation, query.trimmingCharacters(in: .whitespacesAndNewlines) == search.query else { return }
            searchResult = result; searchedQuery = search.query
        } else {
            snapshot = result; snapshotError = nil
        }
        remember(result)
        rebuildItems()
    }
    private func remember(_ result: TicketSnapshot) {
        statuses.formUnion(result.items.compactMap(\.status))
        let clock = now()
        pendingMoves = pendingMoves.filter { id, move in
            clock.timeIntervalSince(move.at) < 300 && !result.items.contains { $0.id == id && $0.status == move.status }
        }
    }
    private func discover() {
        guard discoveryTask == nil, let provider else { return }
        // Only Jira keys need a site to open on; an issue carries its own URL.
        let needsSite = source == .jira && baseURL == nil, needsSettings = !preferencesLoaded
        guard needsSite || needsSettings else { return }
        discoveryTask = Task {
            defer { discoveryTask = nil }
            // Independent from snapshot loading: account discovery cannot delay ticket rows.
            if needsSettings {
                do {
                    let settings = try await provider.settings()
                    try Task.checkCancellation()
                    if filterRevision == 0 {
                        let saved = Self.parseFilters(settings[source.filterSetting + project.id] ?? "")
                        if filters != saved { filters = saved; rebuildFilters() }
                    }
                    preferencesLoaded = true
                } catch { if !Task.isCancelled { preferenceError = error.localizedDescription } }
            }
            if needsSite {
                do {
                    let site = try await provider.siteURL()
                    try Task.checkCancellation()
                    baseURL = site
                    siteError = baseURL == nil ? String(localized: "Configure the Jira site to open ticket links.") : nil
                } catch { if !Task.isCancelled { siteError = error.localizedDescription } }
            }
        }
    }
    static func parseFilters(_ raw: String) -> [String: String] {
        if let values = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            return values.filter { key, value in TicketFacet.allCases.contains { $0.rawValue == key } && !value.isEmpty }
        }
        let legacy = raw.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacy.isEmpty ? [:] : ["project": legacy]
    }
    private func persistFilters() {
        guard preferenceTask == nil, preferencesDirty, let provider else { return }
        preferenceTask = Task {
            defer { preferenceTask = nil }
            while preferencesDirty && !Task.isCancelled {
                let revision = filterRevision
                do {
                    let data = try JSONEncoder().encode(filters)
                    try await provider.saveFilters(String(decoding: data, as: UTF8.self), projectID: project.id)
                    try Task.checkCancellation()
                    if revision == filterRevision { preferencesDirty = false }
                    preferenceError = nil
                } catch { if !Task.isCancelled { preferenceError = error.localizedDescription }; break }
            }
        }
    }
    func search() async {
        guard !retired else { return }
        cancelActions()
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { clearSearch(); return }
        guard let provider else { error = String(localized: "Connect to search \(source.label)."); return }
        let generation = UUID(); searchGeneration = generation
        searching = true; error = nil
        defer { if searchGeneration == generation { searching = false } }
        do {
            try await load(from: provider, search: (typed, generation))
        } catch { if searchGeneration == generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func clearSearch() {
        guard !retired else { return }
        cancelActions(); searchGeneration = UUID(); searching = false; query = ""; searchResult = nil; searchedQuery = nil; error = nil
        rebuildItems()
    }
    func nextStatuses(_ ticket: Ticket) -> [String] { source.nextStatuses(ticket, seen: statuses) }
    func transition(_ ticket: Ticket, to status: String) async {
        guard !busy.contains(ticket.id), let provider, nextStatuses(ticket).contains(status) else { return }
        let connection = connectionGeneration
        busy.insert(ticket.id); error = nil
        defer { busy.remove(ticket.id) }
        do {
            try await provider.move(ticket, to: status)
            guard connection == connectionGeneration else { return }
            // Keep the successful move visible until a snapshot confirms it or the overlay expires.
            pendingMoves[ticket.id] = PendingMove(status: status, at: now())
            if let index = searchResult?.items.firstIndex(where: { $0.id == ticket.id }) {
                searchResult?.items[index].status = status
            }
            rebuildItems()
            refresh()
            syncAfterMutation()
        } catch { if connection == connectionGeneration { self.error = error.localizedDescription } }
    }
    private func syncAfterMutation() {
        syncPending = true
        guard syncTask == nil, let provider else { return }
        syncTask = Task {
            defer { syncTask = nil }
            while syncPending && !Task.isCancelled {
                syncPending = false
                // Explicit successful mutation only; ordinary reads remain snapshot-backed.
                do { try await provider.syncAfterMutation(projectID: project.id) }
                catch { if !Task.isCancelled { snapshotError = String(localized: "Status saved; refresh failed: \(error.localizedDescription)") } }
                if !Task.isCancelled { refresh() }
            }
        }
    }
    func ticketURL(_ ticket: Ticket) -> URL? { source.pageURL(ticket, site: baseURL) }
    func open(_ ticket: Ticket, inTab: Bool = false) { emit(ticket) { $0.inTab = inTab } }
    func openSession(_ ticket: Ticket, agent: SessionAgent? = nil) { emit(ticket) { $0.inSession = true; $0.agent = agent } }
    /// Only a ticket this page still shows opens, resolved against its current row: a stale key
    /// emits nothing, and a missing site sets `siteError` rather than opening nothing silently.
    private func emit(_ ticket: Ticket, configure: (inout OpenPageRequest) -> Void) {
        guard !retired, provider != nil else { return }
        guard let current = rows.first(where: { $0.id == ticket.id }) else { return }
        guard let url = ticketURL(current) else {
            if source == .jira { siteError = String(localized: "Configure the Jira site to open ticket links.") }
            return
        }
        var request = pageRequest(current, url: url)
        request.projectID = project.id
        configure(&request)
        onAction(.open(request))
    }
    func sessionMark(_ ticket: Ticket) -> PageSessionMark? {
        guard !retired, let url = ticketURL(ticket) else { return nil }
        var request = pageRequest(ticket, url: url)
        request.inSession = true; request.projectID = project.id
        return navigation.pageSession(request)
    }
    private func pageRequest(_ ticket: Ticket, url: URL) -> OpenPageRequest {
        var request = OpenPageRequest(url: url.absoluteString, kind: source.pageKind, title: "\(ticket.key) \(ticket.summary ?? "")")
        request.repo = ticket.repo ?? ""
        return request
    }
    func cancelActions() { navigation.cancel() }
    func retire() { retired = true; onAction = { _ in }; disconnect() }
    func retry() { error = nil; preferenceError = nil; siteError = nil; persistFilters(); refresh() }
    private func disconnect() {
        cancelActions(); provider = nil; baseURL = nil
        connectionGeneration = UUID(); searchGeneration = UUID(); searching = false
        refreshTask?.cancel(); discoveryTask?.cancel(); preferenceTask?.cancel(); syncTask?.cancel()
    }
    func stop() async {
        disconnect()
        await refreshTask?.value; await discoveryTask?.value; await preferenceTask?.value; await syncTask?.value
    }
}
