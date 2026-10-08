import Foundation
import Observation

/// The Projects screen. It owns the connection, the tabs and row opening, and
/// hands each data source to its own model: `prs` for GitHub and `tickets` for Jira and GitHub
/// issues. Each child loads and derives its own data asynchronously; views read only what
/// they publish.
@MainActor @Observable final class DashboardViewModel {
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored var snapshotChanged: () -> Void = {}
    let navigation: PageActionViewModel
    let prs = DashboardPullRequestsModel()
    let tickets = DashboardTicketsModel()
    private(set) var retired = false

    /// The page the tab bar shows, changed through `selectTab`, or back to Overview when the last
    /// board goes; a retired model keeps it.
    private(set) var tab: Tab = .overview { didSet { if oldValue != tab { updateBoard() } } }
    /// The projects with their Jira board turned on, from the app: the Board tab's.
    var boardProjectIDs: Set<String> = [] {
        didSet {
            guard boardProjectIDs != oldValue, !retired else { return }
            if tab == .board, boardProjectIDs.isEmpty { tab = .overview }
            updateBoardModel()
        }
    }
    /// The picked project's sprint board, while it has one and a backend is connected.
    private(set) var board: WebBoardViewModel?
    /// Whether Projects is the screen on show: the board loads and follows Jira only then.
    var onScreen = false { didSet { if oldValue != onScreen { updateBoard(); updateLanes() } } }
    var appearance = AppAppearance.system { didSet { if oldValue != appearance { updateBoard() } } }
    @ObservationIgnored private let pageActions: any PageActionServing
    @ObservationIgnored private var boardService: (any BoardService)?
    /// Every session and its agent's state, from the app as its terminals change: Overview's lanes.
    /// Kept while Projects is off screen, laid out again only when it is on.
    var sessions: [DashboardSession] = [] { didSet { if sessions != oldValue, onScreen { updateLanes() } } }
    /// Every chat session, from the app's chat list: listed in its project's lane.
    var chats: [DashboardChat] = [] { didSet { if chats != oldValue, onScreen { updateLanes() } } }
    /// Each project's numbers for Overview, worked out when the pull requests, tickets or session
    /// counts change rather than on every redraw.
    private(set) var projectSummaries: [DashboardProjectSummary] = []
    /// Each project with its sessions, matched to their pull requests, worked out with the summaries.
    private(set) var sessionLanes: [DashboardSessionLane] = []

    init(pageActions: any PageActionServing) {
        self.pageActions = pageActions
        navigation = PageActionViewModel(service: pageActions, failureDescription: String(localized: "Could not open pull request"))
        prs.onChange = { [weak self] in self?.pullRequestsChanged() }
        tickets.onChange = { [weak self] in self?.updateSummaries() }
    }

    // MARK: Loading

    func connect(_ service: any DashboardService) {
        guard !retired else { return }
        cancelActions()
        prs.connect(service)
        tickets.connect(service as? DashboardTicketService)
    }

    /// Everything the dashboard shows, side by side: the PR snapshot and Jira load independently.
    /// `look`: someone is looking at the dashboard (the default), so the backend may sync
    /// behind the read.
    func reload(look: Bool = true) {
        guard !retired else { return }
        prs.refresh(look: look)
        prs.refreshUnreachable()
        tickets.refresh(look ? .look : .echo)
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
        board?.retire(); board = nil
    }

    private func updateSummaries() {
        guard !retired else { return }
        let value = makeProjectSummaries()
        if projectSummaries != value { projectSummaries = value }
        updateLanes()
    }

    /// The lanes alone, as a session's state changes: the summaries do not depend on it.
    private func updateLanes() {
        guard !retired else { return }
        let lanes = makeSessionLanes(projectSummaries)
        if sessionLanes != lanes { sessionLanes = lanes }
    }

    private func pullRequestsChanged() {
        tickets.linkedPRs = prs.linkedPRs
        tickets.projects = prs.projects
        // Projects come with the PR snapshot, which already drops a removed project from the pick;
        // the tickets and the board follow whichever project is left picked.
        tickets.project = prs.project.flatMap { id in prs.projects.first { $0.id == id && $0.claimsTickets } }
        updateBoardModel()
        updateSummaries()
        snapshotChanged()
        if let url = navigation.opening, !(prs.visibleRows + prs.others).contains(where: { $0.url.absoluteString == url }) { cancelActions() }
    }
}

// MARK: - Actions

extension DashboardViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: each action carries
    /// everything needed to act on it, and the coordinator never calls back into this model.
    enum Action: Equatable {
        /// A pull request or ticket page, already resolved to what to open and how.
        case open(OpenPageRequest)
        /// A project's own page, from its name on Projects.
        case openProject(String)
        /// A session, from its row or card on Overview.
        case openSession(String)
        /// A chat session, from its row in its project's lane.
        case openChat(String)
        /// A card on the Board tab.
        case board(WebBoardViewModel.Action)
    }
}

// MARK: - Tabs

