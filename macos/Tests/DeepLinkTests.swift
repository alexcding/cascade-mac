import AppKit
import Testing

@Test func deepLinksRoundTripSupportedRoutesAndProjectChains() throws {
    let router = CascadeRouter()
    let roots: [SidebarDestination] = [.overview, .terminal, .project("p-123"), .session("s_123")]
    let links = roots.map { DeepLink(.destination($0)) }
    for link in links {
        let url = try #require(router.url(for: link))
        #expect(router.deepLink(for: url) == link)
    }
    // Sections the project page dropped still open the project; its settings are in its inspector.
    for retired in ["prs", "workflows", "tickets", "settings"] {
        #expect(router.deepLink(for: URL(string: "cascade://app/projects/p-123/\(retired)")!) == DeepLink(.destination(.project("p-123"))))
    }
    // A project's board link opens the project on its Board tab.
    let board = DeepLink([.destination(.project("p-123")), .projectBoard(projectID: "p-123")])
    #expect(router.deepLink(for: URL(string: "cascade://app/projects/p-123/board")!) == board)
    #expect(router.url(for: board)?.absoluteString == "cascade://app/projects/p-123/board")
    #expect(router.url(for: DeepLink([.destination(.terminal), .projectBoard(projectID: "p-123")])) == nil)
    #expect(router.url(for: DeepLink([.destination(.project("other")), .projectBoard(projectID: "p-123")])) == nil)
    #expect(router.deepLink(for: URL(string: "cascade://app/projects/p-123/unknown")!) == nil)
    #expect(router.url(for: DeepLink(.destination(.session("../s")))) == nil)
}

@Test(arguments: [
    "https://app/overview", "cascade://other/overview", "cascade://user@app/overview",
    "cascade://app:42/overview", "cascade://app/overview?command=run", "cascade://app/overview#fragment",
    "cascade://app/overview?", "cascade://app/overview#", "cascade://app/", "cascade://app",
    "cascade://app//overview", "cascade://app/overview/", "cascade://app/overview/extra",
    "cascade://app/projects", "cascade://app/projects/id/unknown", "cascade://app/projects/id/board/extra",
    "cascade://app/sessions/one/two", "cascade://app/sessions/%2Fetc", "cascade://app/sessions/%252Fetc",
    "cascade://app/sessions/..", "cascade://app/sessions/%00", "cascade://app/sessions/hello%20world",
    "cascade://app/terminal/run", "cascade://app/sessions/" + String(repeating: "x", count: 257)
]) func deepLinksRejectUnsupportedOrAmbiguousURLs(_ value: String) throws {
    #expect(CascadeRouter().deepLink(for: try #require(URL(string: value))) == nil)
}

private struct TestRouteHandler: DeepLinkRouteHandling {
    let destination: SidebarDestination
    func parse(_ components: [String]) -> DeepLink? { components == ["fixture"] ? DeepLink(.destination(destination)) : nil }
    func print(_ deepLink: DeepLink) -> [String]? { deepLink == DeepLink(.destination(destination)) ? ["fixture"] : nil }
}

@Test func deepLinkRouterUsesInjectedHandlersInOrder() throws {
    let router = CascadeRouter(handlers: [TestRouteHandler(destination: .terminal), TestRouteHandler(destination: .overview)])
    let url = try #require(URL(string: "cascade://app/fixture"))
    #expect(router.deepLink(for: url) == DeepLink(.destination(.terminal)))
    #expect(router.url(for: DeepLink(.destination(.terminal))) == url)
    #expect(router.deepLink(for: URL(string: "cascade://app/settings")!) == nil)
}

@MainActor private final class DeepLinkRuntime: RootCoordinating {
    var state = RootState()
    var selections: [SidebarDestination] = []
    var terminals = 0
    var didNavigate: (() -> Void)?
    weak var coordinator: AppCoordinator?
    func rootState() -> RootState { state }
    func activateRootDestination() {
        if let coordinator { state.selection = coordinator.selection; selections.append(coordinator.selection) }
        didNavigate?()
    }
    func performRootCommand(_ command: ShellCommand) {}
    func reconnect() async {}
    func togglePin(_ id: String) {}
    func openTerminal() { terminals += 1 }
}

private struct DeepLinkProjectService: ProjectService {
    func load(_ id: String) async throws -> Project { throw CancellationError() }
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project { throw CancellationError() }
    func delete(_ id: String) async throws {}
    func detectRepository(_ path: String) async throws -> String { "" }
}

