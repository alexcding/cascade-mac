import Foundation
import Observation

@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do. The flow is one way: a ticket action already
    /// carries the resolved request, and the coordinator never calls back into this model to
    /// resolve one, following the Dashboard's pattern.
    enum Action: Equatable {
        case selectSection(ProjectSection), saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        case ticket(TicketsViewModel.Action)
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
            for model in ticketModels { model.onAction = { [onAction] in onAction(.ticket($0)) } }
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    /// The project's Jira tickets and its GitHub issues: one list model per source.
    let tickets: TicketsViewModel?
    let issues: TicketsViewModel?
    private(set) var section = ProjectSection.tickets {
        didSet { if oldValue != section { cancelActions() } }
    }
    /// Which source the Tickets section shows, when the project has both.
    private(set) var ticketSource = TicketSource.jira {
        didSet { if oldValue != ticketSource { cancelActions() } }
    }
    private(set) var retired = false
    init(project: Project, editor: ProjectEditorViewModel, tickets: TicketsViewModel? = nil, issues: TicketsViewModel? = nil) {
        self.project = project; self.editor = editor; self.tickets = tickets; self.issues = issues
        section = Self.resolve(section, for: project)
        ticketSource = Self.resolve(ticketSource, for: project)
    }
    private var ticketModels: [TicketsViewModel] { [tickets, issues].compactMap { $0 } }
    /// Sections the picker offers for this project (`ProjectSection.available`).
    var availableSections: [ProjectSection] { ProjectSection.available(for: project) }
    /// The ticket sources the Tickets section can switch between.
    var ticketSources: [TicketSource] { project.ticketSources.filter { model(for: $0) != nil } }
    /// The list the Tickets section shows now.
    var shownTickets: TicketsViewModel? { ticketSources.contains(ticketSource) ? model(for: ticketSource) : nil }
    func model(for source: TicketSource) -> TicketsViewModel? {
        switch source {
        case .jira: tickets
        case .github: issues
        }
    }
    /// A section the project cannot show falls back to its first available one, so
    /// neither a deep link nor an edit in Settings can leave a hidden tab selected.
    private static func resolve(_ section: ProjectSection, for project: Project) -> ProjectSection {
        let available = ProjectSection.available(for: project)
        return available.contains(section) ? section : (available.first ?? .settings)
    }
    private static func resolve(_ source: TicketSource, for project: Project) -> TicketSource {
        let available = project.ticketSources
        return available.contains(source) ? source : (available.first ?? .jira)
    }
    func connect(_ service: (any ProjectService)?) {
        guard !retired else { return }
        if service == nil { cancelActions() }
        editor.connect(service)
    }
    func retire() {
        retired = true; onAction = { _ in }
        cancelActions(); editor.retire()
        for model in ticketModels { model.retire() }
    }
    func stop() async {
        for model in ticketModels { await model.stop() }
    }
    func selectSection(_ section: ProjectSection) { onAction(.selectSection(section)) }
    func setSection(_ section: ProjectSection) {
        guard !retired else { return }
        self.section = Self.resolve(section, for: project)
    }
    func selectTicketSource(_ source: TicketSource) {
        guard !retired else { return }
        ticketSource = Self.resolve(source, for: project)
    }
    func cancelActions() {
        for model in ticketModels { model.cancelActions() }
    }
    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project; editor.update(project)
        for model in ticketModels { model.update(project) }
        section = Self.resolve(section, for: project)
        ticketSource = Self.resolve(ticketSource, for: project)
    }
}