extension DashboardViewModel {
    /// Projects' pages, picked from the tab bar at the top of the page: every project at a glance,
    /// every pull request, every ticket.
    enum Tab: String, CaseIterable, Identifiable {
        case overview, pullRequests, tickets, board
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return String(localized: "Overview")
            case .pullRequests: return String(localized: "Pull Requests")
            case .tickets: return String(localized: "Tickets")
            case .board: return String(localized: "Board")
            }
        }
    }

    /// The tabs the bar offers: Board only while some project has its Jira board turned on.
    var tabs: [Tab] { Tab.allCases.filter { $0 != .board || !boardProjectIDs.isEmpty } }

    func selectTab(_ value: Tab) {
        guard !retired else { return }
        tab = tabs.contains(value) ? value : .overview
        // Back on a page with tickets and none yet (Jira was slow or failed at connect): try again.
        if value == .overview || value == .tickets, tickets.available, tickets.fetchedNothing, !tickets.loading { tickets.refresh() }
    }

    /// The Pull Requests tab on one author's pull requests under `filter`, in the project picked:
    /// what an Overview total opens.
    func showPullRequests(_ author: DashboardPullRequestsModel.Author, filter: DashboardPullRequestsModel.Filter = .all) {
        guard !retired else { return }
        prs.author = author
        prs.filter = filter
        selectTab(.pullRequests)
    }

    /// The Tickets tab on the user's tickets under `filter`, in the project picked: what an
    /// Overview total opens. Picking the tab instead returns to it as it was left.
    func showTickets(_ filter: DashboardTicketsModel.Filter = .all) {
        guard !retired else { return }
        tickets.author = .mine
        tickets.filter = filter
        selectTab(.tickets)
    }

    func openProject(_ id: String) {
        guard !retired, prs.projects.contains(where: { $0.id == id }) else { return }
        onAction(.openProject(id))
    }

    func openSession(_ id: String) {
        guard !retired, sessions.contains(where: { $0.id == id }) else { return }
        onAction(.openSession(id))
    }

    func openChat(_ id: String) {
        guard !retired, chats.contains(where: { $0.id == id }) else { return }
        onAction(.openChat(id))
    }

    /// The project every tab is narrowed to, from the menu at the tab bar's end; nil is every project.
    var project: String? { prs.project }

    /// Whether the narrowed-to project tracks tickets; with none, the Tickets tab has nothing to list.
    var projectTracksTickets: Bool {
        guard let id = prs.project else { return true }
        return prs.projects.contains { $0.id == id && $0.claimsTickets }
    }

    /// One project, or nil for every project, for every tab at once.
    func selectProject(_ id: String?) {
        guard !retired else { return }
        // A project with a board is known before the PR snapshot names it, so a board link at
        // launch keeps its project rather than landing on every project.
        let id = id.flatMap { id in prs.projects.contains { $0.id == id } || boardProjectIDs.contains(id) ? id : nil }
        prs.project = id
        tickets.project = id.flatMap { id in prs.projects.first { $0.id == id && $0.claimsTickets } }
        updateBoardModel()
    }

    /// Whether the picked project shows a board; with every project picked there is none to show.
    var projectShowsBoard: Bool { prs.project.map(boardProjectIDs.contains) ?? false }

    /// The board's backend; nil pauses a board already built, which keeps its filters.
    func connectBoards(_ service: (any BoardService)?) {
        guard !retired else { return }
        boardService = service
        if let service { board?.connect(service: service) } else { board?.pause() }
        updateBoardModel()
        updateBoard()
    }

    /// A Jira sync for one project's board, or for every board.
    func refreshBoard(event id: String?) {
        guard !retired, let board, id == nil || id == "board:\(board.projectID)" else { return }
        board.refresh()
    }

    /// Builds the board of the picked project when it shows one, and retires one no longer picked.
    private func updateBoardModel() {
        guard !retired else { return }
        let wanted = projectShowsBoard ? prs.project : nil
        if board?.projectID != wanted { board?.retire(); board = nil }
        guard board == nil, let wanted, let boardService else { return }
        let board = WebBoardViewModel(projectID: wanted, service: boardService, pageActions: pageActions, preferences: .standard)
        board.onAction = { [weak self] in self?.onAction(.board($0)) }
        self.board = board
        updateBoard()
    }

    private func updateBoard() {
        guard !retired, let board else { return }
        board.appearance = appearance
        // With no backend the board stays idle, so neither Refresh nor a refresh reaches the old one.
        board.active = onScreen && tab == .board && boardService != nil
    }
}

// MARK: - Opening rows

extension DashboardViewModel {
    /// Only a row the dashboard still shows opens, in its current form: a row kept by a view that
    /// has not redrawn since the snapshot dropped it resolves to nothing.
    func open(_ row: DashboardRow) {
        request(currentRow(row).map(\.openPageRequest))
    }
    func sessionMark(_ row: DashboardRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(row.openPageRequest) }

    func open(_ row: DashboardTicketRow) {
        request(currentTicket(row).map(\.openPageRequest))
    }
    func sessionMark(_ row: DashboardTicketRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(row.openPageRequest) }

    func cancelActions() { navigation.cancel() }

    /// A row still shown anywhere: the user's own and review orbit, or the Pull Requests tab's Others.
    private func currentRow(_ row: DashboardRow) -> DashboardRow? {
        prs.visibleRows.first { $0.id == row.id } ?? prs.others.first { $0.id == row.id }
    }
    /// A ticket still shown: the user's own, or one under the Tickets tab's Others.
    private func currentTicket(_ row: DashboardTicketRow) -> DashboardTicketRow? {
        tickets.rows.first { $0.id == row.id } ?? tickets.others.first { $0.id == row.id }
    }

    /// The one way out for an open: dropped for a row no longer shown, otherwise handed to the
    /// coordinator, which decides whether it may present, then opens it or says why not.
    private func request(_ value: OpenPageRequest?) {
        guard !retired, let value else { return }
        onAction(.open(value))
    }
}
