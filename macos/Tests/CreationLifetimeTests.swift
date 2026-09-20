import Foundation
import Testing

private actor CreationGate<Value: Sendable> {
    private var pending: CheckedContinuation<Value, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation {
            pending = $0; started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ result: Result<Value, any Error>) {
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }
}

private let lifetimeProject = Project(id: "lifetime", name: "Lifetime", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")

private actor LifetimeProjectService: ProjectService {
    var saves = 0, deletes = 0, detections = 0
    let detection: CreationGate<String>?
    init(detection: CreationGate<String>? = nil) { self.detection = detection }
    func load(_ id: String) -> Project { lifetimeProject }
    func save(_ draft: ProjectDraft, id: String?) -> Project { saves += 1; return lifetimeProject }
    func delete(_ id: String) { deletes += 1 }
    func detectRepository(_ path: String) async throws -> String {
        detections += 1
        if let detection { return try await detection.value() }
        return "fixture/repo"
    }
    func pullRequests(_ id: String, state: String, force: Bool) -> ProjectPRSnapshot { .init() }
}

private actor LifetimeSessionService: SessionCreating {
    var references = 0, resolutions = 0, creations = 0
    let resolution: CreationGate<SessionDraft>?
    var creation: CreationGate<WorkspaceSession>?
    init(resolution: CreationGate<SessionDraft>? = nil, creation: CreationGate<WorkspaceSession>? = nil) {
        self.resolution = resolution; self.creation = creation
    }
    func references(_ project: Project) -> GitReferences {
        references += 1; return GitReferences(branches: [.init(name: "main")], defaultBranch: "main")
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft, workflow: Bool) async throws -> SessionDraft {
        resolutions += 1
        if let resolution { return try await resolution.value() }
        return draft
    }
    private(set) var movedMainCheckoutTo: String?
    func switchMainCheckout(to branch: String, project: Project) { movedMainCheckoutTo = branch }
    func create(project: Project, draft: SessionDraft, requireExactBranch: Bool) async throws -> WorkspaceSession {
        creations += 1
        if let creation {
            self.creation = nil
            return try await creation.value()
        }
        return WorkspaceSession(id: "created", projectId: project.id, workspace: project.workspace,
            worktree: "/tmp/fixture/worktree", title: draft.title, branch: draft.branch, url: draft.url, createdAt: nil, pinned: false)
    }
}

@MainActor @Test func creationLifetimeRetiresDismissedProjectsAndPreventsRepeatedCreation() async throws {
    let service = LifetimeProjectService()
    var folderCalls = 0, saved = 0
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { folderCalls += 1; return "/tmp/folder" }))
    coordinator.presentNewProject(service: service, didSave: { _ in saved += 1 })
    let sheet = try #require(coordinator.sheet)
    guard case .newProject(let model) = sheet.destination else { Issue.record("Wrong destination"); return }
    model.draft = ProjectDraft(lifetimeProject)
    coordinator.dismissSheet(id: sheet.id)
    model.connect(service) // Reconnection must not revive a dismissed editor.
    await model.save(); await model.detectRepository(); await model.pickFolder(); model.requestDeletion()
    #expect(model.makeDeletionRequest() == nil)
    #expect(model.retired && !model.canSave && saved == 0 && folderCalls == 0)
    #expect(await service.saves == 0)
    #expect(await service.detections == 0)

    let standalone = ProjectEditorViewModel(project: nil, service: service, chooseFolder: { nil })
    standalone.draft = ProjectDraft(lifetimeProject)
    standalone.onAction = { _ in saved += 1 }
    await standalone.save(); await standalone.save()
    #expect(saved == 1 && !standalone.canSave)
    #expect(await service.saves == 1)

    let editor = ProjectEditorViewModel(project: lifetimeProject, service: service, chooseFolder: { nil })
    editor.draft.name = "First edit"; await editor.save()
    editor.draft.name = "Second edit"; await editor.save()
    #expect(await service.saves == 3) // Existing project editing remains reusable.
    let deletion = try #require(editor.makeDeletionRequest())
    await editor.delete(deletion)
    editor.connect(service); await editor.delete(deletion); await editor.save()
    #expect(await service.deletes == 1)
    #expect(await service.saves == 3)
}

