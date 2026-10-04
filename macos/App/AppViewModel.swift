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
    /// The chat views on screen, by the terminal they sit over: an agent's approval request goes
    /// to its chat, and one with no chat watching goes straight back to the terminal.
    @ObservationIgnored private var permissionWatchers: [String: PermissionWatcher] = [:]
    /// The requests each watched terminal is waiting on, oldest first: an agent can ask again
    /// before the first is answered, and each must be shown in turn, not dropped.
    @ObservationIgnored private var offeredPermissions: [String: [AgentPermissionPrompt]] = [:]
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
    private(set) var sessions: [WorkspaceSession] = [] {
        didSet {
            guard oldValue != sessions else { return }
            updateWorkspaceReviewState()
            let byProject = Dictionary(grouping: sessions, by: \.projectId)
            for (id, model) in projectModels { model.updateSessions(byProject[id] ?? []) }
        }
    }
    var selection: SidebarDestination { coordinator.selection }
    private(set) var terminals: [String: TerminalSession] = [:] {
        didSet { updateWorkspaceTerminalState() }
    }
    var projectModels: [String: ProjectPageViewModel] { coordinator.projectModels }
    private(set) var changingSessions: Set<String> = []
    /// Sessions the pool stopped with a finished turn nobody had looked at: their terminal, and the
    /// tracker that knew it, are gone, but the row stays done until the session is shown.
    private var finishedUnseenStopped: Set<String> = []
    /// First prompts for sessions the project composer created, by session id, until their agent launches.
    @ObservationIgnored private var launchPrompts: [String: String] = [:]
    /// Sessions a fork is being made of, so a second request waits for the first.
    @ObservationIgnored private var forkingSessions: Set<String> = []
    /// The last open or close of each project's panel shell, which the next one waits for.
    @ObservationIgnored private var projectTerminalSteps: [String: Task<Void, Never>] = [:]
    private(set) var buildModels: [String: BuildWorkspaceViewModel] = [:]
    private(set) var historyModels: [String: GitHistoryViewModel] = [:]
    private(set) var diffModels: [String: DiffViewModel] = [:]
    @ObservationIgnored private var pendingPins: Set<String> = []
    /// Observed, not ignored: `isRemoving(_:)` is read from a view body, so a lock taken or
    /// released has to invalidate it.
    private var removalLocks: [UUID: Set<String>] = [:]
    @ObservationIgnored private let backendRuntime: any BackendRuntimeServing
    @ObservationIgnored private let backendFactory: any BackendFeatureFactory
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var relaunching: Task<Void, Never>?
    @ObservationIgnored private var startGeneration = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private enum Inventory: Hashable { case projects, sessions }
    @ObservationIgnored private var refreshPending: Set<Inventory> = []
    @ObservationIgnored private var inventoryGenerations: [Inventory: UUID] = [:]
    @ObservationIgnored private var eventRefreshTask: Task<Void, Never>?
    /// Keeps the session usage fresh for the menu-bar item, which is always on screen.
    @ObservationIgnored private var usageWatch: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshEvents: [ServerEvent] = []
    @ObservationIgnored private var started = false
    // Keep navigation visible on the first frame, before the async inventory load.
    private(set) var sidebarEntries = SidebarEntry.make(projects: [], sessions: [])
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
         router: any DeepLinkRouting = CascadeRouter(),
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
        coordinator.windowBackdrop = shell.windowBackdrop
        coordinator.presentSettingsWindow = { [weak self] in self?.presentSettings() }
        shell.documentStyleChanged = { [weak self] in
            guard let self else { return }
            coordinator.appearance = shell.appearance
            updateWorkspaceDocumentState()
        }
        shell.terminalStyleChanged = { [weak self] in self?.updateWorkspaceTerminalState() }
        shell.windowBackgroundChanged = { [weak self] in
            guard let self else { return }
            coordinator.windowBackdrop = shell.windowBackdrop
        }
        shell.memoryLimitsChanged = { [weak self] in
            guard let self else { return }
            sessionPool.limit = shell.sessionMemoryLimit
            viewer.pageMemoryLimit = shell.pageMemoryLimit
        }
        viewer.pageMemoryLimit = shell.pageMemoryLimit
        sessionPool.sessions = { [weak self] in self?.poolSessions() ?? [] }
        sessionPool.stop = { [weak self] id in await self?.stopPooledSession(id) ?? false }
        _ = coordinator.makeDashboard(factory: dashboardFactory, pageActions: platformFactory.pageActions(open: { [weak self] request in
            guard let self else { throw BackendError.operation(String(localized: "The workspace has closed.")) }
            try await self.openPage(request)
        }, session: { [weak self] request in self?.pageSessionMark(request) }), shell: shell)
        _ = coordinator.makeAutomation(factory: NativeAutomationFeatureFactory())
        // Activity lives in the Settings window: what a row opened is in the main window, so it comes up.
        _ = coordinator.makeLogs(factory: logsFactory, pageActions: platformFactory.pageActions(open: { [weak self] request in
            guard let self else { throw BackendError.operation(String(localized: "The workspace has closed.")) }
            try await self.openPage(request)
            self.showMainWindow?()
        }), copy: copy)
        dashboard?.snapshotChanged = { [weak self] in self?.cachedResolverPullRequests = nil; self?.updateWorkspaceReviewState() }
        _ = coordinator.makeSettings(factory: settingsFactory ?? NativeSettingsFeatureFactory(desktop: desktop, copy: copy, adBlocker: .shared), shell: shell, runtime: self)
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
    /// Tracking includes nested terminal and browser state, so those updates
    /// schedule a load even when no backend inventory request is needed.
    private func loadSidebar() async {
        guard sidebarNeedsLoad else { return }
        sidebarNeedsLoad = false
        acknowledgeShownSession()
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
        // Per-session agent state for the row's dot: live while its terminal is attached, busy
        // between the CLI's turn hooks, done once a turn ends until the session is shown
        // (`acknowledgeShownSession`).
        var status: [String: SidebarSessionStatus] = [:]
        for session in sessions {
            let terminal = terminals["task:\(session.id)"]
            let turns = terminal?.agentTurns
            status[session.id] = SidebarSessionStatus(
                live: terminal?.isLive ?? false, busy: terminal?.agentBusy == true,
                needsInput: turns?.needsInput == true, done: turns?.finishedUnseen == true || finishedUnseenStopped.contains(session.id),
                cli: turns?.cli ?? session.cli)
        }
        return SidebarEntry.make(projects: projects, sessions: sessions, status: status,
            order: sidebarOrder, canCreateProject: canPerform(.newProject))
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
        if context.pane == .diff { context.showPages(); return }
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

    func agentTranscript(cli: String, worktree: String, since: String?, conversation: String?) async throws -> AgentTranscript {
        guard let api else { throw BackendError.operation(String(localized: "Connect to the backend to read the conversation.")) }
        var query = ["cli": cli, "worktree": worktree]
        if let since { query["since"] = since }
        if let conversation { query["session"] = conversation }
        return try await api.get(APIClient.query(Routes.AGENT_TRANSCRIPT, query))
    }

    func agentCommands(cli: String, worktree: String) async -> [AgentCommand] {
        struct Listed: Decodable { let commands: [AgentCommand] }
        guard let api else { return [] }
        let listed: Listed? = try? await api.get(APIClient.query(Routes.AGENT_COMMANDS, ["cli": cli, "worktree": worktree]))
        return listed?.commands ?? []
    }

    func worktreeFiles(_ worktree: String, matching query: String) async -> [String] {
        guard let api else { return [] }
        return (try? await APIFileSearchService(api: api).files(in: worktree, matching: query)) ?? []
    }

    func watchPermissions(runID: String, _ watcher: PermissionWatcher) {
        permissionWatchers[runID] = watcher
        watcher.show(offeredPermissions[runID]?.first)
    }

    /// The chat left the screen. The requests it was showing go back to the terminal, which would
    /// otherwise show nothing while their hooks wait.
    func unwatchPermissions(runID: String) {
        permissionWatchers[runID] = nil
        for prompt in offeredPermissions.removeValue(forKey: runID) ?? [] { pass(prompt.id) }
    }

    func answerPermission(_ id: String, decision: String) async throws {
        guard let api else { throw BackendError.operation(String(localized: "Connect to the backend to answer the agent.")) }
        withdrawPermission(id)
        try await api.answerPermission(id: id, decision: decision)
    }

    private func pass(_ id: String) { Task { try? await answerPermission(id, decision: "pass") } }

    /// Takes a request off its terminal's queue and shows the next one; whether it was queued.
    @discardableResult private func withdrawPermission(_ id: String) -> Bool {
        guard let runID = offeredPermissions.first(where: { $0.value.contains { $0.id == id } })?.key else { return false }
        offeredPermissions[runID]?.removeAll { $0.id == id }
        if offeredPermissions[runID]?.isEmpty == true { offeredPermissions[runID] = nil }
        permissionWatchers[runID]?.show(offeredPermissions[runID]?.first)
        return true
    }

    private func receivePermission(_ event: ServerEvent) {
        guard let id = event.id, let runID = event.runId else { return }
        if event.type == "agent-permission-done" {
            // A request the chat was holding now waits in the terminal it covers: show that.
            if withdrawPermission(id), event.outcome == "terminal" { permissionWatchers[runID]?.movedToTerminal() }
            return
        }
        guard let details = event.request, let watcher = permissionWatchers[runID] else { pass(id); return }
        offeredPermissions[runID, default: []].append(AgentPermissionPrompt(id: id, details: details))
        watcher.show(offeredPermissions[runID]?.first)
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
            guard let api else { context.error = String(localized: "Connect to the backend to load changes."); return }
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
        model.retire()
        // The project's own shell goes with it; its sessions' shells are theirs and stay.
        let id = model.project.id
        Task { await closeProjectTerminal(id) }
    }

    static func projectTerminalKey(_ projectID: String) -> String { "project:\(projectID)" }

    /// A new shell for a project's terminal panel, in `directory` (the project's checkout or one
    /// of its worktrees) and needing no session. Any shell under the project's pair key is stopped
    /// first, so the new one never attaches to it: one the panel had, or one an unexpected exit
    /// left behind. Kept in `terminals`, so Quit stops it with every other.
    func projectTerminal(for project: Project, directory: String) async throws -> TerminalSession {
        try await projectTerminalStep(project.id) { [self] in
            // Stopped before anything can fail, so a failed open never leaves the old shell running.
            try await stopProjectTerminal(project.id)
            let directory = directory.isEmpty ? project.workspace : directory
            guard !directory.isEmpty else {
                throw BackendError.operation(String(localized: "Choose a workspace folder for this project in its Settings."))
            }
            // Deleted while its old shell stopped.
            guard projects.contains(where: { $0.id == project.id }) else { throw CancellationError() }
            let key = Self.projectTerminalKey(project.id)
            let terminal = platformFactory.terminal(.init(key: key, directory: directory, paired: true))
            terminal.presentation.style = shell.terminalStyle
            terminal.openLink = { [weak self] raw, directory, _ in
                guard let self, let link = WorkspaceLink.parse(raw, directory: directory, home: platformFactory.homeDirectory) else { return }
                switch link {
                case .web(let url): NSWorkspace.shared.open(url)
                case .file(let location): NSWorkspace.shared.open(URL(fileURLWithPath: location.path))
                }
            }
            terminals[key] = terminal
            return terminal
        }
    }

    /// Stops the project's panel shell: the panel closed, or the project went.
    func closeProjectTerminal(_ projectID: String) async {
        _ = try? await projectTerminalStep(projectID) { [self] in try await stopProjectTerminal(projectID) }
    }

    private func stopProjectTerminal(_ projectID: String) async throws {
        let key = Self.projectTerminalKey(projectID)
        await terminals.removeValue(forKey: key)?.stopConnecting()
        try await terminalControl.stopPaired(keys: [key])
    }

    /// Runs a project's terminal open or close after the ones asked for before it, so a panel
    /// opened, closed and opened again ends with the shell the last asked for, and no other.
    private func projectTerminalStep<T: Sendable>(_ projectID: String, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = projectTerminalSteps[projectID]
        let step = Task { @MainActor in
            await previous?.value
            return try await body()
        }
        let tail = Task { _ = await step.result }
        projectTerminalSteps[projectID] = tail
        defer { if projectTerminalSteps[projectID] == tail { projectTerminalSteps[projectID] = nil } }
        return try await step.value
    }

    /// Panel shells a relaunch kept, or a crash left: no panel is open at launch, so each is stopped.
    private func stopLeftoverProjectTerminals() async {
        guard let shells = try? await terminalControl.pairedShells() else { return }
        let prefix = Self.projectTerminalKey("")
        for key in shells.keys where key.hasPrefix(prefix) {
            let projectID = String(key.dropFirst(prefix.count))
            // Through the project's steps, so a panel opened meanwhile keeps its new shell.
            _ = try? await projectTerminalStep(projectID) { [self] in
                if terminals[key] == nil { try await terminalControl.stopPaired(keys: [key]) }
            }
        }
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

    /// The project a new session is created under, from where it was asked for — Start never
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
        default: return local.count == 1 ? local[0] : nil
        }
    }

    /// The local project a GitHub PR or issue, or a Jira ticket page, belongs to, or nil for any other page.
    static func pageProject(_ url: String, in projects: [Project]) -> Project? {
        guard let page = SessionPage.parse(url) else { return nil }
        let local = projects.filter { !$0.workspace.isEmpty }
        if page.kind == "github" || page.kind == "issue" {
            let path = URL(string: page.url)?.path.split(separator: "/").prefix(2).joined(separator: "/").lowercased()
            return local.first { !$0.repo.isEmpty && $0.repo.lowercased() == path }
        }
        let prefix = page.key.split(separator: "-").first.map(String.init) ?? ""
        return local.first { project in
            (project.jiraProjectKey ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).uppercased() == prefix }
        }
    }

    private var canStartSession: Bool {
        connection == "Connected" && coordinator.canPresent
    }

    /// New Session for the selection: its project's Start. `agent` picks Start's agent; nil keeps
    /// the one it has.
    func newSession(agent: SessionAgent?) {
        guard canPerform(.newSession), let project = sessionProject(for: selection) else { return }
        openStart(in: project.id, agent: agent)
    }

    /// Every session starts on its project's Start page: this opens it, filled in. `jiraKey` is
    /// the ticket a pull request link references, for the session created from it.
    func openStart(in projectID: String, text: String? = nil, jiraKey: String? = nil, agent: SessionAgent? = nil) {
        guard coordinator.canPresent, projects.contains(where: { $0.id == projectID }) else { return }
        select(.project(projectID))
        projectModels[projectID]?.start(text: text, jiraKey: jiraKey, agent: agent)
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

    /// The row's own project when it names one, else the project the page belongs to.
    static func pageSessionProject(for request: OpenPageRequest, in projects: [Project]) -> Project? {
        if let id = request.projectID { return projects.first { $0.id == id && !$0.workspace.isEmpty } }
        return pageProject(request.url, in: projects)
    }

    /// The session a page already has — its own, or one on its branch or ticket key.
    func existingSession(for request: OpenPageRequest) -> WorkspaceSession? {
        Self.pageSession(for: request, sessions: sessions, projects: projects, pullRequests: resolverPullRequests)
    }

    /// The session a list row's page already has — what its badge and menu title show.
    func pageSessionMark(_ request: OpenPageRequest) -> PageSessionMark? {
        existingSession(for: request).map(PageSessionMark.init)
    }

    public func canPerform(_ command: ShellCommand) -> Bool {
        switch command {
        case .newProject: connection == "Connected" && coordinator.canPresent
        // ⌘T, as `newBrowserTab`: a blank tab in the workspace on screen.
        case .newTab: coordinator.canPresent && viewer.active != nil
        case .newSession: canStartSession && sessionProject(for: selection) != nil
        case .back: coordinator.canPresent && viewer.active?.activePage?.controls.canGoBack == true
        case .forward: coordinator.canPresent && viewer.active?.activePage?.controls.canGoForward == true
        case .openFile: viewer.active != nil && connection == "Connected" && coordinator.canPresent
        case .saveFile: viewer.active?.activeDocument?.loaded == true && viewer.active?.activeDocument?.readOnly == false
        case .findPage: activeHistory != nil || hasActivePage
        case .zoomIn, .zoomOut, .resetZoom: coordinator.canPresent && viewer.active?.activePage?.controls.active == true
        case .nextPage, .previousPage: (viewer.active?.tabs.count ?? 0) > 1
        case .biggerFont, .smallerFont, .resetFont: fontTarget != nil || canPerform(.zoomIn)
        case .reloadPage: canPerform(.zoomIn)
        case .nextModel, .previousModel: coordinator.canPresent && coordinator.activeWorkspaceModel?.canCycleAgentPreset == true
        case .toggleChat: coordinator.canPresent && coordinator.activeWorkspaceModel?.canShowChat == true
        case .session1, .session2, .session3, .session4, .session5, .session6, .session7, .session8, .session9, .session10:
            sidebarSessions.count > command.sessionIndex ?? 0
        case .nextSession, .previousSession: !sidebarSessions.isEmpty
        case .refresh: connection == "Connected"
        case .runProject: coordinator.activeWorkspaceModel.map { $0.canRun && $0.build?.running != true } ?? false
        case .stopBuild: coordinator.canPresent && coordinator.activeWorkspaceModel?.build?.running == true
        default: true
        }
    }

    /// A session reached by its shortcut takes the keyboard to its agent, as one clicked in the sidebar does.
    private func showSession(_ id: String) {
        select(.session(id))
        focusSession(id)
    }

    /// The keyboard goes to the shown session's agent — the terminal, or the chat's message field
    /// when it is in Chat — so typing goes straight to it. One reached with the sidebar's arrow keys
    /// is not focused, so the arrows keep moving through the sidebar.
    func focusSession(_ id: String) {
        guard case .session(id) = selection else { return }
        // In Chat the keyboard goes to its message field; a chat not built yet takes it on appear.
        if SessionWorkspaceViewModel.opensInChat(sessionID: id) { coordinator.activeWorkspaceModel?.focusAgent() }
        else { terminals["task:\(id)"]?.surface.requestFocus() }
    }

    /// The sessions in sidebar order, which is what ⌘1–9, ⌘0 and ⌘[ ] count.
    private var sidebarSessions: [String] { root?.entries.flatMap(\.descendants).compactMap(\.sessionID) ?? [] }

    public func perform(_ command: ShellCommand) {
        if [.overview, .terminal].contains(command) { coordinator.discardQueuedDeepLink() }
        if zoomChat(for: command) { return }
        // ⌘+ / ⌘− / ⌘0 zoom the web page when that is what has focus, or is all there is to zoom.
        if let zoom = pageZoom(for: command) { return perform(zoom) }
        switch command {
        case .session1, .session2, .session3, .session4, .session5, .session6, .session7, .session8, .session9, .session10:
            guard canPerform(command), let index = command.sessionIndex else { return }
            showSession(sidebarSessions[index])
        case .nextSession, .previousSession:
            // Wraps; from anything but a session, Next goes to the first and Previous to the last.
            let sessions = sidebarSessions
            guard !sessions.isEmpty else { return }
            let step = command == .nextSession ? 1 : -1
            let current: String? = if case .session(let id) = selection { id } else { nil }
            let target = current.flatMap { sessions.firstIndex(of: $0) }.map { ($0 + step + sessions.count) % sessions.count }
                ?? (step > 0 ? 0 : sessions.count - 1)
            showSession(sessions[target])
        case .nextModel, .previousModel:
            if canPerform(command) { coordinator.activeWorkspaceModel?.cycleAgentPreset(command == .nextModel ? 1 : -1) }
        case .toggleChat: if canPerform(.toggleChat) { coordinator.activeWorkspaceModel?.toggleChat() }
        case .reloadPage: if canPerform(.reloadPage) { viewer.active?.activePage?.controls.reload() }
        case .newProject:
            guard canPerform(.newProject), let api else { return }
            coordinator.presentNewProject(service: backendFactory.projects(api: api), didSave: { [weak self] in self?.savedProject($0) })
        case .newSession: newSession(agent: nil)
        case .newTab: if canPerform(.newTab) { newBrowserTab() }
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

    /// ⌘+ / ⌘− / ⌘0 in Chat size the conversation: the terminal they would reach is under it. A
    /// browser tab beside it that has the keyboard keeps its own zoom.
    private func zoomChat(for command: ShellCommand) -> Bool {
        let delta: Double?
        switch command {
        case .biggerFont: delta = 0.1
        case .smallerFont: delta = -0.1
        case .resetFont: delta = nil
        default: return false
        }
        guard let workspace = coordinator.activeWorkspaceModel, workspace.chatCoversTerminal, let chat = workspace.chat else { return false }
        let inChat = chat.page?.hasFocus == true
        guard inChat || (fontTarget == .term && !webPageFocused) else { return false }
        chat.zoom(delta)
        return true
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
            if context.activeDocument != nil && (!hasTerminal || context.pane == .term) { return .diff }
        }
        return terminal?.ready == true ? .term : nil
    }

    /// Cmd-T: a blank tab in the browser panel of the workspace on screen, as in Safari's window in
    /// front. A session panel showing something else switches to Browser first.
    func newBrowserTab() {
        guard coordinator.canPresent, let context = viewer.active else { return }
        // Selecting the new page shows the pages: asking for them first would open a blank tab too.
        context.openBlankPage()
    }

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
    /// A Today-popover row: its PR opens by link; a ticket by its key on the configured Jira site.
    func openActivityEntry(_ entry: LogEntry) async throws {
        if let link = entry.link {
            // The page's own kind — an issue's tab is an issue tab — and a pull request's otherwise, as before.
            try await openPage(OpenPageRequest(url: link, kind: SessionPage.parse(link)?.kind ?? "github", title: entry.title)); return
        }
        guard let key = entry.jiraKey, let api else { throw BackendError.operation(String(localized: "Connect before opening a page.")) }
        let site: JiraSite = try await api.get(Routes.JIRA_SITE, timeout: 30)
        guard let base = safeWebURL(site.baseUrl) else { throw BackendError.operation(String(localized: "Configure the Jira site to open ticket links.")) }
        try await openPage(OpenPageRequest(url: base.appendingPathComponent("browse").appendingPathComponent(key).absoluteString,
                                           kind: "jira", title: key))
    }

    /// Every PR or ticket click — a row or its Go to Session / New Session, a board card, an
    /// Activity entry, a tray review, a notice: the page's session when it has one, else its
    /// project's Start with the link (and the ticket a pull request references) filled in. No
    /// session is created here, and nothing opens outside Cascade: a page no local project claims
    /// is an error for the surface to show. A superseded click opens nothing.
    func openPage(_ request: OpenPageRequest) async throws {
        try Task.checkCancellation()
        guard safeWebURL(request.url) != nil else { throw BackendError.operation(String(localized: "Invalid page address.")) }
        if let session = existingSession(for: request) {
            select(.session(session.id)); return
        }
        guard SessionPage.parse(request.url) != nil, let project = Self.pageSessionProject(for: request, in: projects) else {
            throw BackendError.operation(String(localized: "No project with a workspace matches this page."))
        }
        guard canStartSession else { throw BackendError.operation(String(localized: "A session cannot be started right now.")) }
        openStart(in: project.id, text: request.url, jiraKey: request.jiraKeys.first)
    }

    /// A click from outside the window (the tray, a notice) that could not open: the window shows
    /// the Dashboard, where the app reports its errors, with the reason. `showWindow` is false
    /// where the caller brings the window up itself.
    func reportOutsideOpenFailure(_ error: any Error, showWindow: Bool = true) {
        guard !(error is CancellationError) else { return }
        select(.overview)
        reportRootError(error.localizedDescription)
        if showWindow { showMainWindow?() }
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
        acknowledgeShownSession()
        // A switch hides the session it leaves, which the pool may now stop.
        sessionPool.trim()
    }
    /// The session on screen has been seen: its finished turn is no news, now or once it is left.
    /// Called on every navigation and before each sidebar load, so the rows never read the selection.
    private func acknowledgeShownSession() {
        guard case .session(let id) = selection else { return }
        terminals["task:\(id)"]?.agentTurns.acknowledge()
        if finishedUnseenStopped.contains(id) { finishedUnseenStopped.remove(id) }
    }
    /// For the area extensions: `error` is only settable from this file.
    func reportRootError(_ message: String) { error = message }

    /// Opens a page's link as the Dashboard's rows do, marking the session it already has.
    private func projectPageActions() -> any PageActionServing {
        platformFactory.pageActions(open: { [weak self] request in
            guard let self else { throw BackendError.operation(String(localized: "The workspace has closed.")) }
            try await self.openPage(request)
        }, session: { [weak self] request in self?.pageSessionMark(request) })
    }

    private func showSelectedContext() {
        switch selection {
        case .project(let id):
            viewer.deactivate()
            if let project = projects.first(where: { $0.id == id }), let api {
                let services = backendFactory.projectServices(api: api)
                coordinator.prepareProject(project, services: services, factory: projectFactory, runtime: self,
                                           agent: shell.defaultAgent, pageActions: projectPageActions())
                projectModels[id]?.updateSessions(sessions.filter { $0.projectId == id })
            }
        case .session(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                sessionPool.shown(id)
                let context = viewer.select(id: "task:\(id)", url: session.url, title: session.title)
                warmIDE(for: session)
                buildModel(for: session, context: context)?.warmDestinations()
                openTerminal()
            } else { viewer.deactivate() }
        case .terminal:
            viewer.select(id: "scratch", url: "", title: String(localized: "Terminal"))
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

    private func adoptProjectDestinations() {
        for (contextID, model) in buildModels {
            guard let session = sessions.first(where: { "task:\($0.id)" == contextID }),
                  let project = projects.first(where: { $0.id == session.projectId }) else { continue }
            model.adopt(project)
        }
    }

    func openWorkflowHookSettings() {
        settings?.section = .clis; presentSettings()
    }

    func removalModel(for record: WorkspaceSession) -> SessionRemovalViewModel? {
        guard let api else { return nil }
        let operationID = UUID()
        let service = backendFactory.removal(api: api, stopTerminals: { [weak self] keys in
            guard let self else { throw BackendError.operation(String(localized: "The workspace closed before removal.")) }
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
            guard let self else { throw BackendError.operation(String(localized: "The workspace closed before the build could start.")) }
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
        guard changingSessions.isDisjoint(with: ids) else { throw BackendError.operation(String(localized: "A session operation is already in progress.")) }
        changingSessions.formUnion(ids)
        removalLocks[operationID] = ids
        let worktrees = sessions.filter { ids.contains($0.id) }.map(\.worktree)
        guard !diffModels.values.contains(where: { model in
            worktrees.contains(model.worktree) && model.actions?.busy == true
        }) else {
            changingSessions.subtract(ids); removalLocks.removeValue(forKey: operationID)
            throw BackendError.operation(String(localized: "Wait for the Git operation to finish before removing this worktree."))
        }
        guard await viewer.closeDocuments(contextIDs: Set(ids.map { "task:\($0)" }), worktrees: worktrees) else {
            changingSessions.subtract(ids); removalLocks.removeValue(forKey: operationID)
            throw CancellationError()
        }
        for id in ids {
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
        // Worked out before the shell exists, so the shell starts the agent itself once its
        // startup files have loaded.
        let prepared = PreparedLaunch()
        terminal.startupCommand = { [weak self] in
            prepared.launch = nil
            guard let self else { return nil }
            prepared.launch = try await agentLaunch(record: record, fresh: fresh)
            return prepared.launch?.command
        }
        // The agent runs from the moment its shell exists, so its new conversation id is kept then,
        // not once the pane has attached, which can still fail.
        terminal.startupCommandStarted = { [weak self] in
            guard let self, let launch = prepared.launch else { return }
            if launch.prompted { launchPrompts[record.id] = nil }
            do { try await keepReservedID(launch, record: record) } catch { self.error = error.localizedDescription }
            await settleFork(launch, record: record)
        }
        terminal.onReattached = { [weak self] terminal in await self?.replayLastHook(terminal) }
        terminal.onCreated = { [weak self] terminal in
            guard let self, let launch = prepared.launch else { return }
            try await noteAgent(terminal, cli: launch.agent.rawValue, started: true)
            watchLaunch(terminal, agent: launch.agent, resuming: launch.resuming, record: record)
        }
        return terminal
    }

    /// `reservedID` is a new conversation id the command starts, not yet on the session record.
    /// `prompted` is a launch carrying the composer's prompt, which is spent once the agent starts.
    private struct AgentLaunch { let command: String; let agent: SessionAgent; let resuming: Bool; var reservedID: String?; var prompted = false }
    @MainActor private final class PreparedLaunch { var launch: AgentLaunch? }

    /// Enters the agent's launch at an existing shell, one whose agent was quit.
    /// `afresh` starts a new conversation under a new id, whatever the session had.
    private func launchAgent(_ terminal: TerminalSession, record: WorkspaceSession, fresh: Bool, afresh: Bool = false) async throws {
        guard let launch = try await agentLaunch(record: record, fresh: fresh, afresh: afresh) else { return }
        try await keepReservedID(launch, record: record)
        await settleFork(launch, record: record)
        try await enterAgent(terminal, command: launch.command, cli: launch.agent.rawValue)
        if launch.prompted { launchPrompts[record.id] = nil }
        watchLaunch(terminal, agent: launch.agent, resuming: launch.resuming, record: record)
    }

    private func agentLaunch(record: WorkspaceSession, fresh: Bool, afresh: Bool = false) async throws -> AgentLaunch? {
        let latest = self.sessions.first { $0.id == record.id } ?? record
        let agent = latest.agent
        var id = latest.sessionId
        var firstLaunch = fresh
        var reservedID: String?
        let names = agent.driver?.namesConversationAtLaunch == true
        if names && (afresh || id == nil || id == "") {
            guard self.sessionOperations != nil else { throw BackendError.operation(String(localized: "Connect before starting the agent.")) }
            id = UUID().uuidString.lowercased(); firstLaunch = true
            reservedID = id
        } else if names, !firstLaunch, let id, let operations = self.sessionOperations,
                  (try? await operations.conversationExists(cli: agent.rawValue, id: id)) == false {
            // The id was reserved at a launch that never sent a prompt, so nothing is on disk
            // under it and `--resume` would fail hard. Reserving it again starts it for real.
            firstLaunch = true
        }
        // Claude Code reports its real context window only to its status line, so the app's
        // wrapper rides along on the sessions it launches.
        let script = Bundle.main.url(forResource: "cascade-statusline", withExtension: "sh")
            ?? Bundle.main.url(forResource: "cascade-statusline", withExtension: "sh", subdirectory: "AgentStatusLine")
        let statusLine = script.map { AgentStatusLine(script: $0.path, taskID: latest.id) }
        // The composer's prompt opens the conversation, so it goes with the first launch only. It is
        // kept until that launch has started, so a launch that fails before it can try again with it.
        let prompt = firstLaunch ? launchPrompts[latest.id] : nil
        // A fork copies the source's conversation until it has one of its own: a launch that ended
        // before its first message, even across a restart, forks again.
        let resuming = !firstLaunch && !(id ?? "").isEmpty
        var forking = resuming ? nil : latest.forkFrom.flatMap { $0.isEmpty ? nil : (source: $0, directory: latest.worktree) }
        // A source the CLI no longer has would fail every launch, so the fork starts afresh instead.
        if let source = forking?.source, let driver = agent.driver, let operations = sessionOperations,
           (try? await operations.conversationExists(cli: agent.rawValue, id: driver.forkedConversation(source))) == false {
            forking = nil
            await forgetFork(latest, operations: operations)
        }
        return agent.command(sessionID: id, fresh: firstLaunch, statusLine: statusLine, prompt: prompt, forking: forking).map {
            AgentLaunch(command: $0, agent: agent, resuming: resuming, reservedID: reservedID, prompted: prompt != nil)
        }
    }

    /// Saves a launch's new conversation id once its shell exists, so a shell that is never created
    /// leaves the session record as it was. A relaunch at an open shell saves it before typing.
    private func keepReservedID(_ launch: AgentLaunch, record: WorkspaceSession) async throws {
        guard let id = launch.reservedID else { return }
        guard let operations = sessionOperations else { throw BackendError.operation(String(localized: "Connect before starting the agent.")) }
        let latest = sessions.first { $0.id == record.id } ?? record
        try await operations.saveAgentID(id, session: latest)
        if let index = sessions.firstIndex(where: { $0.id == latest.id }) { sessions[index].sessionId = id }
    }

    /// A fork resuming its own conversation has no more use for its source. Failing to forget it
    /// only costs the same check at the next launch.
    /// Only once the CLI is known to have the fork's own conversation: an answer that did not come
    /// keeps the source, so the next launch can still fork.
    private func settleFork(_ launch: AgentLaunch, record: WorkspaceSession) async {
        guard launch.resuming, let operations = sessionOperations,
              let latest = sessions.first(where: { $0.id == record.id }), latest.forkFrom?.isEmpty == false,
              let own = latest.sessionId, !own.isEmpty,
              (try? await operations.conversationExists(cli: launch.agent.rawValue, id: own)) == true else { return }
        await forgetFork(latest, operations: operations)
    }

    /// Clears a fork's source on the record and here. A reload already in flight read the row
    /// before, and would bring the source back: its sessions are dropped, and the backend's `tasks`
    /// event reloads them once saved.
    private func forgetFork(_ session: WorkspaceSession, operations: any SessionServing) async {
        guard (try? await operations.clearFork(session)) != nil else { return }
        inventoryGenerations[.sessions] = UUID()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].forkFrom = "" }
    }

    /// A launch the CLI refuses ends at the shell, which otherwise looks like a session that
    /// simply never started: a resume it cannot find, or an id it says is already in use. Both
    /// are caught, the one that flashed past and the one that never took the foreground at all.
    /// The stored id is kept; this reports that something is wrong, it does not abandon it.
    /// A Claude resume that ends at the shell with its conversation gone from disk is one Claude could
    /// not find: the session starts a new conversation under a new id instead, and follows that one.
    /// Only then, since quitting at once reads the same at the shell; and only once, since a new
    /// conversation that fails too is reported.
    private func watchLaunch(_ terminal: TerminalSession, agent: SessionAgent, resuming: Bool, record: WorkspaceSession) {
        var seen = terminal.launchedAgentForeground != nil
        Task { [weak self, weak terminal] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let terminal, let atShell = try? await terminal.atShell() else { return }
                if !atShell { seen = true } else if seen { break }
            }
            guard let self, let terminal, (try? await terminal.atShell()) == true else { return }
            let current = sessions.first { $0.id == record.id }?.sessionId
            if resuming, agent.driver?.namesConversationAtLaunch == true, let current, let operations = sessionOperations,
               (try? await operations.conversationExists(cli: agent.rawValue, id: current)) == false {
                do { try await launchAgent(terminal, record: record, fresh: true, afresh: true) }
                catch { self.error = String(localized: "\(agent.label) could not resume its conversation, and starting a new one failed: \(error.localizedDescription)") }
                return
            }
            // Quitting the agent within the window reads the same, so this does not claim a failure.
            self.error = resuming
                ? String(localized: "\(agent.label) returned to the shell after resuming. If you did not quit it, check the terminal for details.")
                : String(localized: "\(agent.label) returned to the shell after starting. If you did not quit it, check the terminal for details.")
        }
    }

    /// Runs an agent's launch line at the shell and notes what came to the foreground, so the agent
    /// it launched can later be told apart from one the user started.
    private func enterAgent(_ terminal: TerminalSession, command: String, cli: String) async throws {
        try await terminal.submit(command)
        try await noteAgent(terminal, cli: cli, started: false)
    }

    private func noteAgent(_ terminal: TerminalSession, cli: String, started: Bool) async throws {
        terminal.launchedAgent = AgentDrivers.of(cli)?.cli
        terminal.launchedAgentForeground = nil
        // A shell that starts the agent itself runs its startup files first, and what they run
        // holds the foreground briefly; there the agent is the program that keeps it.
        var held = 0
        var candidate: Int32?
        for _ in 0..<(started ? 500 : 100) {
            let foreground = try await terminal.foregroundProcess()
            if foreground.atShell { held = 0; candidate = nil }
            else {
                held = foreground.pgid == candidate ? held + 1 : 0
                candidate = foreground.pgid
                if !started || held == 25 { terminal.launchedAgentForeground = foreground; break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func wireLinks(_ terminal: TerminalSession, contextID: String) {
        terminal.openLink = { [weak self] raw, directory, _ in
            guard let self, let context = viewer.contexts[contextID] else { return }
            guard let link = WorkspaceLink.parse(raw, directory: directory, home: platformFactory.homeDirectory) else {
                context.error = String(localized: "This terminal link is not a supported web or local file address.")
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

    /// A session a project's Start made: its prompt waits for the agent's first launch.
    func projectSessionCreated(_ session: WorkspaceSession, prompt: String?) {
        if let prompt { launchPrompts[session.id] = prompt }
        createdSession(session)
    }

    /// Sidebar right-click Fork Session, and the chat's fork button: a new session, named after
    /// this one with the next number, whose agent carries this one's conversation on in a copy of
    /// its worktree. The backend makes the worktree and the record; the fork opens like any new one.
    func forkSession(_ id: String) {
        guard let operations = sessionOperations, let record = sessions.first(where: { $0.id == id }),
              record.agent.driver != nil, !changingSessions.contains(id), forkingSessions.insert(id).inserted else { return }
        Task {
            defer { forkingSessions.remove(id) }
            do {
                let forked = try await operations.fork(record)
                createdSession(forked.task)
                if let warning = forked.warning {
                    self.error = String(localized: "Forked \(record.label), but not all of its uncommitted work came across: \(warning)")
                }
            } catch {
                self.error = String(localized: "Could not fork session: \(error.localizedDescription)")
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
                await terminals[key]?.stopConnecting()
                try await terminalControl.stopPaired(keys: [record.id])
                terminals[key] = makeTerminal(sessions.first { $0.id == record.id } ?? record)
            } catch { self.error = String(localized: "Could not restart session: \(error.localizedDescription)") }
        }
    }

    /// Sidebar right-click Reattach Session, on a row that has gone grey: its terminal failed, its
    /// shell ended, or the memory pool stopped it. Unlike Restart it stops nothing: a shell the
    /// daemon still runs is attached to as it is, and only one that is gone is started again, its
    /// agent resuming as a stopped session's does when opened. The session is shown, since a
    /// terminal attaches from its pane.
    func reattachSession(_ id: String) {
        let key = "task:\(id)"
        guard terminals[key]?.isLive != true, sessions.contains(where: { $0.id == id }),
              changingSessions.insert(id).inserted else { return }
        Task {
            defer { changingSessions.remove(id) }
            await terminals[key]?.stopConnecting()
            guard let record = sessions.first(where: { $0.id == id }) else { return }
            terminals[key] = makeTerminal(record)
            select(.session(id))
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
            && !isRemoving(record.id)
    }

    /// Stops a session the pool picked, as Restart does, without starting it again: opening it
    /// does that. Only the agent Cascade launched goes, still in the terminal's foreground, with
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
        guard let foreground = try? await terminal.foregroundProcess(), !foreground.atShell, foreground.pgid == agent,
              await processes.processGroups(of: agent) == [agent], stillIdle() else {
            changingSessions.remove(id)
            return false
        }
        await terminal.stopConnecting()
        let stopping = stillIdle()
        if stopping { try? await terminalControl.stopPaired(keys: [id]) }
        let owned = terminals[key] === terminal
        if owned {
            if terminal.agentTurns.finishedUnseen { finishedUnseenStopped.insert(id) }
            terminals.removeValue(forKey: key)
        }
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
            } catch { self.error = String(localized: "Could not update pin: \(error.localizedDescription)") }
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
                self.error = String(localized: "Could not rename session: \(error.localizedDescription)")
            }
        }
    }

    public func quit() async throws { try await prepareToTerminate() }

    /// Whether any session's agent is in the middle of a turn — the sidebar's working dot, or one
    /// waiting on a person. Quit stops every shell, so it asks first only then.
    public var hasRunningSessions: Bool {
        sessions.contains { session in
            guard let terminal = terminals["task:\(session.id)"] else { return false }
            return terminal.agentBusy || terminal.agentTurns.needsInput
        }
    }

    public func prepareForUpdate() async throws { try await prepareToTerminate() }

    public func cancelBrowserPresentation() { coordinator.browserDialogCoordinator.cancel() }

    /// Leaves so that the build a Run just made of this very copy can take its place. It is Quit
    /// in everything but the shells: unsaved files are asked about, and the backend stops with
    /// its forwarders, but the daemon stays for the new build to pick up, and the Run waiting in
    /// one of its terminals with it. Hence `exit`, which `terminate` would not reach this way.
    /// Asked again while it is still asking about files, it is already leaving.
    private func leaveForRelaunch() {
        guard relaunching == nil else { return }
        relaunching = Task {
            do { try await prepareToTerminate(keepingShells: true) } catch { relaunching = nil; return }
            exit(0)
        }
    }

    private func prepareToTerminate(keepingShells: Bool = false) async throws {
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
        if !keepingShells {
            for terminal in terminals.values { await terminal.stopConnecting() }
            try await terminalControl.stopExisting()
            for terminal in terminals.values { terminal.disconnect() }
            // Simulator streams go with the shells. serve-sim cannot tell ours from a stream started in
            // a terminal, so Quit stops those too.
            if let api { await workspaceFactory.simulatorPreview(api: api).stopAll() }
        }
        // A page visited just before quitting would otherwise miss the debounced write.
        await viewer.browserHistory.flush()
        await viewer.browserBookmarks.flush()
        await stop()
    }

    private func restoreSessionTerminals() {
        for record in sessions {
            let key = "task:\(record.id)"
            _ = viewer.restore(id: key, url: record.url, title: record.title)
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
        Task { [weak self] in await self?.stopLeftoverProjectTerminals() }
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
            if let api {
                shell.connect(shellFactory.data(api: api)); viewer.connect(api); dashboard?.connect(backendFactory.dashboard(api: api))
                usageWatch?.cancel(); usageWatch = Task { [shell] in await shell.watchUsage() }
            }
            if let api { ideWarmup.connect(backendFactory.ideWarmup(api: api)) }
            if let api { for model in projectModels.values { model.connect(backendFactory.projects(api: api), sessions: backendFactory.sessions(api: api), boards: backendFactory.projectServices(api: api).boards) } }
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
        if case .project(let id) = selection { projectModels[id]?.board?.refresh() }
        if coordinator.activityVisible { logs?.refresh() }
        refreshInventory([.projects, .sessions])
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
                    // Preferences are the app's now; what an earlier version left in the
                    // backend is adopted once, alongside the first inventory read, and a failure
                    // there costs nothing but a retry with the next refresh.
                    let importsSettings = shell.needsLegacyPreferenceImport || viewer.needsImport
                    async let settingsRequest: [String: String?]? = importsSettings ? (try? await api.get(Routes.SETTINGS)) : nil
                    let (snapshot, sessionSnapshot, legacy) = try await (projectRequest, sessionRequest, settingsRequest)
                    try Task.checkCancellation()
                    if let legacy {
                        shell.importLegacyPreferences(legacy)
                        // Only sessions that still exist: the backend kept snapshots of ones deleted
                        // long ago, and nothing else would prune them.
                        let live = Set((sessionSnapshot ?? sessions).map { "task:\($0.id)" })
                        viewer.importLegacySnapshots(legacy) { live.contains($0) || !($0.hasPrefix("task:") || $0.hasPrefix("tab:")) }
                    }
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
                        }
                        sessions = sessionSnapshot
                        finishedUnseenStopped.formIntersection(retained)
                        sessionPool.retain(retained)
                    }
                    restoreSessionTerminals()
                    showSelectedContext()
                    guard refreshPending.isEmpty else { continue }
                    await loadSidebar()
                    // Only sidebar-backed destinations can go stale: a project or session that
                    // the inventory no longer lists. Settings, Activity and Terminal are reached from
                    // the menu and have no sidebar row, so they must never be bounced to Dashboard.
                    if selection.isSidebarBacked,
                       !sidebarEntries.flatMap(\.descendants).contains(where: { $0.destinations.contains(selection) }) { select(.overview) }
                    lastUpdate = Date()
                    // The pass is clean; what is left to say is the page tabs' store's notice, or
                    // that an earlier build's sidebar tabs are gone, each told once, after the pass
                    // so nothing here clears it: neither has a screen of its own.
                    error = viewer.takeRecoveryNotice() ?? platformFactory.sidebarTabsRemovalNotice() ?? viewer.lastError
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
        if events.contains(where: { $0.type == "tasks" }) { inventory.insert(.sessions) }
        if !inventory.isEmpty { refreshInventory(inventory) }
        let prs = events.filter { $0.type == "sync" && $0.scope == "prs" }
        if !prs.isEmpty { dashboard?.prs.refresh() }
        if !prs.isEmpty || events.contains(where: { $0.type == "reviews" }) { shell.refresh() }
        if events.contains(where: { $0.type == "sync" && $0.scope == "usage" }) { shell.refreshUsage() }
        let jira = events.filter { $0.type == "jira-sync" }
        for event in jira { for model in projectModels.values { model.refreshBoard(event: event.id) } }
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
        // Now that it can say so: the agent hooks the person installed are brought up to date, and
        // each update comes back as a toast, since the CLI may ask them to allow it.
        if let api { Task { try? await api.updateAgentHooks() } }
    }

    private struct LastHook: Decodable { let event: ServerEvent? }

    /// A shell that outlived the app, or its connection, is attached again with its agent's hooks
    /// unheard: until its next turn, nothing would say whether it is working or at its prompt, and
    /// the chat would hold every message. The backend kept the last hook it relayed for this
    /// terminal, which is taken as if it had just arrived — unless the live stream has spoken
    /// since, which is newer.
    private func replayLastHook(_ terminal: TerminalSession) async {
        guard let api, let runID = terminal.termID,
              let reply: LastHook = try? await api.get(APIClient.query(Routes.AGENT_LAST_HOOK, ["runId": runID])),
              let event = reply.event, event.runId == runID, terminal.termID == runID,
              !terminal.agentTurns.busy, !terminal.agentTurns.betweenTurns else { return }
        received(event)
        // It says what the agent was doing, not whether it has asked anything since.
        terminal.agentTurns.promptsUnheard()
    }

    private func saveConversation(_ id: String, for session: WorkspaceSession) {
        guard let operations = sessionOperations else { return }
        Task {
            do {
                try await operations.saveAgentID(id, session: session)
                if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].sessionId = id }
            } catch { self.error = String(localized: "Could not save agent session: \(error.localizedDescription)") }
        }
    }

    private func received(_ event: ServerEvent) {
        // A CLI in a terminal opening a link runs the BROWSER cascade-ptyd gave it, which lands here:
        // the link opens as a click in that terminal would, in the panel beside it.
        if event.type == "terminal-open-url", let runID = event.runId, let url = event.url {
            // A shell that outlived a relaunch, in a session not opened since, has no terminal
            // here to open beside: its link goes to the default browser, as it would have
            // without Cascade, rather than nowhere.
            if let terminal = terminals.values.first(where: { $0.termID == runID }) { terminal.openLink(url, terminal.cwd, false) }
            else if let web = safeWebURL(url) { desktop.openBrowser(web) }
        }
        // A Run in one of this copy's terminals has rebuilt this very copy, and waits for it to
        // leave before it opens the new build.
        if event.type == "terminal-relaunch", event.pid == Int(ProcessInfo.processInfo.processIdentifier) { leaveForRelaunch() }
        if ["agent-permission", "agent-permission-done"].contains(event.type) {
            receivePermission(event)
            // Whether or not a chat shows it, the agent's own prompt is up in that terminal.
            terminals.values.first { $0.termID == event.runId }?.agentTurns.receivePermission(event)
        }
        // A tool call of a terminal's agent, as it happens: the Live tab's feed. Only its session's
        // own CLI, as for the turn hooks: another run nested in one of its tools inherits the
        // terminal's run id.
        if event.type == "agent-tool", let runID = event.runId,
           let terminal = terminals.values.first(where: { $0.termID == runID }),
           let session = sessions.first(where: { $0.id == terminal.pairKey }), event.cli == session.cli {
            terminal.agentTurns.tools.receive(event)
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
           let session = sessions.first(where: { $0.id == terminal.pairKey }), event.cli == session.cli {
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
        if event.type == "automations" { automation?.receive(scope: event.scope) }
        if event.type == "config" { settings?.refresh() }
        if ["sync", "jira-sync", "activity", "config", "reload"].contains(event.type) { settings?.diagnostics.invalidate() }
        if ["sync", "jira-sync", "tasks", "reviews", "reload"].contains(event.type) { queueRefresh(event) }
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
        usageWatch?.cancel(); usageWatch = nil
        await eventRefreshTask?.value
        eventRefreshTask = nil
        pendingRefreshEvents.removeAll()
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
            model.connect(nil, sessions: nil)
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
