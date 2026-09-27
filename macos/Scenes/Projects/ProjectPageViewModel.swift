import Foundation
import Observation

/// The pages of a project, picked from the toolbar as the Dashboard's are.
enum ProjectSection: String, CaseIterable, Identifiable {
    case home, settings, orchestration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .settings: String(localized: "Settings")
        case .orchestration: String(localized: "Orchestration")
        }
    }
}

/// A project's screen: Home, the composer that starts its sessions; Settings; and Orchestration.
@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do.
    enum Action: Equatable {
        case saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
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
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    let composer: ProjectComposerModel
    private(set) var section = ProjectSection.home
    private(set) var retired = false

    init(project: Project, editor: ProjectEditorViewModel, composer: ProjectComposerModel) {
        self.project = project; self.editor = editor; self.composer = composer
    }
    func selectSection(_ section: ProjectSection) {
        guard !retired else { return }
        self.section = section
    }
    func connect(_ service: (any ProjectService)?) {
        guard !retired else { return }
        editor.connect(service)
    }
    func retire() {
        retired = true; onAction = { _ in }
        editor.retire(); composer.retire()
    }
    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project; editor.update(project); composer.update(project)
    }
}