@MainActor @Test(.timeLimit(.minutes(1))) func creationLifetimeIgnoresLateFolderAndRepositoryResults() async {
    let folder = CreationGate<String?>(), lookup = CreationGate<String>()
    let service = LifetimeProjectService(detection: lookup)
    let model = ProjectEditorViewModel(project: nil, service: service, chooseFolder: { try? await folder.value() })
    let picking = Task { await model.pickFolder() }
    await folder.waitForStart()
    model.retire()
    await folder.finish(.success("/tmp/obsolete")); await picking.value
    #expect(model.draft.workspace.isEmpty && !model.busy)

    let editor = ProjectEditorViewModel(project: lifetimeProject, service: service, chooseFolder: { nil })
    let detecting = Task { await editor.detectRepository() }
    await lookup.waitForStart()
    editor.connect(nil); editor.connect(service)
    await lookup.finish(.success("stale/repository")); await detecting.value
    #expect(editor.draft.repo == lifetimeProject.repo && editor.error == nil && !editor.busy)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func creationLifetimeDismissedSessionIgnoresPendingResolution(failing: Bool) async throws {
    let gate = CreationGate<SessionDraft>(), service = LifetimeSessionService(resolution: gate)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let request = SessionCreationRequest(project: lifetimeProject, agent: .shell, pageURL: "https://github.com/fixture/repo/pull/42")
    var created = 0
    coordinator.presentNewSession(request: request, operations: service, didCreate: { _ in created += 1 })
    let sheet = try #require(coordinator.sheet)
    guard case .newSession(let model) = sheet.destination else { Issue.record("Wrong destination"); return }
    let resolving = Task { await model.resolve() }
    await gate.waitForStart()
    let original = model.draft
    coordinator.dismissSheet(id: sheet.id)
    var resolved = original; resolved.branch = "obsolete-branch"
    await gate.finish(failing ? .failure(BackendError.operation("Obsolete lookup failed")) : .success(resolved))
    #expect(await resolving.value == false)
    await model.loadReferences(); await model.create(); await model.resolve()
    await Task.yield()
    #expect(model.retired && !model.canCreate && !model.loading && !model.resolving)
    #expect(model.draft == original && model.error == nil && created == 0 && coordinator.sheet == nil)
    #expect(await service.references == 0)
    #expect(await service.resolutions == 1)
    #expect(await service.creations == 0)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func creationLifetimeInputChangeDuringResolutionCannotCreateWorktree(failing: Bool) async {
    let gate = CreationGate<SessionDraft>(), service = LifetimeSessionService(resolution: gate)
    let model = NewSessionViewModel(project: lifetimeProject, operations: service)
    model.input = "https://github.com/fixture/repo/pull/42"
    let resolving = Task { await model.resolve() }
    await gate.waitForStart()
    model.input = "https://github.com/fixture/repo/pull/43" // A new address is a new request.
    var resolved = model.draft; resolved.branch = "obsolete-branch"
    await gate.finish(failing ? .failure(BackendError.operation("Obsolete lookup failed")) : .success(resolved))
    #expect(await resolving.value == false)
    #expect(model.resolved == nil && model.error == nil && model.unresolvedPullRequest == nil)
    #expect(await service.creations == 0)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func creationLifetimeSessionFailureCanRetryButCompletedModelCannotCreateAgain() async throws {
    let gate = CreationGate<WorkspaceSession>(), service = LifetimeSessionService(creation: gate)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    var created = 0
    coordinator.presentNewSession(request: .init(project: lifetimeProject, agent: .shell, pageURL: nil),
        operations: service, didCreate: { _ in created += 1 })
    let sheet = try #require(coordinator.sheet)
    guard case .newSession(let model) = sheet.destination else { Issue.record("Wrong destination"); return }
    model.input = "keep-draft"
    let creating = Task { await model.create() }
    await gate.waitForStart()
    coordinator.dismissSheet(id: sheet.id)
    #expect(coordinator.sheet?.id == sheet.id && !sheet.canDismiss)
    await gate.finish(.failure(BackendError.operation("Fixture create failed"))); await creating.value
    #expect(model.canCreate && !model.retired && model.error == "Fixture create failed" && model.input == "keep-draft")
    await model.create(); await model.create(); await model.loadReferences()
    #expect(created == 1 && model.completed && model.retired && !model.canCreate && coordinator.sheet == nil)
    #expect(await service.creations == 2)
    #expect(await service.references == 0)
}
