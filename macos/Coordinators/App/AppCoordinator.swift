import Foundation
import Observation

/// The window's coordinator. Owns the sidebar selection, the current `root` destination
/// it maps to, the child coordinators behind each screen, and app-wide presentations.
/// Follows record-ios: route -> model-bearing destination -> `Destination.view()`.
@MainActor @Observable final class AppCoordinator: Coordinatable {
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    struct Sheet: Identifiable {
        enum Destination {
            case newProject(ProjectEditorViewModel)
            case newSession(NewSessionViewModel)
            case build(BuildDestinationViewModel)
            case welcome(WelcomeViewModel)
        }
        let id: UUID
        let destination: Destination

        @MainActor func retire() {
            switch destination {
            case .newProject(let model): model.retire()
            case .newSession(let model): model.retire()
            case .build(let model): model.retire()
            case .welcome(let model): model.retire()
            }
        }

        @MainActor var canDismiss: Bool {
            switch destination {
            case .newProject(let model): !model.busy
            case .newSession(let model): !model.creating
            case .build(let model): !model.starting
            case .welcome(let model): !model.busy
            }
        }
    }

    private(set) var sheet: Sheet?
    struct RestartConfirmation: Identifiable {
        let id = UUID()
        let perform: () -> Void
    }
    private(set) var restartConfirmation: RestartConfirmation?

    /// Removing a session is a system confirmation, not a sheet of ours: the plan loads first
    /// (`preparing`), the dialog asks (`confirming`), and the work runs with the dialog already
    /// gone (`removing`). A failure at either end becomes an alert.
    struct RemovalRequest: Identifiable {
        enum Phase { case preparing, confirming, removing }
        let id: UUID
        let model: SessionRemovalViewModel
        var phase: Phase
    }
    struct RemovalFailure: Identifiable {
        let id = UUID()
        let message: String
    }
    private(set) var removal: RemovalRequest?
    private(set) var removalFailure: RemovalFailure?
    var canPresent: Bool {
        sheet == nil && restartConfirmation == nil && removal == nil && removalFailure == nil && !browserDialogCoordinator.isPresenting && !documentCloseCoordinator.isPresenting && !fileOpenCoordinator.isPresenting && !hasDocumentPresentation() && !projectCoordinators.values.contains { $0.isPresenting }
    }
    /// Deep links also wait for the Activity Clear confirmation. That sheet belongs to the Settings
    /// window, so it holds back routing without disabling the main window's commands.
    var canRoute: Bool { canPresent && logsCoordinator?.isPresenting != true }
    @ObservationIgnored var hasDocumentPresentation: () -> Bool = { false }
    @ObservationIgnored private let factory: any CreationFlowFactory
    @ObservationIgnored private let workspaceFactory: any WorkspaceFeatureFactory
    private(set) var selection: SidebarDestination
    @ObservationIgnored let selectionStore: any SidebarSelectionPersisting
    @ObservationIgnored weak var rootRuntime: (any RootCoordinating)?
    @ObservationIgnored var rootBindingID = UUID()
    @ObservationIgnored let router: any DeepLinkRouting
    @ObservationIgnored let projectCoordinatorFactory: any ProjectCoordinatorFactory
    @ObservationIgnored let canOpenExternalRoute: () -> Bool
    var projectCoordinators: [String: ProjectCoordinator] = [:]
    /// One per live workspace context, matched by the context object: ids change on promotion.
    var workspaceCoordinators: [SessionWorkspaceCoordinator] = []
    @ObservationIgnored weak var workspaceRuntime: (any WorkspaceCoordinating)?
    struct WeakProjectRuntime { weak var runtime: (any ProjectCoordinating)? }
    @ObservationIgnored var projectRuntimes: [String: WeakProjectRuntime] = [:]
    /// The sidebar and root placeholders bind to this; `makeRoot` installs it.
    var rootModel: RootViewModel?
    var appearance = AppAppearance.system {
        didSet { if oldValue != appearance { projectModels.values.forEach { $0.appearance = appearance } } }
    }
    var dashboardCoordinator: DashboardCoordinator?
    var logsCoordinator: LogsCoordinator?
    var settingsCoordinator: SettingsCoordinator?
    /// Whether the Settings window is on screen. Settings is its own window, not a selection,
    /// so this is what its coordinator's activity and `canPresent` follow.
    private(set) var settingsPresented = false
    /// Whether the Settings window is the key window: the font-size keys drive its sliders then.
    var settingsFocused = false
    /// Opens the Settings window; the app installs it, since only a view can reach the action.
    @ObservationIgnored var presentSettingsWindow: () -> Void = {}
    /// Activity is a section of the Settings window, so it is on screen only while both hold.
    var activityVisible: Bool { settingsPresented && settingsCoordinator?.model.section == .activity }
    func presentActivity() {
        settingsCoordinator?.model.section = .activity
        presentSettingsWindow()
    }
    /// The Settings window came on screen or left it.
    func setSettingsPresented(_ value: Bool) {
        settingsPresented = value
        if !value { settingsFocused = false; logsCoordinator?.endPresentation() }
        settingsCoordinator?.setActive(value)
    }
    var trayCoordinator: TrayCoordinator?
    var notificationCoordinator: NotificationCoordinator?
    let browserDialogCoordinator: BrowserDialogCoordinator
    let documentCloseCoordinator: EditorCloseCoordinator
    let fileOpenCoordinator: FileOpenCoordinator
    @ObservationIgnored var pendingDeepLink: DeepLink?
    @ObservationIgnored var routingReady = false
    var routingError: String?

