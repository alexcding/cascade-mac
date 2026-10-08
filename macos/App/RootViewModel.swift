import Foundation
import Observation

@MainActor struct RootState {
    var selection: SidebarDestination = .overview
    var entries: [SidebarEntry] = []
    var pinnedIDs: Set<String> = []
    var projects: [Project] = []
    var sessions: [WorkspaceSession] = []
    var projectModels: [String: ProjectPageViewModel] = [:]
    var dashboard: DashboardViewModel?
    var logs: LogsViewModel?
    var todayActivity: TodayActivityViewModel?
    var settings: SettingsViewModel?
    var error: String?
    var canCreateProject = false
    var canCreateSession = false
    var canRefresh = false
    var gitClientLabel: String?
    /// Every chat the store holds, and whether it has been read yet.
    var chats: [ChatThreadShell] = []
    var chatsLoaded = false
}

@MainActor protocol RootServing: AnyObject { func rootState() -> RootState }

@MainActor @Observable final class RootViewModel {
    enum Action: Equatable {
        case select(SidebarDestination), command(ShellCommand), togglePin(String)
        case moveProject(String, before: String?), moveSession(String, before: String?), movePinned(String, before: String?)
        case reconnect, openTerminal, removeSession(String), openGitClient(String)
        case renameSession(String, name: String), forkSession(String), focusSession(String)
        case reattachSession(String)
        /// A project row's hover New Task.
        case newTask(String)
        case renameChat(String, name: String)
        case deleteChat(String)
    }
    let shell: ShellStore
    let viewer: ViewerStore
    @ObservationIgnored private weak var service: (any RootServing)?
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }

    init(service: any RootServing, shell: ShellStore, viewer: ViewerStore) {
        self.service = service; self.shell = shell; self.viewer = viewer
    }
    private var state: RootState { service?.rootState() ?? RootState() }
    var selection: SidebarDestination { state.selection }
    var entries: [SidebarEntry] { state.entries }
    var pinnedIDs: Set<String> { state.pinnedIDs }
    /// The sessions whose agent can fork its conversation: every one running an agent.
    var forkableIDs: Set<String> { Set(state.sessions.filter { $0.agent.driver != nil }.map(\.id)) }
    /// The key that selects each of the first ten sessions, by session id, in the sidebar's order:
    /// what it shows beside them while ⌘ is held.
    var sessionShortcuts: [String: String] {
        let ids = entries.flatMap(\.descendants).compactMap(\.sessionID)
        return Dictionary(zip(ids, ShellCommand.sessions).compactMap { id, command in
            ShortcutRegistry.shared.shortcut(for: command).map { (id, $0.title) }
        }, uniquingKeysWith: { first, _ in first })
    }
    var error: String? {
        let state = self.state
        switch state.selection {
        // A chat's rename or delete is reported where its row was used from, or on its screen.
        case .overview, .project, .chat: return state.error
        default: return nil
        }
    }
    var todayActivity: TodayActivityViewModel? { state.todayActivity }
    var canCreateSession: Bool { state.canCreateSession }
    var canRefresh: Bool { state.canRefresh }
    var title: String {
        let state = self.state
        switch state.selection {
        case .newSession: return String(localized: "New Task")
        case .overview: return String(localized: "Projects")
        case .automation: return String(localized: "Automation")
        case .terminal: return String(localized: "Terminal")
        case .project(let id): return state.projects.first { $0.id == id }?.name ?? String(localized: "Project")
        case .session(let id): return state.sessions.first { $0.id == id }?.label ?? String(localized: "Session")
        case .chat(let id): return state.chats.first { $0.id == id }?.label ?? String(localized: "Chat")
        }
    }
    func session(_ id: String) -> WorkspaceSession? { state.sessions.first { $0.id == id } }
    func select(_ destination: SidebarDestination) { onAction(.select(destination)) }
    func togglePin(_ id: String) { onAction(.togglePin(id)) }
    /// A session row's right-click Remove Session: the confirmation sheet is the coordinator's.
    func removeSession(_ id: String) { onAction(.removeSession(id)) }
    /// A session row's right-click Rename Session, with the name typed into the prompt.
    func renameSession(_ id: String, to name: String) { onAction(.renameSession(id, name: name)) }
    /// A session row's right-click Fork Session.
    func forkSession(_ id: String) { onAction(.forkSession(id)) }
    /// A stopped session row's right-click Reattach Session.
    func reattachSession(_ id: String) { onAction(.reattachSession(id)) }
    /// A session row clicked: the keyboard goes to its terminal or chat.
    func focusSession(_ id: String) { onAction(.focusSession(id)) }
    /// "Open in Sourcetree" for a session row; nil until a git client is chosen in Settings.
    var gitClientLabel: String? { state.gitClientLabel }
    func openGitClient(_ id: String) { onAction(.openGitClient(id)) }
    /// Drops a project before `before` in the Projects list, or at its end when nil.
    func moveProject(_ id: String, before: String?) { onAction(.moveProject(id, before: before)) }
    /// Drops a session before its sibling `before`, or last in its project when nil.
    func moveSession(_ id: String, before: String?) { onAction(.moveSession(id, before: before)) }
    /// Drops a pinned session before `before` in the Pinned section, or at its end when nil.
    func movePinned(_ id: String, before: String?) { onAction(.movePinned(id, before: before)) }
    func reconnect() { onAction(.reconnect) }
    func openActivity() { onAction(.command(.activity)) }
    func openSettings() { onAction(.command(.settings)) }
    func newSession() { if canCreateSession { onAction(.command(.newSession)) } }
    /// A project row's hover pencil: New Task on that project, wherever the window is.
    func newTask(in projectID: String) { onAction(.newTask(projectID)) }
    func refresh() { if canRefresh { onAction(.command(.refresh)) } }
    /// A chat row's Rename…, with the title typed into the prompt.
    func renameChat(_ id: String, to name: String) { onAction(.renameChat(id, name: name)) }
    /// A chat row's Delete…, once its confirmation was answered.
    func deleteChat(_ id: String) { onAction(.deleteChat(id)) }
    func openTerminal() { onAction(.openTerminal) }
}
