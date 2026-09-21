import Foundation
import Testing

private actor ProjectFixture: ProjectService {
    var project = Project(id: "p", name: "Native", repo: "o/r", color: nil, workspace: "/tmp/repo")
    var fails = false
    var deleted: [String] = []
    var requestedStates: [String] = []
    var cancelledStates: [String] = []
    var snapshotRefreshing = false
    var snapshotError: String?
    var forcedReads = 0
    var delayReads = false
    func delayReads(_ value: Bool) { delayReads = value }
    func snapshot(refreshing: Bool, error: String? = nil) { snapshotRefreshing = refreshing; snapshotError = error }
    func fail(_ value: Bool) { fails = value }
    func load(_ id: String) -> Project { project }
    func save(_ draft: ProjectDraft, id: String?) throws -> Project {
        if fails { throw BackendError.operation("Save unavailable") }
        project = Project(id: id ?? "created", name: draft.name, repo: draft.repo, color: nil,
                          workspace: draft.workspace, ide: draft.ide, ideTarget: draft.ideTarget,
                          jiraProjectKey: draft.jiraProjectKey, jql: draft.jql, ideCmd: draft.ideCmd)
        return project
    }
    func delete(_ id: String) throws {
        if fails { throw BackendError.operation("Delete unavailable") }
        deleted.append(id)
    }
    func detectRepository(_ path: String) -> String { path.hasSuffix("/bare") ? "" : "detected/repo" }
    func pullRequests(_ id: String, state: String, force: Bool) async throws -> ProjectPRSnapshot {
        if force { forcedReads += 1 }
        requestedStates.append(state)
        if delayReads { try await Task.sleep(for: .milliseconds(100)) }
        if state == "merged" {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { cancelledStates.append(state); throw error }
        }
        if fails { throw BackendError.operation("PRs unavailable") }
        return ProjectPRSnapshot(prs: try JSONDecoder().decode([DashboardPR].self, from: Data("[{\"number\":1,\"title\":\"\(state) result\",\"url\":\"https://github.com/o/r/pull/1\",\"state\":\"\(state.uppercased())\",\"category\":\"other\"}]".utf8)), error: snapshotError, refreshing: snapshotRefreshing)
    }
}

@MainActor @Test func projectEditorRetainsEditsOnRefreshAndFailureAndDeletesOnlyAfterConfirmation() async throws {
    let service = ProjectFixture()
    let initial = await service.load("p")
    var saved: Project?
    var removed: String?
    var deletion: ProjectEditorViewModel.DeletionRequest?
    let editor = ProjectEditorViewModel(project: initial, service: service, chooseFolder: { "/tmp/picked" })
    editor.onAction = { action in
        switch action {
        case .saved(let value): saved = value
        case .deleted(let id): removed = id
        case .requestDeletion(let request): deletion = request
        }
    }
    await editor.pickFolder()
    await editor.detectRepository()
    #expect(editor.draft.workspace == "/tmp/picked" && editor.draft.repo == "detected/repo")
    editor.draft.name = "Unsaved name"
    editor.update(initial)
    #expect(editor.draft.name == "Unsaved name" && editor.dirty)
    await service.fail(true)
    await editor.save()
    #expect(saved == nil && editor.error == "Save unavailable" && editor.dirty)
    await service.fail(false)
    await editor.save()
    #expect(saved?.name == "Unsaved name" && !editor.dirty && editor.saved)
    editor.requestDeletion()
    #expect(await service.deleted.isEmpty)
    let request = try #require(deletion)
    await service.fail(true)
    await editor.delete(request)
    #expect(removed == nil && editor.error == "Delete unavailable")
    await service.fail(false)
    await editor.delete(request)
    #expect(removed == "p")
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectPRStateChangesRejectLateResponsesAndKeepOtherAuthors() async throws {
    let service = ProjectFixture()
    let project = await service.load("p")
    let editor = ProjectEditorViewModel(project: project, service: service, chooseFolder: { nil })
    let model = ProjectPageViewModel(project: project, service: service, editor: editor)
    model.state = "merged"
    while await service.requestedStates.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    model.state = "open"
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.rows.first?.title == "open result")
    #expect(model.rows.count == 1 && model.loadedState == "open")
    #expect(await service.requestedStates == ["merged", "open"])
    // The cancelled "merged" read records itself when its sleep throws, which can land after
    // the "open" read has already finished. Wait for it instead of assuming that order; the
    // time limit on this test is what catches a cancel that never happens.
    while await service.cancelledStates.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await service.cancelledStates == ["merged"])
    model.state = "open"
    await Task.yield()
    #expect(await service.requestedStates == ["merged", "open"])
    await service.fail(true)
    await model.refresh()
    #expect(model.rows.count == 1 && model.error == "PRs unavailable")
    model.state = "merged"
    #expect(model.rows.isEmpty)
    model.cancelRefresh()
    #expect(!model.loading)
}

