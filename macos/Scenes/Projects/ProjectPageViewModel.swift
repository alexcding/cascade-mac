import Foundation
import Observation

/// A project's screen, opened from its name on Projects: its Settings. Its Jira sprint board is
/// Projects' Board tab. Its composer is New Task's when New Task is on this project: sessions start
/// there, not here.
@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do.
    enum Action: Equatable {
        case saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        /// Start made a session; `prompt` is its agent's first message, when it has one.
        case sessionCreated(WorkspaceSession, prompt: String?, launch: AgentLaunchChoice?)
        /// The toolbar's back button: back to Projects, where the page was opened from.
        case back
    }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in } {
        didSet {
            // Forward the current parent callback by value, following Record's
            // action.didSet pattern. Children do not retain this parent model.
            editor.onAction = { [onAction] action in
                switch action {
                case .saved(let project): onAction(.saved(project, .configuration))
                case .deleted(let id): onAction(.deleted(id))
                case .requestDeletion(let request): onAction(.requestDeletion(request))
                }
            }
            composer.onAction = { [onAction] action in
                switch action {
                case .created(let session, let prompt, let launch): onAction(.sessionCreated(session, prompt: prompt, launch: launch))
                }
            }
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    let composer: ProjectComposerModel
    private(set) var retired = false

    init(project: Project, editor: ProjectEditorViewModel, composer: ProjectComposerModel) {
        self.project = project; self.editor = editor; self.composer = composer
    }

    func goBack() { if !retired { onAction(.back) } }

    func connect(_ service: (any ProjectService)?, sessions: (any SessionCreating)?) {
        guard !retired else { return }
        editor.connect(service); composer.connect(sessions)
    }
    func retire() {
        retired = true; onAction = { _ in }
        editor.retire(); composer.retire()
    }
    func updateSessions(_ sessions: [WorkspaceSession]) {
        guard !retired else { return }
        composer.updateSessions(sessions)
    }
    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project; editor.update(project); composer.update(project)
    }
}
