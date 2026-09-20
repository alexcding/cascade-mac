import Foundation

struct JiraTicket: Decodable, Identifiable, Equatable, Sendable {
    let key: String
    var summary: String?
    var status: String?
    var type: String?
    var priority: String?
    var assignee: String?
    var assigneeId: String?
    var statusId: String?
    var statusCategory: String?
    var assigneeEmail: String?
    var id: String { key }
    var projectKey: String { String(key.split(separator: "-").first ?? "") }
}

struct JiraSnapshot: Decodable, Sendable {
    var items: [JiraTicket]
    var jql: String?
    var lastSynced: String?
    var error: String?
}

struct JiraSite: Decodable, Sendable {
    let baseUrl: String
    var me: JiraAccount? = nil
}

/// The acli login. `accountId` is only known with a REST token; otherwise match by email.
struct JiraAccount: Decodable, Equatable, Sendable {
    var email: String?
    var accountId: String?
}

enum JiraFacet: String, CaseIterable, Identifiable {
    case project, status, type, priority
    var id: String { rawValue }
    var label: String {
        switch self { case .project: "Projects"; case .status: "Statuses"; case .type: "Types"; case .priority: "Priorities" }
    }
    func value(_ ticket: JiraTicket) -> String {
        switch self {
        case .project: ticket.projectKey
        case .status: ticket.status ?? ""
        case .type: ticket.type ?? ""
        case .priority: ticket.priority ?? ""
        }
    }
}

protocol JiraService: Sendable {
    func snapshot(projectID: String) async throws -> JiraSnapshot
    func site() async throws -> JiraSite
    func search(jql: String) async throws -> JiraSnapshot
    func transition(key: String, status: String) async throws
    func syncAfterMutation() async throws
    func settings() async throws -> [String: String]
    func saveFilters(_ filters: String, projectID: String) async throws
}

struct APIJiraService: JiraService {
    let api: APIClient
    func snapshot(projectID: String) async throws -> JiraSnapshot { try await api.get(Routes.projectJira(projectID)) }
    func site() async throws -> JiraSite { try await api.get(Routes.JIRA_SITE, timeout: 30) }
    func search(jql: String) async throws -> JiraSnapshot {
        try await api.request(Routes.JIRA_SEARCH, method: "POST", body: ["jql": jql])
    }
    func transition(key: String, status: String) async throws {
        let _: OperationOK = try await api.request(Routes.jiraKeyTransition(key), method: "POST", body: ["transition": status])
    }
    func syncAfterMutation() async throws {
        let _: OperationOK = try await api.request(Routes.POLL, method: "POST", body: [String: String]())
    }
    func settings() async throws -> [String: String] { try await api.get(Routes.SETTINGS) }
    func saveFilters(_ filters: String, projectID: String) async throws {
        try await api.setSetting("ticket_filter_" + projectID, value: filters)
    }
}

// Keyword/key/JQL interpretation is owned here now; the shared jql.mjs it was written
// against went with the node backend.
enum JiraQuery {
    static func looksLikeJQL(_ text: String) -> Bool {
        if text.range(of: #"[=~<>!]|(?:^|\s)order\s+by\s"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return text.range(of: #"(?:^|\s|\()[\w.\"'\[\]]+\s+(?:not\s+)?(?:in|is|was|changed)\s+(?:\(|not\s|empty\b|null\b|\"|'|\w+\(|-?\d)"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func make(_ input: String, projectKey: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.range(of: #"^[A-Z][A-Z0-9_]+-\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "key = \(text.uppercased())"
        }
        if looksLikeJQL(text) { return text }
        let words = text.replacingOccurrences(of: #"[\"\\]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (projectKey.isEmpty ? "" : "project = \(projectKey) AND ") + "text ~ \"\(words)\" ORDER BY updated DESC"
    }
}
