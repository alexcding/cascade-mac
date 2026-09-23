import Foundation
import Observation

@MainActor @Observable final class DashboardViewModel {
    enum Action: Equatable { case open(String, inTab: Bool), session(String, agent: SessionAgent?), openTicket(String, inTab: Bool), ticketSession(String, agent: SessionAgent?), showTickets, closeTickets }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let navigation: PageActionViewModel
    private(set) var retired = false
    private(set) var projects: [DashboardProject] = []
    @ObservationIgnored var snapshotChanged: () -> Void = {}
    private(set) var loading = false
    /// A forced GitHub sync, apart from `loading`: a snapshot read finishing mid-sync must not
    /// re-enable the refresh button while the sync still runs.
    private(set) var syncing = false
    private(set) var updated: Date?
    private(set) var error: String?
    @ObservationIgnored private var service: (any DashboardService)? {
        didSet {
            let available = service is DashboardTicketService
            if ticketsAvailable != available { ticketsAvailable = available }
        }
    }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var connectionGeneration = UUID()

    init(pageActions: any PageActionServing) {
        navigation = PageActionViewModel(service: pageActions, failureDescription: "Could not open pull request")
    }

    func connect(_ service: any DashboardService) {
        guard !retired else { return }
        cancelRefresh(); cancelActions(); self.service = service; refresh(); refreshTickets()
    }

    private(set) var rows: [DashboardRow] = []
    private(set) var visibleRows: [DashboardRow] = []
    private(set) var mine: [DashboardRow] = []
    private(set) var reviews: [DashboardRow] = []
    private(set) var warnings: [String] = []
    /// The Jira section. `ticketsAvailable` is false until the service offers tickets at all.
    private(set) var tickets: [DashboardTicketRow] = []
    private(set) var ticketsError: String?
    private(set) var ticketsLoading = false
    /// Mirrors the service, which is not observed, so the toolbar's Tickets tab appears the moment a
    /// Jira-capable service connects and goes when it is dropped.
    private(set) var ticketsAvailable = false
    @ObservationIgnored private var ticketTask: Task<Void, Never>?

    var query = ""
    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filtering: Bool { !needle.isEmpty }

    private func searchMatches(_ row: DashboardRow) -> Bool {
        needle.isEmpty || row.searchText.localizedCaseInsensitiveContains(needle)
    }
    private func searchMatches(_ row: DashboardTicketRow) -> Bool {
        let needle = needle
        return needle.isEmpty || row.ticket.key.localizedCaseInsensitiveContains(needle)
            || row.title.localizedCaseInsensitiveContains(needle)
    }

    var visibleMine: [DashboardRow] { mine.filter(searchMatches) }
    var visibleReviews: [DashboardRow] { reviews.filter(searchMatches) }
    var visibleTickets: [DashboardTicketRow] { tickets.filter(searchMatches) }
    func clearFilter() { guard !retired else { return }; query = "" }

    /// The My Tickets screen's tags: every ticket, one workflow stage, or the urgent ones.
    enum TicketFilter: Hashable, Identifiable {
        case all, stage(TicketStage), urgent
        static let allCases: [TicketFilter] = [.all] + TicketStage.allCases.map(TicketFilter.stage) + [.urgent]
        var id: String {
            switch self {
            case .all: return "all"
            case .stage(let stage): return stage.rawValue
            case .urgent: return "urgent"
            }
        }
        var title: String {
            switch self {
            case .all: return "All"
            case .stage(let stage): return stage.title
            case .urgent: return "Urgent"
            }
        }
        func matches(_ row: DashboardTicketRow) -> Bool {
            switch self {
            case .all: return true
            case .stage(let stage): return row.stage == stage
            case .urgent: return row.urgent
            }
        }
    }
    var ticketFilter: TicketFilter = .all

