import Foundation
import Observation

@MainActor struct RootState {
    var selection: SidebarDestination = .overview
    var entries: [SidebarEntry] = []
    var pinnedIDs: Set<String> = []
    var projects: [Project] = []
    var sessions: [WorkspaceSession] = []
    var tabs: [SavedTab] = []
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
}

@MainActor protocol RootServing: AnyObject { func rootState() -> RootState }

@MainActor @Observable final class RootViewModel {
    enum Action: Equatable {
        case select(SidebarDestination), command(ShellCommand), togglePin(String), newSession(projectID: String)
        case closeTab(String), newTab, moveTab(String, before: String?), togglePinTab(String)
        case moveProject(String, before: String?), moveSession(String, before: String?), movePinned(String, before: String?)
        case reconnect, openTerminal, openBrowser(URL), removeSession(String), openGitClient(String)
        case renameSession(String, name: String)
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
        case .overview, .project: return state.error
        default: return nil
        }
    }
    var canCreateProject: Bool { state.canCreateProject }
    var todayActivity: TodayActivityViewModel? { state.todayActivity }
    var canCreateSession: Bool { state.canCreateSession }
    var canRefresh: Bool { state.canRefresh }
    var title: String {
        let state = self.state
        switch state.selection {
        case .overview: return "Overview"
        case .automation: return "Automation"
        case .terminal: return "Terminal"
        case .project(let id): return state.projects.first { $0.id == id }?.name ?? "Project"
        case .session(let id): return state.sessions.first { $0.id == id }?.label ?? "Session"
        case .tab(let id): return state.tabs.first { $0.id == id }?.displayTitle ?? "Tab"
        }
    }
    func session(_ id: String) -> WorkspaceSession? { state.sessions.first { $0.id == id } }
    func tab(_ id: String) -> SavedTab? { state.tabs.first { $0.id == id } }
    /// A tab's address when it is a web URL the system browser can open.
    func browserAddress(_ url: String) -> URL? {
        guard let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased() ?? "") else { return nil }
        return address
    }
    func select(_ destination: SidebarDestination) { onAction(.select(destination)) }
    func togglePin(_ id: String) { onAction(.togglePin(id)) }
    /// A session row's right-click Remove Session: the confirmation sheet is the coordinator's.
    func removeSession(_ id: String) { onAction(.removeSession(id)) }
    /// A session row's right-click Rename Session, with the name typed into the prompt.
    func renameSession(_ id: String, to name: String) { onAction(.renameSession(id, name: name)) }
    /// "Open in Sourcetree" for a session row; nil until a git client is chosen in Settings.
    var gitClientLabel: String? { state.gitClientLabel }
    func openGitClient(_ id: String) { onAction(.openGitClient(id)) }
    func closeTab(_ id: String) { onAction(.closeTab(id)) }
    /// Moves a saved tab between the Tabs list and the pinned grid under Dashboard.
    func togglePinTab(_ id: String) { onAction(.togglePinTab(id)) }
    /// Drops `id` before `before` in the Tabs list, or at its end when nil.
    func moveTab(_ id: String, before: String?) { onAction(.moveTab(id, before: before)) }
    /// Drops a project before `before` in the Projects list, or at its end when nil.
    func moveProject(_ id: String, before: String?) { onAction(.moveProject(id, before: before)) }
    /// Drops a session before its sibling `before`, or last in its project when nil.
    func moveSession(_ id: String, before: String?) { onAction(.moveSession(id, before: before)) }
    /// Drops a pinned session before `before` in the Pinned section, or at its end when nil.
    func movePinned(_ id: String, before: String?) { onAction(.movePinned(id, before: before)) }
    /// The Tabs heading's "+": a blank tab in the current workspace's second panel.
    func newTab() { onAction(.newTab) }
    func reconnect() { onAction(.reconnect) }
    func openActivity() { onAction(.command(.activity)) }
    func openSettings() { onAction(.command(.settings)) }
    func newProject() { if canCreateProject { onAction(.command(.newProject)) } }
    func newSession() { if canCreateSession { onAction(.command(.newSession)) } }
    /// A project folder's hover "+": New Session on that project, wherever the window is.
    func newSession(in projectID: String) { onAction(.newSession(projectID: projectID)) }
    func refresh() { if canRefresh { onAction(.command(.refresh)) } }
    func openTerminal() { onAction(.openTerminal) }
    func openBrowser(_ url: URL) { onAction(.openBrowser(url)) }
}

extension SavedTab {
    /// The sidebar row's and toolbar's name for a tab: its title, else its address, else "New Tab".
    var displayTitle: String { title.isEmpty ? (url.isEmpty ? "New Tab" : url) : title }
}
