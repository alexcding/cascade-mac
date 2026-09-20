import Foundation
import Observation

@MainActor @Observable final class DashboardViewModel {
    enum Action: Equatable { case open(String), copy(String) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let navigation: PageActionViewModel
    private(set) var retired = false
    private(set) var projects: [DashboardProject] = [] {
        didSet {
            if oldValue != projects {
                snapshotChanged()
                if let url = navigation.opening, !visibleRows.contains(where: { $0.url.absoluteString == url }) { cancelActions() }
            }
        }
    }
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

    var rows: [DashboardRow] {
        var seen: Set<String> = []
        return projects.flatMap { project in
            project.prs.compactMap { pr -> DashboardRow? in
                guard pr.error == nil, pr.state == "OPEN", let address = pr.url, let url = safeWebURL(address) else { return nil }
                let row = DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
                guard seen.insert(row.id).inserted else { return nil }
                return row
            }
        }
    }
    var visibleRows: [DashboardRow] { rows.filter { $0.isMine || $0.inReviewGroup } }
    var mine: [DashboardRow] { visibleRows.filter(\.isMine) }
    var reviews: [DashboardRow] { visibleRows.filter { !$0.isMine && $0.inReviewGroup } }
    var warnings: [String] {
        projects.flatMap { project -> [String] in
            var messages = project.prs.compactMap { $0.error.map { "\(project.name): \($0)" } }
            if let error = project.syncError { messages.insert("\(project.name): \(error)", at: 0) }
            if project.lastSynced == nil { messages.append("\(project.name): waiting for the first sync.") }
            return messages
        }
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
                    let snapshot = try await service.snapshot()
                    try Task.checkCancellation()
                    guard connectionGeneration == generation else { return }
                    if projects != snapshot { projects = snapshot }
                    updated = Date(); error = nil
                } catch { if !Task.isCancelled && connectionGeneration == generation { self.error = error.localizedDescription } }
            }
        }
    }

    func open(_ row: DashboardRow) { if !retired { onAction(.open(row.id)) } }
    func copyLink(_ row: DashboardRow) { if !retired { onAction(.copy(row.id)) } }
    func perform(_ action: Action) {
        guard !retired else { return }
        let id: String
        switch action { case .open(let value), .copy(let value): id = value }
        guard let row = visibleRows.first(where: { $0.id == id }) else { return }
        switch action {
        case .open:
            guard service != nil else { navigation.reject("Connect to open pull requests in Craft."); return }
            navigation.open(row.openPageRequest)
        case .copy: navigation.copy(row.url)
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
