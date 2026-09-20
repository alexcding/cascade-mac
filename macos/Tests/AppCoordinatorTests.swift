import Foundation
import Testing

@MainActor private final class WorkspaceCoordinatorFixture: WorkspaceCoordinating {
    var state = SessionWorkspaceState()
    var owns = true
    var operations: [WorkspaceOperation] = []
    var buildRequests = 0
    var removalRequests = 0
    var restarts: [String] = []
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { state }
    func ownsWorkspace(_ context: WorkspaceContext) -> Bool { owns }
    func performWorkspaceOperation(_ operation: WorkspaceOperation, in context: WorkspaceContext) { operations.append(operation) }
    func makeWorkspaceBuild(in context: WorkspaceContext) -> BuildWorkspaceViewModel? { buildRequests += 1; return nil }
    func makeWorkspaceRemoval(in context: WorkspaceContext) -> SessionRemovalViewModel? { removalRequests += 1; return nil }
    func restartWorkspaceSession(_ id: String, in context: WorkspaceContext) { if owns { restarts.append(id) } }
}

@MainActor @Test func workspaceActionsAreHandledByCoordinatorAndRejectUnownedContexts() throws {
    let context = WorkspaceContext(id: "task:fixture", sourceURL: "", title: "Fixture")
    let runtime = WorkspaceCoordinatorFixture()
    runtime.state.session = WorkspaceSession(id: "fixture", projectId: "p", workspace: "/tmp", worktree: "/tmp/fixture",
        title: "Fixture", branch: "fixture", url: "", createdAt: nil, pinned: false)
    runtime.state.project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    runtime.state.canPresent = true; runtime.state.connected = true
    let model = SessionWorkspaceViewModel(context: context, service: runtime)
    var coordinator: AppCoordinator? = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator?.bindWorkspace(model, context: context, runtime: runtime)
    model.openTerminal()
    #expect(runtime.operations == [.openTerminal])
    model.restart()
    let request = try #require(coordinator?.restartConfirmation)
    model.run(); model.remove()
    #expect(runtime.buildRequests == 0 && runtime.removalRequests == 0)
    coordinator?.confirmRestart(id: request.id)
    #expect(runtime.restarts == ["fixture"])
    model.run(); model.remove()
    #expect(runtime.buildRequests == 1 && runtime.removalRequests == 1)
    runtime.owns = false
    model.openTerminal(); model.restart(); model.run()
    #expect(runtime.operations == [.openTerminal] && coordinator?.restartConfirmation == nil && runtime.buildRequests == 1)
    runtime.owns = true
    model.restart()
    let stale = try #require(coordinator?.restartConfirmation)
    runtime.owns = false
    coordinator?.confirmRestart(id: stale.id)
    #expect(runtime.restarts == ["fixture"])
    runtime.owns = true; coordinator = nil
    model.openTerminal(); model.restart()
    #expect(runtime.operations == [.openTerminal])
}

@MainActor @Test func workspaceRestartConfirmationBlocksOtherFlowsAndRejectsCancelledOrDuplicateActions() throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    var restarts = 0, factories = 0
    coordinator.presentRestart { restarts += 1 }
    let first = try #require(coordinator.restartConfirmation)
    #expect(!coordinator.canPresent)
    coordinator.presentRemoval { factories += 1; return nil }
    coordinator.presentBuild { factories += 1; return nil }
    #expect(factories == 0 && coordinator.sheet == nil)
    coordinator.confirmRestart(id: UUID())
    #expect(restarts == 0 && coordinator.restartConfirmation?.id == first.id)
    coordinator.dismissRestart(id: first.id)
    coordinator.confirmRestart(id: first.id)
    #expect(restarts == 0 && coordinator.canPresent)
    coordinator.presentRestart { restarts += 1 }
    let second = try #require(coordinator.restartConfirmation)
    coordinator.confirmRestart(id: first.id)
    coordinator.confirmRestart(id: second.id)
    coordinator.confirmRestart(id: second.id)
    #expect(restarts == 1 && coordinator.canPresent)
}