@MainActor @Test func projectSnapshotRefreshKeepsCardsAndReportsBackgroundFailureAndRetry() async {
    let service = ProjectFixture(), project = await service.load("p")
    let model = ProjectPageViewModel(project: project, service: service,
        editor: ProjectEditorViewModel(project: project, service: service, chooseFolder: { nil }))
    await service.snapshot(refreshing: true)
    await model.refresh()
    #expect(!model.loading && model.refreshing && model.rows.count == 1)
    await service.snapshot(refreshing: false, error: "Snapshot unavailable")
    await model.refresh()
    #expect(!model.refreshing && model.rows.count == 1 && model.error == "Snapshot unavailable")
    await service.delayReads(true)
    let pending = Task { await model.refresh() }
    while await service.requestedStates.count < 3 { await Task.yield() }
    #expect(model.error == "Snapshot unavailable" && model.rows.count == 1)
    await pending.value
    await service.delayReads(false)
    await service.snapshot(refreshing: true)
    await model.refresh(force: true)
    #expect(await service.forcedReads == 1)
    #expect(model.refreshing && model.error == nil && model.rows.count == 1)
    model.update(Project(id: "p", name: "New repo", repo: "other/repo", color: nil, workspace: "/tmp/repo"))
    #expect(model.rows.isEmpty && model.loadedState == nil && !model.refreshing)
}

@Test func projectDraftValidatesPathsWithoutSerializingAutomationOrRunDestinations() throws {
    var draft = ProjectDraft()
    #expect(draft.validationError != nil)
    draft.name = "Native"; draft.workspace = "relative/path"
    #expect(draft.validationError != nil)
    draft.workspace = "/tmp/repo"; draft.ideTarget = "../another/App.xcodeproj"
    #expect(draft.validationError != nil)
    draft.ideTarget = "App/App.xcworkspace"
    #expect(draft.validationError == nil)
    let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    #expect(body["runScheme"] == nil && body["workflows"] == nil && body["forwardWebhooks"] == nil)
}

@MainActor @Test func newProjectChooseDetectsTheRepositoryAndCancelledPickKeepsTheDraft() async {
    let picked = ProjectEditorViewModel(project: nil, service: ProjectFixture(), chooseFolder: { "/tmp/picked" })
    await picked.chooseWorkspace()
    #expect(picked.draft.workspace == "/tmp/picked" && picked.draft.repo == "detected/repo" && !picked.busy)
    #expect(picked.draft.name == "repo")
    picked.draft.workspace = "/tmp/bare"
    await picked.detectRepository()
    #expect(picked.draft.repo.isEmpty && picked.draft.name == "bare")
    picked.draft.name = "Typed"
    await picked.detectRepository()
    #expect(picked.draft.name == "Typed")

    let cancelled = ProjectEditorViewModel(project: nil, service: ProjectFixture(), chooseFolder: { nil })
    cancelled.draft.workspace = "/tmp/typed"
    await cancelled.chooseWorkspace()
    #expect(cancelled.draft.workspace == "/tmp/typed" && cancelled.draft.repo.isEmpty)
}
