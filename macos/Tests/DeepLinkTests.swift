import AppKit
import Testing

@Test func deepLinksRoundTripSupportedRoutesAndProjectChains() throws {
    let router = CraftRouter()
    let roots: [SidebarDestination] = [.overview, .terminal, .project("p-123"), .session("s_123")]
    let links = roots.map { DeepLink(.destination($0)) }
        + ProjectSection.allCases.map { DeepLink([.destination(.project("p-123")), .projectSection($0)]) }
    for link in links {
        let url = try #require(router.url(for: link))
        #expect(router.deepLink(for: url) == link)
    }
    let chain = try #require(router.deepLink(for: URL(string: "craft://app/projects/p-123/board")!))
    #expect(chain.first == .destination(.project("p-123")))
    #expect(chain.droppingFirst() == DeepLink(.projectSection(.board)))
    #expect(chain.droppingFirst().droppingFirst().routes.isEmpty)
    #expect(router.url(for: DeepLink(.destination(.tab("https://example.test")))) == nil)
    #expect(router.url(for: DeepLink([.destination(.terminal), .projectSection(.board)])) == nil)
    #expect(router.url(for: DeepLink(.destination(.session("../s")))) == nil)
}

@Test(arguments: [
    "https://app/overview", "craft://other/overview", "craft://user@app/overview",
    "craft://app:42/overview", "craft://app/overview?command=run", "craft://app/overview#fragment",
    "craft://app/overview?", "craft://app/overview#", "craft://app/", "craft://app",
    "craft://app//overview", "craft://app/overview/", "craft://app/overview/extra",
    "craft://app/projects", "craft://app/projects/id/unknown", "craft://app/projects/id/board/extra",
    "craft://app/sessions/one/two", "craft://app/sessions/%2Fetc", "craft://app/sessions/%252Fetc",
    "craft://app/sessions/..", "craft://app/sessions/%00", "craft://app/sessions/hello%20world",
    "craft://app/terminal/run", "craft://app/sessions/" + String(repeating: "x", count: 257)
]) func deepLinksRejectUnsupportedOrAmbiguousURLs(_ value: String) throws {
    #expect(CraftRouter().deepLink(for: try #require(URL(string: value))) == nil)
}

private struct TestRouteHandler: DeepLinkRouteHandling {
    let destination: SidebarDestination
    func parse(_ components: [String]) -> DeepLink? { components == ["fixture"] ? DeepLink(.destination(destination)) : nil }
    func print(_ deepLink: DeepLink) -> [String]? { deepLink == DeepLink(.destination(destination)) ? ["fixture"] : nil }
}

@Test func deepLinkRouterUsesInjectedHandlersInOrder() throws {
    let router = CraftRouter(handlers: [TestRouteHandler(destination: .terminal), TestRouteHandler(destination: .overview)])
    let url = try #require(URL(string: "craft://app/fixture"))
    #expect(router.deepLink(for: url) == DeepLink(.destination(.terminal)))
    #expect(router.url(for: DeepLink(.destination(.terminal))) == url)
    #expect(router.deepLink(for: URL(string: "craft://app/settings")!) == nil)
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
    func closeTab(_ url: String) {}
    func openTerminal() { terminals += 1 }
    func openRootBrowser(_ url: URL) {}
}

