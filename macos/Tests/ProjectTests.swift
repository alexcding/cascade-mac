import Foundation
import Testing

private actor ProjectCancellationGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancelled = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, any Error>) in
                if cancelled { pending.resume(throwing: CancellationError()) }
                else { continuation = pending }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

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
    private var mergedGate: ProjectCancellationGate?
    func holdMergedUntilCancelled() { mergedGate = ProjectCancellationGate() }
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
            do {
                if let gate = mergedGate {
                    mergedGate = nil
                    try await gate.wait()
                } else {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
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
    await service.holdMergedUntilCancelled()
    let project = await service.load("p")
    let editor = ProjectEditorViewModel(project: project, service: service, chooseFolder: { nil })
    let model = ProjectPageViewModel(project: project, service: service, editor: editor)
    model.setState("merged")
    while await service.requestedStates.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    model.setState("open")
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.rows.first?.title == "open result")
    #expect(model.rows.count == 1 && model.loadedState == "open")
    #expect(await service.requestedStates == ["merged", "open"])
    // The merged read cannot finish naturally before the main actor switches states.
    // Its cancellation may still be recorded after the open read finishes.
    while await service.cancelledStates.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await service.cancelledStates == ["merged"])
    model.setState("open")
    await Task.yield()
    #expect(await service.requestedStates == ["merged", "open"])
    await service.fail(true)
    await model.refresh()
    #expect(model.rows.count == 1 && model.error == "PRs unavailable")
    model.setState("merged")
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

@MainActor @Test func projectDisplayRowsFollowSearchProjectNamesAndPushedSnapshots() async throws {
    let service = ProjectFixture(), project = await service.load("p")
    let model = ProjectPageViewModel(project: project, service: service,
        editor: ProjectEditorViewModel(project: project, service: service, chooseFolder: { nil }))
    await model.refresh()
    let pr = try #require(model.prs.first)
    model.setSearch("Native")
    #expect(model.rows.count == 1)
    let renamed = Project(id: "p", name: "Renamed", repo: "o/r", color: nil, workspace: "/tmp/repo")
    model.update(renamed)
    #expect(model.rows.isEmpty)
    model.setSearch("Renamed")
    #expect(model.rows.first?.projectName == "Renamed")
    let warning = try JSONDecoder().decode(DashboardPR.self, from: Data(#"{"error":"Sync unavailable"}"#.utf8))
    model.update(renamed, snapshot: [pr, pr, warning])
    #expect(model.rows.count == 1 && model.warnings == ["Sync unavailable"])
    model.update(renamed, snapshot: [])
    #expect(model.rows.isEmpty && model.warnings.isEmpty)
    model.retire()
    model.setSearch("ignored"); model.setState("merged")
    #expect(model.search == "Renamed" && model.state == "open")
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
    #expect(body["runScheme"] == nil && body["workflows"] == nil)
    // Forwarding is the project's own switch, since it puts a webhook on the repo: on unless turned off.
    #expect(body["forwardWebhooks"] as? Bool == true)
    #expect(!ProjectDraft(Project(id: "p", name: "P", repo: "o/r", color: nil, workspace: "/tmp", forwardWebhooks: false)).forwardWebhooks)
    // The worktree fields are the project's own and save with it, text kept as typed.
    draft.worktreeSetup = "npm ci\n"; draft.worktreeInclude = ".env\n!.env.example"
    let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    #expect(saved["worktreeSetup"] as? String == "npm ci\n" && saved["worktreeInclude"] as? String == ".env\n!.env.example")
    #expect(ProjectDraft(Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp/repo", worktreeSetup: "make", worktreeInclude: ".env")).worktreeSetup == "make")
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

@MainActor @Test func setupScriptPickKeepsAPathInsideTheProjectAndRunsItTheWayItCan() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let runnable = folder.appendingPathComponent("scripts/setup.sh"), plain = folder.appendingPathComponent("scripts/plain.sh")
    for file in [runnable, plain] { try "echo hi\n".write(to: file, atomically: true, encoding: .utf8) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnable.path)
    var picked = runnable.path
    let model = ProjectEditorViewModel(project: nil, service: ProjectFixture(), chooseFolder: { nil }, chooseFile: { _ in picked })
    model.draft.workspace = folder.path
    await model.pickSetupScript()
    #expect(model.draft.worktreeSetup == "./scripts/setup.sh")
    picked = plain.path; await model.pickSetupScript()
    #expect(model.draft.worktreeSetup == "sh ./scripts/plain.sh")
    // Outside the project there is no copy in the worktree to run: refused, the draft kept.
    picked = "/usr/bin/true"; await model.pickSetupScript()
    #expect(model.draft.worktreeSetup == "sh ./scripts/plain.sh" && model.error != nil)
    #expect(ProjectEditorViewModel.setupCommand(relative: "my scripts/it's.sh", executable: true) == "'./my scripts/it'\"'\"'s.sh'")
    // A cancelled pick clears what an earlier one said and keeps the draft.
    let cancelling = ProjectEditorViewModel(project: nil, service: ProjectFixture(), chooseFolder: { nil }, chooseFile: { _ in nil })
    cancelling.draft.workspace = "/usr"
    await cancelling.pickSetupScript()
    #expect(cancelling.error == nil)
}

/// Git's record decides, not the disk: the worktree is checked out from it.
private struct TrackedFixture: ProjectService {
    let answer: TrackedFile
    func load(_ id: String) -> Project { Project(id: id, name: "P", repo: "", color: nil, workspace: "") }
    func save(_ draft: ProjectDraft, id: String?) -> Project { load(id ?? "p") }
    func delete(_ id: String) {}
    func detectRepository(_ path: String) -> String { "" }
    func pullRequests(_ id: String, state: String, force: Bool) -> ProjectPRSnapshot { ProjectPRSnapshot() }
    func trackedFile(workspace: String, rel: String) -> TrackedFile? { answer }
}

@MainActor @Test func setupScriptPickGoesByWhatGitRecordsAndWarnsWhenItIsNotCommitted() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = folder.appendingPathComponent("setup.sh")
    try "echo hi\n".write(to: script, atomically: true, encoding: .utf8)
    // Executable on disk, but git records 644: the worktree's copy will not run as ./setup.sh.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let recorded = ProjectEditorViewModel(project: nil, service: TrackedFixture(answer: .init(tracked: true, executable: false)),
                                          chooseFolder: { nil }, chooseFile: { _ in script.path })
    recorded.draft.workspace = folder.path
    await recorded.pickSetupScript()
    #expect(recorded.draft.worktreeSetup == "sh ./setup.sh" && recorded.error == nil)
    let untracked = ProjectEditorViewModel(project: nil, service: TrackedFixture(answer: .init(tracked: false, executable: false)),
                                           chooseFolder: { nil }, chooseFile: { _ in script.path })
    untracked.draft.workspace = folder.path
    await untracked.pickSetupScript()
    #expect(untracked.draft.worktreeSetup == "sh ./setup.sh" && untracked.error?.contains("isn't committed") == true)
}

