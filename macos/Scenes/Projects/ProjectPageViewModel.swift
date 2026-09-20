import Foundation
import Observation

@MainActor @Observable final class ProjectPageViewModel {
    enum PullRequestAction: Equatable { case open(String), copy(String) }
    enum Action: Equatable {
        case selectSection(ProjectSection), saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        case pullRequest(PullRequestAction)
        case jiraTicket(JiraTicketsViewModel.Action), boardTicket(WebBoardViewModel.Action)
    }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in } {
        didSet {
            // Forward the current parent callback by value, following Record's
            // action.didSet pattern. Children do not retain this parent model.
            editor.onAction = { [onAction] action in
                switch action {
                case .saved(let project): onAction(.saved(project, .configuration))
                case .deleted(let id): onAction(.deleted(id))
                case .requestDeletion(let request): onAction(.requestDeletion(request))
                }
            }
            workflows?.onAction = { [onAction] action in
                if case .saved(let project) = action { onAction(.saved(project, .workflows)) }
            }
            automation?.onAction = { [onAction] action in
                if case .saved(let project) = action { onAction(.saved(project, .automation)) }
            }
            tickets?.onAction = { [onAction] in onAction(.jiraTicket($0)) }
            board?.onAction = { [onAction] in onAction(.boardTicket($0)) }
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    let board: WebBoardViewModel?
    let tickets: JiraTicketsViewModel?
    let workflows: WorkflowEditorViewModel?
    let automation: AutomationViewModel?
    private(set) var section = ProjectSection.prs {
        didSet { if oldValue != section { cancelActions(); updateBoardPresentation() } }
    }
    var active = false { didSet { if oldValue != active { updateBoardPresentation() } } }
    var appearance = AppAppearance.system { didSet { if oldValue != appearance { updateBoardPresentation() } } }
    var state = "open" { didSet { if oldValue != state { requestRefresh() } } }
    var search = ""
    private(set) var prs: [DashboardPR] = []
    private(set) var loadedState: String?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var refreshing = false
    private(set) var opening: Set<String> = []
    private(set) var actionError: String?
    private(set) var retired = false
    private var service: (any ProjectService)?
    private let pageActions: (any PageActionServing)?
    private var generation = UUID()
    private var actionGeneration = UUID()
    private var actionErrorGeneration = UUID()
    @ObservationIgnored private var stateTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private var actionTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    init(project: Project, service: any ProjectService, editor: ProjectEditorViewModel, board: WebBoardViewModel? = nil, tickets: JiraTicketsViewModel? = nil,
         workflows: WorkflowEditorViewModel? = nil, automation: AutomationViewModel? = nil,
         pageActions: (any PageActionServing)? = nil) {
        self.project = project; self.service = service; self.editor = editor; self.board = board; self.tickets = tickets
        self.workflows = workflows; self.automation = automation
        self.pageActions = pageActions
        section = Self.resolve(section, for: project)
    }
    /// Sections the picker offers for this project (`ProjectSection.available`).
    var availableSections: [ProjectSection] { ProjectSection.available(for: project) }
    /// A section the project cannot show falls back to its first available one, so
    /// neither a deep link nor an edit in Settings can leave a hidden tab selected.
    private static func resolve(_ section: ProjectSection, for project: Project) -> ProjectSection {
        let available = ProjectSection.available(for: project)
        return available.contains(section) ? section : (available.first ?? .settings)
    }
    func connect(_ service: (any ProjectService)?) {
        guard !retired else { return }
        cancelRefresh()
        if service == nil { cancelActions() }
        self.service = service; editor.connect(service)
    }
    func retire() {
        active = false
        retired = true; service = nil; onAction = { _ in }
        cancelRefresh(); cancelActions(); editor.retire()
        tickets?.retire(); board?.retire()
    }
    func selectSection(_ section: ProjectSection) { onAction(.selectSection(section)) }
    func setSection(_ section: ProjectSection) {
        guard !retired else { return }
        self.section = Self.resolve(section, for: project)
    }
    private func updateBoardPresentation() {
        guard !retired else { return }
        board?.appearance = appearance
        board?.active = active && section == .board
    }
    private func requestRefresh() {
        guard !retired else { return }
        cancelActions()
        refreshing = false; error = nil
        loading = service != nil
        stateTask = Task { [weak self] in await self?.refresh() }
    }
    func cancelRefresh() { stateTask = nil; generation = UUID(); loading = false; refreshing = false }
    func retry() { stateTask = Task { [weak self] in await self?.refresh(force: true) } }
    func cancelActions() {
        actionTask = nil; actionGeneration = UUID(); opening = []
        tickets?.cancelActions(); board?.cancelActions()
    }
    func open(_ row: DashboardRow) { request(.open(row.id)) }
    func copyLink(_ row: DashboardRow) { request(.copy(row.id)) }
    private func request(_ action: PullRequestAction) {
        guard !retired, pageActions != nil else { return }
        onAction(.pullRequest(action))
    }
    func performPullRequestAction(_ action: PullRequestAction) {
        guard !retired, let pageActions else { return }
        let id: String
        switch action { case .open(let value), .copy(let value): id = value }
        guard let row = rows.first(where: { $0.id == id }) else { return }
        switch action {
        case .open:
            guard !opening.contains(id) else { return }
            let generation = UUID(), errorGeneration = UUID()
            actionGeneration = generation; actionErrorGeneration = errorGeneration
            opening = [id]; actionError = nil
            let request = row.openPageRequest
            actionTask = Task { [weak self] in
                defer {
                    if self?.actionGeneration == generation { self?.opening = []; self?.actionTask = nil }
                }
                do {
                    try Task.checkCancellation()
                    try await pageActions.openPage(request)
                } catch {
                    if !Task.isCancelled && self?.actionGeneration == generation && self?.actionErrorGeneration == errorGeneration {
                        self?.actionError = "Could not open pull request: \(error.localizedDescription)"
                    }
                }
            }
        case .copy:
            actionErrorGeneration = UUID(); actionError = nil
            pageActions.copyLink(row.url.absoluteString)
        }
    }
    var rows: [DashboardRow] {
        guard loadedState == state else { return [] }
        var seen: Set<String> = []
        return prs.compactMap { pr in
            guard pr.error == nil, let raw = pr.url, let url = safeWebURL(raw) else { return nil }
            let row = DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
            guard seen.insert(row.id).inserted, search.isEmpty || row.searchText.localizedStandardContains(search) else { return nil }
            return row
        }
    }
    var warnings: [String] { loadedState == state ? prs.compactMap(\.error) : [] }
    func update(_ project: Project, snapshot: [DashboardPR]? = nil) {
        guard !retired else { return }
        if self.project.repo != project.repo || self.project.jiraProjectKey != project.jiraProjectKey {
            cancelRefresh(); cancelActions(); prs = []; loadedState = nil; error = nil
        }
        self.project = project; editor.update(project); tickets?.update(project)
        workflows?.update(project); automation?.update(project)
        section = Self.resolve(section, for: project)
        if state == "open", let snapshot { prs = snapshot; loadedState = "open" }
    }
    func refresh(force: Bool = false) async {
        guard !retired, !Task.isCancelled, let service else { return }
        let generation = UUID(); self.generation = generation
        let requestedState = state
        loading = true
        defer { if self.generation == generation { loading = false } }
        do {
            let result = try await service.pullRequests(project.id, state: requestedState, force: force)
            try Task.checkCancellation()
            guard self.generation == generation && state == requestedState else { return }
            prs = result.prs; loadedState = requestedState
            refreshing = result.refreshing; error = result.error
        } catch {
            if self.generation == generation && !Task.isCancelled { self.error = error.localizedDescription; refreshing = false }
        }
    }
}