    init(factory: any CreationFlowFactory, selectionStore: any SidebarSelectionPersisting = TransientSidebarSelectionStore(),
         workspaceFactory: any WorkspaceFeatureFactory = NativeWorkspaceFeatureFactory(),
         router: any DeepLinkRouting = CraftRouter(),
         projectCoordinatorFactory: any ProjectCoordinatorFactory = NativeProjectCoordinatorFactory(),
         documentCloseCoordinator: EditorCloseCoordinator = EditorCloseCoordinator(),
         browserDialogCoordinator: BrowserDialogCoordinator = BrowserDialogCoordinator(),
         fileOpenCoordinator: FileOpenCoordinator = FileOpenCoordinator(),
         canOpenExternalRoute: @escaping () -> Bool = { true }) {
        self.factory = factory; self.selectionStore = selectionStore
        self.workspaceFactory = workspaceFactory
        self.router = router; self.projectCoordinatorFactory = projectCoordinatorFactory
        self.canOpenExternalRoute = canOpenExternalRoute
        self.documentCloseCoordinator = documentCloseCoordinator
        self.browserDialogCoordinator = browserDialogCoordinator
        self.fileOpenCoordinator = fileOpenCoordinator
        selection = selectionStore.load() ?? .overview
        documentCloseCoordinator.presentationEnded = { [weak self] in self?.schedulePendingDeepLink() }
        browserDialogCoordinator.canPresent = { [weak self] in
            guard let self else { return false }
            return canPresent && canOpenExternalRoute()
        }
        browserDialogCoordinator.presentationEnded = { [weak self] in self?.schedulePendingDeepLink() }
        fileOpenCoordinator.canPresent = { [weak self] in
            guard let self else { return false }
            return canPresent && canOpenExternalRoute()
        }
        fileOpenCoordinator.presentationEnded = { [weak self] in self?.schedulePendingDeepLink() }
        // Removal sheets may legitimately ask to save documents. Only the file
        // picker reservation blocks this nested document-close operation.
        documentCloseCoordinator.canPresent = { [weak fileOpenCoordinator] in fileOpenCoordinator?.isPresenting == false }
    }

    func navigate(to destination: SidebarDestination) {
        // Picking Overview always lands on the Dashboard's home, never on a My Tickets left pushed.
        if destination == .overview { dashboardCoordinator?.leaveTickets() }
        if selection != destination {
            projectCoordinator?.endPresentation(); dashboardCoordinator?.model.cancelActions()
        }
        routingError = nil
        selection = destination
        for (id, child) in projectCoordinators { child.model.active = destination == .project(id) }
        selectionStore.save(destination)
        rootRuntime?.activateRootDestination()
        refreshRoot()
    }

    func navigate(to route: Route) {
        switch route {
        case .destination(let destination): navigate(to: destination)
        case .projectSection: projectCoordinator?.navigate(to: route)
        case .dashboardTickets:
            navigate(to: SidebarDestination.overview)
            // Through the model, like View All, so the list opens on every ticket, not a stale tag.
            dashboardCoordinator?.model.showTickets()
        }
    }