private struct IDEGuessFixture: ProjectService {
    func load(_ id: String) -> Project { Project(id: id, name: "", repo: "", color: nil, workspace: "") }
    func save(_ draft: ProjectDraft, id: String?) throws -> Project { load(id ?? "created") }
    func delete(_ id: String) {}
    func detectRepository(_ path: String) -> String { "o/r" }
    func detect(_ path: String) -> DetectedWorkspace {
        DetectedWorkspace(repo: "o/r", ide: path.hasSuffix("ios") ? "xcode" : path.hasSuffix("web") ? "vscode" : "")
    }
    func pullRequests(_ id: String, state: String, force: Bool) -> ProjectPRSnapshot { ProjectPRSnapshot(prs: [], error: nil, refreshing: false) }
}

@MainActor @Test func newProjectGuessesItsIDEButNeverReplacesAPick() async {
    var folder = "/tmp/ios"
    let editor = ProjectEditorViewModel(project: nil, service: IDEGuessFixture(), chooseFolder: { folder })
    await editor.chooseWorkspace()
    #expect(editor.draft.ide == "xcode")
    folder = "/tmp/web"
    await editor.chooseWorkspace()
    #expect(editor.draft.ide == "vscode")
    folder = "/tmp/other"
    await editor.chooseWorkspace()
    #expect(editor.draft.ide == "")
    editor.draft.ide = "zed"
    folder = "/tmp/ios"
    await editor.chooseWorkspace()
    #expect(editor.draft.ide == "zed")

    let existing = ProjectEditorViewModel(project: Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp/x", ide: "cursor"),
                                          service: IDEGuessFixture(), chooseFolder: { "/tmp/ios" })
    await existing.chooseWorkspace()
    #expect(existing.draft.ide == "cursor")
    #expect(existing.ideChoices.last?.title == "Cursor" && !IDEChoice.all.contains { $0.id == "cursor" || $0.id == "windsurf" })
}
