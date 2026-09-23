import Foundation
import Observation

@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: `pullRequest` already
    /// carries the resolved request, and the coordinator never calls back into this model to
    /// resolve one, following the Dashboard's pattern.
    enum Action: Equatable {
        case selectSection(ProjectSection), saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        case pullRequest(OpenPageRequest)
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
    private(set) var state = "open"
    private(set) var search = ""
    private(set) var prs: [DashboardPR] = []
    private(set) var loadedState: String?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var refreshing = false
    private(set) var opening: Set<String> = []
    @ObservationIgnored private var openingInSession = false
    @ObservationIgnored private var openingInTab = false
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
    /// Only a row this page still shows opens, in its current form: a row kept by a view that has
    /// not redrawn since the snapshot dropped it resolves to nothing.
    func open(_ row: DashboardRow, inTab: Bool = false) { request(currentRow(row).map { Self.tabRequest($0.openPageRequest, inTab: inTab) }) }
    func openSession(_ row: DashboardRow, agent: SessionAgent? = nil) { request(currentRow(row).map { DashboardViewModel.sessionRequest($0, agent: agent) }) }
    func sessionMark(_ row: DashboardRow) -> PageSessionMark? { retired ? nil : pageActions?.pageSession(DashboardViewModel.sessionRequest(row)) }

    private func currentRow(_ row: DashboardRow) -> DashboardRow? { rows.first { $0.id == row.id } }

    /// The one way out for an open: dropped for a row no longer shown, otherwise handed to the
    /// coordinator, which decides whether it may present and runs it through `openPage`.
    private func request(_ value: OpenPageRequest?) {
        guard !retired, pageActions != nil, let value else { return }
        onAction(.pullRequest(value))
    }

    private static func tabRequest(_ request: OpenPageRequest, inTab: Bool) -> OpenPageRequest {
        var request = request
        request.inTab = inTab
        return request
    }

    /// Runs a request the coordinator has already approved. The same row asked another way —
    /// click, Open in Tab, session — is a new request, not a repeat; a resolved id keeps the
    /// in-flight dedupe and `opening` keyed the way `ProjectViews` reads it, by `DashboardRow.id`.
    func openPage(_ request: OpenPageRequest) {
        guard !retired, let pageActions else { return }
        let id = Self.rowID(request)
        guard !opening.contains(id) || openingInSession != request.inSession || openingInTab != request.inTab else { return }
        openingInSession = request.inSession; openingInTab = request.inTab
        let generation = UUID(), errorGeneration = UUID()
        actionGeneration = generation; actionErrorGeneration = errorGeneration
        opening = [id]; actionError = nil
        actionTask = Task { [weak self] in
            defer {
                if self?.actionGeneration == generation { self?.opening = []; self?.actionTask = nil }
            }
            do {
                try Task.checkCancellation()
                try await pageActions.openPage(request)
            } catch {
                if !Task.isCancelled && self?.actionGeneration == generation && self?.actionErrorGeneration == errorGeneration {
                    self?.actionError = request.failure("Could not open pull request", error)
                }
            }
        }
    }
    private static func rowID(_ request: OpenPageRequest) -> String { "\(request.projectID ?? ""):\(request.url)" }
    private(set) var rows: [DashboardRow] = []
    private(set) var warnings: [String] = []
    @ObservationIgnored private var loadedRows: [DashboardRow] = []

    func setState(_ value: String) {
        guard !retired, state != value else { return }
        state = value
        updateVisibleRows()
        requestRefresh()
    }
    func setSearch(_ value: String) {
        guard !retired, search != value else { return }
        search = value
        updateVisibleRows()
    }
    private func prepareRows() {
        var seen: Set<String> = []
        loadedRows = prs.compactMap { pr in
            guard pr.error == nil, let raw = pr.url, let url = safeWebURL(raw) else { return nil }
            let row = DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
            guard seen.insert(row.id).inserted else { return nil }
            return row
        }
        updateVisibleRows()
    }
    private func updateVisibleRows() {
        let rows = loadedState == state ? loadedRows.filter { search.isEmpty || $0.searchText.localizedStandardContains(search) } : []
        let warnings = loadedState == state ? prs.compactMap(\.error) : []
        if self.rows != rows { self.rows = rows }
        if self.warnings != warnings { self.warnings = warnings }
    }
    func update(_ project: Project, snapshot: [DashboardPR]? = nil) {
        guard !retired else { return }
        if self.project.repo != project.repo || self.project.jiraProjectKey != project.jiraProjectKey {
            cancelRefresh(); cancelActions(); prs = []; loadedState = nil; error = nil
        }
        self.project = project; editor.update(project); tickets?.update(project)
        workflows?.update(project); automation?.update(project)
        section = Self.resolve(section, for: project)
        if state == "open", let snapshot { prs = snapshot; loadedState = "open" }
        prepareRows()
    }
    func refresh(force: Bool = false) async {
        guard !retired, !Task.isCancelled, let service else { return }
        let generation = UUID(); self.generation = generation
        let requestedState = state
        loading = true
        defer { if self.generation == generation { loading = false } }
        do {
            try await load(from: service, state: requestedState, force: force, generation: generation)
        } catch {
            if self.generation == generation && !Task.isCancelled { self.error = error.localizedDescription; refreshing = false }
        }
    }
    private func load(from service: any ProjectService, state: String, force: Bool, generation: UUID) async throws {
        let result = try await service.pullRequests(project.id, state: state, force: force)
        try Task.checkCancellation()
        guard !retired, self.generation == generation, self.state == state else { return }
        prs = result.prs; loadedState = state
        prepareRows()
        refreshing = result.refreshing; error = result.error
    }
}
