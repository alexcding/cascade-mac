import Foundation

enum ProjectSaveSource: Equatable { case configuration }

struct ProjectFeatureServices {
    let projects: any ProjectService
    let sessions: any SessionCreating
    var boards: (any BoardService)? = nil
}

@MainActor protocol ProjectFeatureFactory {
    /// `agent` is Start's first choice of agent; `pageActions` opens the board's cards.
    func project(_ project: Project, services: ProjectFeatureServices, agent: SessionAgent,
                 pageActions: any PageActionServing) -> ProjectPageViewModel
}

@MainActor struct NativeProjectFeatureFactory: ProjectFeatureFactory {
    let creation: any CreationFlowFactory

    func project(_ project: Project, services: ProjectFeatureServices, agent: SessionAgent,
                 pageActions: any PageActionServing) -> ProjectPageViewModel {
        let editor = creation.projectEditor(project: project, service: services.projects)
        let composer = ProjectComposerModel(project: project, agent: agent, operations: services.sessions)
        let model = ProjectPageViewModel(project: project, editor: editor, composer: composer, pageActions: pageActions)
        model.connectBoard(services.boards)
        return model
    }
}
