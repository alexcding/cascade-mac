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
    /// The ticket's own Jira labels, and who raised it. `acli` allows only a fixed set of fields
    /// on a search — key, summary, status, issuetype, priority, assignee, labels, reporter — and
    /// rejects anything else, `updated` included.
    var labels: [String]?
    var reporter: String?
    var id: String { key }
    var projectKey: String { String(key.split(separator: "-").first ?? "") }
}

/// A project's Jira project key field, which may list several keys comma-separated: the keys in it,
/// uppercased. A field of only commas, spaces or quotes names none, so it is no Jira project at all.
enum JiraKeys {
    static func parse(_ field: String?) -> [String] {
        (field ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))).uppercased() }
            .filter { !$0.isEmpty }
    }
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
