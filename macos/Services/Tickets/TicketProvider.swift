import Foundation

/// One ticket source, as the Tickets list uses it. The list is the same for every source; this
/// is where they differ: how a typed search becomes a query, which statuses a ticket can move to,
/// and where its page is.
protocol TicketProvider: Sendable {
    var source: TicketSource { get }
    func snapshot(projectID: String) async throws -> TicketSnapshot
    func search(_ typed: String, project: Project) async throws -> TicketSnapshot
    func move(_ ticket: Ticket, to status: String) async throws
    func syncAfterMutation(projectID: String) async throws
    /// The site a ticket key is browsed on; nil for a source whose tickets carry their own URL.
    func siteURL() async throws -> URL?
    func settings() async throws -> [String: String]
    func saveFilters(_ filters: String, projectID: String) async throws
}

extension TicketSource {
    /// The statuses `ticket` can move to. Jira's workflow is not fetched, so it offers the
    /// statuses seen on loaded tickets; an issue is open, closed, or closed as not planned.
    func nextStatuses(_ ticket: Ticket, seen: Set<String>) -> [String] {
        switch self {
        case .jira: seen.filter { !$0.isEmpty && $0 != ticket.status }.sorted()
        case .github: IssueStatus.all.filter { $0 != ticket.status }
        }
    }

    /// The ticket's page: a key on the Jira site, or the GitHub issue's own URL. Anything that
    /// does not look like one of those opens nothing.
    func pageURL(_ ticket: Ticket, site: URL?) -> URL? {
        switch self {
        case .jira:
            guard ticket.key.range(of: #"^[A-Z][A-Z0-9_]*-\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            return site?.appendingPathComponent("browse").appendingPathComponent(ticket.key)
        case .github:
            guard let raw = ticket.url, let url = safeWebURL(raw), SessionPage.parse(url.absoluteString)?.kind == "issue" else { return nil }
            return url
        }
    }
}

struct JiraTicketProvider: TicketProvider {
    let service: any JiraService
    var source: TicketSource { .jira }
    func snapshot(projectID: String) async throws -> TicketSnapshot { try await service.snapshot(projectID: projectID) }
    func search(_ typed: String, project: Project) async throws -> TicketSnapshot {
        try await service.search(jql: JiraQuery.make(typed, projectKey: project.jiraProjectKey ?? ""))
    }
    func move(_ ticket: Ticket, to status: String) async throws { try await service.transition(key: ticket.key, status: status) }
    func syncAfterMutation(projectID: String) async throws { try await service.syncAfterMutation(projectID: projectID) }
    func siteURL() async throws -> URL? { safeWebURL(try await service.site().baseUrl) }
    func settings() async throws -> [String: String] { try await service.settings() }
    func saveFilters(_ filters: String, projectID: String) async throws { try await service.saveFilters(filters, projectID: projectID) }
}

protocol IssueService: Sendable {
    func snapshot(projectID: String) async throws -> TicketSnapshot
    /// A live search over `repos`; `#12` or `12` looks that issue up.
    func search(_ query: String, repos: [String]) async throws -> TicketSnapshot
    /// A live search over every project repo that lists its issues, which the backend knows.
    func searchAllProjects(_ query: String) async throws -> TicketSnapshot
    func setStatus(repo: String, number: Int, status: String) async throws
    func syncAfterMutation(projectID: String) async throws
    func lookup(url: String) async throws -> Ticket?
    func settings() async throws -> [String: String]
    func saveFilters(_ filters: String, projectID: String) async throws
}

struct APIIssueService: IssueService {
    let api: APIClient
    func snapshot(projectID: String) async throws -> TicketSnapshot { try await api.get(Routes.projectIssues(projectID)) }
    func search(_ query: String, repos: [String]) async throws -> TicketSnapshot {
        struct Body: Encodable, Sendable { let query: String; let repos: [String] }
        return try await api.request(Routes.ISSUES_SEARCH, method: "POST", body: Body(query: query, repos: repos), timeout: 60)
    }
    func searchAllProjects(_ query: String) async throws -> TicketSnapshot {
        struct Body: Encodable, Sendable { let query: String; let allProjects = true }
        return try await api.request(Routes.ISSUES_SEARCH, method: "POST", body: Body(query: query), timeout: 60)
    }
    func setStatus(repo: String, number: Int, status: String) async throws {
        let _: OperationOK = try await api.request(Routes.issueNumberStatus(number), method: "POST", body: ["repo": repo, "status": status])
    }
    func syncAfterMutation(projectID: String) async throws {
        let _: TicketSnapshot = try await api.get(APIClient.query(Routes.projectIssues(projectID), ["refresh": "1"]), timeout: 130)
    }
    func lookup(url: String) async throws -> Ticket? {
        try await api.get(APIClient.query(Routes.ISSUE_LOOKUP, ["url": url]), timeout: 30)
    }
    func settings() async throws -> [String: String] { try await api.get(Routes.SETTINGS) }
    func saveFilters(_ filters: String, projectID: String) async throws {
        try await api.setSetting(TicketSource.github.filterSetting + projectID, value: filters)
    }
}

struct IssueTicketProvider: TicketProvider {
    let service: any IssueService
    var source: TicketSource { .github }
    func snapshot(projectID: String) async throws -> TicketSnapshot { try await service.snapshot(projectID: projectID) }
    func search(_ typed: String, project: Project) async throws -> TicketSnapshot {
        try await service.search(typed, repos: [project.repo])
    }
    func move(_ ticket: Ticket, to status: String) async throws {
        guard let repo = ticket.repo, let number = ticket.number else {
            throw BackendError.operation(String(localized: "This issue has no repository or number."))
        }
        try await service.setStatus(repo: repo, number: number, status: status)
    }
    func syncAfterMutation(projectID: String) async throws { try await service.syncAfterMutation(projectID: projectID) }
    func siteURL() async throws -> URL? { nil }
    func settings() async throws -> [String: String] { try await service.settings() }
    func saveFilters(_ filters: String, projectID: String) async throws { try await service.saveFilters(filters, projectID: projectID) }
}