    /// The selection's destination, built from whichever child coordinator serves it.
    func makeDestination(for route: Route) -> Destination {
        guard case .destination(let destination) = route else { return .none }
        switch destination {
        case .overview:
            return dashboardCoordinator.map(Destination.dashboardCoordinator) ?? .unavailable(title: "Overview", message: "Connect to load the dashboard.")
        case .project(let id):
            return projectCoordinators[id].map(Destination.projectCoordinator) ?? .unavailable(title: rootModel?.title ?? "Project", message: "Connect to load this project.")
        // A workspace selection shows its coordinator once the viewer has activated the
        // context and a coordinator is bound to it; until then, the root placeholder.
        case .terminal:
            return activeWorkspaceCoordinator.map(Destination.sessionWorkspaceCoordinator)
                ?? rootModel.map(Destination.terminal) ?? .none
        case .session(let id):
            return activeWorkspaceCoordinator.map(Destination.sessionWorkspaceCoordinator)
                ?? rootModel.map { .session(id: id, $0) } ?? .none
        case .tab(let id):
            return activeWorkspaceCoordinator.map(Destination.sessionWorkspaceCoordinator)
                ?? rootModel.map { .tab(id: id, $0) } ?? .none
        }
    }

    /// The workspace in view, for the Product menu.
    var activeWorkspaceModel: SessionWorkspaceViewModel? { activeWorkspaceCoordinator?.model }

    private var activeWorkspaceCoordinator: SessionWorkspaceCoordinator? {
        guard let context = rootModel?.viewer.active else { return nil }
        return workspaceCoordinator(for: context)
    }

    /// The connection error the root model scopes to the current selection, and its remedy.
    var connectionError: String? { rootModel?.error }
    func reconnect() { handle(.root(.reconnect)) }

    /// Child coordinators arrive after the selection is restored, and a workspace's
    /// coordinator after its context is activated, so `root` is rebuilt whenever the
    /// selection or the set of children changes.
    func refreshRoot() {
        pruneWorkspaces()
        let next = makeDestination(for: .destination(selection))
        if root != next { root = next }
    }

    func handle(_ action: Action) {
        switch action {
        case .root(let action): handle(action)
        case .workspace(let action, let context): handleWorkspace(action, in: context)
        case .projectEvent(let event, let id): handleProjectEvent(event, projectID: id)
        case .dashboard, .logs, .settings, .project:
            self.action?(action) // Screen actions belong to their child coordinators.
        }
    }

    private func cancelPageActions() {
        settingsCoordinator?.cancelNavigation()
        projectCoordinator?.model.cancelActions(); dashboardCoordinator?.model.cancelActions()
        logsCoordinator?.model.cancelActions()
    }

    func presentNewProject(service: any ProjectService, didSave: @escaping (Project) -> Void) {
        guard canPresent else { return }
        cancelPageActions()
        let id = UUID()
        let model = factory.projectEditor(project: nil, service: service)
        model.onAction = { [weak self] action in
            guard case .saved(let project) = action, self?.complete(id) == true else { return }
            didSave(project)
        }
        sheet = Sheet(id: id, destination: .newProject(model))
    }

    func presentNewSession(request: SessionCreationRequest, operations: (any SessionCreating)?,
                           didCreate: @escaping (WorkspaceSession) -> Void) {
        guard canPresent else { return }
        cancelPageActions()
        let id = UUID()
        let model = factory.newSession(request: request, operations: operations)
        model.onAction = { [weak self] action in
            guard case .created(let session) = action, self?.complete(id) == true else { return }
            didCreate(session)
        }
        sheet = Sheet(id: id, destination: .newSession(model))
    }

    /// The first-run welcome, or a rerun from Settings. Returns whether it went up, so the
    /// caller records it as shown only when the user actually saw it.
    @discardableResult func presentWelcome(_ makeModel: () -> WelcomeViewModel) -> Bool {
        guard canPresent else { return false }
        cancelPageActions()
        let id = UUID()
        let model = makeModel()
        model.onAction = { [weak self] action in
            guard let self, sheet?.id == id else { return }
            switch action {
            case .finished: _ = complete(id)
            }
        }
        sheet = Sheet(id: id, destination: .welcome(model))
        return true
    }
    var welcomeModel: WelcomeViewModel? {
        if case .welcome(let model) = sheet?.destination { model } else { nil }
    }

