import Foundation
import Observation

@MainActor @Observable final class ProjectEditorViewModel {
    struct DeletionRequest: Identifiable, Equatable, Sendable {
        let id = UUID()
        let projectID: String
        let name: String
        fileprivate let generation: UUID
    }
    enum Action: Equatable { case saved(Project), deleted(String), requestDeletion(DeletionRequest) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let id: String?
    var draft: ProjectDraft
    private(set) var baseline: ProjectDraft
    private(set) var busy = false
    private(set) var error: String?
    private(set) var saved = false
    private(set) var retired = false
    private var completedCreation = false
    private var suggestedName = ""
    private var generation = UUID()
    private var service: (any ProjectService)?
    private let chooseFolder: () async -> String?

    init(project: Project?, service: any ProjectService, chooseFolder: @escaping () async -> String?) {
        id = project?.id; draft = ProjectDraft(project); baseline = ProjectDraft(project)
        self.service = service; self.chooseFolder = chooseFolder
    }
    var dirty: Bool { draft != baseline }
    private var active: Bool { !retired && !completedCreation }
    var canSave: Bool { active && service != nil && !busy && draft.validationError == nil && (id == nil || dirty) }
    var canDelete: Bool { active && id != nil && service != nil && !busy }
    func makeDeletionRequest() -> DeletionRequest? {
        guard canDelete, let id else { return nil }
        return DeletionRequest(projectID: id, name: baseline.name, generation: generation)
    }
    func requestDeletion() {
        if let request = makeDeletionRequest() { error = nil; onAction(.requestDeletion(request)) }
    }
    func canDelete(_ request: DeletionRequest) -> Bool {
        canDelete && request.projectID == id && request.generation == generation
    }
    func deletionError(for request: DeletionRequest) -> String? {
        guard active, request.projectID == id, request.generation == generation else {
            return "The project or backend connection changed. Cancel and reopen deletion to review the current project."
        }
        return error
    }
    func connect(_ service: (any ProjectService)?) {
        guard !retired else { return }
        if service == nil { generation = UUID() }
        self.service = service
    }
    func retire() {
        retired = true; service = nil; generation = UUID()
        onAction = { _ in }
    }
    var ideChoices: [IDEChoice] {
        IDEChoice.all.contains(where: { $0.id == draft.ide }) ? IDEChoice.all : IDEChoice.all + [.init(id: draft.ide, title: draft.ide)]
    }
    func update(_ project: Project) {
        guard active && !dirty && !busy else { return }
        draft = ProjectDraft(project); baseline = draft
    }
    func revert() { guard active && !busy else { return }; draft = baseline; error = nil }
    func pickFolder() async {
        guard active, !Task.isCancelled, !busy else { return }
        let generation = generation
        busy = true
        defer { busy = false }
        if let path = await chooseFolder(), active, !Task.isCancelled, self.generation == generation {
            draft.workspace = path; saved = false
        }
    }
    /// The New Project sheet's Choose…: pick the checkout, then read its GitHub repo from the git
    /// origin (the web modal's chooseModalWorkspace) — the repo is derived, never typed there.
    func chooseWorkspace() async {
        let before = draft.workspace
        await pickFolder()
        guard draft.workspace != before else { return }
        await detectRepository()
    }
    func detectRepository() async {
        guard active, !Task.isCancelled, !busy && !draft.workspace.isEmpty, let service else { return }
        let generation = generation, workspace = draft.workspace
        busy = true; error = nil
        defer { busy = false }
        do {
            let repo = try await service.detectRepository(workspace)
            guard active, !Task.isCancelled, self.generation == generation, draft.workspace == workspace else { return }
            if repo.isEmpty {
                error = "No GitHub remote found in this workspace."
                // A new project's repo is only ever derived, so one left from another folder is stale.
                if id == nil { draft.repo = "" }
            } else { draft.repo = repo }
            suggestName()
        } catch {
            if active && !Task.isCancelled && self.generation == generation && draft.workspace == workspace {
                self.error = error.localizedDescription
            }
        }
    }
    /// A new project is named after its GitHub repo, or the checkout folder when there is no
    /// remote. A name the user typed is never replaced — only an empty or still-suggested one.
    private func suggestName() {
        guard active, id == nil, draft.name.isEmpty || draft.name == suggestedName else { return }
        var name = draft.repo.split(separator: "/").last.map(String.init) ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        if name.isEmpty, !draft.workspace.isEmpty { name = URL(fileURLWithPath: draft.workspace).lastPathComponent }
        guard !name.isEmpty, name != "/" else { return }
        draft.name = name; suggestedName = name
    }
    func save() async {
        guard active, !Task.isCancelled, !busy, let service else { return }
        let generation = generation
        if let message = draft.validationError { error = message; return }
        busy = true; error = nil; saved = false
        defer { busy = false }
        do {
            let project = try await service.save(draft, id: id)
            guard active, self.generation == generation else { return }
            draft = ProjectDraft(project); baseline = draft; saved = true
            completedCreation = id == nil
            onAction(.saved(project))
        } catch { if active && self.generation == generation { self.error = error.localizedDescription } }
    }
    func delete(_ request: DeletionRequest) async {
        guard canDelete(request), !Task.isCancelled, let id, let service else { return }
        let generation = generation
        busy = true; error = nil
        defer { busy = false }
        do {
            try await service.delete(id)
            guard active, self.generation == generation else { return }
            let action = onAction
            retire()
            action(.deleted(id))
        } catch { if active && self.generation == generation { self.error = error.localizedDescription } }
    }
}
