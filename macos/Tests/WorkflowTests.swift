import Foundation
import Testing

@Test func workflowHelpersMatchLegacyShapesAndLiteralPlaceholderRules() throws {
    let legacy = try JSONDecoder().decode(WorkflowRecipe.self, from: Data(#"{"name":"Legacy","cli":"unknown","commands":["one","two"]}"#.utf8))
    #expect(legacy.cli == .claude && legacy.id == "")
    #expect(legacy.steps == [.init(command: "one"), .init(command: "two")])
    let modern = try JSONDecoder().decode(WorkflowRecipe.self, from: Data(#"{"id":"same","steps":[{"title":"goal","command":"run"},{"command":"next"}],"commands":["ignored"]}"#.utf8))
    #expect(modern.steps == [.init(title: "goal", command: "run"), .init(command: "next")])
    let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    #expect(body["commands"] == nil && body["steps"] != nil)
    #expect(WorkflowText.slug("  --weird__name--  ") == "weird-name")
    #expect(WorkflowText.slug(String(repeating: "x", count: 60)).count == 40)
    #expect(WorkflowText.branch(key: "REC-12", summary: "Fix the login bug") == "feature/rec-12-fix-the-login-bug")
    #expect(WorkflowText.branch(key: "REC-12", summary: "") == "feature/rec-12")
    let context = ["key": "REC-1", "worktree": "", "url": "$& {key} 🦀"]
    #expect(WorkflowText.resolve("🦀 {url} {key} {worktree} {missing}", context: context) == "🦀 $& {key} 🦀 REC-1 {worktree} {missing}")
}

private actor WorkflowFixture: WorkflowService {
    var project: Project
    var fails = false
    private(set) var calls = 0
    private(set) var payloads: [[WorkflowRecipe]] = []
    init(_ project: Project) { self.project = project }
    func fail(_ value: Bool) { fails = value }
    func save(projectID: String, workflows: [WorkflowRecipe]) async throws -> Project {
        calls += 1; payloads.append(workflows)
        try await Task.sleep(for: .milliseconds(60))
        if fails { throw BackendError.operation("Workflow save failed") }
        project.workflows = workflows
        return project
    }
}

@MainActor @Test func workflowEditorKeepsDraftsOrdersStepsAndRecoversFailedSaves() async throws {
    var project = Project(id: "p", name: "Project", repo: "o/r", color: nil, workspace: "/tmp/project", jiraProjectKey: "REC",
                          workflows: [.init(id: "recipe", name: "Original", steps: [.init(command: "first")])])
    let service = WorkflowFixture(project)
    var saved: [Project] = []
    let model = WorkflowEditorViewModel(project: project, service: service)
    model.onAction = { if case .saved(let project) = $0 { saved.append(project) } }
    let originalID = try #require(model.draft.first?.id)
    model.setName(originalID, "Local draft")
    project.workflows?[0].name = "Changed elsewhere"
    model.update(project)
    #expect(model.draft.first?.name == "Local draft" && model.changedElsewhere)
    model.revert()
    #expect(model.draft.first?.name == "Changed elsewhere" && !model.dirty && !model.changedElsewhere)
    let id = try #require(model.draft.first?.id)
    let first = try #require(model.draft.first?.steps.first?.id)
    model.addStep(id)
    let second = try #require(model.draft.first?.steps.last?.id)
    model.setStep(id, step: second, title: "Ready for {key}", command: "  /review {url}  ")
    model.moveStep(id, step: second, direction: -1)
    #expect(model.draft.first?.steps.map(\.id) == [second, first])
    model.removeStep(id, step: first)
    model.addStep(id) // Empty editor rows are omitted from the wire payload.
    model.setName(id, String(repeating: "🦀", count: 41))
    #expect(model.validationError != nil && !model.canSave)
    model.setName(id, "  Review  "); model.setCLI(id, .codex)
    #expect(model.preview("/check {key} {worktree}") == "/check REC-123 {worktree}")
    await service.fail(true)
    await model.save()
    #expect(model.dirty && model.error == "Workflow save failed" && saved.isEmpty)
    await service.fail(false)
    async let one: Void = model.save()
    async let duplicate: Void = model.save()
    await one; await duplicate
    #expect(await service.calls == 2)
    #expect(!model.dirty && model.saved && saved.count == 1)
    let recipe = try #require(saved.first?.workflows?.first)
    #expect(recipe.id == "recipe" && recipe.name == "Review" && recipe.cli == .codex)
    #expect(recipe.steps == [.init(title: "Ready for {key}", command: "/review {url}")])
    model.add()
    let draftIDs = model.draft.map(\.id)
    model.update(saved[0])
    #expect(model.draft.map(\.id) == draftIDs && model.dirty)
    await model.stop()
    #expect(!model.canSave && model.dirty)
}

@MainActor @Test func workflowEditorRejectsLateSaveAfterConnectionChangesAndNormalizesLegacyIDs() async throws {
    let recipe = WorkflowRecipe(id: "", name: "Legacy", steps: [])
    let project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "", workflows: [recipe, recipe])
    let old = WorkflowFixture(project), replacement = WorkflowFixture(project)
    var saves = 0
    let model = WorkflowEditorViewModel(project: project, service: old)
    model.onAction = { _ in saves += 1 }
    #expect(Set(model.draft.map(\.savedID)).count == 2)
    let rows = model.draft.map(\.id)
    model.update(project)
    #expect(model.draft.map(\.id) == rows && !model.dirty)
    let id = try #require(model.draft.first?.id)
    model.setName(id, "Changed")
    let saving = Task { await model.save() }
    for _ in 0..<100 { if await old.calls == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
    model.connect(replacement)
    await saving.value
    #expect(saves == 0 && model.dirty && model.error?.contains("connection changed") == true)
    await model.save()
    #expect(saves == 1 && !model.dirty)
}
