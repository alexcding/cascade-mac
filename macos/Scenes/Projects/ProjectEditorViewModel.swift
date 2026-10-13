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
    /// The folder last detected, and whether it is a git repository.
    private var gitAnswer: (workspace: String, git: Bool?)?
    /// The chosen folder is no git repository: a new project, or one moved to another folder, needs
    /// `draft.initGit` to be saved. A project left in its folder is not asked again.
    var needsGit: Bool { movesFolder && gitAnswer?.workspace == draft.workspace && gitAnswer?.git == false }
    /// Whether saving sets the project's folder: a new project's, or a folder changed.
    private var movesFolder: Bool { id == nil || draft.workspace != baseline.workspace }
    private(set) var retired = false
    private var completedCreation = false
    private var suggestedName = ""
    private var suggestedIDE = ""
    private var generation = UUID()
    private var service: (any ProjectService)?
    private let chooseFolder: () async -> String?
    private let chooseFile: (String) async -> String?

    init(project: Project?, service: any ProjectService, chooseFolder: @escaping () async -> String?,
         chooseFile: @escaping (String) async -> String? = { _ in nil }) {
        id = project?.id; draft = ProjectDraft(project); baseline = ProjectDraft(project)
        self.service = service; self.chooseFolder = chooseFolder; self.chooseFile = chooseFile
    }
    var dirty: Bool { draft != baseline }
    private var active: Bool { !retired && !completedCreation }
    var canSave: Bool {
        active && service != nil && !busy && draft.validationError == nil && (id == nil || dirty)
            && (!needsGit || draft.initGit)
    }
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
            return String(localized: "The project or backend connection changed. Cancel and reopen deletion to review the current project.")
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
        IDEChoice.choices(keeping: draft.ide)
    }
    func update(_ project: Project) {
        guard active && !dirty && !busy else { return }
        draft = ProjectDraft(project); baseline = draft
    }
    func revert() { guard active && !busy else { return }; draft = baseline; error = nil }
    /// Opened in place of New Task, for a project with no folder to start a session in: says why.
    func explainMissingFolder() {
        guard active, draft.workspace.isEmpty else { return }
        error = String(localized: "Choose the project folder to start sessions in this project.")
    }
    func pickFolder() async {
        guard active, !Task.isCancelled, !busy else { return }
        let generation = generation
        busy = true
        defer { busy = false }
        if let path = await chooseFolder(), active, !Task.isCancelled, self.generation == generation {
            draft.workspace = path; saved = false
        }
    }
    /// The setup script's Choose…: a file inside the project, kept as a path relative to it. The
    /// script runs with the NEW worktree as its folder, so the path names that worktree's copy —
    /// the version on the session's branch, not the one in the project checkout.
    func pickSetupScript() async {
        let workspace = (draft.workspace as NSString).standardizingPath
        guard active, !Task.isCancelled, !busy, !workspace.isEmpty else { return }
        let generation = generation
        busy = true; error = nil
        defer { busy = false }
        guard let path = await chooseFile(workspace), active, !Task.isCancelled, self.generation == generation else { return }
        let file = (path as NSString).standardizingPath
        guard file.hasPrefix(workspace + "/") else {
            error = String(localized: "Choose a script inside the project folder, so each worktree has its own copy.")
            return
        }
        let relative = String(file.dropFirst(workspace.count + 1))
        // What git records decides it, since that is what the worktree checks out: a file made
        // executable only on disk still arrives without the bit. Unknown falls back to the disk.
        let recorded: TrackedFile? = (try? await service?.trackedFile(workspace: workspace, rel: relative)) ?? nil
        guard active, !Task.isCancelled, self.generation == generation else { return }
        let executable = recorded?.executable ?? FileManager.default.isExecutableFile(atPath: file)
        draft.worktreeSetup = Self.setupCommand(relative: relative, executable: executable)
        saved = false
        if recorded?.tracked == false {
            error = String(localized: "\(relative) isn't committed, so new worktrees won't have it. Commit it, or list it under Copy ignored files if git ignores it.")
        }
    }
    /// `./path` for an executable, which then runs with its own shebang; `sh ./path` otherwise.
    /// Quoted when the path holds anything a shell would read.
    static func setupCommand(relative: String, executable: Bool) -> String {
        let plain = relative.allSatisfy { $0.isLetter || $0.isNumber || "._-/".contains($0) }
        let path = plain ? "./\(relative)" : AgentDrivers.quote("./\(relative)")
        return executable ? path : "sh \(path)"
    }
    /// The New Project sheet's Choose…: pick the checkout, then read its GitHub repo from the git
    /// origin (the web modal's chooseModalWorkspace) — the repo is derived, never typed there.
    func chooseWorkspace() async {
        let before = draft.workspace
        await pickFolder()
        guard draft.workspace != before else { return }
        await detectRepository()
    }
    /// What the folder holds: its GitHub repo, a name and IDE for a new project, and whether it is a
    /// git repository. `git` asks only that last, for a project moved to another folder, whose repo
    /// is the person's to keep.
    func detectRepository(git gitOnly: Bool = false) async {
        guard active, !Task.isCancelled, !busy && !draft.workspace.isEmpty, let service else { return }
        let generation = generation, workspace = draft.workspace
        busy = true; error = nil
        defer { busy = false }
        do {
            let detected = try await service.detect(workspace)
            let repo = detected.repo
            guard active, !Task.isCancelled, self.generation == generation, draft.workspace == workspace else { return }
            // Agreeing to make one folder a repository is not agreeing for the next.
            if gitAnswer?.workspace != workspace { draft.initGit = false }
            gitAnswer = (workspace, detected.git)
            if gitOnly { return }
            if repo.isEmpty {
                // A folder without git the project is moving to says so itself (`needsGit`); it has no remote.
                if !needsGit { error = String(localized: "No GitHub remote found in this workspace.") }
                // A new project's repo is only ever derived, so one left from another folder is stale.
                if id == nil { draft.repo = "" }
            } else { draft.repo = repo }
            suggestName()
            suggestIDE(detected.ide)
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
    /// A new project's IDE is guessed from what the checkout holds. A pick the user made is
    /// never replaced — only None or a still-suggested guess.
    private func suggestIDE(_ ide: String) {
        guard active, id == nil, draft.ide.isEmpty || draft.ide == suggestedIDE,
              ide.isEmpty || IDEChoice.all.contains(where: { $0.id == ide }) else { return }
        draft.ide = ide; suggestedIDE = ide
    }
    func save() async {
        guard active, !Task.isCancelled, !busy, let service else { return }
        if let message = draft.validationError { error = message; return }
        // A folder not yet detected is detected first: one without git waits for the box. A project
        // moved to another folder only asks about git: the repository it names is the person's.
        if movesFolder, !draft.workspace.isEmpty, gitAnswer?.workspace != draft.workspace {
            let before = generation
            await detectRepository(git: id != nil)
            // A detection that failed keeps its error on screen rather than saving blind.
            guard active, !Task.isCancelled, self.generation == before, gitAnswer?.workspace == draft.workspace, !needsGit else { return }
        }
        // The box was ticked for the folder detected; a folder never detected has not been agreed to.
        if gitAnswer?.workspace != draft.workspace { draft.initGit = false }
        let generation = generation
        busy = true; error = nil; saved = false
        defer { busy = false }
        do {
            let project = try await service.save(draft, id: id)
            guard active, self.generation == generation else { return }
            draft = ProjectDraft(project); baseline = draft; saved = true
            completedCreation = id == nil
            onAction(.saved(project))
        } catch {
            guard active && self.generation == generation else { return }
            self.error = error.localizedDescription
            // What the folder was may have changed under the answer kept (a `.git` taken away): the
            // next Save asks again, and offers to set git up if it must.
            gitAnswer = nil
        }
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