@MainActor @Test func workspaceTabCallbacksResolveCurrentOwnedTabsAndRespectPresentationGates() throws {
    let context = WorkspaceContext(id: "tabs", sourceURL: "", title: "Tabs")
    let runtime = WorkspaceCoordinatorFixture(), model = SessionWorkspaceViewModel(context: context, service: runtime)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.bindWorkspace(model, context: context, runtime: runtime)
    let first = try #require(context.open("https://example.test/first"))
    let second = try #require(context.open("https://example.test/second"))
    model.selectTab(.page(first)); #expect(context.activeID == first.id)
    runtime.owns = false
    model.selectTab(.page(second)); model.closeTab(.page(first))
    #expect(context.activeID == first.id && context.pages.count == 2)
    runtime.owns = true; coordinator.presentRestart {}
    model.closeTab(.page(first)); #expect(context.pages.count == 2)
    coordinator.dismissRestart(id: try #require(coordinator.restartConfirmation).id)
    let foreign = WorkspaceContext(id: "foreign", sourceURL: "", title: "Foreign")
    let tab = try #require(foreign.open("https://example.test/foreign"))
    model.selectTab(.page(tab)); model.closeTab(.page(tab))
    #expect(context.activeID == first.id && context.pages.count == 2)
    model.closeTab(.page(first)); model.closeTab(.page(first))
    #expect(context.pages.count == 1 && context.activeID == second.id)
}

@MainActor @Test func workspaceTabMovesBeforeItsTargetOrToTheEndAndRespectsOwnership() throws {
    let context = WorkspaceContext(id: "tabs", sourceURL: "", title: "Tabs")
    let runtime = WorkspaceCoordinatorFixture(), model = SessionWorkspaceViewModel(context: context, service: runtime)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.bindWorkspace(model, context: context, runtime: runtime)
    let ids = try ["first", "second", "third"].map { try #require(context.open("https://example.test/\($0)")).id }
    let start = context.tabOrder
    #expect(Set(start) == Set(ids))
    model.moveTab(start[2], before: start[0])
    #expect(context.tabOrder == [start[2], start[0], start[1]] && context.pages.map(\.id) == context.tabOrder)
    model.moveTab(start[2], before: nil)
    #expect(context.tabOrder == [start[0], start[1], start[2]])
    model.moveTab(start[0], before: start[0]); model.moveTab("missing", before: nil)
    #expect(context.tabOrder == start)
    runtime.owns = false
    model.moveTab(start[2], before: start[0])
    #expect(context.tabOrder == start)
}

private actor CreationProjectService: ProjectService {
    private var pending: CheckedContinuation<Project, any Error>?
    private var waiting: CheckedContinuation<Void, Never>?
    func load(_ id: String) -> Project { Self.project }
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project {
        try await withCheckedThrowingContinuation {
            pending = $0
            waiting?.resume(); waiting = nil
        }
    }
    func waitForSave() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish(failing: Bool) {
        let current = pending; pending = nil
        if failing { current?.resume(throwing: BackendError.operation("Fixture save failed")) }
        else { current?.resume(returning: Self.project) }
    }
    func delete(_ id: String) {}
    func detectRepository(_ path: String) -> String { "fixture/repo" }
    func pullRequests(_ id: String, state: String, force: Bool) -> ProjectPRSnapshot { .init() }
    static let project = Project(id: "created", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")
}

@MainActor private final class RecordingCreationFactory: CreationFlowFactory {
    let native = NativeCreationFlowFactory(chooseFolder: { "/tmp/injected-folder" })
    var projectCompletions: [(Project) -> Void] = []
    var sessionCompletions: [(WorkspaceSession) -> Void] = []
    func projectEditor(project: Project?, service: any ProjectService) -> ProjectEditorViewModel {
        let model = native.projectEditor(project: project, service: service)
        projectCompletions.append { [weak model] in model?.onAction(.saved($0)) }
        return model
    }
    func newSession(request: SessionCreationRequest, operations: (any SessionCreating)?) -> NewSessionViewModel {
        let model = native.newSession(request: request, operations: operations)
        sessionCompletions.append { [weak model] in model?.onAction(.created($0)) }
        return model
    }
}

@MainActor @Test func creationCoordinatorRetainsDraftRejectsDuplicateRoutesAndIgnoresStaleCompletion() async throws {
    let factory = RecordingCreationFactory(), service = CreationProjectService()
    let coordinator = AppCoordinator(factory: factory)
    var saved: [String] = []
    let open = { coordinator.presentNewProject(service: service, didSave: { saved.append($0.id) }) }
    open()
    let first = try #require(coordinator.sheet)
    guard case .newProject(let model) = first.destination else { Issue.record("Wrong destination"); return }
    model.draft.name = "Unsaved draft"
    await model.pickFolder()
    open()
    #expect(factory.projectCompletions.count == 1 && coordinator.sheet?.id == first.id)
    #expect(model.draft.name == "Unsaved draft" && model.draft.workspace == "/tmp/injected-folder")
    coordinator.dismissSheet(id: first.id)
    open()
    let second = try #require(coordinator.sheet)
    guard case .newProject(let fresh) = second.destination else { Issue.record("Wrong destination"); return }
    #expect(first.id != second.id && model !== fresh && fresh.draft.name.isEmpty)
    coordinator.dismissSheet(id: first.id)
    factory.projectCompletions[0](CreationProjectService.project)
    #expect(coordinator.sheet?.id == second.id && saved.isEmpty)
    factory.projectCompletions[1](CreationProjectService.project)
    factory.projectCompletions[1](CreationProjectService.project)
    #expect(coordinator.sheet == nil && saved == ["created"])
}

@MainActor @Test(.timeLimit(.minutes(1))) func creationCoordinatorBlocksDismissalDuringSaveAndPreservesFailureForRetry() async throws {
    let service = CreationProjectService()
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    var saved: Project?
    coordinator.presentNewProject(service: service, didSave: { saved = $0 })
    let sheet = try #require(coordinator.sheet)
    guard case .newProject(let model) = sheet.destination else { Issue.record("Wrong destination"); return }
    model.draft.name = "Keep this draft"
    let failing = Task { await model.save() }
    await service.waitForSave()
    coordinator.dismissSheet(id: sheet.id)
    #expect(coordinator.sheet?.id == sheet.id && model.busy && !sheet.canDismiss)
    await service.finish(failing: true)
    await failing.value
    #expect(coordinator.sheet?.id == sheet.id && saved == nil)
    #expect(model.error == "Fixture save failed" && model.draft.name == "Keep this draft" && sheet.canDismiss)
    let retry = Task { await model.save() }
    await service.waitForSave()
    await service.finish(failing: false)
    await retry.value
    #expect(coordinator.sheet == nil && saved?.id == "created")
}

@MainActor @Test func creationCoordinatorInjectsSessionContextAndCompletesOnlyItsOwnPresentation() throws {
    let factory = RecordingCreationFactory(), coordinator = AppCoordinator(factory: factory)
    let project = CreationProjectService.project
    let url = "https://github.com/fixture/repo/pull/42"
    let request = SessionCreationRequest(project: project, agent: .codex, pageURL: url)
    var created = 0
    let open = { coordinator.presentNewSession(request: request, operations: nil, didCreate: { _ in created += 1 }) }
    open()
    let first = try #require(coordinator.sheet)
    guard case .newSession(let model) = first.destination else { Issue.record("Wrong destination"); return }
    #expect(model.project.id == project.id && model.draft.agent == .codex)
    #expect(model.input == url)
    model.pullRequestBranch = "Draft branch"
    coordinator.presentNewProject(service: CreationProjectService(), didSave: { _ in })
    open()
    #expect(factory.projectCompletions.isEmpty && factory.sessionCompletions.count == 1)
    #expect(coordinator.sheet?.id == first.id && model.pullRequestBranch == "Draft branch")
    coordinator.dismissSheet(id: first.id)
    open()
    let second = try #require(coordinator.sheet)
    let session = WorkspaceSession(id: "session", projectId: project.id, workspace: project.workspace, worktree: "/tmp/worktree",
                                   title: "Session", branch: "feature", url: url, createdAt: nil, pinned: false)
    factory.sessionCompletions[0](session)
    #expect(coordinator.sheet?.id == second.id && created == 0)
    factory.sessionCompletions[1](session)
    factory.sessionCompletions[1](session)
    #expect(coordinator.sheet == nil && created == 1)
}
