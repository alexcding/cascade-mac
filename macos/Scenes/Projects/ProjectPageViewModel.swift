import Foundation
import Observation

/// A project's home: the composer that starts its sessions, with the project's settings in the
/// window's inspector column (`InspectorPresenting`), shown until the user hides it.
@MainActor @Observable final class ProjectPageViewModel: InspectorPresenting {
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
    /// One setting for every project: open until the user closes it. A model re-reads it whenever
    /// its project is shown again (`update`), so a change made on another project reaches it.
    private(set) var showsInspector: Bool
    private(set) var retired = false
    @ObservationIgnored private let defaults: UserDefaults
    static let inspectorKey = "project.showsInspector"

    init(project: Project, editor: ProjectEditorViewModel, composer: ProjectComposerModel, defaults: UserDefaults = .standard) {
        self.project = project; self.editor = editor; self.composer = composer; self.defaults = defaults
        showsInspector = defaults.object(forKey: Self.inspectorKey) as? Bool ?? true
    }
    var canToggleInspector: Bool { !retired }
    func setInspectorPresented(_ presented: Bool) {
        guard !retired, presented != showsInspector else { return }
        showsInspector = presented
        defaults.set(presented, forKey: Self.inspectorKey)
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
        showsInspector = defaults.object(forKey: Self.inspectorKey) as? Bool ?? true
    }
}
