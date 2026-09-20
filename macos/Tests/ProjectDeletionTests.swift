import Foundation
import Testing

private let deletionProject = Project(id: "delete-project", name: "Delete fixture", repo: "", color: nil, workspace: "/tmp/fixture")

private actor ProjectDeletionGate {
    private var pending: CheckedContinuation<Void, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws {
        try await withCheckedThrowingContinuation {
            pending = $0; started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(failing: Bool) {
        let continuation = pending; pending = nil
        if failing { continuation?.resume(throwing: BackendError.operation("Fixture deletion failed")) }
        else { continuation?.resume() }
    }
}

private actor ProjectDeletionService: ProjectService {
    var deletions: [String] = []
    var gate: ProjectDeletionGate?
    init(gate: ProjectDeletionGate? = nil) { self.gate = gate }
    func load(_ id: String) -> Project { deletionProject }
    func save(_ draft: ProjectDraft, id: String?) -> Project { deletionProject }
    func delete(_ id: String) async throws {
        deletions.append(id)
        if let gate { self.gate = nil; try await gate.wait() }
    }
    func detectRepository(_ path: String) -> String { "" }
    func pullRequests(_ id: String, state: String, force: Bool) -> ProjectPRSnapshot { .init() }
}

@MainActor private final class ProjectDeletionRuntime: RootCoordinating, ProjectCoordinating {
    weak var coordinator: AppCoordinator?
    var projects = [deletionProject]
    var removed: [String] = []
    func rootState() -> RootState {
        RootState(selection: coordinator?.selection ?? .overview, projects: projects,
                  projectModels: coordinator?.projectModels ?? [:])
    }
    func ownsProject(_ id: String) -> Bool { projects.contains { $0.id == id } }
    func applyProjectSave(_ project: Project, source: ProjectSaveSource) {}
    func applyProjectDeletion(_ id: String, model: ProjectPageViewModel) {
        projects.removeAll { $0.id == id }; removed.append(id)
    }
    func activateRootDestination() {}
    func performRootCommand(_ command: ShellCommand) {}
    func reconnect() async {}
    func togglePin(_ id: String) {}
    func closeTab(_ url: String) {}
    func openTerminal() {}
    func openRootBrowser(_ url: URL) {}
}

@MainActor private func deletionModel(service: any ProjectService) -> ProjectPageViewModel {
    ProjectPageViewModel(project: deletionProject, service: service,
        editor: ProjectEditorViewModel(project: deletionProject, service: service, chooseFolder: { nil }))
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectDeletionCoordinatorCancelsStaleRequestsAndDefersDeepLinks() async throws {
    let service = ProjectDeletionService(), runtime = ProjectDeletionRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    runtime.coordinator = root; root.rootRuntime = runtime; root.setRoutingReady(true)
    let model = deletionModel(service: service), child = root.installProject(model, runtime: runtime)
    model.editor.requestDeletion() // A retained background feature cannot open a dialog.
    #expect(child.deletionConfirmation == nil)
    root.navigate(to: .project(deletionProject.id))
    model.editor.requestDeletion()
    let first = try #require(child.deletionConfirmation)
    model.editor.requestDeletion()
    #expect(child.deletionConfirmation?.id == first.id && !root.canPresent)
    root.presentNewProject(service: service, didSave: { _ in Issue.record("Competing creation") })
    root.presentRestart { Issue.record("Competing restart") }
    #expect(root.sheet == nil && root.restartConfirmation == nil)
    child.cancelDeletion(id: UUID())
    #expect(child.deletionConfirmation?.id == first.id)
    child.cancelDeletion(id: first.id)
    model.editor.requestDeletion()
    let second = try #require(child.deletionConfirmation)
    await child.confirmDeletion(id: first.id)
    #expect(child.deletionConfirmation?.id == second.id)
    #expect(await service.deletions.isEmpty)
    root.handle(url: URL(string: "craft://app/terminal")!)
    #expect(root.selection == .project(deletionProject.id) && root.pendingDeepLink != nil)
    child.cancelDeletion(id: second.id)
    while root.pendingDeepLink != nil { await Task.yield() }
    #expect(root.selection == .terminal && root.canPresent)
    await child.confirmDeletion(id: second.id)
    #expect(await service.deletions.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectDeletionCoordinatorKeepsFailureForRetryAndBlocksBusyDismissal() async throws {
    let gate = ProjectDeletionGate(), service = ProjectDeletionService(gate: gate), runtime = ProjectDeletionRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    runtime.coordinator = root; root.rootRuntime = runtime; root.setRoutingReady(true)
    let model = deletionModel(service: service), child = root.installProject(model, runtime: runtime)
    root.navigate(to: .project(deletionProject.id)); model.editor.requestDeletion()
    let request = try #require(child.deletionConfirmation)
    let deleting = Task { await child.confirmDeletion(id: request.id) }
    await gate.waitForStart()
    child.cancelDeletion(id: request.id)
    await child.confirmDeletion(id: request.id)
    root.handle(url: URL(string: "craft://app/terminal")!)
    #expect(child.deleting && child.deletionConfirmation?.id == request.id && !root.canPresent)
    await gate.finish(failing: true); await deleting.value
    #expect(child.deletionConfirmation?.id == request.id && !child.deleting && model.editor.canDelete(request))
    #expect(model.editor.error == "Fixture deletion failed" && root.selection == .project(deletionProject.id))
    await child.confirmDeletion(id: request.id)
    while root.pendingDeepLink != nil { await Task.yield() }
    #expect(root.selection == .terminal && runtime.removed == [deletionProject.id] && child.retired && root.canPresent)
    await child.confirmDeletion(id: request.id)
    #expect(await service.deletions == [deletionProject.id, deletionProject.id])
}

@MainActor @Test func projectDeletionRejectsDisconnectedRemovedAndRecreatedModels() async throws {
    let service = ProjectDeletionService(), runtime = ProjectDeletionRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = deletionModel(service: service), child = root.installProject(model, runtime: runtime)
    root.navigate(to: .project(deletionProject.id)); model.editor.requestDeletion()
    let oldConnection = try #require(child.deletionConfirmation)
    model.connect(nil); model.connect(service)
    #expect(!model.editor.canDelete(oldConnection) && model.editor.deletionError(for: oldConnection) != nil)
    await child.confirmDeletion(id: oldConnection.id)
    #expect(child.deletionConfirmation == nil && root.canPresent)
    model.editor.requestDeletion()
    let removed = try #require(child.deletionConfirmation)
    _ = root.removeMissingProjects([])
    let replacement = deletionModel(service: service), current = root.installProject(replacement, runtime: runtime)
    replacement.editor.requestDeletion()
    let fresh = try #require(current.deletionConfirmation)
    await child.confirmDeletion(id: removed.id)
    await current.confirmDeletion(id: removed.id)
    await replacement.editor.delete(removed)
    #expect(await service.deletions.isEmpty)
    #expect(child.retired && model.editor.retired && current.deletionConfirmation?.id == fresh.id)
    current.cancelDeletion(id: fresh.id)
}

@MainActor @Test func projectDeletionCannotStartAfterRuntimeOwnerIsReleased() async throws {
    let service = ProjectDeletionService()
    var runtime: ProjectDeletionRuntime? = ProjectDeletionRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = deletionModel(service: service), child = root.installProject(model, runtime: runtime)
    root.navigate(to: .project(deletionProject.id)); model.editor.requestDeletion()
    let request = try #require(child.deletionConfirmation)
    runtime = nil
    await child.confirmDeletion(id: request.id)
    #expect(child.deletionConfirmation == nil && root.canPresent)
    #expect(await service.deletions.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func projectDeletionFinishesOriginalOperationWithoutRedirectingAnotherScreen(failing: Bool) async throws {
    let gate = ProjectDeletionGate(), service = ProjectDeletionService(gate: gate), runtime = ProjectDeletionRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = deletionModel(service: service), child = root.installProject(model, runtime: runtime)
    root.navigate(to: .project(deletionProject.id)); model.editor.requestDeletion()
    let request = try #require(child.deletionConfirmation)
    let deleting = Task { await child.confirmDeletion(id: request.id) }
    await gate.waitForStart()
    root.navigate(to: .terminal)
    #expect(child.deletionConfirmation == nil && !root.canPresent)
    await gate.finish(failing: failing); await deleting.value
    #expect(root.selection == .terminal && root.canPresent)
    #expect(runtime.removed == (failing ? [] : [deletionProject.id]))
    #expect(await service.deletions == [deletionProject.id])
}
