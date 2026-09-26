import Foundation
import Testing

private actor ProjectFixture: ProjectService {
    var project = Project(id: "p", name: "Native", repo: "o/r", color: nil, workspace: "/tmp/repo")
    var fails = false
    var deleted: [String] = []
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
    #expect(body["runScheme"] == nil)
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