    func dismissSheet(id: UUID) {
        guard sheet?.id == id, sheet?.canDismiss == true else { return }
        _ = complete(id)
    }

    /// Checks the worktree first, so the dialog can state exactly what goes before it asks.
    func presentRemoval(_ makeModel: () -> SessionRemovalViewModel?) {
        guard canPresent, let model = makeModel(), !model.retired, !model.completed else { return }
        cancelPageActions()
        let id = UUID()
        model.onAction = { [weak self] action in
            guard let self, case .removed(let sessions) = action, removal?.id == id else { return }
            if case .session(let selected) = selection, sessions.contains(where: { $0.id == selected }) {
                navigate(to: .overview)
            }
        }
        removal = RemovalRequest(id: id, model: model, phase: .preparing)
        Task { [weak self] in
            await model.load()
            guard let self, let request = removal, request.id == id, request.phase == .preparing else { return }
            guard model.plan != nil, !model.retired else { return endRemoval(id, failure: model.error) }
            removal?.phase = .confirming
        }
    }

    /// Cancel, or a preparation that produced nothing. Refused once removal is under way.
    func cancelRemoval(id: UUID) {
        guard let request = removal, request.id == id, request.phase != .removing else { return }
        endRemoval(id, failure: nil)
    }

    func confirmRemoval(id: UUID) {
        guard let request = removal, request.id == id, request.phase == .confirming, request.model.canRemove else { return }
        removal?.phase = .removing
        Task { [weak self] in
            await request.model.remove()
            guard let self, removal?.id == id else { return }
            endRemoval(id, failure: request.model.completed ? nil : request.model.error)
        }
    }

    func dismissRemovalFailure(id: UUID) {
        guard removalFailure?.id == id else { return }
        removalFailure = nil
        schedulePendingDeepLink()
    }

    private func endRemoval(_ id: UUID, failure: String?) {
        guard let request = removal, request.id == id else { return }
        removal = nil
        request.model.retire()
        if let failure { removalFailure = RemovalFailure(message: failure) } else { schedulePendingDeepLink() }
    }

    func presentBuild(purpose: BuildDestinationViewModel.Purpose = .run, _ makeModel: () -> BuildWorkspaceViewModel?) {
        guard canPresent, let runtime = makeModel() else { return }
        let model = workspaceFactory.buildDestination(runtime: runtime, purpose: purpose)
        guard !model.retired else { return }
        present(model)
    }

    /// Run goes straight to the saved destination; the sheet is for a project that has
    /// none, or for a run that failed and needs another choice.
    func runBuild(_ makeModel: () -> BuildWorkspaceViewModel?) {
        guard canPresent, let runtime = makeModel() else { return }
        guard runtime.hasSavedDestination else { return presentBuild { runtime } }
        let model = workspaceFactory.buildDestination(runtime: runtime, purpose: .run)
        guard !model.retired else { return }
        Task { [weak self] in
            if await model.runSaved() { return }
            guard let self, canPresent, model.presentable else { return model.retire() }
            present(model)
        }
    }

    private func present(_ model: BuildDestinationViewModel) {
        cancelPageActions()
        let id = UUID()
        model.onAction = { [weak self] action in
            switch action { case .started, .saved: _ = self?.complete(id) }
        }
        sheet = Sheet(id: id, destination: .build(model))
    }

    func presentRestart(perform: @escaping () -> Void) {
        guard canPresent else { return }
        cancelPageActions()
        restartConfirmation = RestartConfirmation(perform: perform)
    }

    func dismissRestart(id: UUID) {
        if restartConfirmation?.id == id { restartConfirmation = nil; schedulePendingDeepLink() }
    }

    func confirmRestart(id: UUID) {
        guard let confirmation = restartConfirmation, confirmation.id == id else { return }
        restartConfirmation = nil
        confirmation.perform()
        schedulePendingDeepLink()
    }

    private func complete(_ id: UUID) -> Bool {
        guard let sheet, sheet.id == id else { return false }
        self.sheet = nil
        sheet.retire()
        schedulePendingDeepLink()
        return true
    }
}
