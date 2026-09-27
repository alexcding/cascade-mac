import Foundation

enum ProjectSaveSource: Equatable { case configuration }

struct ProjectFeatureServices {
    let projects: any ProjectService
    let sessions: any SessionCreating
}

@MainActor protocol ProjectFeatureFactory {
    /// `agent` is Start's first choice of agent.
    func project(_ project: Project, services: ProjectFeatureServices, agent: SessionAgent) -> ProjectPageViewModel
}

@MainActor struct NativeProjectFeatureFactory: ProjectFeatureFactory {
    let creation: any CreationFlowFactory

    func project(_ project: Project, services: ProjectFeatureServices, agent: SessionAgent) -> ProjectPageViewModel {
        let editor = creation.projectEditor(project: project, service: services.projects)
        let composer = ProjectComposerModel(project: project, agent: agent, operations: services.sessions)
        composer.connect(services.sessions)
        return ProjectPageViewModel(project: project, editor: editor, composer: composer)
    }
}
