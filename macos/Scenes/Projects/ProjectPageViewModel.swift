import Foundation
import Observation

/// The pages of a project, picked from the toolbar as the Dashboard's are. Board is offered only
/// when the project turns it on (`ProjectPageViewModel.sections`).
enum ProjectSection: String, CaseIterable, Identifiable {
    case start, board, orchestration, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: String(localized: "Start")
        case .board: String(localized: "Board")
        case .settings: String(localized: "Settings")
        case .orchestration: String(localized: "Orchestration")
        }
    }
}

/// A project's screen: Start, the composer that starts its sessions; Board, its Jira sprint board
/// when switched on; Orchestration; and Settings. Under whichever is shown, the project's own
/// terminal can be split open (`terminal`).
@MainActor @Observable final class ProjectPageViewModel {
    /// What the screen asks its coordinator to do.
    enum Action: Equatable {
        case saved(Project, ProjectSaveSource), deleted(String)
        case requestDeletion(ProjectEditorViewModel.DeletionRequest)
        /// Start made a session; `prompt` is its agent's first message, when it has one.
        case sessionCreated(WorkspaceSession, prompt: String?)
        /// A board card asked to open; the coordinator gates it before the board opens it.
        case board(WebBoardViewModel.Action)
        /// The terminal panel needs a new shell in `directory`, in place of any running.
        case openTerminal(directory: String, request: UUID)
        /// The terminal panel closed: its shell stops.
        case closeTerminal
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
                case .created(let session, let prompt): onAction(.sessionCreated(session, prompt: prompt))
                }
            }
            board?.onAction = { [onAction] in onAction(.board($0)) }
            terminal.requestTerminal = { [onAction] in onAction(.openTerminal(directory: $0, request: $1)) }
            terminal.closeTerminal = { [onAction] in onAction(.closeTerminal) }
        }
    }
    private(set) var project: Project
    let editor: ProjectEditorViewModel
    let composer: ProjectComposerModel
    /// The shell split under the pages, in the project's checkout.
    let terminal: ProjectTerminalViewModel
    /// The sprint board, while the project shows one and a backend is connected.
    private(set) var board: WebBoardViewModel?
    private(set) var section = ProjectSection.start {
        didSet { if oldValue != section { board?.cancelActions(); updateBoard() } }
    }
    /// Whether the project is the selected screen: the board loads and follows Jira only while it
    /// is on screen.
    var active = false {
        didSet {
            guard oldValue != active else { return }
            updateBoard()
            if active && !retired { terminal.appear() }
        }
    }
    var appearance = AppAppearance.system { didSet { if oldValue != appearance { updateBoard() } } }
    private(set) var retired = false
    @ObservationIgnored private let pageActions: any PageActionServing
    @ObservationIgnored private var boardService: (any BoardService)?

    init(project: Project, editor: ProjectEditorViewModel, composer: ProjectComposerModel,
         pageActions: any PageActionServing = NativePageActionService(open: { _ in }),
         terminal: ProjectTerminalViewModel? = nil) {
        self.project = project; self.editor = editor; self.composer = composer
        self.terminal = terminal ?? ProjectTerminalViewModel(project: project)
        self.pageActions = pageActions
    }

    /// The tabs the toolbar offers: Board only for a project that shows one.
    var sections: [ProjectSection] { ProjectSection.allCases.filter { $0 != .board || project.showsBoard } }

    func selectSection(_ section: ProjectSection) {
        guard !retired else { return }
        self.section = sections.contains(section) ? section : .start
    }
    func connect(_ service: (any ProjectService)?, sessions: (any SessionCreating)?, boards: (any BoardService)? = nil) {
        guard !retired else { return }
        editor.connect(service); composer.connect(sessions); terminal.connect(sessions)
        connectBoard(boards)
    }
    /// The board's backend; nil pauses a board already built, which keeps its filters.
    func connectBoard(_ boards: (any BoardService)?) {
        guard !retired else { return }
        boardService = boards
        if let boards { board?.connect(service: boards) } else { board?.pause() }
        updateBoardModel()
        updateBoard()
    }
    /// Opens Start to begin a session, on a link when one is given. `jiraKey` is the ticket the
    /// link's pull request references, recorded on the session its lookup names no ticket for.
    func start(text: String? = nil, jiraKey: String? = nil, agent: SessionAgent? = nil) {
        guard !retired else { return }
        section = .start
        composer.prepare(text: text, jiraKey: jiraKey, agent: agent)
    }
    /// A Jira sync for this project's board, or for every board.
    func refreshBoard(event id: String?) {
        guard !retired, id == nil || id == "board:\(project.id)" else { return }
        board?.refresh()
    }
    func retire() {
        active = false
        retired = true; onAction = { _ in }
        editor.retire(); composer.retire(); terminal.retire()
        board?.retire(); board = nil
    }
    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project; editor.update(project); composer.update(project); terminal.update(project)
        updateBoardModel()
    }

    /// Builds the board when the project turns it on, and retires it when it is turned off or
    /// loses its Jira key; a page left on Board then falls back to Start.
    private func updateBoardModel() {
        if !project.showsBoard {
            board?.retire(); board = nil
            if section == .board { section = .start }
            return
        }
        guard board == nil, let boardService else { return }
        let board = WebBoardViewModel(projectID: project.id, service: boardService, pageActions: pageActions, preferences: .standard)
        board.onAction = { [onAction] in onAction(.board($0)) }
        self.board = board
        updateBoard()
    }

    private func updateBoard() {
        guard !retired, let board else { return }
        board.appearance = appearance
        // With no backend the board stays idle, so neither Refresh nor a refresh reaches the old one.
        board.active = active && section == .board && boardService != nil
    }
}
