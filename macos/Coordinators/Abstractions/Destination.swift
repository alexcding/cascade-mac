import SwiftUI

/// Every place the app can show, across all coordinators. A destination holds either a
/// view model or a child coordinator; `view()` is the one place views are built from them.
enum Destination: Hashable {
    // MARK: App-level destinations (child coordinators)

    case dashboardCoordinator(DashboardCoordinator)
    case automationCoordinator(AutomationCoordinator)
    case projectCoordinator(ProjectCoordinator)
    case sessionWorkspaceCoordinator(SessionWorkspaceCoordinator)
    case chatCoordinator(ChatCoordinator)

    // MARK: Screen destinations (view models)

    case dashboard(DashboardViewModel, ShellStore)
    case automation(AutomationViewModel)
    case newSession(NewSessionViewModel)
    case logs(LogsViewModel)
    case project(ProjectPageViewModel)
    case sessionWorkspace(SessionWorkspaceViewModel, WorkspaceContext)
    case chat(ChatViewModel)

    // MARK: Root placeholders; the root model resolves their live state

    case terminal(RootViewModel)
    case session(id: String, RootViewModel)
    case unavailable(title: String, message: String)

    // MARK: Empty state

    case none

    /// The destination the user is looking at, drilling through child coordinators.
    @MainActor var visibleDestination: Destination {
        switch self {
        case .dashboardCoordinator(let child): child.visibleDestination
        case .automationCoordinator(let child): child.visibleDestination
        case .projectCoordinator(let child): child.visibleDestination
        case .sessionWorkspaceCoordinator(let child): child.visibleDestination
        case .chatCoordinator(let child): child.visibleDestination
        default: self
        }
    }
}

// MARK: - View Builder

@MainActor
extension Destination {
    @ViewBuilder
    func view() -> some View {
        switch self {
        // Child coordinators
        case .dashboardCoordinator(let coordinator):
            DashboardCoordinatorView(coordinator: coordinator)
        case .automationCoordinator(let coordinator):
            AutomationCoordinatorView(coordinator: coordinator)
        case .projectCoordinator(let coordinator):
            ProjectCoordinatorView(coordinator: coordinator).id(coordinator.model.project.id)
        case .sessionWorkspaceCoordinator(let coordinator):
            SessionWorkspaceCoordinatorView(coordinator: coordinator)
        case .chatCoordinator(let coordinator):
            ChatCoordinatorView(coordinator: coordinator).id(coordinator.threadID)

        // Screens
        case .dashboard(let viewModel, let shell):
            DashboardView(model: viewModel, shell: shell)
        case .automation(let viewModel):
            AutomationView(model: viewModel)
        case .newSession(let viewModel):
            NewSessionView(model: viewModel)
        case .logs(let viewModel):
            LogsView(model: viewModel)
        case .project(let viewModel):
            ProjectPageView(model: viewModel)
        case .sessionWorkspace(let viewModel, let context):
            SessionWorkspaceView(context: context, model: viewModel)
        case .chat(let viewModel):
            ChatView(model: viewModel)

        // Root placeholders
        case .terminal(let root):
            RootTerminalPlaceholderView(model: root)
        case .session(let id, let root):
            RootSessionPlaceholderView(id: id, model: root)
        case .unavailable(let title, let message):
            Text(message).foregroundStyle(.secondary)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        // Empty
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Toolbar

@MainActor
extension Destination {
    /// What this destination shows in the window's toolbar, from the same models as `view()`. A
    /// child coordinator's screens share their coordinator's toolbar, so its screens have none.
    var windowToolbar: WindowToolbar {
        switch self {
        case .dashboardCoordinator(let coordinator):
            // The page's name leads: its lists and their filters are all on the page itself.
            return WindowToolbar(
                leading: [.title(String(localized: "Projects"))],
                // In the toolbar's own glass, as Run is: a plain button, in regular text.
                trailing: [.init("dashboard-new-project", priority: .high) {
                    Button { coordinator.newProject() } label: {
                        Label(String(localized: "New Project"), systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    // A toolbar sets a button's title heavier than a menu's; regular matches New Automation.
                    .fontWeight(.regular)
                    .fixedSize()
                    // Offline, or while another sheet is up, it would do nothing, so it says so.
                    .disabled(!coordinator.canCreateProject())
                    .accessibilityIdentifier("dashboard-new-project")
                }])
        case .automationCoordinator(let coordinator):
            return coordinator.root.windowToolbar
        case .automation(let model):
            // The page's name leads, or the way back to it from an open pipeline; New trails it. The
            // search sits on the page, over the table it narrows.
            let new = WindowToolbarItem("automation-new", priority: .high) { AutomationNewMenu(model: model) }
            if model.draft != nil {
                return WindowToolbar(leading: [.init("automation-back") { AutomationBackButton(model: model) }], trailing: [new])
            }
            return WindowToolbar(leading: [.title(String(localized: "Automations"))], trailing: [new])
        case .projectCoordinator(let coordinator):
            // Back to Projects, where the page was opened from, then the project's name.
            let model = coordinator.model
            let back = WindowToolbarItem("project-back") { ProjectBackButton(model: model) }
            return WindowToolbar(leading: [back, .title(model.project.name)])
        case .sessionWorkspaceCoordinator(let coordinator):
            return SessionWorkspaceToolbar(context: coordinator.context, model: coordinator.model).toolbar
        case .chatCoordinator(let coordinator):
            // The agent's mark and the chat's title lead; its folder trails.
            let model = coordinator.model
            return WindowToolbar(
                leading: [.init("title", style: .plain, priority: .high) { ChatToolbarTitle(model: model) }],
                trailing: [.init("chat-open-folder") { ChatOpenFolderButton(model: model) }])
        case .terminal(let root), .session(_, let root):
            return WindowToolbar(leading: [.title(root.title)])
        case .unavailable(let title, _):
            return WindowToolbar(leading: [.title(title)])
        case .newSession:
            return WindowToolbar(leading: [.title(String(localized: "New Task"))])
        case .dashboard, .logs, .project, .sessionWorkspace, .chat, .none:
            return .empty
        }
    }
}

// MARK: - Identity

// Destinations compare their payloads by identity, never by state.
extension DashboardViewModel: HashableObject {}
extension AutomationViewModel: HashableObject {}
extension NewSessionViewModel: HashableObject {}
extension LogsViewModel: HashableObject {}
extension ProjectPageViewModel: HashableObject {}
extension SessionWorkspaceViewModel: HashableObject {}
extension ChatViewModel: HashableObject {}
extension RootViewModel: HashableObject {}
extension ShellStore: Hashable {
    nonisolated public static func == (lhs: ShellStore, rhs: ShellStore) -> Bool { lhs === rhs }
    nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
extension WorkspaceContext: HashableObject {}
