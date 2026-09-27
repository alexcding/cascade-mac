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
    var worktreeSetup = ""
    var worktreeInclude = ""
    var forwardWebhooks = true

    init(_ project: Project? = nil) {
        guard let project else { return }
        name = project.name; workspace = project.workspace; repo = project.repo
        jiraProjectKey = project.jiraProjectKey ?? ""; jql = project.jql ?? ""
        ide = project.ide ?? ""; ideCmd = project.ideCmd ?? ""; ideTarget = project.ideTarget ?? ""
        worktreeSetup = project.worktreeSetup ?? ""; worktreeInclude = project.worktreeInclude ?? ""
        forwardWebhooks = project.forwardWebhooks ?? true
    }
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Enter a project name.") }
        if !workspace.isEmpty && !workspace.hasPrefix("/") { return String(localized: "Choose an absolute workspace folder path.") }
        if ideTarget.hasPrefix("/") || ideTarget.split(separator: "/").contains("..") { return String(localized: "The IDE target must be a relative path inside the workspace.") }
        return nil
    }
}

protocol ProjectService: Sendable {
    func load(_ id: String) async throws -> Project
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project
    func delete(_ id: String) async throws
    func detectRepository(_ path: String) async throws -> String
    /// What git records for `rel` in `workspace`, which is what a new worktree checks out.
    func trackedFile(workspace: String, rel: String) async throws -> TrackedFile?
    /// The checkout's GitHub repo and a best guess at its IDE ("" when there is no guess).
    func detect(_ path: String) async throws -> DetectedWorkspace
}

struct DetectedWorkspace: Decodable, Equatable, Sendable {
    let repo: String
    let ide: String
}

struct TrackedFile: Decodable, Equatable, Sendable {
    let tracked: Bool
    let executable: Bool
}

extension ProjectService {
    /// Unknown by default: the setup script pick then goes by the file as it is on disk.
    func trackedFile(workspace: String, rel: String) async throws -> TrackedFile? { nil }
    /// No IDE guess by default: only the repo.
    func detect(_ path: String) async throws -> DetectedWorkspace {
        DetectedWorkspace(repo: try await detectRepository(path), ide: "")
    }
}

struct APIProjectService: ProjectService {
    let api: APIClient
    func load(_ id: String) async throws -> Project { try await api.get(Routes.project(id)) }
    func trackedFile(workspace: String, rel: String) async throws -> TrackedFile? {
        try await api.get(APIClient.query(Routes.GIT_TRACKED, ["path": workspace, "rel": rel]))
    }
    func save(_ draft: ProjectDraft, id: String?) async throws -> Project {
        try await api.request(id.map(Routes.project) ?? Routes.PROJECTS, method: id == nil ? "POST" : "PUT", body: draft)
    }
    func delete(_ id: String) async throws {
        let _: OperationOK = try await api.request(Routes.project(id), method: "DELETE", body: [String: String]())
    }
    func detectRepository(_ path: String) async throws -> String { try await detect(path).repo }
    func detect(_ path: String) async throws -> DetectedWorkspace {
        try await api.get(APIClient.query(Routes.DETECT_REPO, ["path": path]), timeout: 30)
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
    /// Editors a project can still open in but the picker no longer offers: the AI editors.
    /// A project already set to one keeps it and shows it.
    static let retired: Set<String> = ["cursor", "windsurf"]
    static let all: [Self] = [.init(id: "", title: String(localized: "None"))]
        + ExternalTool.editors.filter { !retired.contains($0.id) }.map { .init(id: $0.id, title: $0.name) }
        + [.init(id: "custom", title: String(localized: "Custom"))]
    /// The picker's choices, plus the project's current IDE when the picker no longer offers it.
    static func choices(keeping current: String) -> [Self] {
        guard !all.contains(where: { $0.id == current }) else { return all }
        let title = ExternalTool.editors.first { $0.id == current }?.name ?? current
        return all + [.init(id: current, title: title)]
    }
}
