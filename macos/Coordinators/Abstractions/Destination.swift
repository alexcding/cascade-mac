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
    case newSession(NewSessionViewModel)
    case logs(LogsViewModel)
    case project(ProjectPageViewModel)
    case sessionWorkspace(SessionWorkspaceViewModel, WorkspaceContext)

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
        case .newSession(let viewModel):
            NewSessionView(model: viewModel)
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
            // The tabs stand in for the page title, as the system's toolbar segmented control. Tickets
            // is always one of them, so the control never changes width. Tickets is My Tickets,
            // pushed over the home screen, so choosing any other tab from there pops back to it.
            let tabs = DashboardViewModel.Tab.allCases
            let selected = coordinator.path.isEmpty ? model.tab : .tickets
            return WindowToolbar(
                leading: [.segments("dashboard-tabs", titles: tabs.map(\.title), selected: tabs.firstIndex(of: selected) ?? 0) {
                    model.selectTab(tabs[$0])
                }],
                trailing: [.search("dashboard-search", prompt: String(localized: "Search pull requests and tickets"),
                                   text: Bindable(model).query)])
        case .automationCoordinator(let coordinator):
            return coordinator.root.windowToolbar
        case .automation(let model):
            // The page's name leads, or the way back to it from an open pipeline; New trails it. The
            // search sits on the page, over the table it narrows.
            let new = WindowToolbarItem("automation-new", style: .plain, priority: .high) { AutomationNewMenu(model: model) }
            if model.draft != nil {
                return WindowToolbar(leading: [.init("automation-back") { AutomationBackButton(model: model) }], trailing: [new])
            }
            return WindowToolbar(leading: [.title(String(localized: "Automations"))], trailing: [new])
        case .projectCoordinator(let coordinator):
            // The project's name, or, with its board on, the Board and Settings tabs standing in for
            // the title, as the Dashboard's do: the system's toolbar segmented control.
            let model = coordinator.model
            let terminal = model.terminal
            let sections = model.sections
            // With no board there is one page, so its title is the project's name rather than a lone tab.
            let leading: [WindowToolbarItem] = sections.count < 2 ? [.title(model.project.name)]
                : [.segments("project-tabs-board", titles: sections.map(\.title),
                             selected: sections.firstIndex(of: model.section) ?? 0) {
                    if sections.indices.contains($0) { model.selectSection(sections[$0]) }
                }]
            return WindowToolbar(leading: leading, trailing: [.picker("project-terminal", label: String(localized: "Terminal"),
                                   choices: [.init(title: String(localized: "Terminal"), symbol: "terminal", selectedColor: Theme.toolbarSymbolSelected)],
                                   selected: terminal.shown ? 0 : -1, toggles: true) { _ in
                withAnimation(.projectTerminalSlide) { terminal.toggle() }
            }])
        case .sessionWorkspaceCoordinator(let coordinator):
            return SessionWorkspaceToolbar(context: coordinator.context, model: coordinator.model).toolbar
        case .terminal(let root), .session(_, let root):
            return WindowToolbar(leading: [.title(root.title)])
        case .unavailable(let title, _):
            return WindowToolbar(leading: [.title(title)])
        case .newSession:
            return WindowToolbar(leading: [.title(String(localized: "New Task"))])
        case .dashboard, .dashboardTickets, .logs, .project, .sessionWorkspace, .none:
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
extension RootViewModel: HashableObject {}
extension ShellStore: Hashable {
    nonisolated public static func == (lhs: ShellStore, rhs: ShellStore) -> Bool { lhs === rhs }
    nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
extension WorkspaceContext: HashableObject {}
