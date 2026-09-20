import Foundation

struct ProjectDraft: Encodable, Equatable, Sendable {
    var name = ""
    var workspace = ""
    var repo = ""
    var jiraProjectKey = ""
    var jql = ""
    var ide = ""
    var ideCmd = ""
    var ideTarget = ""

    init(_ project: Project? = nil) {
        guard let project else { return }
        name = project.name; workspace = project.workspace; repo = project.repo
        jiraProjectKey = project.jiraProjectKey ?? ""; jql = project.jql ?? ""
        ide = project.ide ?? ""; ideCmd = project.ideCmd ?? ""; ideTarget = project.ideTarget ?? ""
    }
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a project name." }
        if !workspace.isEmpty && !workspace.hasPrefix("/") { return "Choose an absolute workspace folder path." }
        if ideTarget.hasPrefix("/") || ideTarget.split(separator: "/").contains("..") { return "The IDE target must be a relative path inside the workspace." }
        return nil
    }
}

struct ProjectPRSnapshot: Decodable, Sendable {
    var prs: [DashboardPR] = []
    var lastSynced: String? = nil
    var error: String? = nil
    var refreshing = false
}

extension ProjectPRSnapshot {
    private enum CodingKeys: String, CodingKey { case prs, lastSynced, error, refreshing }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        prs = try values.decode([DashboardPR].self, forKey: .prs)
        lastSynced = try values.decodeIfPresent(String.self, forKey: .lastSynced)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        // Older Rust backends return the stored snapshot without live refresh
        // metadata. Keep those cards readable while the helper is upgraded.
        refreshing = try values.decodeIfPresent(Bool.self, forKey: .refreshing) ?? false
    }
}

protocol ProjectService: Sendable {
    func load(_ id: String) async throws -> Project
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project
    func delete(_ id: String) async throws
    func detectRepository(_ path: String) async throws -> String
    func pullRequests(_ id: String, state: String, force: Bool) async throws -> ProjectPRSnapshot
}

struct APIProjectService: ProjectService {
    let api: APIClient
    func load(_ id: String) async throws -> Project { try await api.get(Routes.project(id)) }
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project {
        try await api.request(id.map(Routes.project) ?? Routes.PROJECTS, method: id == nil ? "POST" : "PUT", body: draft)
    }
    func delete(_ id: String) async throws {
        let _: OperationOK = try await api.request(Routes.project(id), method: "DELETE", body: [String: String]())
    }
    func detectRepository(_ path: String) async throws -> String {
        struct Result: Decodable, Sendable { let repo: String }
        let result: Result = try await api.get(APIClient.query(Routes.DETECT_REPO, ["path": path]), timeout: 30)
        return result.repo
    }
    func pullRequests(_ id: String, state: String, force: Bool) async throws -> ProjectPRSnapshot {
        try await api.get(APIClient.query(Routes.projectPrs(id), ["state": state, "snapshot": "1", "refresh": force ? "1" : "0"]))
    }
}

enum ProjectSection: String, CaseIterable, Identifiable {
    case prs = "Pull Requests", tickets = "Tickets", board = "Sprint Board", workflows = "Workflows", automation = "Automation", settings = "Settings"
    var id: String { rawValue }

    /// The sections a project can show. Pull Requests and Automation (webhook
    /// forwarding) need GitHub, Tickets and Sprint Board need Jira. Workflows and
    /// Settings always apply. Automation's Jira merge actions hide on their own.
    static func available(for project: Project) -> [ProjectSection] {
        allCases.filter { section in
            switch section {
            case .prs, .automation: project.hasGitHub
            case .tickets, .board: project.hasJira
            case .workflows, .settings: true
            }
        }
    }
}

extension Project {
    var hasGitHub: Bool { !repo.isEmpty }
    /// A Jira project key or a saved JQL query.
    var hasJira: Bool { !(jiraProjectKey ?? "").isEmpty || !(jql ?? "").isEmpty }
}

struct IDEChoice: Identifiable {
    let id: String
    let title: String
    static let all: [Self] = [.init(id: "", title: "None")]
        + ExternalTool.editors.map { .init(id: $0.id, title: $0.name) }
        + [.init(id: "custom", title: "Custom")]
}
