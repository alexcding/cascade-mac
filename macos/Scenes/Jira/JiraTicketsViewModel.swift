import Foundation
import Observation

@MainActor @Observable final class JiraTicketsViewModel {
    enum Action: Equatable { case open(String), session(String, agent: SessionAgent?) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let navigation: PageActionViewModel
    private(set) var retired = false
    private(set) var project: Project
    var query = ""
    private(set) var filterText = ""
    private(set) var filters: [String: String] = [:]
    private(set) var snapshot: JiraSnapshot?
    private(set) var searchResult: JiraSnapshot?
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
    @ObservationIgnored private var service: (any JiraService)?
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

    init(project: Project, service: any JiraService, pageActions: any PageActionServing, now: @escaping () -> Date = Date.init) {
        self.project = project; self.service = service; self.now = now
        navigation = PageActionViewModel(service: pageActions)
    }
    func update(_ project: Project) {
        guard !retired else { return }
        if self.project.jiraProjectKey != project.jiraProjectKey || self.project.jql != project.jql { cancelActions() }
        self.project = project
    }
    func invalidateSite() async {
        cancelActions()
        discoveryTask?.cancel(); await discoveryTask?.value
        baseURL = nil
    }
    func connect(_ service: any JiraService) { guard !retired else { return }; self.service = service; persistFilters() }
    var source: JiraSnapshot? { searchResult ?? snapshot }
    private(set) var items: [JiraTicket] = []
    private(set) var rows: [JiraTicket] = []
    private var facetOptions: [JiraFacet: [String]] = [:]
    private var facetCounts: [JiraFacet: [String: Int]] = [:]

    private func rebuildItems() {
        let items = (source?.items ?? []).map { ticket in
            var result = ticket
            if let move = pendingMoves[ticket.key] { result.status = move.status }
            return result
        }
        guard self.items != items else { return }
        self.items = items
        rebuildFilters()
    }

