import AppKit
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class AppViewModel {
    public let shell: ShellStore
    @ObservationIgnored private let shellFactory: any ShellFeatureFactory
    @ObservationIgnored private let shellCoordinator: ShellCoordinator
    let viewer: ViewerStore
    let coordinator: AppCoordinator
    private(set) var root: RootViewModel!
    @ObservationIgnored private let creationFactory: any CreationFlowFactory
    @ObservationIgnored private let welcomeFactory: any WelcomeFeatureFactory
    @ObservationIgnored private let welcomeStore: any WelcomePersisting
    @ObservationIgnored private let desktop: any DesktopActions
    @ObservationIgnored private let workspaceFactory: any WorkspaceFeatureFactory
    @ObservationIgnored private let projectFactory: any ProjectFeatureFactory
    @ObservationIgnored private let documentFactory: any DocumentFeatureFactory
    @ObservationIgnored private let trayFactory: any TrayFeatureFactory
    @ObservationIgnored private let copy: (String) -> Void
    var dashboard: DashboardViewModel? { coordinator.dashboardCoordinator?.model }
    var automation: AutomationViewModel? { coordinator.automationCoordinator?.model }
    var logs: LogsViewModel? { coordinator.logsCoordinator?.model }
    var settings: SettingsViewModel? { coordinator.settingsCoordinator?.model }
    let workspaceLaunch: WorkspaceLaunchViewModel
    /// What each worktree's IDE is still preparing. Fed by `ide-warmup` events, read by every
    /// session workspace.
    let ideWarmup = IDEWarmupStore()
    /// Opens the Settings window. The main window installs SwiftUI's `openSettings` here, since
    /// that action only exists in a view's environment.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    @ObservationIgnored var showMainWindow: (() -> Void)?
    /// The sidebar bell's "Today" popover.
    let todayActivity = TodayActivityViewModel()
    @ObservationIgnored private let platformFactory: any AppPlatformFactory
    @ObservationIgnored private let terminalControl: any TerminalRuntimeControlling
    @ObservationIgnored private let processes: any ProcessSampling
    @ObservationIgnored private let sessionPool: SessionPool
    public private(set) var projects: [Project] = [] { didSet { if oldValue != projects { automation?.updateProjects(projects) } } }
    /// The sidebar's dragged order for projects and sessions; see `SidebarOrder`.
    private(set) var sidebarOrder: SidebarOrder { didSet { if oldValue != sidebarOrder { orderStore.save(sidebarOrder) } } }
    @ObservationIgnored private let orderStore: any SidebarOrderPersisting
    public private(set) var connection = "Connecting" { didSet { if oldValue != connection { updateWorkspaceReviewState() } } }
    public private(set) var error: String?
    public private(set) var lastUpdate: Date?
    public private(set) var backendAddress = ""
    private(set) var sessions: [WorkspaceSession] = [] { didSet { if oldValue != sessions { updateWorkspaceReviewState() } } }
    private(set) var tabs: [SavedTab] = []
    /// Tabs the user opened from the sidebar but has not given an address yet. They live only
    /// here until their first navigation turns them into saved tabs.
    private(set) var draftTabs: [SavedTab] = []
    var visibleTabs: [SavedTab] { tabs + draftTabs }
    func isDraftTab(_ id: String) -> Bool { draftTabs.contains { $0.id == id } }
    @ObservationIgnored private var committingDrafts: Set<String> = []
    func tabURL(_ id: String) -> String? { visibleTabs.first { $0.id == id }?.url }
    var selection: SidebarDestination { coordinator.selection }
    private(set) var terminals: [String: TerminalSession] = [:] {
        didSet { updateWorkspaceTerminalState() }
    }
    var projectModels: [String: ProjectPageViewModel] { coordinator.projectModels }
    private(set) var changingSessions: Set<String> = []
    /// PR / ticket pages whose session is being created right now (their Create Session is busy).
    private(set) var startingPages: Set<String> = []
    private(set) var buildModels: [String: BuildWorkspaceViewModel] = [:]
    private(set) var historyModels: [String: GitHistoryViewModel] = [:]
    private(set) var diffModels: [String: DiffViewModel] = [:]
    private(set) var workflowRuns: [String: WorkflowRunViewModel] = [:]
    private(set) var pageWorkflowRuns: [String: WorkflowRunViewModel] = [:]
    @ObservationIgnored private var pageWorkflowTargets: [String: WorkflowPageTarget] = [:]
    @ObservationIgnored private var preparingWorkflowPages: Set<String> = []
    @ObservationIgnored private var pendingPins: Set<String> = []
    /// Observed, not ignored: `isRemoving(_:)` is read from a view body, so a lock taken or
    /// released has to invalidate it.
    private var removalLocks: [UUID: Set<String>] = [:]
    @ObservationIgnored private let backendRuntime: any BackendRuntimeServing
    @ObservationIgnored private let backendFactory: any BackendFeatureFactory
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var startGeneration = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private enum Inventory: Hashable { case projects, sessions, tabs }
    @ObservationIgnored private var refreshPending: Set<Inventory> = []
    @ObservationIgnored private var inventoryGenerations: [Inventory: UUID] = [:]
    @ObservationIgnored private var eventRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshEvents: [ServerEvent] = []
    @ObservationIgnored private var started = false
    // Keep navigation visible on the first frame, before the async inventory load.
    private(set) var sidebarEntries = SidebarEntry.make(projects: [], sessions: [], tabs: [])
    private(set) var sidebarPinnedIDs: Set<String> = []
    @ObservationIgnored private var sidebarLoadTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarLoadPending = false
    @ObservationIgnored private var sidebarNeedsLoad = true

    public convenience init() { self.init(creationFactory: NativeCreationFlowFactory(), welcomeStore: UserDefaultsWelcomeStore()) }

    init(creationFactory: any CreationFlowFactory, desktop: any DesktopActions = NativeDesktopActions(),
         backendRuntime: any BackendRuntimeServing = BackendRuntime(),
         backendFactory: any BackendFeatureFactory = NativeBackendFeatureFactory(),
         shellFactory: any ShellFeatureFactory = NativeShellFeatureFactory(),
         platformFactory: any AppPlatformFactory = NativeAppPlatformFactory(),
         workspaceFactory: any WorkspaceFeatureFactory = NativeWorkspaceFeatureFactory(),
         rootFactory: any RootFeatureFactory = NativeRootFeatureFactory(),
         dashboardFactory: any DashboardFeatureFactory = NativeDashboardFeatureFactory(),
         logsFactory: any LogsFeatureFactory = NativeLogsFeatureFactory(),
         settingsFactory: (any SettingsFeatureFactory)? = nil,
         welcomeFactory: (any WelcomeFeatureFactory)? = nil,
         welcomeStore: any WelcomePersisting = TransientWelcomeStore(),
         documentFactory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         documentClosePresenter: any EditorClosePresenting = NativeEditorClosePresenter(),
         browserDialogPresenter: any BrowserDialogPresenting = NativeBrowserDialogPresenter(),
         trayFactory: any TrayFeatureFactory = NativeTrayFeatureFactory(),
         notificationFactory: any NotificationFeatureFactory = NativeNotificationFeatureFactory(),
         selectionStore: any SidebarSelectionPersisting = UserDefaultsSidebarSelectionStore(),
         orderStore: any SidebarOrderPersisting = UserDefaultsSidebarOrderStore(),
         router: any DeepLinkRouting = CraftRouter(),
         projectFactory: (any ProjectFeatureFactory)? = nil,
         copy: @escaping (String) -> Void = { NativeClipboard.copy($0) }) {
        self.creationFactory = creationFactory
        self.welcomeFactory = welcomeFactory ?? NativeWelcomeFeatureFactory(desktop: desktop, copy: copy)
        self.welcomeStore = welcomeStore
        self.orderStore = orderStore
        self.sidebarOrder = orderStore.load()
        self.backendRuntime = backendRuntime
        self.backendFactory = backendFactory
        self.platformFactory = platformFactory
        let terminalControl = platformFactory.terminalControl()
        self.terminalControl = terminalControl
        self.workspaceLaunch = platformFactory.workspaceLauncher()
        self.shellFactory = shellFactory
        let shell = shellFactory.shell(notifications: notificationFactory.notifications())
        self.shell = shell
        let processes = platformFactory.processSampler()
        self.processes = processes
        sessionPool = SessionPool(control: terminalControl, memory: processes, limit: shell.sessionMemoryLimit)
        self.shellCoordinator = shellFactory.coordinator(model: shell)
        self.desktop = desktop
        self.workspaceFactory = workspaceFactory
        self.documentFactory = documentFactory
        self.trayFactory = trayFactory
        self.copy = copy
        self.projectFactory = projectFactory ?? NativeProjectFeatureFactory(creation: creationFactory)
        let documentCloser = EditorCloseCoordinator(factory: documentFactory, presenter: documentClosePresenter)
        let browserDialogs = BrowserDialogCoordinator(presenter: browserDialogPresenter)
        viewer = platformFactory.viewer(dialogs: browserDialogs, documents: documentFactory, close: documentCloser)
        coordinator = AppCoordinator(factory: creationFactory, selectionStore: selectionStore, workspaceFactory: workspaceFactory, router: router,
            documentCloseCoordinator: documentCloser, browserDialogCoordinator: browserDialogs,
            fileOpenCoordinator: viewer.fileOpenCoordinator,
            canOpenExternalRoute: {
                NSApplication.shared.modalWindow == nil && !NSApplication.shared.windows.contains { $0.attachedSheet != nil }
            })
        coordinator.hasDocumentPresentation = { [weak self] in
            self?.diffModels.values.contains { $0.coordinator.isPresenting } == true
        }
        coordinator.appearance = shell.appearance
        coordinator.presentSettingsWindow = { [weak self] in self?.presentSettings() }
        shell.documentStyleChanged = { [weak self] in
            guard let self else { return }
            coordinator.appearance = shell.appearance
            updateWorkspaceDocumentState()
        }
        shell.terminalStyleChanged = { [weak self] in self?.updateWorkspaceTerminalState() }
        shell.memoryLimitsChanged = { [weak self] in
            guard let self else { return }
            sessionPool.limit = shell.sessionMemoryLimit
            viewer.pageMemoryLimit = shell.pageMemoryLimit
        }
        viewer.pageMemoryLimit = shell.pageMemoryLimit
        sessionPool.sessions = { [weak self] in self?.poolSessions() ?? [] }
        sessionPool.stop = { [weak self] id in await self?.stopPooledSession(id) ?? false }
        _ = coordinator.makeDashboard(factory: dashboardFactory, pageActions: platformFactory.pageActions(open: { [weak self] request in
            guard let self else { throw BackendError.operation("The workspace has closed.") }
            try await self.openPage(request)
        }, session: { [weak self] request in self?.pageSessionMark(request) }), shell: shell)
        _ = coordinator.makeAutomation(factory: NativeAutomationFeatureFactory())
        _ = coordinator.makeLogs(factory: logsFactory, pageActions: platformFactory.pageActions(open: { [weak self] request in
            guard let self else { throw BackendError.operation("The workspace has closed.") }
            try await self.openPage(request)
        }), copy: copy)
        dashboard?.snapshotChanged = { [weak self] in self?.cachedResolverPullRequests = nil; self?.updateWorkspaceReviewState() }
        _ = coordinator.makeSettings(factory: settingsFactory ?? NativeSettingsFeatureFactory(desktop: desktop, copy: copy, adBlocker: .shared), shell: shell, runtime: self)
        viewer.contextChanged = { [weak self] context in
            guard let self, viewer.contexts[context.id] === context else { return }
            commitDraftTab(context)
            syncTabTitle(context)
        }
        // A link opened from a sidebar tab becomes its own tab under Tabs, the way one opened from
        // the dashboard does. A session's second panel keeps such links as pages of that panel.
        // Opening a tab needs the backend, so before it connects the link opens in its own panel
        // rather than not at all.
        viewer.openSidebarTab = { [weak self] url, keepInPanel in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await openPage(OpenPageRequest(url: url, kind: "web", title: "")) }
                catch { keepInPanel() }
            }
        }
        viewer.prepareContext = { [weak self] context in
            guard let self else { return }
            context.configureWorkspace(factory: workspaceFactory, service: self)
            if let model = context.workspaceViewModel { coordinator.bindWorkspace(model, context: context, runtime: self) }
        }
        root = coordinator.makeRoot(factory: rootFactory, runtime: self, shell: shell, viewer: viewer)
        coordinator.installNotifications(shell.notifications, runtime: self)
        todayActivity.openPage = { [weak self] entry in
            guard let self else { throw CancellationError() }
            try await openActivityEntry(entry)
        }
        scheduleSidebarLoad()
    }

    private func scheduleSidebarLoad() {
        sidebarLoadPending = true
        guard sidebarLoadTask == nil else { return }
        sidebarLoadTask = Task { [weak self] in
            guard let self else { return }
            while sidebarLoadPending {
                sidebarLoadPending = false
                await loadSidebar()
            }
            sidebarLoadTask = nil
        }
    }

    /// Store the display snapshot after loading inventory or a live dependency changes.
    /// Tracking includes nested terminal, workflow, and browser state, so those updates
    /// schedule a load even when no backend inventory request is needed.
    private func loadSidebar() async {
        guard sidebarNeedsLoad else { return }
        sidebarNeedsLoad = false
        let (entries, pinnedIDs) = withObservationTracking {
            (makeSidebarEntries(), Set(sessions.filter(\.pinned).map(\.id)))
        } onChange: { [weak self] in
            // Every source is MainActor-owned. Mark dirty synchronously so an inventory
            // load can flush the new rows before validating selection. Re-arm only after
            // an actual change, keeping one observation even across unchanged refreshes.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sidebarNeedsLoad = true
                self.scheduleSidebarLoad()
            }
        }
        if sidebarEntries != entries { sidebarEntries = entries }
        if sidebarPinnedIDs != pinnedIDs { sidebarPinnedIDs = pinnedIDs }
    }

    private func makeSidebarEntries() -> [SidebarEntry] {
        // Per-session agent state for the row glyph (sidebar.js taskSessions + refreshTermBusy):
        // live while its terminal is attached, busy between the CLI's turn hooks or while a
        // workflow runs on it.
        var status: [String: SidebarSessionStatus] = [:]
        for session in sessions {
            let terminal = terminals["task:\(session.id)"]
            let live = terminal.map { !$0.status.hasPrefix("Exited") && $0.status != "Disconnected" } ?? false
            let busy = terminal?.agentBusy == true || workflowRuns[session.id]?.running == true
            status[session.id] = SidebarSessionStatus(live: live, busy: busy, cli: terminal?.agentTurns.cli?.rawValue ?? session.cli)
        }
        let prs = Dictionary((dashboard?.prs.projects ?? []).flatMap(\.prs).compactMap { pr in pr.url.map { ($0, pr) } },
                             uniquingKeysWith: { first, _ in first })
        var tabIcons: [String: SidebarTabIcon] = [:]
        for tab in tabs where tab.kind == "github" {
            let pr = prs[tab.url]
            let ci: SidebarTabIcon.CI = switch (pr?.ci?.status, pr?.ci?.conclusion) {
            case ("in_progress", _), ("queued", _): .running
            case (_, "success"): .success
            case (_, "failure"): .failure
            default: .none
            }
            tabIcons[tab.id] = SidebarTabIcon(kind: tab.kind, login: pr?.author?.login ?? tab.login, avatar: tab.avatar, ci: ci)
        }
        // A web tab keeps the address it was saved under while its page browses on, so the row's
        // favicon follows the page in view, the way its title does, not the saved address.
        for tab in tabs where tab.kind == "web" {
            guard let live = viewer.contexts["tab:\(tab.id)"]?.activePage?.url,
                  let host = FaviconStore.host(of: live), host != FaviconStore.host(of: tab.url) else { continue }
            tabIcons[tab.id] = SidebarTabIcon(kind: tab.kind, login: tab.login, avatar: tab.avatar, url: live)
        }
        // A saved tab whose page is back on the start page reads as a new tab, the way a draft does,
        // until it has an address again. Only the row changes: the saved tab keeps its address, and a
        // tab a session owns stays out of the list under that address.
        let sessionURLs = Set(sessions.map(\.url))
        let shownTabs = visibleTabs.map { tab in
            guard !tab.isOwned(by: sessionURLs),
                  viewer.contexts["tab:\(tab.id)"]?.activePage?.controls.isBlank == true else { return tab }
            var blank = SavedTab(id: tab.id, kind: "web", title: "New Tab", url: "")
            blank.pinned = tab.pinned
            return blank
        }
        return SidebarEntry.make(projects: projects, sessions: sessions, tabs: shownTabs, status: status,
            workflowProgress: workflowRuns.filter { $0.value.running }.mapValues { "\($0.step)/\($0.total)" },
            tabIcons: tabIcons, order: sidebarOrder)
    }
    var activeTerminalKey: String? {
        switch selection {
        case .terminal: "scratch"
        case .session(let id): "task:\(id)"
        default: nil
        }
    }
    var terminal: TerminalSession? { activeTerminalKey.flatMap { terminals[$0] } }
    public var hasActivePage: Bool { viewer.active?.activeID != nil }
    var activeHistory: GitHistoryViewModel? {
        guard let context = viewer.active, context.pane == .diff, context.reviewSection == .history else { return nil }
        return historyModels[context.id]
    }
    var sessionOperations: (any SessionServing)? { api.map { backendFactory.sessions(api: $0) } }

    func showChanges(for session: WorkspaceSession, context: WorkspaceContext) {
        if context.pane == .diff { context.setPane(context.activeDocument != nil ? .files : .term); return }
        prepareChanges(for: session, context: context)
        if diffModels[context.id] != nil { context.setPane(.diff) }
    }

    /// Here rather than beside the other `WorkspaceServing` members because `api` is private.
    func agentCatalog(cli: String) async -> AgentCatalog? {
        guard let api else { return nil }
        return try? await api.get(APIClient.query(Routes.AGENT_CATALOG, ["cli": cli]))
    }

    func agentStatus(cli: String, worktree: String, task: String) async -> AgentStatus? {
        guard let api else { return nil }
        let value: AgentStatus?? = try? await api.get(APIClient.query(Routes.AGENT_STATUS, ["cli": cli, "worktree": worktree, "task": task]))
        return value ?? nil
    }

    func prepareChanges(for session: WorkspaceSession, context: WorkspaceContext) {
        defer { context.workspaceViewModel?.documentStateChanged() }
        if context.reviewSection == .history, let api {
            let base = dashboard?.prs.projects.flatMap(\.prs).first(where: { $0.url == session.url })?.baseRefName
            if let history = historyModels[context.id] { if let base { history.updateBase(base) } }
            else {
                historyModels[context.id] = documentFactory.history(worktree: session.worktree, baseURL: api.baseURL, base: base ?? "",
                    service: backendFactory.history(api: api), copy: copy)
            }
        }
        if diffModels[context.id] == nil {
            guard let api else { context.error = "Connect to the backend to load changes."; return }
            diffModels[context.id] = documentFactory.diff(worktree: session.worktree, baseURL: api.baseURL,
                                                   service: backendFactory.diff(api: api), actionsService: backendFactory.changes(api: api), openFile: { [weak context] location in
                context?.openFile(location.path, line: location.line, column: location.column)
            })
            diffModels[context.id]?.coordinator.canPresent = { [weak self, weak context] in
                guard let self, let context else { return false }
                return viewer.active === context && coordinator.canPresent
            }
            diffModels[context.id]?.coordinator.presentationEnded = { [weak coordinator] in coordinator?.schedulePendingDeepLink() }
        }
    }

    func ownsProject(_ id: String) -> Bool { projects.contains { $0.id == id } }

    func applyProjectDeletion(_ id: String, model: ProjectPageViewModel) {
        projects.removeAll { $0.id == id }
        retireProject(model)
        refresh()
    }

    private func retireProject(_ model: ProjectPageViewModel) {
        model.retire(); model.board?.suspend()
        Task { await model.workflows?.stop(); await model.tickets?.stop() }
    }

    private func savedProject(_ project: Project) {
        applyProjectSave(project, source: .configuration)
        select(.project(project.id))
    }

    func applyProjectSave(_ project: Project, source: ProjectSaveSource) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.append(project) }
        projectModels[project.id]?.update(project)
        for session in sessions where source == .configuration && session.projectId == project.id {
            buildModels.removeValue(forKey: "task:\(session.id)")?.disconnect()
        }
        refresh()
    }

    /// The project a new session is created under, from where it was asked for — the sheet never
    /// offers another. A PR page belongs to the project of its repository, a ticket to the project
    /// on its Jira key; failing that, the only project there is.
    func sessionProject(for destination: SidebarDestination) -> Project? {
        let local = projects.filter { !$0.workspace.isEmpty }
        switch destination {
        // A destination that names its project gets that project or none — never a stand-in.
        case .project(let id): return local.first { $0.id == id }
        case .session(let id):
            guard let session = sessions.first(where: { $0.id == id }) else { return nil }
            return local.first { $0.id == session.projectId }
        case .tab(let id):
            guard let url = tabURL(id), SessionPage.parse(url) != nil else { return local.count == 1 ? local[0] : nil }
            return Self.pageProject(url, in: projects)
        default: return local.count == 1 ? local[0] : nil
        }
    }

    /// The local project a GitHub PR or Jira ticket page belongs to, or nil for any other page.
    static func pageProject(_ url: String, in projects: [Project]) -> Project? {
        guard let page = SessionPage.parse(url) else { return nil }
        let local = projects.filter { !$0.workspace.isEmpty }
        if page.kind == "github" {
            let path = URL(string: page.url)?.path.split(separator: "/").prefix(2).joined(separator: "/").lowercased()
            return local.first { !$0.repo.isEmpty && $0.repo.lowercased() == path }
        }
        let prefix = page.key.split(separator: "-").first.map(String.init) ?? ""
        return local.first { project in
            (project.jiraProjectKey ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).uppercased() == prefix }
        }
    }

    private var canStartSession: Bool {
        connection == "Connected" && coordinator.canPresent && pageWorkflowRuns[viewer.activeContextID ?? ""]?.running != true
            && !(selection.tabID.flatMap(tabURL).map(startingPages.contains) ?? false)
    }

    /// New Session for the selection: the page in view when it is a PR or ticket, else the sheet.
    /// `agent` is the one picked from the Create Session dropdown; nil is the default.
    func newSession(agent: SessionAgent?) {
        guard canPerform(.newSession), let project = sessionProject(for: selection) else { return }
        let pageURL: String? = if case .tab(let id) = selection { tabURL(id) } else { nil }
        startSession(in: project.id, pageURL: pageURL, agent: agent)
    }

    /// New Session from where it was asked. A PR or ticket page already decides its branch, so its
    /// session is created at once (viewer.js newSession); anything else opens the sheet.
    func startSession(in projectID: String, pageURL: String?, agent: SessionAgent? = nil) {
        guard let pageURL, SessionPage.parse(pageURL) != nil else { presentNewSession(in: projectID, pageURL: pageURL, agent: agent); return }
        guard canStartSession, let operations = sessionOperations,
              let project = projects.first(where: { $0.id == projectID && !$0.workspace.isEmpty }),
              startingPages.insert(pageURL).inserted else { return }
        let context = viewer.active
        context?.error = nil
        let agent = agent ?? shell.defaultAgent
        Task {
            let outcome = await PageSessionStart.run(url: pageURL, project: project, agent: agent, operations: operations)
            // Release the page BEFORE acting: the sheet fallback checks canStartSession, which is
            // false while this page is still marked as starting.
            startingPages.remove(pageURL)
            switch outcome {
            case .created(let session): createdSession(session)
            case .needsBranch: presentNewSession(in: projectID, pageURL: pageURL, agent: agent)
            case .failed(let message): context?.error = message
            }
        }
    }

    /// The session a PR or ticket page already has: started from that page, on the ticket's key,
    /// or on the PR's head branch in its project.
    static func pageSession(for request: OpenPageRequest, sessions: [WorkspaceSession], projects: [Project],
                            pullRequests: [SessionResolver.PullRequest] = []) -> WorkspaceSession? {
        guard let page = SessionPage.parse(request.url) else { return nil }
        // Only in the row's project: two projects can track one repository.
        let projectID = pageSessionProject(for: request, in: projects)?.id
        return SessionResolver.resolve(request, page: page, projectID: projectID, sessions: sessions, pullRequests: pullRequests)
    }

    /// The open PRs the resolver ties sessions and tickets together with.
    /// Rebuilt when the dashboard snapshot changes: rows ask for their mark on every render.
    private var resolverPullRequests: [SessionResolver.PullRequest] {
        if let cached = cachedResolverPullRequests { return cached }
        let built = SessionResolver.pullRequests(dashboard?.prs.projects ?? [])
        cachedResolverPullRequests = built
        return built
    }
    @ObservationIgnored private var cachedResolverPullRequests: [SessionResolver.PullRequest]?

    /// The row's own project when it names one — a JQL project lists tickets no key prefix
    /// would find — else the project the page belongs to.
    static func pageSessionProject(for request: OpenPageRequest, in projects: [Project]) -> Project? {
        if let id = request.projectID { return projects.first { $0.id == id && !$0.workspace.isEmpty } }
        return pageProject(request.url, in: projects)
    }

    /// The session a list row's page already has — what its badge and menu title show.
    func pageSessionMark(_ request: OpenPageRequest) -> PageSessionMark? {
        Self.pageSession(for: request, sessions: sessions, projects: projects, pullRequests: resolverPullRequests).map(PageSessionMark.init)
    }

    /// Open in Session from a list row: go to the page's session, or start one as its page would.
    func openPageSession(_ request: OpenPageRequest) async throws {
        if let session = Self.pageSession(for: request, sessions: sessions, projects: projects, pullRequests: resolverPullRequests) {
            select(.session(session.id)); return
        }
        guard SessionPage.parse(request.url) != nil, let project = Self.pageSessionProject(for: request, in: projects) else {
            throw BackendError.operation("No project with a workspace matches this page.")
        }
        // One start at a time: a second row asked meanwhile would create and select a session too.
        guard canStartSession, let operations = sessionOperations, startingPages.isEmpty else {
            throw BackendError.operation("A session cannot be started right now.")
        }
        startingPages.insert(request.url)
        // Its own task, as in startSession: the row's action is cancelled by any navigation, and a
        // create cancelled between the worktree and its record would leave a checkout with no session.
        let agent = request.agent ?? shell.defaultAgent
        let jiraKey = request.jiraKeys.first ?? ""
        let outcome = await Task { await PageSessionStart.run(url: request.url, project: project, agent: agent, jiraKey: jiraKey, operations: operations) }.value
        startingPages.remove(request.url)
        switch outcome {
        case .created(let session): createdSession(session)
        case .needsBranch: presentNewSession(in: project.id, pageURL: request.url, agent: agent)
        case .failed(let message): throw BackendError.operation(message)
        }
    }

    /// Present New Session for `project`. `pageURL` is the page it was asked from, if any.
    func presentNewSession(in projectID: String, pageURL: String?, agent: SessionAgent? = nil) {
        guard canStartSession, let project = projects.first(where: { $0.id == projectID && !$0.workspace.isEmpty }) else { return }
        coordinator.presentNewSession(request: .init(project: project, agent: agent ?? shell.defaultAgent, pageURL: pageURL),
                                      operations: sessionOperations, didCreate: { [weak self] in self?.createdSession($0) })
    }

    public func canPerform(_ command: ShellCommand) -> Bool {
        switch command {
        case .newProject: connection == "Connected" && coordinator.canPresent
        // ⌘T follows the panel in view, as `newBrowserTab` does: a file tab from Files, and a web
        // tab from anywhere else — which a panel holding one page has nowhere to put.
        case .newTab: coordinator.canPresent && viewer.active.map { $0.pane == .files || !$0.holdsOnePage } == true
        case .newSidebarTab: coordinator.canPresent
        case .newSession: canStartSession && sessionProject(for: selection) != nil
        case .back: coordinator.canPresent && viewer.active?.activePage?.controls.canGoBack == true
        case .forward: coordinator.canPresent && viewer.active?.activePage?.controls.canGoForward == true
        case .openFile: viewer.active != nil && connection == "Connected" && coordinator.canPresent
        case .saveFile: viewer.active?.activeDocument?.loaded == true && viewer.active?.activeDocument?.readOnly == false
        case .findPage: activeHistory != nil || hasActivePage
        case .zoomIn, .zoomOut, .resetZoom: coordinator.canPresent && viewer.active?.activePage?.controls.active == true
        case .nextPage, .previousPage: (viewer.active?.modeTabs.count ?? 0) > 1
        case .biggerFont, .smallerFont, .resetFont: fontTarget != nil || canPerform(.zoomIn)
        case .reloadPage: canPerform(.zoomIn)
        case .nextModel, .previousModel: coordinator.canPresent && coordinator.activeWorkspaceModel?.canCycleAgentPreset == true
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            (viewer.active?.modeTabs.count ?? 0) > (command == .tab9 ? 0 : command.tabIndex ?? 0)
        case .refresh: connection == "Connected"
        case .runProject: coordinator.activeWorkspaceModel.map { $0.canRun && $0.build?.running != true } ?? false
        case .stopBuild: coordinator.canPresent && coordinator.activeWorkspaceModel?.build?.running == true
        default: true
        }
    }

    public func perform(_ command: ShellCommand) {
        if [.overview, .terminal].contains(command) { coordinator.discardQueuedDeepLink() }
        // ⌘+ / ⌘− / ⌘0 zoom the web page when that is what has focus, or is all there is to zoom.
        if let zoom = pageZoom(for: command) { return perform(zoom) }
        switch command {
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            guard canPerform(command), let context = viewer.active, let index = command.tabIndex else { return }
            context.select(command == .tab9 ? context.modeTabs[context.modeTabs.count - 1] : context.modeTabs[index])
        case .nextModel, .previousModel:
            if canPerform(command) { coordinator.activeWorkspaceModel?.cycleAgentPreset(command == .nextModel ? 1 : -1) }
        case .reloadPage: if canPerform(.reloadPage) { viewer.active?.activePage?.controls.reload() }
        case .newProject:
            guard canPerform(.newProject), let api else { return }
            coordinator.presentNewProject(service: backendFactory.projects(api: api), didSave: { [weak self] in self?.savedProject($0) })
        case .newSession: newSession(agent: nil)
        case .newTab: if canPerform(.newTab) { newBrowserTab() }
        case .newSidebarTab: if canPerform(.newSidebarTab) { newTab() }
        case .runProject: if canPerform(.runProject) { coordinator.activeWorkspaceModel?.run() }
        case .stopBuild: if canPerform(.stopBuild), let model = coordinator.activeWorkspaceModel { Task { await model.stopBuild() } }
        case .openFile: if canPerform(.openFile), let context = viewer.active { performWorkspaceOperation(.openFile, in: context) }
        case .saveFile: if let document = viewer.active?.activeDocument { Task { await document.save() } }
        case .closePage: if let context = viewer.active, let id = context.activeID, let tab = context.tab(id) { context.close(tab) }
        case .findPage:
            if let history = activeHistory { history.find() }
            else if let document = viewer.active?.activeDocument { document.find() }
            else { viewer.active?.findVisible = true }
        case .back: viewer.active?.activePage?.controls.back()
        case .forward: viewer.active?.activePage?.controls.forward()
        case .nextPage: viewer.active?.cycle(1)
        case .previousPage: viewer.active?.cycle(-1)
        case .zoomIn: viewer.active?.activePage?.controls.zoom(0.1)
        case .zoomOut: viewer.active?.activePage?.controls.zoom(-0.1)
        case .resetZoom: viewer.active?.activePage?.controls.zoom(nil)
        case .overview: select(.overview)
        case .activity: coordinator.presentActivity()
        case .settings: presentSettings()
        case .terminal:
            if activeTerminalKey == nil { select(.terminal) }
            openTerminal()
            viewer.active?.present()
            terminal?.surface.requestFocus()
        case .refresh: refresh()
        case .biggerFont: if let kind = fontTarget { shell.setFont(kind, size: shell.font(kind).size + 1) }
        case .smallerFont: if let kind = fontTarget { shell.setFont(kind, size: shell.font(kind).size - 1) }
        case .resetFont: if let kind = fontTarget { shell.setFont(kind, size: kind.defaultSize) }
        default: break
        }
    }

    private func pageZoom(for command: ShellCommand) -> ShellCommand? {
        let zoom: ShellCommand? = switch command {
        case .biggerFont: .zoomIn
        case .smallerFont: .zoomOut
        case .resetFont: .resetZoom
        default: nil
        }
        guard let zoom, canPerform(zoom), viewer.active?.pane != .diff, fontTarget == nil || webPageFocused else { return nil }
        return zoom
    }

    private var webPageFocused: Bool {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    /// Which font size ⌘+ / ⌘− / ⌘0 move. While a Settings tab that shows a size slider is up,
    /// the keys drive that slider so the change is visible where it was asked for.
    private var fontTarget: CodeFontKind? {
        if coordinator.settingsFocused && settings?.section == .editor { return .diff }
        if coordinator.settingsFocused && settings?.section == .terminal { return .term }
        if let context = viewer.active {
            if context.pane == .diff { return .diff }
            let hasTerminal = context.id == "scratch" || sessions.contains { "task:\($0.id)" == context.id }
            if context.activeDocument != nil && (!hasTerminal || context.pane == .files) { return .diff }
        }
        return terminal?.ready == true ? .term : nil
    }

    /// Cmd-T: a blank tab in the browser panel of the workspace on screen, as in Safari's window in
    /// front. A session panel showing something else switches to Browser first. Never a sidebar tab.
    func newBrowserTab() {
        guard coordinator.canPresent, let context = viewer.active else { return }
        // Cmd-T follows the panel in view: a file tab from Files, a web tab from anywhere else.
        if context.pane == .files { context.newFileTab(); return }
        if context.pane != .term { context.setPane(.term) }
        context.openBlankPage()
    }

    /// The Tabs heading's "+" and ⌥⌘T: a new draft at the end of Tabs, selected, with a blank page
    /// whose address field takes focus. Entering an address commits it as a saved tab.
    func newTab() {
        guard coordinator.canPresent else { return }
        let draft = SavedTab(id: UUID().uuidString, kind: "web", title: "New Tab", url: "")
        draftTabs.append(draft)
        select(.tab(draft.id))
    }

    /// A draft's page reached a real address: save it as a tab under the same id, so the
    /// live context and its web view stay where they are.
    private func commitDraftTab(_ context: WorkspaceContext) {
        guard let draft = draftTabs.first(where: { "tab:\($0.id)" == context.id }),
              let page = context.activePage, let address = safeWebURL(page.url)?.absoluteString,
              let api else { return }
        let request = OpenPageRequest(id: draft.id, url: address, kind: "web",
                                      title: page.title.isEmpty ? (URL(string: address)?.host ?? address) : page.title)
        guard committingDrafts.insert(draft.id).inserted else { return }
        Task {
            defer { committingDrafts.remove(draft.id) }
            do {
                let saved: SavedTabs = try await api.request(Routes.TABS, method: "POST", body: request)
                // The draft stays listed until the saved tab can take its place, so the sidebar
                // row and the selection never blink out between the two.
                draftTabs.removeAll { $0.id == draft.id }
                tabs = saved.tabs
            } catch {
                self.error = "Could not save \(address): \(error.localizedDescription)"
            }
        }
    }

    /// The page in a saved tab has a title now, or a new one: the sidebar follows the page.
    /// Renames touch one row, so a concurrent open or close is never overwritten.
    private func syncTabTitle(_ context: WorkspaceContext) {
        guard let index = tabs.firstIndex(where: { "tab:\($0.id)" == context.id }), let page = context.activePage,
              !page.title.isEmpty, page.title != tabs[index].title, safeWebURL(page.url) != nil, let api else { return }
        let id = tabs[index].id, title = page.title
        tabs[index].title = title
        Task {
            do { let saved: SavedTabs = try await api.request(Routes.TABS, method: "PATCH", body: ["id": id, "title": title]); tabs = saved.tabs }
            catch { self.error = "Could not save tab title: \(error.localizedDescription)" }
        }
    }

    /// Reorders the Tabs list. Saved tabs persist their order through the backend; drafts
    /// only exist locally and always follow the saved ones.
    func moveTab(_ id: String, before: String?) {
        guard id != before else { return }
        // Reorder the list as the sidebar shows it, then split it back: saved tabs keep
        // their relative order, drafts keep theirs and stay after the saved ones.
        guard let shown = Self.reordered(visibleTabs, moving: id, before: before) else { return }
        let previous = tabs.map(\.id)
        draftTabs = shown.filter { isDraftTab($0.id) }
        tabs = shown.filter { !isDraftTab($0.id) }
        guard let api, tabs.map(\.id) != previous else { return }
        let order = tabs.map(\.id)
        tabOrderGeneration += 1
        let generation = tabOrderGeneration
        Task {
            do {
                let saved: SavedTabs = try await api.request(Routes.TABS, method: "PATCH", body: ["order": order])
                // A newer drag owns the list now; its own response will land.
                if generation == tabOrderGeneration { tabs = saved.tabs }
            } catch {
                // Tabs may have been opened, renamed or closed meanwhile: restore only the
                // old relative order of whatever is listed now, never an old snapshot.
                if generation == tabOrderGeneration { tabs = Self.ordered(tabs, by: previous) }
                self.error = "Could not save tab order: \(error.localizedDescription)"
            }
        }
    }
    /// Counts reorders so a stale PATCH response cannot undo a newer drag.
    private var tabOrderGeneration = 0

    /// Reorders the Projects list: `id` lands before `before`, or last when nil. The order is
    /// the sidebar's own arrangement, kept by the app; the backend is not told.
    func moveProject(_ id: String, before: String?) {
        let shown = SidebarEntry.displayOrder(projects, dragged: sidebarOrder.projects)
        guard id != before, let moved = Self.reordered(shown, moving: id, before: before) else { return }
        sidebarOrder.projects = moved.map(\.id)
    }

    /// Reorders the Pinned section: `id` lands before `before`, or last when nil.
    func movePinned(_ id: String, before: String?) {
        let shown = SidebarEntry.displayOrder(sessions.filter(\.pinned), dragged: sidebarOrder.pinned)
        guard id != before, let moved = Self.reordered(shown, moving: id, before: before) else { return }
        sidebarOrder.pinned = moved.map(\.id)
    }

    /// Reorders a project's sessions: `id` lands before its sibling `before`, or last in its
    /// project when nil. A session never leaves its project by dragging.
    func moveSession(_ id: String, before: String?) {
        guard let moved = Self.reordered(SidebarEntry.displayOrder(sessions, dragged: sidebarOrder.sessions),
                                         movingSession: id, before: before) else { return }
        sidebarOrder.sessions = moved.map(\.id)
    }
    /// `shown` — sessions in sidebar order — with `id` moved before `before` among its project's
    /// sessions. Nil when nothing would change or the two belong to different projects.
    static func reordered(_ shown: [WorkspaceSession], movingSession id: String, before: String?) -> [WorkspaceSession]? {
        guard id != before, let moving = shown.first(where: { $0.id == id }) else { return nil }
        if let before, shown.first(where: { $0.id == before })?.projectId != moving.projectId { return nil }
        let siblings = shown.filter { $0.projectId == moving.projectId }
        guard var queue = reordered(siblings, moving: id, before: before).map(ArraySlice.init),
              queue.map(\.id) != siblings.map(\.id) else { return nil }
        // Siblings trade places among their own slots, so other projects' sessions keep theirs.
        return shown.map { $0.projectId == moving.projectId ? queue.removeFirst() : $0 }
    }
    /// `shown` with `id` moved in front of `before`, or to the end when `before` is nil or
    /// unknown. Nil when `id` is not listed.
    static func reordered<Row: Identifiable>(_ shown: [Row], moving id: String, before: String?) -> [Row]? where Row.ID == String {
        var shown = shown
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return nil }
        let moving = shown.remove(at: index)
        let target = before.flatMap { b in shown.firstIndex { $0.id == b } } ?? shown.count
        shown.insert(moving, at: target)
        return shown
    }
    /// `tabs` in the relative order `ids` gives; tabs `ids` does not know keep their place at the end.
    static func ordered(_ tabs: [SavedTab], by ids: [String]) -> [SavedTab] {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return tabs.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.id] ?? Int.max, r = rank[rhs.element.id] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// A Today-popover row: its PR opens by link; a ticket by its key on the configured Jira site.
    func openActivityEntry(_ entry: LogEntry) async throws {
        if let link = entry.link {
            try await openPage(OpenPageRequest(url: link, kind: "github", title: entry.title)); return
        }
        guard let key = entry.jiraKey, let api else { throw BackendError.operation("Connect before opening a page.") }
        let site: JiraSite = try await api.get(Routes.JIRA_SITE, timeout: 30)
        guard let base = safeWebURL(site.baseUrl) else { throw BackendError.operation("Configure the Jira site to open ticket links.") }
        try await openPage(OpenPageRequest(url: base.appendingPathComponent("browse").appendingPathComponent(key).absoluteString,
                                           kind: "jira", title: key))
    }

    func openPage(_ request: OpenPageRequest) async throws {
        try Task.checkCancellation()
        guard safeWebURL(request.url) != nil else { throw BackendError.operation("Invalid page address.") }
        if request.inSession { try await openPageSession(request); return }
        // A page that already has a session — its own, or one on its branch or ticket key — goes
        // there; only a page with none opens a tab. Open in Tab asked for the tab regardless.
        if !request.inTab, let session = Self.pageSession(for: request, sessions: sessions, projects: projects, pullRequests: resolverPullRequests) {
            select(.session(session.id))
            viewer.active?.open(request.url, title: request.title)
            return
        }
        guard let api else { throw BackendError.operation("Connect before opening a page.") }
        let saved: SavedTabs = try await api.request(Routes.TABS, method: "POST", body: request)
        try Task.checkCancellation()
        tabs = saved.tabs
        // A background tab loads when it is selected; the row's screen stays where it was.
        guard let id = saved.active, !request.inTab else { return }
        select(.tab(id))
        viewer.active?.open(request.url, title: request.title)
    }

    public func makeTray(openWindow: @escaping () -> Void, dismiss: @escaping () -> Void,
                         quit: @escaping () -> Void = {}) -> TrayCoordinator {
        coordinator.makeTray(factory: trayFactory, runtime: self, shell: shell,
                             presentation: TrayPresentation(openWindow: openWindow, dismiss: dismiss, quit: quit))
    }

    func select(_ destination: SidebarDestination) {
        coordinator.navigate(to: destination)
    }

    func activateRootDestination() {
        showSelectedContext()
        // A switch hides the session it leaves, which the pool may now stop.
        sessionPool.trim()
    }
    func openRootBrowser(_ url: URL) { _ = desktop.openBrowser(url) }
    /// For the area extensions: `desktop` is private to this file.
    func openInBrowser(_ url: URL) -> Bool { desktop.openBrowser(url) }
    /// For the area extensions: `error` is only settable from this file.
    func reportRootError(_ message: String) { error = message }

    private func showSelectedContext() {
        switch selection {
        case .project(let id):
            viewer.deactivate()
            if let project = projects.first(where: { $0.id == id }), let api {
                let services = backendFactory.projectServices(api: api)
                coordinator.prepareProject(project, services: services, factory: projectFactory, runtime: self, openPage: { [weak self] request in
                    guard let self else { throw BackendError.operation("The workspace has closed.") }
                    try await self.openPage(request)
                }, session: { [weak self] request in self?.pageSessionMark(request) })
            }
        case .session(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                sessionPool.shown(id)
                let context = viewer.select(id: "task:\(id)", url: session.url, title: session.title, legacy: tabs.first { $0.url == session.url && !$0.standalone })
                _ = workflowRunModel(for: session)
                warmIDE(for: session)
                buildModel(for: session, context: context)?.warmDestinations()
                openTerminal()
            } else { viewer.deactivate() }
        case .terminal:
            viewer.select(id: "scratch", url: "", title: "Terminal")
        case .tab(let id):
            let tab = visibleTabs.first { $0.id == id }
            let context = viewer.select(id: "tab:\(id)", url: tab?.url ?? "", title: tab?.title ?? "New Tab", legacy: tabs.first { $0.id == id })
            // A draft has no address to load; it starts as one blank page with the address field focused.
            if isDraftTab(id), context.pages.isEmpty { context.openBlankPage() }
            preparePageWorkflowModel(context)
        default: viewer.deactivate()
        }
    }

    func openTerminal() {
        guard let key = activeTerminalKey, terminals[key] == nil else { return }
        if case .session(let id) = selection, let record = sessions.first(where: { $0.id == id }) {
            guard !changingSessions.contains(id) else { return }
            terminals[key] = makeTerminal(record)
        } else if selection == .terminal {
            let terminal = platformFactory.terminal(.init(key: "native-terminal-spike", directory: platformFactory.homeDirectory, paired: false))
            wireLinks(terminal, contextID: "scratch")
            terminals[key] = terminal
        }
    }

    private func workflowRunModel(for record: WorkspaceSession) -> WorkflowRunViewModel? {
        guard let api, let project = projects.first(where: { $0.id == record.projectId }) else { return nil }
        if let existing = workflowRuns[record.id] { existing.update(project.workflows ?? []); return existing }
        let model = backendFactory.workflowRun(api: api, recipes: project.workflows ?? [], context: { [weak self] in
            let latest = self?.sessions.first { $0.id == record.id } ?? record
            let project = self?.projects.first { $0.id == record.projectId } ?? project
            return WorkflowRunContext.values(project: project, session: latest)
        }, prepare: { [weak self] cli in
            guard let self else { throw BackendError.operation("The workspace closed.") }
            return try await prepareWorkflowTerminal(sessionID: record.id, cli: cli)
        })
        workflowRuns[record.id] = model
        return model
    }

    private func adoptProjectDestinations() {
        for (contextID, model) in buildModels {
            guard let session = sessions.first(where: { "task:\($0.id)" == contextID }),
                  let project = projects.first(where: { $0.id == session.projectId }) else { continue }
            model.adopt(project)
        }
    }

    func workflowModel(in context: WorkspaceContext) -> WorkflowRunViewModel? {
        if let record = sessions.first(where: { "task:\($0.id)" == context.id }) { return workflowRuns[record.id] }
        return pageWorkflowRuns[context.id]
    }

    private func preparePageWorkflowModel(_ context: WorkspaceContext) {
        guard let api, let target = WorkflowPageTarget.resolve(url: context.sourceURL, projects: projects),
              let project = projects.first(where: { $0.id == target.projectID }) else {
            if pageWorkflowRuns[context.id]?.running != true {
                pageWorkflowRuns.removeValue(forKey: context.id); pageWorkflowTargets.removeValue(forKey: context.id)
            }
            return
        }
        if let model = pageWorkflowRuns[context.id], pageWorkflowTargets[context.id] == target || model.running {
            if pageWorkflowTargets[context.id] == target { model.update(project.workflows ?? []) }
            return
        }
        let sourceID = context.id
        var preparedSession: WorkspaceSession?
        let service = backendFactory.workflowPreparation(api: api)
        let model = backendFactory.workflowRun(api: api, recipes: project.workflows ?? [], context: { [weak self] in
            guard let preparedSession else { return [:] }
            let latest = self?.sessions.first { $0.id == preparedSession.id } ?? preparedSession
            let project = self?.projects.first { $0.id == target.projectID } ?? project
            return WorkflowRunContext.values(project: project, session: latest)
        }, prepare: { [weak self] cli in
            guard let self else { throw BackendError.operation("The workspace closed.") }
            if let preparedSession {
                return try await prepareWorkflowTerminal(sessionID: preparedSession.id, cli: cli)
            }
            let record = try await prepareWorkflowPage(target, sourceID: sourceID, service: service)
            preparedSession = record
            try Task.checkCancellation()
            return try await prepareWorkflowTerminal(sessionID: record.id, cli: cli)
        })
        pageWorkflowRuns[sourceID] = model
        pageWorkflowTargets[sourceID] = target
    }

    private func prepareWorkflowPage(_ target: WorkflowPageTarget, sourceID: String,
                                     service: any WorkflowPagePreparing) async throws -> WorkspaceSession {
        guard let project = projects.first(where: { $0.id == target.projectID }),
              WorkflowPageTarget.resolve(url: target.page.url, projects: projects) == target,
              let model = pageWorkflowRuns[sourceID],
              preparingWorkflowPages.insert(target.identity).inserted else {
            throw BackendError.operation("The page's project changed or another workflow is preparing this page.")
        }
        defer { preparingWorkflowPages.remove(target.identity) }
        let record: WorkspaceSession
        if let existing = sessions.first(where: target.matches) {
            guard workflowRuns[existing.id]?.running != true, !changingSessions.contains(existing.id) else {
                throw BackendError.operation("This page already has an active session operation. Open its session to continue.")
            }
            record = existing
        } else {
            record = try await service.prepare(target, project: project)
        }
        // Once creation succeeds, retain the durable result even when Stop raced
        // the HTTP response. Cancellation is checked before any agent startup.
        if !sessions.contains(where: { $0.id == record.id }) { sessions.append(record) }
        let destination = "task:\(record.id)"
        let wasSelected = sourceID.hasPrefix("tab:") && selection == .tab(String(sourceID.dropFirst("tab:".count)))
        try viewer.promoteContext(from: sourceID, to: destination)
        await adoptTab(sourceID)
        pageWorkflowRuns.removeValue(forKey: sourceID)
        pageWorkflowTargets.removeValue(forKey: sourceID)
        workflowRuns[record.id] = model
        if wasSelected { select(.session(record.id)) }
        refresh()
        return record
    }

    /// The tab a session was just started from is the session's own now. A standalone tab (Open in
    /// Tab beside a session) would otherwise keep its row next to the session's under the same page.
    /// Awaited by the caller ahead of its refresh, so the two writes to `tabs` cannot cross.
    private func adoptTab(_ sourceID: String) async {
        guard sourceID.hasPrefix("tab:") else { return }
        let id = String(sourceID.dropFirst("tab:".count))
        guard let api, let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].standalone else { return }
        tabs[index].standalone = false
        struct Payload: Encodable { let id: String; let standalone: Bool }
        do { let saved: SavedTabs = try await api.request(Routes.TABS, method: "PATCH", body: Payload(id: id, standalone: false)); tabs = saved.tabs }
        catch { /* The refresh that follows restores the list from the backend. */ }
    }

    func openWorkflowHookSettings() {
        settings?.section = .clis; presentSettings()
    }

    private func prepareWorkflowTerminal(sessionID: String, cli: WorkflowCLI) async throws -> any WorkflowTerminal {
        guard let operations = sessionOperations, var record = sessions.first(where: { $0.id == sessionID }),
              !record.worktree.isEmpty, changingSessions.insert(sessionID).inserted else {
            throw BackendError.operation("The session is unavailable or another session operation is in progress.")
        }
        defer { changingSessions.remove(sessionID) }
        let key = "task:\(sessionID)"
        if let existing = terminals[key] {
            try await existing.waitForAutomaticLaunch()
            guard let latest = sessions.first(where: { $0.id == sessionID }) else {
                throw BackendError.operation("The session was removed during agent startup.")
            }
            record = latest
            if try await !existing.atShell(), record.cli != cli.rawValue {
                throw BackendError.operation("Another agent is running. Return to the shell before switching to \(cli.title).")
            }
        }
        try Task.checkCancellation()
        record = try await operations.configureAgent(cli, session: record)
        if let index = sessions.firstIndex(where: { $0.id == record.id }) { sessions[index] = record }
        try Task.checkCancellation()
        let terminal: TerminalSession
        if let existing = terminals[key] { terminal = existing }
        else { terminal = makeTerminal(record); terminals[key] = terminal }
        // Retained native panes mount the new surface even if navigation changes.
        await terminal.start()
        try await terminal.waitForAutomaticLaunch()
        if try await terminal.atShell() {
            try await launchAgent(terminal, record: record, fresh: false)
        }
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        let latest = sessions.first { $0.id == sessionID } ?? record
        return try await platformFactory.workflowTerminal(terminal, cli: cli, sessionID: latest.sessionId)
    }

    func removalModel(for record: WorkspaceSession) -> SessionRemovalViewModel? {
        guard let api else { return nil }
        let operationID = UUID()
        let service = backendFactory.removal(api: api, stopTerminals: { [weak self] keys in
            guard let self else { throw BackendError.operation("The workspace closed before removal.") }
            try await self.stopForRemoval(keys, operationID: operationID)
        })
        return workspaceFactory.removal(service: service, record: record, projects: projects, sessions: sessions,
            didRemove: { [weak self] removed in
                guard let self else { return }
                for record in removed {
                    let key = "task:\(record.id)"
                    buildModels.removeValue(forKey: key)?.disconnect()
                    diffModels.removeValue(forKey: key)?.disconnect()
                    historyModels.removeValue(forKey: key)?.hide()
                    terminals.removeValue(forKey: "build:\(record.url)")?.disconnect()
                    terminals.removeValue(forKey: key)?.disconnect()
                    await viewer.remove(id: key)
                }
                sessions.removeAll { record in removed.contains { $0.id == record.id } }
                refresh()
            }, finished: { [weak self] in
                guard let self else { return }
                if let ids = removalLocks.removeValue(forKey: operationID) { changingSessions.subtract(ids) }
                // Removal stops the terminal before it deletes anything. A failed removal leaves the
                // session alive with no shell, so give it one back rather than an endless spinner.
                openTerminal()
                refresh()
            })
    }

    func buildModel(for record: WorkspaceSession, context: WorkspaceContext) -> BuildWorkspaceViewModel? {
        let project = projects.first { $0.id == record.projectId }
        if let existing = buildModels[context.id] { if let project { existing.adopt(project) }; return existing }
        guard let api, let project, project.ide == "xcode" else { return nil }
        // The build drives its shell with no view; the session under the same pair key is only
        // the log popover's viewer, and adopts that shell when it is opened.
        var shell: DetachedShell?
        let model = workspaceFactory.build(api: api, project: project, session: record, terminalFactory: { [weak self] in
            guard let self else { throw BackendError.operation("The workspace closed before the build could start.") }
            let request = AppTerminalRequest(key: "build:\(record.url)", directory: record.worktree, paired: true)
            if terminals[request.key] == nil {
                let viewer = platformFactory.terminal(request)
                wireLinks(viewer, contextID: context.id)
                terminals[request.key] = viewer
            }
            if let shell { return shell }
            let created = platformFactory.detachedShell(request)
            created.grid = DetachedShell.grid(fitting: BuildLog.size, font: self.shell.terminalStyle.font)
            shell = created
            return created
        })
        model.onSimulatorRun = { [weak context] in context?.setPane(.simulator) }
        buildModels[context.id] = model
        // Its Simulator panel streams only while the workspace says it is on screen.
        context.workspaceViewModel?.documentStateChanged()
        return model
    }

    /// Whether a removal is under way for this session. The pane tells that from a terminal that
    /// is merely still opening, which looks the same: a session with no terminal.
    func isRemoving(_ sessionID: String) -> Bool {
        removalLocks.values.contains { $0.contains(sessionID) }
    }

    private func stopForRemoval(_ keys: Set<String>, operationID: UUID) async throws {
        let ids = Set(sessions.filter { keys.contains($0.id) }.map(\.id))
        guard changingSessions.isDisjoint(with: ids) else { throw BackendError.operation("A session operation is already in progress.") }
        changingSessions.formUnion(ids)
        removalLocks[operationID] = ids
        let worktrees = sessions.filter { ids.contains($0.id) }.map(\.worktree)
        guard !diffModels.values.contains(where: { model in
            worktrees.contains(model.worktree) && model.actions?.busy == true
        }) else {
            changingSessions.subtract(ids); removalLocks.removeValue(forKey: operationID)
            throw BackendError.operation("Wait for the Git operation to finish before removing this worktree.")
        }
        guard await viewer.closeDocuments(contextIDs: Set(ids.map { "task:\($0)" }), worktrees: worktrees) else {
            changingSessions.subtract(ids); removalLocks.removeValue(forKey: operationID)
            throw CancellationError()
        }
        for id in ids {
            await workflowRuns.removeValue(forKey: id)?.stop()
            workspaceLaunch.cancel(sessionID: id)
            buildModels.removeValue(forKey: "task:\(id)")?.disconnect()
        }
        for (key, terminal) in terminals where keys.contains(terminal.pairKey) {
            await terminal.stopConnecting()
            if terminals[key] === terminal { terminals.removeValue(forKey: key) }
        }
        try await terminalControl.stopPaired(keys: keys)
    }

    private func makeTerminal(_ record: WorkspaceSession, fresh: Bool = false) -> TerminalSession {
        let terminal = platformFactory.terminal(.init(key: record.id, directory: record.worktree, paired: true))
        sessionPool.started(record.id)
        terminal.agentTurns.setStreamAvailable(connection == "Connected")
        wireLinks(terminal, contextID: "task:\(record.id)")
        terminal.onCreated = { [weak self] terminal in
            guard let self else { return }
            try await launchAgent(terminal, record: record, fresh: fresh)
        }
        return terminal
    }

    private func launchAgent(_ terminal: TerminalSession, record: WorkspaceSession, fresh: Bool) async throws {
        let latest = self.sessions.first { $0.id == record.id } ?? record
        let agent = latest.agent
        var id = latest.sessionId
        var firstLaunch = fresh
        if agent == .claude && (id == nil || id == "") {
            guard let operations = self.sessionOperations else { throw BackendError.operation("Connect before starting the agent.") }
            let newID = UUID().uuidString.lowercased()
            try await operations.saveAgentID(newID, session: latest)
            id = newID; firstLaunch = true
            if let index = self.sessions.firstIndex(where: { $0.id == latest.id }) { self.sessions[index].sessionId = newID }
        } else if agent == .claude, !firstLaunch, let id, let operations = self.sessionOperations,
                  (try? await operations.conversationExists(cli: agent.rawValue, id: id)) == false {
            // The id was reserved at a launch that never sent a prompt, so nothing is on disk
            // under it and `--resume` would fail hard. Reserving it again starts it for real.
            firstLaunch = true
        }
        // Claude Code reports its real context window only to its status line, so the app's
        // wrapper rides along on the sessions it launches.
        let script = Bundle.main.url(forResource: "craft-statusline", withExtension: "sh")
            ?? Bundle.main.url(forResource: "craft-statusline", withExtension: "sh", subdirectory: "AgentStatusLine")
        let statusLine = script.map { AgentStatusLine(script: $0.path, taskID: latest.id) }
        if let command = agent.command(sessionID: id, fresh: firstLaunch, statusLine: statusLine) {
            try await enterAgent(terminal, command: command, cli: agent.rawValue)
            watchLaunch(terminal, agent: agent, resuming: !firstLaunch && !(id ?? "").isEmpty)
        }
    }

    /// A launch the CLI refuses ends at the shell, which otherwise looks like a session that
    /// simply never started: a resume it cannot find, or an id it says is already in use. Both
    /// are caught, the one that flashed past and the one that never took the foreground at all.
    /// The stored id is kept; this reports that something is wrong, it does not abandon it.
    private func watchLaunch(_ terminal: TerminalSession, agent: SessionAgent, resuming: Bool) {
        var seen = terminal.launchedAgentForeground != nil
        Task { [weak self, weak terminal] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let terminal, let atShell = try? await terminal.atShell() else { return }
                if !atShell { seen = true } else if seen { break }
            }
            guard let terminal, (try? await terminal.atShell()) == true else { return }
            // Quitting the agent within the window reads the same, so this does not claim a failure.
            self?.error = "\(agent.label) went back to the shell right after \(resuming ? "resuming its conversation" : "starting"). If you did not quit it, check the terminal for its reason."
        }
    }

    /// Runs an agent's launch line at the shell and notes what came to the foreground, which is
    /// how a workflow step later tells the agent it launched from one the user started.
    private func enterAgent(_ terminal: TerminalSession, command: String, cli: String) async throws {
        try await terminal.submit(command)
        terminal.launchedAgent = WorkflowCLI(rawValue: cli)
        terminal.launchedAgentForeground = nil
        for _ in 0..<100 {
            let foreground = try await terminal.workflowForeground()
            if !foreground.atShell {
                terminal.launchedAgentForeground = foreground; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func wireLinks(_ terminal: TerminalSession, contextID: String) {
        terminal.openLink = { [weak self] raw, directory, _ in
            guard let self, let context = viewer.contexts[contextID] else { return }
            guard let link = WorkspaceLink.parse(raw, directory: directory, home: platformFactory.homeDirectory) else {
                context.error = "This terminal link is not a supported web or local file address."
                return
            }
            if contextID == "scratch" { select(.terminal) }
            else if let record = sessions.first(where: { "task:\($0.id)" == contextID }) { select(.session(record.id)) }
            context.error = nil
            switch link {
            case .web(let url): context.open(url.absoluteString)
            case .file(let location): context.openFile(location.path, line: location.line, column: location.column)
            }
        }
    }

    func createdSession(_ session: WorkspaceSession) {
        if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        terminals["task:\(session.id)"] = makeTerminal(session, fresh: true)
        select(.session(session.id))
        refresh()
    }

    func restartSession(_ record: WorkspaceSession) {
        guard changingSessions.insert(record.id).inserted else { return }
        Task {
            defer { changingSessions.remove(record.id) }
            do {
                let key = "task:\(record.id)"
                await workflowRuns.removeValue(forKey: record.id)?.stop()
                await terminals[key]?.stopConnecting()
                try await terminalControl.stopPaired(keys: [record.id])
                terminals[key] = makeTerminal(sessions.first { $0.id == record.id } ?? record)
            } catch { self.error = "Could not restart session: \(error.localizedDescription)" }
        }
    }

    /// A turn's hooks run as children of its agent, each in a group of its own, and are still
    /// exiting when their event lands: the pool looks once they have gone, as anything the agent
    /// still runs then is work in progress.
    private func trimAfterTurnHooks() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.sessionPool.trim()
        }
    }

    /// The sessions as the memory pool sees them.
    private func poolSessions() -> [SessionPool.Session] {
        sessions.map { record in
            .init(id: record.id, agent: record.agent != .shell, shown: selection == .session(record.id),
                  idle: !changingSessions.contains(record.id) && agentIdle(record))
        }
    }

    /// Hidden, its agent at its prompt by the agent's own hooks, and nothing else under way on it.
    private func agentIdle(_ record: WorkspaceSession) -> Bool {
        record.agent != .shell && selection != .session(record.id) && terminals["task:\(record.id)"]?.agentIdle == true
            && workflowRuns[record.id]?.running != true && !isRemoving(record.id)
    }

    /// Stops a session the pool picked, as Restart does, without starting it again: opening it
    /// does that. Only the agent Craft launched goes, still in the terminal's foreground, with
    /// nothing it started still running in a group of its own: once the user quits it, what runs
    /// there is theirs, and a job it left in the background, a dev server or a build, is work in
    /// progress. Each step can take a moment, so one opened or busy meanwhile is attached again and
    /// left running. One whose stop fails stays detached, as a stopped one does, and quietly: the
    /// user asked for nothing. Attaching it again would start its agent unseen had the stop gone
    /// through after all, and opening it attaches to whatever still runs there, or starts it.
    private func stopPooledSession(_ id: String) async -> Bool {
        let key = "task:\(id)"
        guard let terminal = terminals[key], let agent = terminal.launchedAgentForeground?.pgid,
              changingSessions.insert(id).inserted else { return false }
        func stillIdle() -> Bool { terminals[key] === terminal && sessions.first { $0.id == id }.map(agentIdle) == true }
        guard let foreground = try? await terminal.workflowForeground(), !foreground.atShell, foreground.pgid == agent,
              await processes.processGroups(of: agent) == [agent], stillIdle() else {
            changingSessions.remove(id)
            return false
        }
        await terminal.stopConnecting()
        let stopping = stillIdle()
        if stopping { try? await terminalControl.stopPaired(keys: [id]) }
        let owned = terminals[key] === terminal
        if owned { terminals.removeValue(forKey: key) }
        changingSessions.remove(id)
        if selection == .session(id) {
            // Opened meanwhile: its pane attaches to the shell left running, or starts it again.
            openTerminal()
        } else if !stopping, owned, let record = sessions.first(where: { $0.id == id }) {
            // Busy meanwhile: attached again at once, so its turn is followed.
            terminals[key] = makeTerminal(record)
        }
        return stopping
    }

    func togglePin(_ id: String) {
        guard let api, let record = sessions.first(where: { $0.id == id }), pendingPins.insert(id).inserted else { return }
        Task {
            defer { pendingPins.remove(id) }
            do {
                try await api.setPinned(!record.pinned, for: id)
                // A pin joins the end of Pinned; an unpin is forgotten, so pinning again is last again.
                let shown = SidebarEntry.displayOrder(sessions.filter(\.pinned), dragged: sidebarOrder.pinned).map(\.id)
                sidebarOrder = sidebarOrder.pinning(id, pinned: !record.pinned, shown: shown)
                if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].pinned = !record.pinned }
                refresh()
            } catch { self.error = "Could not update pin: \(error.localizedDescription)" }
        }
    }

    /// Sidebar right-click Rename Session. Only the display name changes, so the worktree,
    /// branch, agent and build settings are untouched; an empty name shows the folder again.
    /// The row updates at once and goes back if the backend refuses.
    func renameSession(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, let index = sessions.firstIndex(where: { $0.id == id }), (sessions[index].name ?? "") != name else { return }
        struct Payload: Encodable, Sendable { let name: String }
        let previous = sessions[index].name
        sessions[index].name = name
        // A reload already in flight read the row before the rename and would put the old name
        // back. Its sessions are dropped; the backend's `tasks` event reloads them once saved.
        inventoryGenerations[.sessions] = UUID()
        Task {
            do {
                let _: OperationOK = try await api.request(Routes.task(id), method: "PATCH", body: Payload(name: name))
            } catch {
                if let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].name == name { sessions[index].name = previous }
                self.error = "Could not rename session: \(error.localizedDescription)"
            }
        }
    }

    /// Pins a saved tab into the grid under Dashboard, or returns it to the Tabs list. A draft
    /// has no backend row yet, so it cannot be pinned. The flag is its own one-row PATCH, so a
    /// concurrent open or rename is never overwritten.
    func togglePinTab(_ id: String) {
        guard let api, !isDraftTab(id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        struct Payload: Encodable { let id: String; let pinned: Bool }
        let pinned = !tabs[index].pinned
        tabs[index].pinned = pinned
        tabPinGeneration += 1
        let generation = tabPinGeneration
        Task {
            do {
                let saved: SavedTabs = try await api.request(Routes.TABS, method: "PATCH", body: Payload(id: id, pinned: pinned))
                // A newer toggle owns the list now; its own response will land.
                if generation == tabPinGeneration { tabs = saved.tabs }
            } catch {
                self.error = "Could not update pin: \(error.localizedDescription)"
                refresh()
            }
        }
    }
    /// Counts pin toggles so a stale PATCH response cannot undo a newer one.
    private var tabPinGeneration = 0

    /// Closes a task-less tab: moves the selection to its neighbour first when it is the tab in
    /// view, then drops the tab from the backend and releases its pages. A tab whose workflow is
    /// still preparing stays open, since the run promotes this tab's pages into its session.
    func closeTab(_ id: String) {
        let sessionURLs = Set(sessions.map(\.url).filter { !$0.isEmpty })
        let visible = visibleTabs.filter { !$0.isOwned(by: sessionURLs) }.map(\.id)
        if let index = draftTabs.firstIndex(where: { $0.id == id }) {
            if selection == .tab(id) { select(Self.destination(closing: id, among: visible)) }
            draftTabs.remove(at: index)
            Task { await viewer.remove(id: "tab:\(id)") }
            return
        }
        guard let api, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let key = "tab:\(id)"
        if pageWorkflowRuns[key]?.running == true {
            error = "Wait for the workflow to start before closing this tab."
            return
        }
        if selection == .tab(id) { select(Self.destination(closing: id, among: visible)) }
        tabs.remove(at: index)
        pageWorkflowRuns.removeValue(forKey: key); pageWorkflowTargets.removeValue(forKey: key)
        Task {
            await viewer.remove(id: key)
            do {
                let saved: SavedTabs = try await api.request(Routes.TABS, method: "DELETE", body: ["id": id])
                tabs = saved.tabs
            } catch {
                self.error = "Could not close tab: \(error.localizedDescription)"
                refresh()
            }
        }
    }

    /// Where the selection goes when the tab in view closes: the tab now at its place in the
    /// sidebar's tab list, else the one before it, else the dashboard.
    static func destination(closing url: String, among visible: [String]) -> SidebarDestination {
        guard let index = visible.firstIndex(of: url) else { return .overview }
        let remaining = visible.filter { $0 != url }
        return remaining.isEmpty ? .overview : .tab(remaining[min(index, remaining.count - 1)])
    }

    public func quit() async throws { try await prepareToTerminate() }

    public func prepareForUpdate() async throws { try await prepareToTerminate() }

    public func cancelBrowserPresentation() { coordinator.browserDialogCoordinator.cancel() }

    private func prepareToTerminate() async throws {
        let browserDialogs = coordinator.browserDialogCoordinator
        let browserWasEnabled = browserDialogs.enabled
        let picker = viewer.fileOpenCoordinator
        let pickerWasEnabled = picker.enabled
        picker.enabled = false
        browserDialogs.enabled = false
        defer { if started { browserDialogs.enabled = browserWasEnabled; picker.enabled = pickerWasEnabled } }
        let actions = diffModels.values.compactMap(\.actions)
        for action in actions { await action.suspendAndWait() }
        defer { actions.forEach { $0.resume() } }
        guard await viewer.closeDocuments() else { throw CancellationError() }
        for model in workflowRuns.values { await model.stop() }
        for model in pageWorkflowRuns.values { await model.stop() }
        for terminal in terminals.values { await terminal.stopConnecting() }
        try await terminalControl.stopExisting()
        for terminal in terminals.values { terminal.disconnect() }
        // Simulator streams go with the shells. serve-sim cannot tell ours from a stream started in
        // a terminal, so Quit stops those too.
        if let api { await workspaceFactory.simulatorPreview(api: api).stopAll() }
        // A page visited just before quitting would otherwise miss the debounced write.
        await viewer.browserHistory.flush()
        await viewer.browserBookmarks.flush()
        await stop()
    }

    private func restoreSessionTerminals() {
        for record in sessions {
            let key = "task:\(record.id)"
            _ = viewer.restore(id: key, url: record.url, title: record.title,
                               legacy: tabs.first { $0.url == record.url && !$0.standalone })
            _ = workflowRunModel(for: record)
            // One the memory pool stopped stays stopped until it is opened.
            if terminals[key] == nil, !sessionPool.stopped.contains(record.id) { terminals[key] = makeTerminal(record) }
        }
    }

    public func start() async {
        if let shutdownTask { await shutdownTask.value }
        guard !started else { return }
        coordinator.browserDialogCoordinator.enabled = true
        viewer.fileOpenCoordinator.enabled = true
        coordinator.setRoutingReady(false)
        started = true
        let generation = UUID()
        startGeneration = generation
        backendRuntime.onEvent = { [weak self] event in
            guard let self, self.started, self.startGeneration == generation else { return }
            self.handleBackendEvent(event)
        }
        settings?.resources.connect(platformFactory.resources(api: nil))
        coordinator.settingsCoordinator?.setActive(coordinator.settingsPresented)
        do {
            let connectedAPI = try await backendRuntime.start()
            guard started, startGeneration == generation else { return }
            api = connectedAPI
            if let api { shell.connect(shellFactory.data(api: api)); viewer.connect(api); dashboard?.connect(backendFactory.dashboard(api: api)); shell.refreshUsage() }
            if let api { ideWarmup.connect(backendFactory.ideWarmup(api: api)) }
            if let api { for model in projectModels.values {
                model.connect(backendFactory.projects(api: api)); model.board?.connect(api: api)
                model.tickets?.connect(backendFactory.tickets(api: api))
                model.workflows?.connect(backendFactory.workflows(api: api))
            } }
            if let api { automation?.connect(backendFactory.automation(api: api)) }
            if let api { logs?.connect(backendFactory.logs(api: api)); todayActivity.connect(backendFactory.logs(api: api)) }
            if let api { for model in historyModels.values { model.connect(baseURL: api.baseURL, service: backendFactory.history(api: api)) } }
            if let api { for model in diffModels.values { model.connect(baseURL: api.baseURL, service: backendFactory.diff(api: api)); model.actions?.connect(backendFactory.changes(api: api)) } }
            if let api {
                settings?.connect(backendFactory.settings(api: api))
                settings?.clis.connect(backendFactory.cliSettings(api: api))
                settings?.webhooks.connect(backendFactory.automation(api: api))
                settings?.diagnostics.connect(backendFactory.diagnostics(api: api))
                settings?.resources.connect(platformFactory.resources(api: api))
                workspaceLaunch.connect(backendFactory.workspaceTargets(api: api))
                if coordinator.settingsPresented { settings?.refresh() }
                settings?.refreshCurrentSection()
                presentWelcome(firstRunOnly: true)
            }
            backendRuntime.startEvents()
        } catch {
            guard started, startGeneration == generation else { return }
            connection = "Disconnected"
            self.error = error.localizedDescription
            started = false
        }
    }

    public func refresh() {
        pendingRefreshEvents.removeAll()
        shell.refresh()
        shell.refreshUsage()
        dashboard?.reload()
        if coordinator.activityVisible { logs?.refresh() }
        if case .project(let id) = selection, let model = projectModels[id], model.section == .board {
            model.board?.refresh()
        }
        if case .project(let id) = selection, let model = projectModels[id], model.section == .tickets {
            model.tickets?.refresh()
        }
        refreshInventory([.projects, .sessions, .tabs])
    }

    private func refreshInventory(_ inventory: Set<Inventory>) {
        for item in inventory { inventoryGenerations[item] = UUID() }
        refreshPending.formUnion(inventory)
        guard refreshTask == nil, let api else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            while !refreshPending.isEmpty && !Task.isCancelled {
                let inventory = refreshPending
                refreshPending.removeAll()
                let generations = inventoryGenerations
                do {
                    async let projectRequest: [Project]? = inventory.contains(.projects) ? api.get(Routes.PROJECTS) : nil
                    async let sessionRequest: [WorkspaceSession]? = inventory.contains(.sessions) ? api.get(Routes.TASKS) : nil
                    async let tabRequest: SavedTabs? = inventory.contains(.tabs) ? api.get(Routes.TABS) : nil
                    let (snapshot, sessionSnapshot, tabSnapshot) = try await (projectRequest, sessionRequest, tabRequest)
                    try Task.checkCancellation()
                    // A newer request invalidates only its own inventory. Keep the other
                    // results, and let the pending set reload only what changed mid-flight.
                    let current = inventory.filter { generations[$0] == inventoryGenerations[$0] }
                    if current.contains(.projects), let snapshot {
                        if projects != snapshot { projects = snapshot; adoptProjectDestinations() }
                        for model in coordinator.removeMissingProjects(Set(snapshot.map(\.id))) { retireProject(model) }
                    }
                    if current.contains(.sessions), let sessionSnapshot, sessions != sessionSnapshot {
                        let retained = Set(sessionSnapshot.map(\.id))
                        for session in sessions where !retained.contains(session.id) {
                            workspaceLaunch.cancel(sessionID: session.id)
                            await workflowRuns.removeValue(forKey: session.id)?.stop()
                        }
                        sessions = sessionSnapshot
                        sessionPool.retain(retained)
                    }
                    if current.contains(.tabs), let tabSnapshot, tabs != tabSnapshot.tabs { tabs = tabSnapshot.tabs }
                    restoreSessionTerminals()
                    showSelectedContext()
                    if current.contains(.projects), case .project(let id) = selection,
                       let model = projectModels[id], model.section == .prs {
                        await model.refresh()
                    }
                    guard refreshPending.isEmpty else { continue }
                    await loadSidebar()
                    // Only sidebar-backed destinations can go stale: a project, session or tab that
                    // the inventory no longer lists. Settings, Activity and Terminal are reached from
                    // the menu and have no sidebar row, so they must never be bounced to Dashboard.
                    // Ask each entry for the destinations it presents, not for its own: a pinned tab
                    // is a tile inside the grid row and has no row of its own to match.
                    if selection.isSidebarBacked,
                       !sidebarEntries.flatMap(\.descendants).contains(where: { $0.destinations.contains(selection) }),
                       pageWorkflowRuns[viewer.activeContextID ?? ""]?.running != true { select(.overview) }
                    lastUpdate = Date()
                    error = nil
                    coordinator.setRoutingReady(started && connection == "Connected")
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription; coordinator.setRoutingReady(false) }
                }
            }
        }
    }

    /// Batch staggered project completions without postponing refresh indefinitely during a
    /// steady stream. Events received during a read get one more batch after that read finishes.
    private func queueRefresh(_ event: ServerEvent) {
        if !pendingRefreshEvents.contains(event) { pendingRefreshEvents.append(event) }
        guard eventRefreshTask == nil else { return }
        eventRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { eventRefreshTask = nil }
            while !pendingRefreshEvents.isEmpty && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let events = pendingRefreshEvents
                pendingRefreshEvents.removeAll()
                await refreshSnapshots(for: events)
            }
        }
    }

    private func refreshSnapshots(for events: [ServerEvent]) async {
        // Project edits and legacy backends do not distinguish snapshot and inventory changes.
        if events.contains(where: { $0.type == "reload" || ($0.type == "sync" && !["prs", "usage"].contains($0.scope ?? "")) }) {
            refresh()
            return
        }
        var inventory: Set<Inventory> = []
        if events.contains(where: { $0.type == "tabs" }) { inventory.insert(.tabs) }
        if events.contains(where: { $0.type == "tasks" }) { inventory.insert(.sessions) }
        if !inventory.isEmpty { refreshInventory(inventory) }
        let prs = events.filter { $0.type == "sync" && $0.scope == "prs" }
        if !prs.isEmpty { dashboard?.prs.refresh() }
        if !prs.isEmpty || events.contains(where: { $0.type == "reviews" }) { shell.refresh() }
        if events.contains(where: { $0.type == "sync" && $0.scope == "usage" }) { shell.refreshUsage() }
        guard case .project(let id) = selection, let model = projectModels[id] else { return }
        let jira = events.filter { $0.type == "jira-sync" }
        switch model.section {
        case .prs:
            if prs.contains(where: { $0.projectId == nil || $0.projectId == id }) { await model.refresh() }
        case .tickets:
            if jira.contains(where: { $0.id == nil || $0.id == id }) { model.tickets?.refresh() }
        case .board:
            if jira.contains(where: { $0.id == nil || $0.id == "board:\(id)" }) { model.board?.refresh() }
        default: break
        }
    }

    public func reconnect() async {
        await stop()
        await start()
    }

    private func handleBackendEvent(_ event: BackendRuntimeEvent) {
        switch event {
        case .starting(let url):
            backendAddress = url.absoluteString
            connection = "Connecting"
        case .connected: connected()
        case .message(let event): received(event)
        case .reconnecting(let message):
            if let message { error = message }
            terminals.values.forEach { $0.agentTurns.setStreamAvailable(false) }
            connection = "Reconnecting"
            coordinator.setRoutingReady(false)
        }
    }

    private func connected() {
        guard started else { return }
        connection = "Connected"
        terminals.values.forEach { $0.agentTurns.setStreamAvailable(true) }
        refresh() // SSE has no replay IDs: refresh the snapshot on every reconnect.
        // Events missed while the stream was down include the one that ends a warm-up, so the
        // open sessions ask for their state rather than showing a run that already finished.
        ideWarmup.resync(worktrees: sessions.filter { viewer.contexts["task:\($0.id)"] != nil }.map(\.worktree))
        settings?.diagnostics.invalidate()
    }

    private func saveConversation(_ id: String, for session: WorkspaceSession) {
        guard let operations = sessionOperations else { return }
        Task {
            do {
                try await operations.saveAgentID(id, session: session)
                if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].sessionId = id }
            } catch { self.error = "Could not save agent session: \(error.localizedDescription)" }
        }
    }

    private func received(_ event: ServerEvent) {
        // A CLI in a terminal opening a link runs the BROWSER craft-ptyd gave it, which lands here:
        // the link opens as a click in that terminal would, in the panel beside it.
        if event.type == "terminal-open-url", let runID = event.runId, let url = event.url {
            // A shell that outlived a relaunch, in a session not opened since, has no terminal
            // here to open beside: its link goes to the default browser, as it would have
            // without Craft, rather than nowhere.
            if let terminal = terminals.values.first(where: { $0.termID == runID }) { terminal.openLink(url, terminal.cwd, false) }
            else if let web = safeWebURL(url) { desktop.openBrowser(web) }
        }
        if ["agent-turn-start", "agent-turn-done"].contains(event.type), let runID = event.runId,
           let terminal = terminals.values.first(where: { $0.termID == runID }),
           let session = sessions.first(where: { $0.id == terminal.pairKey }), event.cli == session.cli,
           terminal.agentTurns.receive(event) {
            if let id = event.sessionId, !id.isEmpty, id != session.sessionId { saveConversation(id, for: session) }
            // An agent that finished its turn may be the one the pool has been waiting to stop.
            if event.type == "agent-turn-done" { trimAfterTurnHooks() }
        }
        // Claude's SessionStart: the conversation changed under a running agent (`/resume`,
        // `/clear`, a compaction), or the user started one by hand, so the next resume must follow
        // it. It is not a turn, so it bypasses the tracker's turn handling. The hook itself drops a
        // nested `claude -p`, which is what makes any of this safe to believe.
        if event.type == "agent-session", let runID = event.runId, let id = event.sessionId, !id.isEmpty,
           let terminal = terminals.values.first(where: { $0.termID == runID }),
           let session = sessions.first(where: { $0.id == terminal.pairKey }), event.cli == session.cli,
           !terminal.agentTurns.hasPendingStep {
            // A resume keeps its conversation, but still says the agent is up at its prompt.
            terminal.agentTurns.adopt(sessionID: id, midTurn: event.source == "compact")
            if id != session.sessionId { saveConversation(id, for: session) }
        }
        if event.type == "activity", let activity = event.event {
            shell.notifications.receiveActivity(activity, enabled: shell.activityNotify)
            if coordinator.activityVisible { logs?.refresh() }
            todayActivity.activityReceived()
        }
        ideWarmup.receive(event)
        if event.type == "settings" { shell.loadSettings() }
        if event.type == "automations" { automation?.receive(scope: event.scope) }
        if event.type == "config" { settings?.refresh() }
        if ["sync", "jira-sync", "activity", "config", "reload"].contains(event.type) { settings?.diagnostics.invalidate() }
        if ["sync", "jira-sync", "tabs", "tasks", "reviews", "reload"].contains(event.type) { queueRefresh(event) }
    }

    /// Marked shown when it goes up, not when it is finished: a welcome that was seen and
    /// abandoned must not come back on every launch. One still up from before a restart is
    /// only handed the new backend.
    var canPresentWelcome: Bool { api != nil && (coordinator.welcomeModel != nil || coordinator.canPresent) }
    func presentWelcome(firstRunOnly: Bool) {
        guard let api else { return }
        if let model = coordinator.welcomeModel { model.connect(backendFactory.cliSettings(api: api)); return }
        guard !firstRunOnly || !welcomeStore.shown, coordinator.presentWelcome({ welcomeFactory.welcome() }) else { return }
        welcomeStore.shown = true
        coordinator.welcomeModel?.connect(backendFactory.cliSettings(api: api))
    }

    public func stop() async {
        viewer.fileOpenCoordinator.enabled = false
        if let shutdownTask { await shutdownTask.value; return }
        coordinator.browserDialogCoordinator.enabled = false
        started = false
        startGeneration = UUID()
        backendRuntime.onEvent = { _ in }
        coordinator.setRoutingReady(false)
        let task = Task { await finishStop() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func finishStop() async {
        await backendRuntime.stopEvents()
        eventRefreshTask?.cancel()
        await eventRefreshTask?.value
        eventRefreshTask = nil
        pendingRefreshEvents.removeAll()
        for model in pageWorkflowRuns.values { await model.stop() }
        pageWorkflowRuns.removeAll()
        pageWorkflowTargets.removeAll()
        for model in workflowRuns.values { await model.stop() }
        workflowRuns.removeAll()
        terminals.values.forEach { $0.agentTurns.setStreamAvailable(false) }
        workspaceLaunch.stop()
        for model in diffModels.values { await model.actions?.suspendAndWait() }
        refreshTask?.cancel()
        await refreshTask?.value
        refreshTask = nil
        refreshPending.removeAll()
        await shell.stop()
        await dashboard?.stop()
        await automation?.stop()
        await logs?.stop()
        await settings?.stop()
        await coordinator.welcomeModel?.stop()
        for model in projectModels.values {
            await model.workflows?.stop()
            model.connect(nil); model.board?.pause(); await model.tickets?.stop()
        }
        await viewer.stop()
        ideWarmup.connect(nil)
        // A backend switch leaves no handle on this backend's streams, so they go with it. Only
        // when a panel asked for one: stopping runs serve-sim, which a Mac without it pays for.
        let streamed = buildModels.values.contains { $0.preview?.udid != nil }
        for model in buildModels.values { model.disconnect() }
        buildModels.removeAll()
        if streamed, let api { await workspaceFactory.simulatorPreview(api: api).stopAll() }
        for model in diffModels.values { model.disconnect() }
        diffModels.removeAll()
        for model in historyModels.values { model.hide() }
        historyModels.removeAll()
        await backendRuntime.stop()
        api = nil
    }
}