private struct DeepLinkLogsService: LogService {
    func categories() -> [String] { ["event"] }
    func entries(category: String, errorsOnly: Bool) -> [LogEntry] { [] }
    func clear(category: String) {}
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func deepLinksWaitForActivityClearConfirmationToFinish(confirm: Bool) async throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    let model = coordinator.makeLogs(factory: NativeLogsFeatureFactory(), pageActions: ProjectPageActions(), copy: { _ in })
    model.connect(DeepLinkLogsService())
    let settingsChild = coordinator.installSettings(settingsFixtureModel(), runtime: SettingsRuntimeFixture())
    settingsChild.model.section = .activity
    coordinator.setSettingsPresented(true)
    coordinator.setRoutingReady(true)
    model.requestClear()
    let child = try #require(coordinator.logsCoordinator), request = try #require(child.confirmation)
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    #expect(coordinator.selection == .overview && coordinator.pendingDeepLink != nil)
    if confirm { await child.confirm(id: request.id) } else { child.cancel(id: request.id) }
    while coordinator.pendingDeepLink != nil { await Task.yield() }
    #expect(coordinator.selection == .terminal && coordinator.canPresent)
    child.retire(); settingsChild.retire()
}

@MainActor private final class DeepLinkProjectFactory: ProjectCoordinatorFactory {
    var creations = 0
    func project(model: ProjectPageViewModel) -> ProjectCoordinator { creations += 1; return ProjectCoordinator(model: model) }
}

@MainActor private final class DeepLinkFilePresenter: FileOpenPresenting {
    var completion: ((URL?) -> Void)?
    func present(in window: NSWindow?, directory: URL?, completion: @escaping (URL?) -> Void) -> () -> Void {
        self.completion = completion
        return { completion(nil) }
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func deepLinksWaitForFilePickerAndResumeAfterSelectionOrCancel(select: Bool) async throws {
    let presenter = DeepLinkFilePresenter(), picker = FileOpenCoordinator(presenter: presenter)
    let model = FileOpenViewModel()
    let context = WorkspaceContext(id: "picker", sourceURL: "", title: "Picker")
    picker.bind(model, activeContext: { context }, window: { nil })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(), fileOpenCoordinator: picker)
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    coordinator.setRoutingReady(true)
    model.begin(contextID: context.id)
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    #expect(coordinator.selection == .overview && coordinator.pendingDeepLink != nil)
    presenter.completion?(select ? URL(fileURLWithPath: "/tmp/deep-link-selected.swift") : nil)
    while coordinator.pendingDeepLink != nil { await Task.yield() }
    #expect(coordinator.selection == .terminal && coordinator.canPresent)
    #expect(context.documents.count == (select ? 1 : 0))
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func deepLinksWaitForDocumentCloseAndResumeAfterSaveOrCancel(save: Bool) async throws {
    let presenter = EditorClosePresenterFixture(), gate = ProjectPageGate()
    let closer = EditorCloseCoordinator(presenter: presenter)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), documentCloseCoordinator: closer)
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    coordinator.setRoutingReady(true)
    let (document, surface, _) = await closeFixtureDocument("/tmp/deep-link.swift")
    presenter.chooseAction = { _ in try? await gate.wait(); return save ? .save : .cancel }
    closer.requestClose([document], isOwned: { true }, commit: { document.dispose() })
    #expect(!coordinator.canPresent) // Reserved before the prompt task runs.
    coordinator.presentNewProject(service: DeepLinkProjectService(), didSave: { _ in })
    #expect(coordinator.sheet == nil)
    await gate.waitForStart()
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    #expect(coordinator.selection == .overview && coordinator.pendingDeepLink != nil)
    await gate.finish()
    while coordinator.pendingDeepLink != nil { await Task.yield() }
    #expect(coordinator.selection == .terminal && coordinator.canPresent)
    #expect(surface.disposed == save)
    if !save { #expect(document.dirty && !document.closing && !surface.frozen) }
    document.dispose()
}

@MainActor @Test func deepLinkCoordinatorDefersUntilSnapshotAndOpensRetiredProjectSections() throws {
    let factory = DeepLinkProjectFactory()
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), projectCoordinatorFactory: factory)
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    #expect(coordinator.handle(url: URL(string: "cascade://app/projects/p/settings")!))
    #expect(runtime.selections.isEmpty && coordinator.pendingDeepLink != nil)
    // The project page is one screen, so a link to one of its old sections opens the project.
    let project = Project(id: "p", name: "Fixture", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: "APP")
    runtime.state.projects = [project]
    coordinator.setRoutingReady(true)
    #expect(coordinator.selection == .project("p") && coordinator.pendingDeepLink == nil && factory.creations == 0)
    coordinator.handle(url: URL(string: "cascade://app/sessions/missing")!)
    #expect(coordinator.selection == .project("p") && coordinator.routingError != nil && runtime.terminals == 0)
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    #expect(coordinator.selection == .terminal && coordinator.routingError == nil && runtime.terminals == 0)
    #expect(coordinator.projectCoordinator == nil)
    // A project's board link opens the project, and only for a project that still exists.
    coordinator.handle(url: URL(string: "cascade://app/projects/p/board")!)
    #expect(coordinator.selection == .project("p") && coordinator.routingError == nil)
    coordinator.navigate(to: SidebarDestination.terminal)
    coordinator.handle(url: URL(string: "cascade://app/projects/gone/board")!)
    #expect(coordinator.selection == .terminal && coordinator.routingError == "The linked project is no longer available.")
    runtime.state.projects.append(Project(id: "plain", name: "No Jira", repo: "", color: nil, workspace: "/tmp"))
    coordinator.handle(url: URL(string: "cascade://app/projects/plain/board")!)
    #expect(coordinator.selection == .terminal && coordinator.routingError == "The linked project has no Jira board.")
}

