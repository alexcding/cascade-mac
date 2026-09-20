import Foundation

@MainActor protocol WorkspaceFeatureFactory {
    func workspace(context: WorkspaceContext, service: any WorkspaceServing) -> SessionWorkspaceViewModel
    func removal(service: any SessionRemoving, record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession],
                 didRemove: @escaping ([WorkspaceSession]) async -> Void, finished: @escaping () -> Void) -> SessionRemovalViewModel
    func build(api: APIClient, project: Project, session: WorkspaceSession,
               terminalFactory: @escaping () throws -> any BuildTerminal) -> BuildWorkspaceViewModel
    func buildDestination(runtime: BuildWorkspaceViewModel, purpose: BuildDestinationViewModel.Purpose) -> BuildDestinationViewModel
}

@MainActor struct NativeWorkspaceFeatureFactory: WorkspaceFeatureFactory {
    func workspace(context: WorkspaceContext, service: any WorkspaceServing) -> SessionWorkspaceViewModel {
        SessionWorkspaceViewModel(context: context, service: service)
    }
    func removal(service: any SessionRemoving, record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession],
                 didRemove: @escaping ([WorkspaceSession]) async -> Void, finished: @escaping () -> Void) -> SessionRemovalViewModel {
        SessionRemovalViewModel(service: service, record: record, projects: projects, sessions: sessions,
                                didRemove: didRemove, finished: finished)
    }
    func build(api: APIClient, project: Project, session: WorkspaceSession,
               terminalFactory: @escaping () throws -> any BuildTerminal) -> BuildWorkspaceViewModel {
        BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session, terminalFactory: terminalFactory)
    }
    func buildDestination(runtime: BuildWorkspaceViewModel, purpose: BuildDestinationViewModel.Purpose) -> BuildDestinationViewModel {
        BuildDestinationViewModel(runtime: runtime, purpose: purpose)
    }
}
