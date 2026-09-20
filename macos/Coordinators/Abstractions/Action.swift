import Foundation

/// User intents that view models and child coordinators emit for a coordinator to handle.
/// View models know nothing about navigation: they say what happened, never where to go.
///
/// Actions are grouped by domain so each coordinator matches the domains it owns and
/// forwards the rest to its parent.
enum Action {
    case root(RootViewModel.Action)
    case dashboard(DashboardViewModel.Action)
    case logs(LogsViewModel.Action)
    case settings(SettingsViewModel.Action)
    case project(ProjectPageViewModel.Action)
    case projectEvent(ProjectCoordinator.Event, projectID: String)
    case workspace(SessionWorkspaceViewModel.Action, WorkspaceContext)
}
