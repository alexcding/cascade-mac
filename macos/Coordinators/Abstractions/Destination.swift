import SwiftUI

/// Every place the app can show, across all coordinators. A destination holds either a
/// view model or a child coordinator; `view()` is the one place views are built from them.
enum Destination: Hashable {
    // MARK: App-level destinations (child coordinators)

    case dashboardCoordinator(DashboardCoordinator)
    case automationCoordinator(AutomationCoordinator)
    case projectCoordinator(ProjectCoordinator)
    case sessionWorkspaceCoordinator(SessionWorkspaceCoordinator)

    // MARK: Screen destinations (view models)

    case dashboard(DashboardViewModel, ShellStore)
    case dashboardTickets(DashboardViewModel)
    case automation(AutomationViewModel)
    case logs(LogsViewModel)
    case project(ProjectPageViewModel)
    case sessionWorkspace(SessionWorkspaceViewModel, WorkspaceContext)

    // MARK: Root placeholders; the root model resolves their live state

    case terminal(RootViewModel)
    case session(id: String, RootViewModel)
    case tab(id: String, RootViewModel)
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

        // Screens
        case .dashboard(let viewModel, let shell):
            DashboardView(model: viewModel, shell: shell)
        case .dashboardTickets(let viewModel):
            DashboardTicketsView(model: viewModel)
        case .automation(let viewModel):
            AutomationView(model: viewModel)
        case .logs(let viewModel):
            LogsView(model: viewModel)
        case .project(let viewModel):
            ProjectPageView(model: viewModel)
        case .sessionWorkspace(let viewModel, let context):
            SessionWorkspaceView(context: context, model: viewModel)

        // Root placeholders
        case .terminal(let root):
            RootTerminalPlaceholderView(model: root)
        case .session(let id, let root):
            RootSessionPlaceholderView(id: id, model: root)
        case .tab(let id, let root):
            RootTabPlaceholderView(id: id, model: root)
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
            let model = coordinator.model
            // The tabs stand in for the page title. Tickets is My Tickets, pushed over the home
            // screen, so choosing any other tab from there pops back to it.
            return WindowToolbar(
                leading: [.init("dashboard-tabs") {
                    DashboardTabBar(selection: coordinator.path.isEmpty ? model.tab : .tickets,
                                    tickets: model.tickets.available, select: model.selectTab)
                }],
                trailing: [.search("dashboard-search", prompt: String(localized: "Search pull requests and tickets"),
                                   text: Bindable(model).query)])
        case .automationCoordinator(let coordinator):
            return coordinator.root.windowToolbar
        case .automation(let model):
            // New sits where a page title would, over the list it adds to; the page carries its own title.
            return WindowToolbar(leading: [.init("automation-new") { AutomationNewMenu(model: model) }],
                                 trailing: [.init("automation-switch") { AutomationMasterSwitch(model: model) }])
        case .projectCoordinator(let coordinator):
            return WindowToolbar(leading: [.title(coordinator.model.project.name)])
        case .sessionWorkspaceCoordinator(let coordinator):
            return SessionWorkspaceToolbar(context: coordinator.context, model: coordinator.model).toolbar
        case .terminal(let root), .session(_, let root), .tab(_, let root):
            return WindowToolbar(leading: [.title(root.title)])
        case .unavailable(let title, _):
            return WindowToolbar(leading: [.title(title)])
        case .dashboard, .dashboardTickets, .logs, .project, .sessionWorkspace, .none:
            return .empty
        }
    }
}

// MARK: - Identity

// Destinations compare their payloads by identity, never by state.
extension DashboardViewModel: HashableObject {}
extension AutomationViewModel: HashableObject {}
extension LogsViewModel: HashableObject {}
extension ProjectPageViewModel: HashableObject {}
extension SessionWorkspaceViewModel: HashableObject {}
extension RootViewModel: HashableObject {}
extension ShellStore: Hashable {
    nonisolated public static func == (lhs: ShellStore, rhs: ShellStore) -> Bool { lhs === rhs }
    nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
extension WorkspaceContext: HashableObject {}
