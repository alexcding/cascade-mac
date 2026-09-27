import Foundation

enum ProjectSaveSource: Equatable { case configuration }

struct ProjectFeatureServices {
    let projects: any ProjectService
    let tickets: any JiraService
    let api: APIClient
    let baseURL: URL
    /// The GitHub issues service; nil uses the backend at `api`.
    var issues: (any IssueService)? = nil
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
        let tickets = TicketsViewModel(project: project, service: services.tickets, pageActions: pageActions)
        let issues = TicketsViewModel(project: project, provider: IssueTicketProvider(service: services.issues ?? APIIssueService(api: services.api)),
                                      pageActions: pageActions)
        return ProjectPageViewModel(project: project, editor: editor, tickets: tickets, issues: issues)
    }
}