private struct DeepLinkProjectService: ProjectService {
    func load(_ id: String) async throws -> Project { throw CancellationError() }
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project { throw CancellationError() }
    func delete(_ id: String) async throws {}
    func detectRepository(_ path: String) async throws -> String { "" }
    func pullRequests(_ id: String, state: String, force: Bool) async throws -> ProjectPRSnapshot { .init() }
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
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
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
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
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
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
    #expect(coordinator.selection == .overview && coordinator.pendingDeepLink != nil)
    await gate.finish()
    while coordinator.pendingDeepLink != nil { await Task.yield() }
    #expect(coordinator.selection == .terminal && coordinator.canPresent)
    #expect(surface.disposed == save)
    if !save { #expect(document.dirty && !document.closing && !surface.frozen) }
    document.dispose()
}

@MainActor @Test func deepLinkCoordinatorDefersUntilSnapshotAndForwardsProjectRemainder() throws {
    let factory = DeepLinkProjectFactory()
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), projectCoordinatorFactory: factory)
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    #expect(coordinator.handle(url: URL(string: "craft://app/projects/p/board")!))
    #expect(runtime.selections.isEmpty && coordinator.pendingDeepLink != nil)
    // Jira sections only exist for a project with Jira configured.
    let project = Project(id: "p", name: "Fixture", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: "APP")
    let service = DeepLinkProjectService()
    let editor = ProjectEditorViewModel(project: project, service: service, chooseFolder: { nil })
    let model = ProjectPageViewModel(project: project, service: service, editor: editor)
    runtime.state.projects = [project]; runtime.state.projectModels[project.id] = model
    coordinator.setRoutingReady(true)
    #expect(coordinator.selection == .project("p") && model.section == .board)
    #expect(factory.creations == 1 && coordinator.projectCoordinator?.model === model && coordinator.pendingDeepLink == nil)
    coordinator.handle(url: URL(string: "craft://app/projects/p/tickets")!)
    #expect(model.section == .tickets && factory.creations == 1)
    #expect(coordinator.projectCoordinator?.navigate(to: DeepLink(.destination(.overview))) == false)
    coordinator.handle(url: URL(string: "craft://app/sessions/missing")!)
    #expect(coordinator.selection == .project("p") && coordinator.routingError != nil && runtime.terminals == 0)
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
    #expect(coordinator.selection == .terminal && coordinator.routingError == nil && runtime.terminals == 0)
    #expect(coordinator.projectCoordinator == nil)
}

@MainActor @Test func deepLinkCoordinatorKeepsLatestValidIntentAndRevalidatesAfterReconnect() throws {
    var presentationOpen = false
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), canOpenExternalRoute: { !presentationOpen })
    let runtime = DeepLinkRuntime(); runtime.coordinator = coordinator; coordinator.rootRuntime = runtime
    runtime.state.sessions = [WorkspaceSession(id: "s", projectId: "p", workspace: "/tmp", worktree: "/tmp/worktree", title: "Title",
        branch: "feature", url: "", createdAt: nil, pinned: false)]
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
    coordinator.handle(url: URL(string: "craft://app/sessions/s")!)
    #expect(!coordinator.handle(url: URL(string: "https://example.test/terminal")!))
    coordinator.setRoutingReady(true)
    #expect(runtime.selections == [.session("s")])
    presentationOpen = true
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
    #expect(coordinator.selection == .session("s"))
    presentationOpen = false
    coordinator.processPendingDeepLink()
    #expect(coordinator.selection == .terminal)
    coordinator.setRoutingReady(false)
    coordinator.handle(url: URL(string: "craft://app/sessions/removed")!)
    coordinator.setRoutingReady(true)
    #expect(coordinator.selection == .terminal && coordinator.routingError == "The linked session is no longer available.")
    coordinator.setRoutingReady(false)
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
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
    coordinator.handle(url: URL(string: "craft://app/terminal")!)
    #expect(coordinator.sheet?.id == sheet.id && model.draft.name == "Keep this draft" && runtime.selections.isEmpty)
    await withCheckedContinuation { continuation in
        runtime.didNavigate = { continuation.resume(); runtime.didNavigate = nil }
        coordinator.dismissSheet(id: sheet.id)
    }
    #expect(coordinator.selection == .terminal && coordinator.sheet == nil)
    var restartedAt: SidebarDestination?
    coordinator.presentRestart { restartedAt = coordinator.selection }
    let confirmation = try #require(coordinator.restartConfirmation)
    coordinator.handle(url: URL(string: "craft://app/overview")!)
    coordinator.dismissRestart(id: UUID())
    #expect(coordinator.restartConfirmation?.id == confirmation.id && coordinator.selection == .terminal)
    await withCheckedContinuation { continuation in
        runtime.didNavigate = { continuation.resume(); runtime.didNavigate = nil }
        coordinator.confirmRestart(id: confirmation.id)
    }
    #expect(restartedAt == .terminal && coordinator.selection == .overview && coordinator.pendingDeepLink == nil)
}
