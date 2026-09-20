import SwiftUI

/// Every place the app can show, across all coordinators. A destination holds either a
/// view model or a child coordinator; `view()` is the one place views are built from them.
enum Destination: Hashable {
    // MARK: App-level destinations (child coordinators)

    case dashboardCoordinator(DashboardCoordinator)
    case projectCoordinator(ProjectCoordinator)
    case sessionWorkspaceCoordinator(SessionWorkspaceCoordinator)

    // MARK: Screen destinations (view models)

    case dashboard(DashboardViewModel, ShellStore)
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
        case .projectCoordinator(let coordinator):
            ProjectCoordinatorView(coordinator: coordinator).id(coordinator.model.project.id)
        case .sessionWorkspaceCoordinator(let coordinator):
            SessionWorkspaceCoordinatorView(coordinator: coordinator)

        // Screens
        case .dashboard(let viewModel, let shell):
            DashboardView(model: viewModel, shell: shell)
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
                .toolbar { PageTitleToolbarItem(title: title) }

        // Empty
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Identity

// Destinations compare their payloads by identity, never by state.
extension DashboardViewModel: HashableObject {}
extension LogsViewModel: HashableObject {}
extension ProjectPageViewModel: HashableObject {}
extension SessionWorkspaceViewModel: HashableObject {}
extension RootViewModel: HashableObject {}
extension ShellStore: Hashable {
    nonisolated public static func == (lhs: ShellStore, rhs: ShellStore) -> Bool { lhs === rhs }
    nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
extension WorkspaceContext: HashableObject {}
