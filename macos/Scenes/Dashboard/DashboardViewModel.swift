import Foundation
import Observation

/// The Dashboard screen. It owns the connection, the tabs, the global search and row opening, and
/// hands each data source to its own model: `prs` for GitHub, `tickets` for Jira and `usage` for
/// agent spend. Each child loads and derives its own data asynchronously; views read only what
/// they publish.
@MainActor @Observable final class DashboardViewModel {
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored var snapshotChanged: () -> Void = {}
    let navigation: PageActionViewModel
    let prs = DashboardPullRequestsModel()
    let tickets = DashboardTicketsModel()
    let usage = DashboardUsageModel()
    private(set) var retired = false

    var tab: Tab = .overview
    /// The number each overview tile last showed, so a tile only rolls from one value to the next
    /// and never from zero again when the overview comes back from My Tickets.
    var tileValues: [String: Double] = [:]
    /// The toolbar's search. It is global: while it holds text the dashboard shows every matching
    /// pull request and ticket in place of whichever page is up, and clearing it returns there.
    var query = "" { didSet { if query != oldValue { updateSearch() } } }
    private(set) var search = SearchResults()

    init(pageActions: any PageActionServing) {
        navigation = PageActionViewModel(service: pageActions, failureDescription: "Could not open pull request")
        prs.onChange = { [weak self] in self?.pullRequestsChanged() }
        tickets.onChange = { [weak self] in self?.updateSearch() }
    }

    // MARK: Loading

    func connect(_ service: any DashboardService) {
        guard !retired else { return }
        cancelActions()
        prs.connect(service)
        tickets.connect(service as? DashboardTicketService)
    }

    /// Everything the dashboard shows, side by side: the PR snapshot and Jira load independently.
    func reload() {
        guard !retired else { return }
        prs.refresh()
        tickets.refresh()
    }

    /// Both children cancel before the first suspension, so no load queued behind this call can
    /// publish afterwards; then wait for them to wind down.
    func stop() async {
        cancelActions()
        let pending = prs.halt() + [tickets.halt()].compactMap { $0 }
        for task in pending { await task.value }
    }

    func retire() {
        retired = true
        onAction = { _ in }
        snapshotChanged = {}
        cancelActions()
        prs.retire()
        tickets.retire()
        usage.retire()
    }

    private func pullRequestsChanged() {
        tickets.linkedPRs = prs.linkedPRs
        updateSearch()
        snapshotChanged()
        if let url = navigation.opening, !prs.visibleRows.contains(where: { $0.url.absoluteString == url }) { cancelActions() }
    }
}

// MARK: - Actions

extension DashboardViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: each action carries
    /// everything needed to act on it, and the coordinator never calls back into this model.
    enum Action: Equatable {
        /// A pull request or ticket page, already resolved to what to open and how.
        case open(OpenPageRequest)
        case showTickets
        case closeTickets
    }
}

// MARK: - Search

extension DashboardViewModel {
    /// Everything on the dashboard that matches the toolbar's search, whatever page is up.
    struct SearchResults: Equatable {
        var needle = ""
        var mine: [DashboardRow] = []
        var reviews: [DashboardRow] = []
        var tickets: [DashboardTicketRow] = []
        var count: Int { mine.count + reviews.count + tickets.count }
        var isEmpty: Bool { count == 0 }
        /// "3 results for “login”".
        var caption: String { "\(count) result\(count == 1 ? "" : "s") for “\(needle)”" }
    }

    var searching: Bool { !search.needle.isEmpty }

    func clearFilter() {
        guard !retired else { return }
        query = ""
    }

    private func updateSearch() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = SearchResults(needle: needle)
        if !needle.isEmpty {
            func matches(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(needle) }
            value.mine = prs.mine.filter { matches($0.searchText) }
            value.reviews = prs.reviews.filter { matches($0.searchText) }
            value.tickets = DashboardTicketsModel.stamp(tickets.rows.filter { matches($0.searchText) }, linked: prs.linkedPRs)
        }
        if search != value { search = value }
    }
}

// MARK: - Tabs

extension DashboardViewModel {
    /// The Dashboard's tabs. Overview, Pull Requests and Reviews swap the home screen's body;
    /// Tickets is My Tickets, pushed over it; any other tab, or Command-[, pops back.
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

    /// A tab pick is navigation, so it ends any search in progress.
    func selectTab(_ value: Tab) {
        guard !retired else { return }
        clearFilter()
        if value == .tickets { showTickets(); return }
        tab = value
        closeTickets()
        // Back on the overview with no tickets yet (Jira was slow or failed at connect): try again.
        if value == .overview, tickets.available, tickets.rows.isEmpty, !tickets.loading { tickets.refresh() }
    }

    func showTickets(_ filter: DashboardTicketsModel.Filter = .all) {
        guard !retired else { return }
        clearFilter()
        tickets.filter = filter
        onAction(.showTickets)
    }

    func closeTickets() {
        guard !retired else { return }
        onAction(.closeTickets)
    }
}

// MARK: - Opening rows

extension DashboardViewModel {
    /// Only a row the dashboard still shows opens, in its current form: a row kept by a view that
    /// has not redrawn since the snapshot dropped it resolves to nothing.
    func open(_ row: DashboardRow, inTab: Bool = false) {
        request(currentRow(row).map { Self.tabRequest($0.openPageRequest, inTab: inTab) })
    }
    func openSession(_ row: DashboardRow, agent: SessionAgent? = nil) {
        request(currentRow(row).map { Self.sessionRequest($0, agent: agent) })
    }
    func sessionMark(_ row: DashboardRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(Self.sessionRequest(row)) }

    func open(_ row: DashboardTicketRow, inTab: Bool = false) {
        request(currentTicket(row).map { Self.tabRequest($0.openPageRequest, inTab: inTab) })
    }
    func openSession(_ row: DashboardTicketRow, agent: SessionAgent? = nil) {
        request(currentTicket(row).map { Self.sessionRequest($0, agent: agent) })
    }
    func sessionMark(_ row: DashboardTicketRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(Self.sessionRequest(row)) }

    static func sessionRequest(_ row: DashboardRow, agent: SessionAgent? = nil) -> OpenPageRequest {
        var request = row.openPageRequest
        request.inSession = true
        request.projectID = row.projectID
        request.agent = agent
        return request
    }

    static func sessionRequest(_ row: DashboardTicketRow, agent: SessionAgent? = nil) -> OpenPageRequest {
        var request = row.openPageRequest
        request.inSession = true
        request.agent = agent
        return request
    }

    func cancelActions() { navigation.cancel() }

    private func currentRow(_ row: DashboardRow) -> DashboardRow? { prs.visibleRows.first { $0.id == row.id } }
    private func currentTicket(_ row: DashboardTicketRow) -> DashboardTicketRow? { tickets.rows.first { $0.id == row.id } }

    /// The one way out for an open: refused while disconnected, dropped for a row no longer shown,
    /// otherwise handed to the coordinator, which decides whether it may present and opens it.
    private func request(_ value: OpenPageRequest?) {
        guard !retired else { return }
        guard prs.connected else { navigation.reject("Connect to open pull requests in Craft."); return }
        guard let value else { return }
        onAction(.open(value))
    }

    private static func tabRequest(_ request: OpenPageRequest, inTab: Bool) -> OpenPageRequest {
        var request = request
        request.inTab = inTab
        return request
    }
}
