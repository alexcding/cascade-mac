import Foundation
import Observation

@MainActor @Observable final class WorkflowEditorViewModel {
    private(set) var project: Project
    private(set) var draft: [WorkflowEditorRecipe]
    private(set) var busy = false
    private(set) var saved = false
    private(set) var changedElsewhere = false
    private(set) var error: String?
    private var baseline: [WorkflowEditorRecipe]
    private var serverRecipes: [WorkflowRecipe]
    @ObservationIgnored private var service: (any WorkflowService)?
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    enum Action: Equatable { case saved(Project) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }

    init(project: Project, service: any WorkflowService) {
        self.project = project; self.service = service
        let recipes = project.workflows ?? []
        let editing = Self.editing(recipes)
        serverRecipes = recipes; draft = editing; baseline = editing
    }
    private static func editing(_ recipes: [WorkflowRecipe]) -> [WorkflowEditorRecipe] {
        var used = Set<String>()
        return recipes.map { recipe in
            var recipe = recipe
            if recipe.id.isEmpty || recipe.id.utf16.count > 64 || !used.insert(recipe.id).inserted { recipe.id = UUID().uuidString }
            used.insert(recipe.id)
            return WorkflowEditorRecipe(recipe)
        }
    }
    var dirty: Bool { draft != baseline }
    var canAdd: Bool { !busy && draft.count < 20 }
    var canSave: Bool { service != nil && !busy && dirty && validationError == nil }
    var validationError: String? {
        if draft.count > 20 { return "Keep at most 20 workflows per project." }
        for recipe in draft {
            if recipe.name.utf16.count > 80 { return "Workflow names must be at most 80 characters." }
            if recipe.steps.count > 20 { return "Keep at most 20 steps in a workflow." }
            for step in recipe.steps {
                if step.value.title.utf16.count > 120 { return "Step goals must be at most 120 characters." }
                if step.value.command.utf16.count > 500 { return "Step commands must be at most 500 characters." }
            }
        }
        return nil
    }
    func connect(_ service: (any WorkflowService)?) {
        connection = UUID(); self.service = service
        if busy { error = "The connection changed while saving. Your draft is kept; review it after reconnecting." }
    }
    func update(_ project: Project) {
        self.project = project
        let recipes = project.workflows ?? []
        guard recipes != serverRecipes else { return }
        serverRecipes = recipes
        if dirty || busy { changedElsewhere = true }
        else { draft = Self.editing(recipes); baseline = draft; changedElsewhere = false; saved = false }
    }
    func revert() {
        guard !busy else { return }
        draft = Self.editing(serverRecipes); baseline = draft; error = nil; saved = false; changedElsewhere = false
    }
    func add() {
        guard canAdd else { return }
        draft.append(WorkflowEditorRecipe(.init(name: "Workflow \(draft.count + 1)"))); saved = false
    }
    func remove(_ id: UUID) { guard !busy else { return }; draft.removeAll { $0.id == id }; saved = false }
    private func edit(_ id: UUID, _ body: (inout WorkflowEditorRecipe) -> Void) {
        guard !busy, let index = draft.firstIndex(where: { $0.id == id }) else { return }
        body(&draft[index]); saved = false
    }
    func setName(_ id: UUID, _ value: String) { edit(id) { $0.name = value } }
    func setCLI(_ id: UUID, _ value: WorkflowCLI) { edit(id) { $0.cli = value } }
    func addStep(_ id: UUID) { edit(id) { if $0.steps.count < 20 { $0.steps.append(.init(value: .init())) } } }
    func removeStep(_ id: UUID, step: UUID) {
        edit(id) { recipe in
            recipe.steps.removeAll { $0.id == step }
            if recipe.steps.isEmpty { recipe.steps = [.init(value: .init())] }
        }
    }
    func setStep(_ id: UUID, step: UUID, title: String? = nil, command: String? = nil) {
        edit(id) { recipe in
            guard let index = recipe.steps.firstIndex(where: { $0.id == step }) else { return }
            if let title { recipe.steps[index].value.title = title }
            if let command { recipe.steps[index].value.command = command }
        }
    }
    func moveStep(_ id: UUID, step: UUID, direction: Int) {
        edit(id) { recipe in
            guard [-1, 1].contains(direction), let index = recipe.steps.firstIndex(where: { $0.id == step }),
                  recipe.steps.indices.contains(index + direction) else { return }
            recipe.steps.swapAt(index, index + direction)
        }
    }
    var sampleContext: [String: String] {
        let key = "\((project.jiraProjectKey?.isEmpty == false ? project.jiraProjectKey : nil) ?? "ABC")-123"
        return ["key": key, "url": "https://example.atlassian.net/browse/\(key)", "pr": "42",
                "branch": WorkflowText.branch(key: key, summary: "sample task"),
                "repo": project.repo.isEmpty ? "owner/repo" : project.repo, "workspace": project.workspace, "worktree": ""]
    }
    func preview(_ text: String) -> String { WorkflowText.resolve(text, context: sampleContext) }
    var sampleBranch: String { sampleContext["branch"] ?? "" }
    func save() async {
        if let saveTask { await saveTask.value; return }
        guard let service, dirty else { return }
        if let message = validationError { error = message; return }
        let token = connection, payload = draft.map(\.payload), id = project.id
        busy = true; error = nil; saved = false
        let task = Task {
            defer { busy = false; saveTask = nil }
            do {
                let result = try await service.save(projectID: id, workflows: payload)
                guard connection == token else { return }
                project = result; serverRecipes = result.workflows ?? []
                draft = Self.editing(serverRecipes); baseline = draft
                saved = true; changedElsewhere = false; onAction(.saved(result))
            } catch { if connection == token { self.error = error.localizedDescription } }
        }
        saveTask = task
        await task.value
    }
    func stop() async { connect(nil); await saveTask?.value }
}
