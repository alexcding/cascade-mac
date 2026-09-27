import Foundation

/// Builds backend adapters at the composition boundary. Root and feature models
/// receive protocols; replacing a service also applies to nested flows.
@MainActor protocol BackendFeatureFactory {
    func projects(api: APIClient) -> any ProjectService
    func automation(api: APIClient) -> any AutomationService
    func dashboard(api: APIClient) -> any DashboardService
    func logs(api: APIClient) -> any LogService
    func settings(api: APIClient) -> any SettingsService
    func cliSettings(api: APIClient) -> any CLISettingsService
    func diagnostics(api: APIClient) -> any DiagnosticsService
    func history(api: APIClient) -> any GitHistoryService
    func diff(api: APIClient) -> any DiffService
    func changes(api: APIClient) -> any GitChangesService
    func workspaceTargets(api: APIClient) -> any WorkspaceTargetService
    func sessions(api: APIClient) -> any SessionServing
    func ideWarmup(api: APIClient) -> any IDEWarmupServing
    func removal(api: APIClient, stopTerminals: @escaping @Sendable (Set<String>) async throws -> Void) -> any SessionRemoving
}

@MainActor struct NativeBackendFeatureFactory: BackendFeatureFactory {}

extension BackendFeatureFactory {
    func projects(api: APIClient) -> any ProjectService { APIProjectService(api: api) }
    func automation(api: APIClient) -> any AutomationService { APIAutomationService(api: api) }
    func dashboard(api: APIClient) -> any DashboardService { APIDashboardService(api: api) }
    func logs(api: APIClient) -> any LogService { APILogService(api: api) }
    func settings(api: APIClient) -> any SettingsService { APISettingsService(api: api) }
    func cliSettings(api: APIClient) -> any CLISettingsService { APICLISettingsService(api: api) }
    func diagnostics(api: APIClient) -> any DiagnosticsService { APIDiagnosticsService(api: api) }
    func history(api: APIClient) -> any GitHistoryService { APIGitHistoryService(api: api) }
    func diff(api: APIClient) -> any DiffService { APIDiffService(api: api) }
    func changes(api: APIClient) -> any GitChangesService { APIGitChangesService(api: api) }
    func workspaceTargets(api: APIClient) -> any WorkspaceTargetService { APIWorkspaceTargetService(api: api) }
    func sessions(api: APIClient) -> any SessionServing { SessionOperations(api: api) }
    func ideWarmup(api: APIClient) -> any IDEWarmupServing { APIIDEWarmupService(api: api) }
    func removal(api: APIClient, stopTerminals: @escaping @Sendable (Set<String>) async throws -> Void) -> any SessionRemoving {
        SessionRemovalService(api: api, stopTerminals: stopTerminals)
    }
    func projectServices(api: APIClient) -> ProjectFeatureServices {
        ProjectFeatureServices(projects: projects(api: api), sessions: sessions(api: api))
    }
}
