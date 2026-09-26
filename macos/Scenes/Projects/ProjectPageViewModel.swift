import Foundation
import Observation

@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: a ticket action already
    /// carries the resolved request, and the coordinator never calls back into this model to
    /// resolve one, following the Dashboard's pattern.
    enum Action: Equatable {
        case selectSection(ProjectSection), saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        case jiraTicket(JiraTicketsViewModel.Action)
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
            tickets?.onAction = { [onAction] in onAction(.jiraTicket($0)) }
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    let tickets: JiraTicketsViewModel?
    private(set) var section = ProjectSection.tickets {
        didSet { if oldValue != section { cancelActions() } }
    }
    private(set) var retired = false
    init(project: Project, editor: ProjectEditorViewModel, tickets: JiraTicketsViewModel? = nil) {
        self.project = project; self.editor = editor; self.tickets = tickets
        section = Self.resolve(section, for: project)
    }
    /// Sections the picker offers for this project (`ProjectSection.available`).
    var availableSections: [ProjectSection] { ProjectSection.available(for: project) }
    /// A section the project cannot show falls back to its first available one, so
    /// neither a deep link nor an edit in Settings can leave a hidden tab selected.
    private static func resolve(_ section: ProjectSection, for project: Project) -> ProjectSection {
        let available = ProjectSection.available(for: project)
        return available.contains(section) ? section : (available.first ?? .settings)
    }
    func connect(_ service: (any ProjectService)?) {
        guard !retired else { return }
        if service == nil { cancelActions() }
        editor.connect(service)
    }
    func retire() {
        retired = true; onAction = { _ in }
        cancelActions(); editor.retire()
        tickets?.retire()
    }
    func selectSection(_ section: ProjectSection) { onAction(.selectSection(section)) }
    func setSection(_ section: ProjectSection) {
        guard !retired else { return }
        self.section = Self.resolve(section, for: project)
    }
    func cancelActions() {
        tickets?.cancelActions()
    }
    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project; editor.update(project); tickets?.update(project)
        section = Self.resolve(section, for: project)
    }
}