    /// Count every facet in one pass. Each facet ignores its own selection, but respects
    /// the text filter and all other selections. View updates then only read the results.
    private func rebuildFilters() {
        var rows: [JiraTicket] = []
        var counts: [JiraFacet: [String: Int]] = [:]
        for ticket in items {
            guard filterText.isEmpty || "\(ticket.key) \(ticket.summary ?? "") \(ticket.assignee ?? "")".localizedStandardContains(filterText) else { continue }
            let values = JiraFacet.allCases.map { (facet: $0, value: $0.value(ticket)) }
            let mismatches = values.filter {
                let selected = filters[$0.facet.rawValue] ?? ""
                return !selected.isEmpty && selected != $0.value
            }
            if mismatches.isEmpty { rows.append(ticket) }
            for (facet, value) in values where mismatches.isEmpty || (mismatches.count == 1 && mismatches[0].facet == facet) {
                counts[facet, default: [:]][value, default: 0] += 1
            }
        }
        var options: [JiraFacet: [String]] = [:]
        for facet in JiraFacet.allCases {
            var values = Set((counts[facet] ?? [:]).keys.filter { !$0.isEmpty })
            if let selected = filters[facet.rawValue], !selected.isEmpty { values.insert(selected) }
            options[facet] = values.sorted()
        }
        if self.rows != rows { self.rows = rows }
        if facetOptions != options { facetOptions = options }
        if facetCounts != counts { facetCounts = counts }
    }
    var emptyMessage: String {
        if !items.isEmpty { return "No tickets match these filters." }
        if searchResult != nil { return "No tickets match this search." }
        if (snapshot?.jql ?? project.jql ?? "").isEmpty && (project.jiraProjectKey ?? "").isEmpty {
            return "Set a Jira project key or JQL in this project's Settings."
        }
        return "No Jira tickets found."
    }
    func options(_ facet: JiraFacet) -> [String] { facetOptions[facet] ?? [] }
    func count(_ value: String, facet: JiraFacet) -> Int { facetCounts[facet]?[value] ?? 0 }
    func setFilterText(_ value: String) {
        guard !retired, filterText != value else { return }
        filterText = value
        rebuildFilters(); cancelActions()
    }
    func setFilter(_ facet: JiraFacet, _ value: String) {
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
        guard refreshTask == nil, let service else { return }
        loading = true
        refreshTask = Task {
            defer { refreshTask = nil; loading = false }
            while refreshPending && !Task.isCancelled {
                refreshPending = false
                do {
                    try await load(from: service)
                } catch { if !Task.isCancelled { snapshotError = error.localizedDescription } }
            }
        }
    }
    /// Await source data, then apply status overlays and set the stored display lists.
    private func load(from service: any JiraService, search: (query: String, generation: UUID)? = nil) async throws {
        let connection = connectionGeneration
        let result: JiraSnapshot
        if let search {
            result = try await service.search(jql: JiraQuery.make(search.query, projectKey: project.jiraProjectKey ?? ""))
        } else {
            result = try await service.snapshot(projectID: project.id)
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
    private func remember(_ result: JiraSnapshot) {
        statuses.formUnion(result.items.compactMap(\.status))
        let clock = now()
        pendingMoves = pendingMoves.filter { key, move in
            clock.timeIntervalSince(move.at) < 300 && !result.items.contains { $0.key == key && $0.status == move.status }
        }
    }
    private func discover() {
        guard discoveryTask == nil, let service else { return }
        let needsSite = baseURL == nil, needsSettings = !preferencesLoaded
        guard needsSite || needsSettings else { return }
        discoveryTask = Task {
            defer { discoveryTask = nil }
            // Independent from snapshot loading: account discovery cannot delay ticket rows.
            if needsSettings {
                do {
                    let settings = try await service.settings()
                    try Task.checkCancellation()
                    if filterRevision == 0 {
                        let saved = Self.parseFilters(settings["ticket_filter_" + project.id] ?? "")
                        if filters != saved { filters = saved; rebuildFilters() }
                    }
                    preferencesLoaded = true
                } catch { if !Task.isCancelled { preferenceError = error.localizedDescription } }
            }
            if needsSite {
                do {
                    let site = try await service.site()
                    try Task.checkCancellation()
                    baseURL = safeWebURL(site.baseUrl)
                    siteError = baseURL == nil ? "Configure the Jira site to open ticket links." : nil
                } catch { if !Task.isCancelled { siteError = error.localizedDescription } }
            }
        }
    }
    static func parseFilters(_ raw: String) -> [String: String] {
        if let values = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            return values.filter { key, value in JiraFacet.allCases.contains { $0.rawValue == key } && !value.isEmpty }
        }
        let legacy = raw.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacy.isEmpty ? [:] : ["project": legacy]
    }
    private func persistFilters() {
        guard preferenceTask == nil, preferencesDirty, let service else { return }
        preferenceTask = Task {
            defer { preferenceTask = nil }
            while preferencesDirty && !Task.isCancelled {
                let revision = filterRevision
                do {
                    let data = try JSONEncoder().encode(filters)
                    try await service.saveFilters(String(decoding: data, as: UTF8.self), projectID: project.id)
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
        guard let service else { error = "Connect to search Jira."; return }
        let generation = UUID(); searchGeneration = generation
        searching = true; error = nil
        defer { if searchGeneration == generation { searching = false } }
        do {
            try await load(from: service, search: (typed, generation))
        } catch { if searchGeneration == generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func clearSearch() {
        guard !retired else { return }
        cancelActions(); searchGeneration = UUID(); searching = false; query = ""; searchResult = nil; searchedQuery = nil; error = nil
        rebuildItems()
    }
    func nextStatuses(_ ticket: JiraTicket) -> [String] { statuses.filter { !$0.isEmpty && $0 != ticket.status }.sorted() }
    func transition(_ ticket: JiraTicket, to status: String) async {
        guard !busy.contains(ticket.key), let service, nextStatuses(ticket).contains(status) else { return }
        let connection = connectionGeneration
        busy.insert(ticket.key); error = nil
        defer { busy.remove(ticket.key) }
        do {
            try await service.transition(key: ticket.key, status: status)
            guard connection == connectionGeneration else { return }
            // Keep the successful move visible until a snapshot confirms it or the overlay expires.
            pendingMoves[ticket.key] = PendingMove(status: status, at: now())
            if let index = searchResult?.items.firstIndex(where: { $0.key == ticket.key }) {
                searchResult?.items[index].status = status
            }
            rebuildItems()
            refresh()
            syncAfterMutation()
        } catch { if connection == connectionGeneration { self.error = error.localizedDescription } }
    }
    private func syncAfterMutation() {
        syncPending = true
        guard syncTask == nil, let service else { return }
        syncTask = Task {
            defer { syncTask = nil }
            while syncPending && !Task.isCancelled {
                syncPending = false
                // Explicit successful mutation only; ordinary reads remain snapshot-backed.
                do { try await service.syncAfterMutation(projectID: project.id) }
                catch { if !Task.isCancelled { snapshotError = "Status saved; refresh failed: \(error.localizedDescription)" } }
                if !Task.isCancelled { refresh() }
            }
        }
    }
    func ticketURL(_ ticket: JiraTicket) -> URL? {
        guard ticket.key.range(of: #"^[A-Z][A-Z0-9_]*-\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return baseURL?.appendingPathComponent("browse").appendingPathComponent(ticket.key)
    }
    func open(_ ticket: JiraTicket) { if !retired { onAction(.open(ticket.key)) } }
    func openSession(_ ticket: JiraTicket, agent: SessionAgent? = nil) { if !retired { onAction(.session(ticket.key, agent: agent)) } }
    func perform(_ action: Action) {
        guard !retired, service != nil else { return }
        let key: String
        switch action { case .open(let value), .session(let value, _): key = value }
        guard let ticket = rows.first(where: { $0.key == key }) else { return }
        guard let url = ticketURL(ticket) else { siteError = "Configure the Jira site to open ticket links."; return }
        switch action {
        case .open, .session:
            var request = pageRequest(ticket, url: url)
            request.projectID = project.id
            if case .session(_, let agent) = action { request.inSession = true; request.agent = agent }
            navigation.open(request)
        }
    }
    func sessionMark(_ ticket: JiraTicket) -> PageSessionMark? {
        guard !retired, let url = ticketURL(ticket) else { return nil }
        var request = pageRequest(ticket, url: url)
        request.inSession = true; request.projectID = project.id
        return navigation.pageSession(request)
    }
    private func pageRequest(_ ticket: JiraTicket, url: URL) -> OpenPageRequest {
        OpenPageRequest(url: url.absoluteString, kind: "jira", title: "\(ticket.key) \(ticket.summary ?? "")")
    }
    func cancelActions() { navigation.cancel() }
    func retire() { retired = true; onAction = { _ in }; disconnect() }
    func retry() { error = nil; preferenceError = nil; siteError = nil; persistFilters(); refresh() }
    private func disconnect() {
        cancelActions(); service = nil; baseURL = nil
        connectionGeneration = UUID(); searchGeneration = UUID(); searching = false
        refreshTask?.cancel(); discoveryTask?.cancel(); preferenceTask?.cancel(); syncTask?.cancel()
    }
    func stop() async {
        disconnect()
        await refreshTask?.value; await discoveryTask?.value; await preferenceTask?.value; await syncTask?.value
    }
}
