import Foundation

enum ProjectSaveSource: Equatable { case configuration, workflows, automation }

struct ProjectFeatureServices {
    let projects: any ProjectService
    let tickets: any JiraService
    let workflows: any WorkflowService
    let automation: any AutomationService
    let api: APIClient
    let baseURL: URL
}

@MainActor protocol ProjectFeatureFactory {
    func project(_ project: Project, services: ProjectFeatureServices,
                 openPage: @escaping (OpenPageRequest) async throws -> Void,
                 session: @escaping (OpenPageRequest) -> PageSessionMark?) -> ProjectPageViewModel
}

extension ProjectFeatureFactory {
    func project(_ project: Project, services: ProjectFeatureServices,
                 openPage: @escaping (OpenPageRequest) async throws -> Void) -> ProjectPageViewModel {
        self.project(project, services: services, openPage: openPage, session: { _ in nil })
    }
}

@MainActor struct NativeProjectFeatureFactory: ProjectFeatureFactory {
    let creation: any CreationFlowFactory

    func project(_ project: Project, services: ProjectFeatureServices,
                 openPage: @escaping (OpenPageRequest) async throws -> Void,
                 session: @escaping (OpenPageRequest) -> PageSessionMark?) -> ProjectPageViewModel {
        let editor = creation.projectEditor(project: project, service: services.projects)
        let pageActions = NativePageActionService(open: openPage, session: session)
        let board = WebBoardViewModel(projectID: project.id, api: services.api, pageActions: pageActions)
        let tickets = JiraTicketsViewModel(project: project, service: services.tickets, pageActions: pageActions)
        let workflows = WorkflowEditorViewModel(project: project, service: services.workflows)
        let automation = AutomationViewModel(project: project, service: services.automation)
        return ProjectPageViewModel(project: project, service: services.projects, editor: editor, board: board,
                                    tickets: tickets, workflows: workflows, automation: automation,
                                    pageActions: pageActions)
    }
}
