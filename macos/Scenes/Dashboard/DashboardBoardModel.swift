import Foundation
import Observation

/// My Tickets' Board: one project's sprint board at a time. It owns that board's model, builds a
/// new one when the project changes and retires the old, and remembers the pick across launches.
/// Only Jira projects are offered; a board needs a Jira key or a saved JQL query.
@MainActor @Observable final class DashboardBoardModel {
    /// A board's card asked to open; the owner gates it before the board opens it.
    @ObservationIgnored var onAction: (WebBoardViewModel.Action) -> Void = { _ in }
    private(set) var retired = false
    /// Projects a board can be shown for, in the dashboard's project order.
    private(set) var projects: [DashboardProject] = []
    /// The project the board shows, or nil when there is none to show.
    private(set) var project: DashboardProject?
    private(set) var board: WebBoardViewModel?
    /// Whether the board is on screen: only then does it load and follow Jira.
    var active = false { didSet { if active != oldValue { updateBoard() } } }
    var appearance = AppAppearance.system { didSet { if appearance != oldValue { updateBoard() } } }

    static let storageKey = "dashboard.board.project"
    @ObservationIgnored private var service: (any BoardService)?
    /// A project asked for before the dashboard's projects loaded, chosen once they do.
    @ObservationIgnored private var requested: String?
    @ObservationIgnored private let pageActions: any PageActionServing
    @ObservationIgnored private let defaults: UserDefaults

    init(pageActions: any PageActionServing, defaults: UserDefaults = .standard) {
        self.pageActions = pageActions
        self.defaults = defaults
    }

    var available: Bool { service != nil && !projects.isEmpty }

    func connect(_ service: (any BoardService)?) {
        guard !retired else { return }
        self.service = service
        rebuild()
    }

    /// Follows the dashboard's snapshot: a project that lost Jira or was removed gives way to the
    /// remembered one, then to the first left.
    func update(projects all: [DashboardProject]) {
        guard !retired else { return }
        let projects = all.filter(\.hasJira)
        if self.projects != projects { self.projects = projects }
        let asked = requested.flatMap { id in projects.first { $0.id == id } }
        if asked != nil { requested = nil }
        let current = project.flatMap { current in projects.first { $0.id == current.id } }
        let chosen = asked ?? current ?? remembered ?? projects.first
        if chosen?.id != project?.id { project = chosen; rebuild() } else if chosen != project { project = chosen }
    }

    func select(_ id: String) {
        guard !retired, id != project?.id else { return }
        guard let chosen = projects.first(where: { $0.id == id }) else { requested = id; return }
        project = chosen
        defaults.set(id, forKey: Self.storageKey)
        rebuild()
    }

    /// A Jira sync for this board's project, or for every board.
    func refresh(event id: String?) {
        guard !retired, let project, id == nil || id == "board:\(project.id)" else { return }
        board?.refresh()
    }

    func cancelActions() { board?.cancelActions() }

    func retire() {
        retired = true
        active = false
        onAction = { _ in }
        board?.retire(); board = nil
        service = nil
    }

    private var remembered: DashboardProject? {
        defaults.string(forKey: Self.storageKey).flatMap { id in projects.first { $0.id == id } }
    }

    /// A board belongs to one project and one service, so either changing builds a new one.
    private func rebuild() {
        board?.retire()
        board = nil
        guard !retired, let service, let project else { return }
        let board = WebBoardViewModel(projectID: project.id, service: service, pageActions: pageActions)
        board.onAction = { [weak self] in self?.onAction($0) }
        self.board = board
        updateBoard()
    }

    private func updateBoard() {
        guard !retired, let board else { return }
        board.appearance = appearance
        board.active = active
    }
}