    /// The Dashboard's tabs. Overview, Pull Requests and Reviews swap the home screen's body;
    /// Tickets is My Tickets, pushed over it, with its own search; any other tab, or Command-[,
    /// pops back.
    enum Tab: String, CaseIterable, Identifiable {
        case overview, pullRequests, reviews, tickets
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .pullRequests: return "Pull Requests"
            case .reviews: return "Reviews"
            case .tickets: return "Tickets"
            }
        }
    }
    var tab: Tab = .overview
    func selectTab(_ value: Tab) {
        guard !retired else { return }
        if value == .tickets { showTickets(); return }
        tab = value
        closeTickets()
        // Back on the overview with no tickets yet (Jira was slow or failed at connect): try again.
        if value == .overview, ticketsAvailable, tickets.isEmpty, !ticketsLoading { refreshTickets() }
    }

    /// The Pull Requests tab's tags, each a check state or review state of the user's own.
    enum PRFilter: String, CaseIterable, Identifiable {
        case all, failing, running, changesRequested, approved, drafts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .failing: return "Failing"
            case .running: return "Running"
            case .changesRequested: return "Changes requested"
            case .approved: return "Approved"
            case .drafts: return "Drafts"
            }
        }
        func matches(_ row: DashboardRow) -> Bool {
            switch self {
            case .all: return true
            case .failing: return row.checks == .failing
            case .running: return row.checks == .running
            case .changesRequested: return row.pr.reviewDecision == "CHANGES_REQUESTED"
            case .approved: return row.pr.reviewDecision == "APPROVED"
            case .drafts: return row.pr.isDraft == true
            }
        }
    }
    var prFilter: PRFilter = .all
    /// The My Tickets screen's rows from the searched tickets: the tag, then urgent first, each
    /// half in Jira's own order.
    func screenTickets(from rows: [DashboardTicketRow]) -> [DashboardTicketRow] {
        let tagged = rows.filter(ticketFilter.matches)
        return tagged.filter(\.urgent) + tagged.filter { !$0.urgent }
    }
    /// The home screen's short list, in `attentionRank` order and each group in Jira's own order.
    /// A ticket being worked on is left out once one of the listed pull requests names it: the
    /// pull request's row already stands for that work. Nothing else is padded in.
    func attentionTickets(from rows: [DashboardTicketRow], limit: Int) -> [DashboardTicketRow] {
        let linked = linkedPRs
        let ranked = rows.enumerated().compactMap { offset, row -> (rank: Int, offset: Int, row: DashboardTicketRow)? in
            guard let rank = row.attentionRank, !(rank == 2 && linked[row.ticket.key] != nil) else { return nil }
            return (rank, offset, row)
        }
        return Array(ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.prefix(limit).map(\.row))
    }
    /// Each My Tickets tag's count over the searched tickets, in one pass.
    func ticketCounts(of rows: [DashboardTicketRow]) -> [DashboardViewModel.TicketFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: TicketFilter.allCases.map { ($0, 0) })
        for row in rows {
            counts[.all, default: 0] += 1
            counts[.stage(row.stage), default: 0] += 1
            if row.urgent { counts[.urgent, default: 0] += 1 }
        }
        return counts
    }
    func showTickets(_ filter: TicketFilter = .all) {
        guard !retired else { return }
        ticketFilter = filter
        onAction(.showTickets)
    }
    func closeTickets() { if !retired { onAction(.closeTickets) } }

    /// Every Jira key a shown pull request references, against that pull request's number. My
    /// Tickets' Pull Request column reads it, and the home list uses it to skip tickets whose pull
    /// request is already shown; the lowest number wins when two PRs name one
    /// ticket, so the column does not flip between them as the snapshot reorders.
    var linkedPRs: [String: String] {
        var value: [String: Int] = [:]
        for row in visibleRows {
            guard let number = row.pr.number else { continue }
            for key in row.pr.jiraKeys ?? [] where number < value[key] ?? .max { value[key] = number }
        }
        return value.mapValues { "#\($0)" }
    }

    /// Load the snapshot and its display lists together before notifying the coordinator.
    private func load(from service: any DashboardService, generation: UUID) async throws {
        let projects = try await service.snapshot()
        try Task.checkCancellation()
        guard !retired, connectionGeneration == generation else { return }
        defer { updated = Date(); error = nil }
        guard self.projects != projects else { return }
        self.projects = projects
        var seen: Set<String> = []
        let rows = projects.flatMap { project in
            project.prs.compactMap { pr -> DashboardRow? in
                guard pr.error == nil, pr.state == "OPEN", let address = pr.url, let url = safeWebURL(address) else { return nil }
                let row = DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
                guard seen.insert(row.id).inserted else { return nil }
                return row
            }
        }
        let visibleRows = rows.filter { $0.isMine || $0.inReviewGroup }
        let mine = visibleRows.filter(\.isMine)
        let reviews = visibleRows.filter { !$0.isMine && $0.inReviewGroup }
        let warnings = projects.flatMap { project -> [String] in
            var messages = project.prs.compactMap { $0.error.map { "\(project.name): \($0)" } }
            if let error = project.syncError { messages.insert("\(project.name): \(error)", at: 0) }
            if project.lastSynced == nil { messages.append("\(project.name): waiting for the first sync.") }
            return messages
        }
        if self.rows != rows { self.rows = rows }
        if self.visibleRows != visibleRows { self.visibleRows = visibleRows }
        if self.mine != mine { self.mine = mine }
        if self.reviews != reviews { self.reviews = reviews }
        if self.warnings != warnings { self.warnings = warnings }
        snapshotChanged()
        if let url = navigation.opening, !visibleRows.contains(where: { $0.url.absoluteString == url }) { cancelActions() }
    }

    func refresh() {
        guard !retired, let service else { return }
        refreshPending = true
        guard refreshTask == nil else { return }
        let generation = connectionGeneration
        loading = true
        refreshTask = Task {
            defer { if connectionGeneration == generation { refreshTask = nil; loading = false } }
            while refreshPending && !Task.isCancelled && connectionGeneration == generation {
                refreshPending = false
                do {
                    try await load(from: service, generation: generation)
                } catch { if !Task.isCancelled && connectionGeneration == generation { self.error = error.localizedDescription } }
            }
        }
    }

    func syncPRs() {
        guard !retired, let service, syncTask == nil else { return }
        let generation = connectionGeneration
        syncing = true
        syncTask = Task {
            defer { if connectionGeneration == generation { syncTask = nil; syncing = false } }
            do {
                try await service.syncPRs()
                try Task.checkCancellation()
                guard !retired, connectionGeneration == generation else { return }
                try await load(from: service, generation: generation)
            } catch {
                if !Task.isCancelled && connectionGeneration == generation { self.error = error.localizedDescription }
            }
        }
    }

    /// Tickets load apart from the PR snapshot: a GitHub sync must not re-query Jira, and Jira
    /// can be slow or unconfigured without holding the PR sections back.
    func refreshTickets() {
        guard !retired, let service = service as? DashboardTicketService, ticketTask == nil else { return }
        let generation = connectionGeneration
        ticketsLoading = true
        ticketTask = Task {
            defer { if connectionGeneration == generation { ticketTask = nil; ticketsLoading = false } }
            do {
                let tickets = try await service.myTickets()
                try Task.checkCancellation()
                guard !retired, connectionGeneration == generation else { return }
                if self.tickets != tickets { self.tickets = tickets }
                ticketsError = nil
            } catch {
                if !Task.isCancelled && connectionGeneration == generation { ticketsError = error.localizedDescription }
            }
        }
    }

    func open(_ row: DashboardTicketRow, inTab: Bool = false) { if !retired { onAction(.openTicket(row.id, inTab: inTab)) } }
    func openSession(_ row: DashboardTicketRow, agent: SessionAgent? = nil) { if !retired { onAction(.ticketSession(row.id, agent: agent)) } }
    func sessionMark(_ row: DashboardTicketRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(Self.sessionRequest(row)) }
    static func sessionRequest(_ row: DashboardTicketRow, agent: SessionAgent? = nil) -> OpenPageRequest {
        var request = row.openPageRequest
        request.inSession = true; request.agent = agent
        return request
    }

    func open(_ row: DashboardRow, inTab: Bool = false) { if !retired { onAction(.open(row.id, inTab: inTab)) } }
    func openSession(_ row: DashboardRow, agent: SessionAgent? = nil) { if !retired { onAction(.session(row.id, agent: agent)) } }
    func sessionMark(_ row: DashboardRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(Self.sessionRequest(row)) }
    static func sessionRequest(_ row: DashboardRow, agent: SessionAgent? = nil) -> OpenPageRequest {
        var request = row.openPageRequest
        request.inSession = true; request.projectID = row.projectID; request.agent = agent
        return request
    }
    static func tabRequest(_ request: OpenPageRequest, inTab: Bool) -> OpenPageRequest {
        var request = request; request.inTab = inTab; return request
    }
    func perform(_ action: Action) {
        guard !retired else { return }
        guard service != nil else { navigation.reject("Connect to open pull requests in Craft."); return }
        switch action {
        case .open(let id, let inTab):
            if let row = visibleRows.first(where: { $0.id == id }) { navigation.open(Self.tabRequest(row.openPageRequest, inTab: inTab)) }
        case .session(let id, let agent):
            if let row = visibleRows.first(where: { $0.id == id }) { navigation.open(Self.sessionRequest(row, agent: agent)) }
        case .openTicket(let id, let inTab):
            if let row = tickets.first(where: { $0.id == id }) { navigation.open(Self.tabRequest(row.openPageRequest, inTab: inTab)) }
        case .ticketSession(let id, let agent):
            if let row = tickets.first(where: { $0.id == id }) { navigation.open(Self.sessionRequest(row, agent: agent)) }
        case .showTickets, .closeTickets:
            break
        }
    }
    func cancelActions() { navigation.cancel() }
    private func cancelRefresh() {
        connectionGeneration = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshPending = false; loading = false
        syncTask?.cancel(); syncTask = nil; syncing = false
        ticketTask?.cancel(); ticketTask = nil; ticketsLoading = false
    }
    func retire() {
        retired = true; onAction = { _ in }; snapshotChanged = {}; service = nil
        cancelActions(); cancelRefresh()
    }
    func stop() async {
        let pending = refreshTask, pendingTickets = ticketTask, pendingSync = syncTask
        cancelActions(); cancelRefresh(); service = nil
        await pending?.value; await pendingTickets?.value; await pendingSync?.value
    }
}
