import Foundation

struct JiraSite: Decodable, Sendable {
    let baseUrl: String
    var me: JiraAccount? = nil
}

/// The acli login. `accountId` is only known with a REST token; otherwise match by email.
struct JiraAccount: Decodable, Equatable, Sendable {
    var email: String?
    var accountId: String?
}

protocol JiraService: Sendable {
    func snapshot(projectID: String) async throws -> TicketSnapshot
    func site() async throws -> JiraSite
    func search(jql: String) async throws -> TicketSnapshot
    func transition(key: String, status: String) async throws
    func syncAfterMutation(projectID: String) async throws
    func settings() async throws -> [String: String]
    func saveFilters(_ filters: String, projectID: String) async throws
}

struct APIJiraService: JiraService {
    let api: APIClient
    func snapshot(projectID: String) async throws -> TicketSnapshot { try await api.get(Routes.projectJira(projectID)) }
    func site() async throws -> JiraSite { try await api.get(Routes.JIRA_SITE, timeout: 30) }
    func search(jql: String) async throws -> TicketSnapshot {
        try await api.request(Routes.JIRA_SEARCH, method: "POST", body: ["jql": jql])
    }
    func transition(key: String, status: String) async throws {
        let _: OperationOK = try await api.request(Routes.jiraKeyTransition(key), method: "POST", body: ["transition": status])
    }
    func syncAfterMutation(projectID: String) async throws {
        async let tickets: TicketSnapshot = api.get(APIClient.query(Routes.projectJira(projectID), ["refresh": "1"]), timeout: 130)
        async let board: BoardSnapshot = api.get(APIClient.query(Routes.projectBoard(projectID), ["refresh": "1"]), timeout: 130)
        _ = try await (tickets, board)
    }
    func settings() async throws -> [String: String] { try await api.get(Routes.SETTINGS) }
    func saveFilters(_ filters: String, projectID: String) async throws {
        try await api.setSetting(TicketSource.jira.filterSetting + projectID, value: filters)
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
