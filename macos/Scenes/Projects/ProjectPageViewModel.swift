import Foundation
import Observation

@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: a ticket action already
    /// carries the resolved request, and the coordinator never calls back into this model to
    /// resolve one, following the Dashboard's pattern.
    enum Action: Equatable {
        case selectSection(ProjectSection), saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        case jiraTicket(JiraTicketsViewModel.Action), boardTicket(WebBoardViewModel.Action)
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
            board?.onAction = { [onAction] in onAction(.boardTicket($0)) }
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    let board: WebBoardViewModel?
    let tickets: JiraTicketsViewModel?
    private(set) var section = ProjectSection.tickets {
        didSet { if oldValue != section { cancelActions(); updateBoardPresentation() } }
    }
    var active = false { didSet { if oldValue != active { updateBoardPresentation() } } }
    var appearance = AppAppearance.system { didSet { if oldValue != appearance { updateBoardPresentation() } } }
    private(set) var retired = false
    init(project: Project, editor: ProjectEditorViewModel, board: WebBoardViewModel? = nil, tickets: JiraTicketsViewModel? = nil) {
        self.project = project; self.editor = editor; self.board = board; self.tickets = tickets
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
        active = false
        retired = true; onAction = { _ in }
        cancelActions(); editor.retire()
        tickets?.retire(); board?.retire()
    }
    func selectSection(_ section: ProjectSection) { onAction(.selectSection(section)) }
    func setSection(_ section: ProjectSection) {
        guard !retired else { return }
        self.section = Self.resolve(section, for: project)
    }
    private func updateBoardPresentation() {
        guard !retired else { return }
        board?.appearance = appearance
        board?.active = active && section == .board
    }
    func cancelActions() {
        tickets?.cancelActions(); board?.cancelActions()
    }
    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project; editor.update(project); tickets?.update(project)
        section = Self.resolve(section, for: project)
    }
}
