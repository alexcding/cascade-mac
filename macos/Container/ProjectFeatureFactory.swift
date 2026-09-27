import Foundation

enum ProjectSaveSource: Equatable { case configuration }

struct ProjectFeatureServices {
    let projects: any ProjectService
}

@MainActor protocol ProjectFeatureFactory {
    /// `agent` is the composer's first choice; `startSession` starts what the composer submits.
    func project(_ project: Project, services: ProjectFeatureServices, agent: SessionAgent,
                 startSession: @escaping (ProjectSessionRequest) async throws -> Void) -> ProjectPageViewModel
}

@MainActor struct NativeProjectFeatureFactory: ProjectFeatureFactory {
    let creation: any CreationFlowFactory

    func project(_ project: Project, services: ProjectFeatureServices, agent: SessionAgent,
                 startSession: @escaping (ProjectSessionRequest) async throws -> Void) -> ProjectPageViewModel {
        let editor = creation.projectEditor(project: project, service: services.projects)
        let composer = ProjectComposerModel(project: project, agent: agent, start: startSession)
        return ProjectPageViewModel(project: project, editor: editor, composer: composer)
    }
}
