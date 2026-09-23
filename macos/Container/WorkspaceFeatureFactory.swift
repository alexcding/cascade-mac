import Foundation

@MainActor protocol WorkspaceFeatureFactory {
    func workspace(context: WorkspaceContext, service: any WorkspaceServing) -> SessionWorkspaceViewModel
    func removal(service: any SessionRemoving, record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession],
                 didRemove: @escaping ([WorkspaceSession]) async -> Void, finished: @escaping () -> Void) -> SessionRemovalViewModel
    func build(api: APIClient, project: Project, session: WorkspaceSession,
               terminalFactory: @escaping () throws -> any BuildTerminal) -> BuildWorkspaceViewModel
    func buildDestination(runtime: BuildWorkspaceViewModel, purpose: BuildDestinationViewModel.Purpose) -> BuildDestinationViewModel
    /// The simulator streams: the one each build's panel starts, and the one Quit stops.
    func simulatorPreview(api: APIClient) -> any SimulatorPreviewing
}
extension WorkspaceFeatureFactory {
    func simulatorPreview(api: APIClient) -> any SimulatorPreviewing { APISimulatorPreviewService(api: api) }
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
        BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session,
            preview: SimulatorPreviewModel(service: simulatorPreview(api: api)), terminalFactory: terminalFactory)
    }
    func buildDestination(runtime: BuildWorkspaceViewModel, purpose: BuildDestinationViewModel.Purpose) -> BuildDestinationViewModel {
        BuildDestinationViewModel(runtime: runtime, purpose: purpose)
    }
}
