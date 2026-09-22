import Foundation
import Observation

@MainActor @Observable final class DashboardViewModel {
    enum Action: Equatable { case open(String), session(String, agent: SessionAgent?) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let navigation: PageActionViewModel
    private(set) var retired = false
    private(set) var projects: [DashboardProject] = []
    @ObservationIgnored var snapshotChanged: () -> Void = {}
    private(set) var loading = false
    private(set) var updated: Date?
    private(set) var error: String?
    @ObservationIgnored private var service: (any DashboardService)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var connectionGeneration = UUID()

    init(pageActions: any PageActionServing) {
        navigation = PageActionViewModel(service: pageActions, failureDescription: "Could not open pull request")
    }

    func connect(_ service: any DashboardService) {
        guard !retired else { return }
        cancelRefresh(); cancelActions(); self.service = service; refresh()
    }

    private(set) var rows: [DashboardRow] = []
    private(set) var visibleRows: [DashboardRow] = []
    private(set) var mine: [DashboardRow] = []
    private(set) var reviews: [DashboardRow] = []
    private(set) var warnings: [String] = []

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

    func open(_ row: DashboardRow) { if !retired { onAction(.open(row.id)) } }
    func openSession(_ row: DashboardRow, agent: SessionAgent? = nil) { if !retired { onAction(.session(row.id, agent: agent)) } }
    func sessionMark(_ row: DashboardRow) -> PageSessionMark? { retired ? nil : navigation.pageSession(Self.sessionRequest(row)) }
    static func sessionRequest(_ row: DashboardRow, agent: SessionAgent? = nil) -> OpenPageRequest {
        var request = row.openPageRequest
        request.inSession = true; request.projectID = row.projectID; request.agent = agent
        return request
    }
    func perform(_ action: Action) {
        guard !retired else { return }
        let id: String
        switch action { case .open(let value), .session(let value, _): id = value }
        guard let row = visibleRows.first(where: { $0.id == id }) else { return }
        guard service != nil else { navigation.reject("Connect to open pull requests in Craft."); return }
        switch action {
        case .open: navigation.open(row.openPageRequest)
        case .session(_, let agent): navigation.open(Self.sessionRequest(row, agent: agent))
        }
    }
    func cancelActions() { navigation.cancel() }
    private func cancelRefresh() {
        connectionGeneration = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshPending = false; loading = false
    }
    func retire() {
        retired = true; onAction = { _ in }; snapshotChanged = {}; service = nil
        cancelActions(); cancelRefresh()
    }
    func stop() async {
        let pending = refreshTask
        cancelActions(); cancelRefresh(); service = nil
        await pending?.value
    }
}