@MainActor @Test func deepLinkCoordinatorKeepsLatestValidIntentAndRevalidatesAfterReconnect() throws {
    var presentationOpen = false
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), canOpenExternalRoute: { !presentationOpen })
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    runtime.state.sessions = [WorkspaceSession(id: "s", projectId: "p", workspace: "/tmp", worktree: "/tmp/worktree", title: "Title",
        branch: "feature", url: "", createdAt: nil, pinned: false)]
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    coordinator.handle(url: URL(string: "cascade://app/sessions/s")!)
    #expect(!coordinator.handle(url: URL(string: "https://example.test/terminal")!))
    coordinator.setRoutingReady(true)
    #expect(runtime.selections == [.session("s")])
    presentationOpen = true
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    #expect(coordinator.selection == .session("s"))
    presentationOpen = false
    coordinator.processPendingDeepLink()
    #expect(coordinator.selection == .terminal)
    coordinator.setRoutingReady(false)
    coordinator.handle(url: URL(string: "cascade://app/sessions/removed")!)
    coordinator.setRoutingReady(true)
    #expect(coordinator.selection == .terminal && coordinator.routingError == "The linked session is no longer available.")
    coordinator.setRoutingReady(false)
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    coordinator.handle(RootViewModel.Action.select(.overview))
    coordinator.setRoutingReady(true)
    #expect(coordinator.selection == .overview && coordinator.pendingDeepLink == nil && coordinator.routingError == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func deepLinksPreserveDraftAndRestartOriginUntilPresentationFinishes() async throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    coordinator.setRoutingReady(true)
    coordinator.presentNewProject(service: DeepLinkProjectService(), didSave: { _ in })
    let sheet = try #require(coordinator.sheet)
    guard case .newProject(let model) = sheet.destination else { Issue.record("Missing draft"); return }
    model.draft.name = "Keep this draft"
    coordinator.handle(url: URL(string: "cascade://app/terminal")!)
    #expect(coordinator.sheet?.id == sheet.id && model.draft.name == "Keep this draft" && runtime.selections.isEmpty)
    await withCheckedContinuation { continuation in
        runtime.didNavigate = { continuation.resume(); runtime.didNavigate = nil }
        coordinator.dismissSheet(id: sheet.id)
    }
    #expect(coordinator.selection == .terminal && coordinator.sheet == nil)
    var restartedAt: SidebarDestination?
    coordinator.presentRestart { restartedAt = coordinator.selection }
    let confirmation = try #require(coordinator.restartConfirmation)
    coordinator.handle(url: URL(string: "cascade://app/overview")!)
    coordinator.dismissRestart(id: UUID())
    #expect(coordinator.restartConfirmation?.id == confirmation.id && coordinator.selection == .terminal)
    await withCheckedContinuation { continuation in
        runtime.didNavigate = { continuation.resume(); runtime.didNavigate = nil }
        coordinator.confirmRestart(id: confirmation.id)
    }
    #expect(restartedAt == .terminal && coordinator.selection == .overview && coordinator.pendingDeepLink == nil)
}
