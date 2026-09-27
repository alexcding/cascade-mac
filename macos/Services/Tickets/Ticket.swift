import Foundation

/// Where a ticket comes from. Both sources arrive in the one `Ticket` shape the backend maps them
/// onto; what differs — its name and the kind of page it opens as — is answered here, never by a view.
enum TicketSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case jira, github
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jira: String(localized: "Jira")
        case .github: String(localized: "GitHub Issues")
        }
    }
    /// The page kind a ticket's tab and session are recorded under.
    var pageKind: String {
        switch self {
        case .jira: "jira"
        case .github: "issue"
        }
    }
}

struct Ticket: Identifiable, Equatable, Sendable {
    /// `ABC-12` for Jira, `#12` for a GitHub issue.
    let key: String
    var summary: String?
    var status: String?
    var type: String?
    var priority: String?
    var assignee: String?
    var assigneeId: String?
    var statusId: String?
    /// Jira's status category keys — `new`, `indeterminate`, `done` — for both sources.
    var statusCategory: String?
    var assigneeEmail: String?
    /// The ticket's own labels, and who raised it. `acli` allows only a fixed set of fields
    /// on a search — key, summary, status, issuetype, priority, assignee, labels, reporter — and
    /// rejects anything else, `updated` included.
    var labels: [String]?
    var reporter: String?
    var source: TicketSource = .jira
    /// A GitHub issue's number, repository and page; nil for Jira, whose page is on its site.
    var number: Int? = nil
    var repo: String? = nil
    var url: String? = nil
    var updated: String? = nil
    /// Whether the backend found the user among an issue's assignees. Nil for Jira, whose My
    /// Tickets search only returns the user's own tickets.
    var mine: Bool? = nil
    /// The user's: every Jira ticket My Tickets returns, and an issue the backend marked `mine`.
    var isMine: Bool { source == .jira || mine == true }
    /// Unique across sources and repos: two repos both have a `#12`.
    var id: String { source == .github ? "\(repo ?? "")\(key)" : key }
    /// The Jira project a key belongs to, or the repository an issue is in.
    var projectKey: String { source == .github ? repo ?? "" : String(key.split(separator: "-").first ?? "") }
    /// The key sessions and pull requests record a ticket under: a Jira key, or `owner/repo#12`.
    var sessionKey: String { source == .github ? "\(repo ?? "")#\(number ?? 0)" : key }
}

// In an extension so the memberwise initializer stays: a missing `source` is a Jira ticket, as
// every ticket was before GitHub issues.
extension Ticket: Decodable {
    private enum CodingKeys: String, CodingKey {
        case key, summary, status, type, priority, assignee, assigneeId, statusId, statusCategory, assigneeEmail
        case labels, reporter, source, number, repo, url, updated, mine
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        priority = try values.decodeIfPresent(String.self, forKey: .priority)
        assignee = try values.decodeIfPresent(String.self, forKey: .assignee)
        assigneeId = try values.decodeIfPresent(String.self, forKey: .assigneeId)
        statusId = try values.decodeIfPresent(String.self, forKey: .statusId)
        statusCategory = try values.decodeIfPresent(String.self, forKey: .statusCategory)
        assigneeEmail = try values.decodeIfPresent(String.self, forKey: .assigneeEmail)
        labels = try values.decodeIfPresent([String].self, forKey: .labels)
        reporter = try values.decodeIfPresent(String.self, forKey: .reporter)
        source = (try? values.decodeIfPresent(TicketSource.self, forKey: .source)) ?? .jira
        number = try values.decodeIfPresent(Int.self, forKey: .number)
        repo = try values.decodeIfPresent(String.self, forKey: .repo)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        updated = try values.decodeIfPresent(String.self, forKey: .updated)
        mine = try values.decodeIfPresent(Bool.self, forKey: .mine)
    }
}

struct TicketSnapshot: Decodable, Sendable {
    var items: [Ticket]
    /// The query the snapshot ran: JQL for Jira, a GitHub search for issues.
    var jql: String?
    var lastSynced: String?
    var error: String?
    /// Something the search could not settle, beside the items it did return: for issues, that
    /// the GitHub login was unknown, so none could be marked the user's.
    var warning: String? = nil
}
