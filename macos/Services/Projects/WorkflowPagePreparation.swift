import Foundation

struct WorkflowPageTarget: Equatable, Sendable {
    let projectID: String
    let page: SessionPage
    var identity: String { projectID + ":" + Self.identity(page) }

    static func identity(_ page: SessionPage) -> String {
        if page.kind == "jira" { return "jira:" + page.key }
        let parts = URL(string: page.url)?.path.split(separator: "/") ?? []
        return "github:" + parts.prefix(4).joined(separator: "/").lowercased()
    }
    static func resolve(url: String, projects: [Project]) -> Self? {
        guard let page = SessionPage.parse(url) else { return nil }
        let matches: [Project]
        if page.kind == "jira" {
            let key = String(page.key.split(separator: "-").first ?? "")
            matches = projects.filter { $0.jiraProjectKey?.uppercased() == key }
        } else {
            let repo = URL(string: page.url)?.path.split(separator: "/").prefix(2).joined(separator: "/").lowercased() ?? ""
            matches = projects.filter { $0.repo.lowercased() == repo }
        }
        // Ambiguous project mappings require the user to choose a session.
        guard matches.count == 1, let project = matches.first else { return nil }
        return .init(projectID: project.id, page: page)
    }
    func matches(_ session: WorkspaceSession) -> Bool {
        session.projectId == projectID && SessionPage.parse(session.url).map(Self.identity) == Self.identity(page)
    }
}

protocol WorkflowPagePreparing: Sendable {
    func prepare(_ target: WorkflowPageTarget, project: Project) async throws -> WorkspaceSession
}

struct APIWorkflowPagePreparation: WorkflowPagePreparing {
    let operations: any SessionCreating
    func prepare(_ target: WorkflowPageTarget, project: Project) async throws -> WorkspaceSession {
        guard target.projectID == project.id, !project.workspace.isEmpty else {
            throw BackendError.operation("Choose a local workspace for this project before running a workflow.")
        }
        // Agent launch happens only after the durable session is handed to the
        // runner. A cancelled checkout does not mint an unused conversation ID.
        var draft = SessionDraft(); draft.agent = .shell
        draft = try await operations.resolvePage(target.page.url, project: project, draft: draft, workflow: true)
        try Task.checkCancellation()
        if draft.createBranch {
            draft.base = try await operations.references(project).defaultBranch
            guard !draft.base.isEmpty else { throw BackendError.operation("Could not determine the default branch for this workflow.") }
        }
        try Task.checkCancellation()
        // Once checkout creation begins, drain its record write even if Stop is
        // pressed. The caller then retains the session and skips agent startup.
        let captured = draft
        let creation = Task { try await operations.create(project: project, draft: captured, requireExactBranch: true) }
        return try await creation.value
    }
}
