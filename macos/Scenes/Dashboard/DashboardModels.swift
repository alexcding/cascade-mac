import Foundation

struct DashboardPR: Decodable, Equatable, Sendable {
    struct Author: Decodable, Equatable, Sendable { let login: String? }
    struct Tag: Decodable, Equatable, Sendable { let name: String; let color: String? }
    let number: Int?
    let title: String?
    let url: String?
    let repo: String?
    let state: String?
    let category: String?
    let awaitingMyReview: Bool?
    let isDraft: Bool?
    let reviewDecision: String?
    let headRefName: String?
    var baseRefName: String? = nil
    let author: Author?
    let createdAt: String?
    let labels: [Tag]?
    let jiraKeys: [String]?
    let ci: TrayPR.CI?
    let error: String?
}

struct DashboardProject: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let repo: String
    let prs: [DashboardPR]
    let lastSynced: String?
    let syncError: String?
}

struct DashboardRow: Identifiable, Equatable {
    let projectID: String
    let projectName: String
    let pr: DashboardPR
    let url: URL
    var id: String { "\(projectID):\(url.absoluteString)" }
    var title: String { pr.title ?? "Pull request" }
    var number: String { pr.number.map { "#\($0)" } ?? "PR" }
    var inReviewGroup: Bool { pr.awaitingMyReview ?? (pr.category == "review") }
    var isMine: Bool { pr.category == "mine" }
    var openPageRequest: OpenPageRequest {
        OpenPageRequest(url: url.absoluteString, kind: "github", title: "\(number) \(title)",
            repo: pr.repo ?? "", branch: pr.headRefName ?? "",
            category: isMine ? "mine" : inReviewGroup ? "review" : "other", login: pr.author?.login ?? "",
            projectID: projectID, jiraKeys: pr.jiraKeys ?? [])
    }
    var ciRunning: Bool { ["queued", "in_progress"].contains(pr.ci?.status ?? "") }
    var ciLabel: String {
        if ciRunning { return "CI running" }
        switch pr.ci?.conclusion {
        case "success": return "CI passed"
        case "failure": return "CI failed"
        case "cancelled": return "CI cancelled"
        default: return "No checks"
        }
    }
    var ciSymbol: String {
        if ciRunning { return "clock" }
        switch pr.ci?.conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.circle.fill"
        default: return "circle.dashed"
        }
    }
    var reviewLabel: String? {
        if pr.isDraft == true { return "Draft" }
        switch pr.reviewDecision {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        default: return nil
        }
    }
    var detail: String {
        [pr.repo ?? projectName, pr.headRefName, pr.author?.login].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var dateLabel: String? {
        pr.createdAt.flatMap(backendTimestamp)?.formatted(date: .abbreviated, time: .omitted)
    }
    // Sort keys for the dashboard table; every key is total so columns sort without optionals.
    var sortNumber: Int { pr.number ?? 0 }
    var sortRepo: String { (pr.repo ?? projectName).split(separator: "/").last.map(String.init) ?? projectName }
    var sortBranch: String { pr.headRefName ?? "" }
    var sortDate: Date { pr.createdAt.flatMap(backendTimestamp) ?? .distantPast }
    var sortJira: String { (pr.jiraKeys ?? []).joined(separator: " ") }
    /// Failing first, then running, passing, and unknown.
    var ciRank: Int {
        if ciRunning { return 1 }
        switch pr.ci?.conclusion { case "failure": return 0; case "success": return 2; default: return 3 }
    }
    var searchText: String {
        ([title, number, projectName, detail] + (pr.labels ?? []).map(\.name) + (pr.jiraKeys ?? [])).joined(separator: " ")
    }
}

struct OpenPageRequest: Encodable, Sendable {
    /// Reuses a draft tab's id; nil lets the backend mint one.
    var id: String? = nil
    let url: String
    let kind: String
    let title: String
    var repo: String = ""
    var branch: String = ""
    var category: String = ""
    var login: String = ""
    /// Open the page's session instead of a tab: the one it already has, else a new one.
    /// Routing only — the backend never sees it. `projectID` is the row's project, which scopes
    /// the session lookup for a click and its badge alike; two projects can track one repository.
    var inSession = false
    var projectID: String? = nil
    /// The Jira keys a PR references: a session started from one of those tickets is the PR's too.
    var jiraKeys: [String] = []
    /// The agent a New Session menu item chose; nil starts the default agent.
    var agent: SessionAgent? = nil

    private enum CodingKeys: String, CodingKey { case id, url, kind, title, repo, branch, category, login }

    /// A session start already says what failed; a page open needs the surface's own words.
    func failure(_ description: String, _ error: any Error) -> String {
        inSession ? error.localizedDescription : "\(description): \(error.localizedDescription)"
    }
}

/// A Jira ticket assigned to the user, as the dashboard's third section shows it.
struct DashboardTicketRow: Identifiable, Equatable {
    let ticket: JiraTicket
    let url: URL
    var id: String { ticket.key }
    var title: String { ticket.summary ?? ticket.key }
    var status: String { ticket.status ?? "" }
    var type: String { ticket.type ?? "" }
    var priority: String { ticket.priority ?? "" }
    /// The project is resolved from the key when the page opens, so none is fixed here.
    var openPageRequest: OpenPageRequest {
        OpenPageRequest(url: url.absoluteString, kind: "jira", title: "\(ticket.key) \(ticket.summary ?? "")", jiraKeys: [ticket.key])
    }
}

protocol DashboardService: Sendable {
    func snapshot() async throws -> [DashboardProject]
}

/// The dashboard's Jira section: the tickets assigned to the user across every project.
/// Separate from `DashboardService` so fixtures without Jira keep conforming.
protocol DashboardTicketService: Sendable {
    func myTickets() async throws -> [DashboardTicketRow]
}

struct APIDashboardService: DashboardService, DashboardTicketService {
    static let myTicketsJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    let api: APIClient
    func snapshot() async throws -> [DashboardProject] { try await api.get(Routes.DASHBOARD) }
    func myTickets() async throws -> [DashboardTicketRow] {
        let site: JiraSite = try await api.get(Routes.JIRA_SITE, timeout: 30)
        guard let base = URL(string: site.baseUrl) else { return [] }
        let result: JiraSnapshot = try await api.request(Routes.JIRA_SEARCH, method: "POST", body: ["jql": Self.myTicketsJQL])
        if let error = result.error, !error.isEmpty { throw DashboardTicketError.search(error) }
        return result.items.map { DashboardTicketRow(ticket: $0, url: base.appending(path: "browse").appending(path: $0.key)) }
    }
}

enum DashboardTicketError: LocalizedError {
    case search(String)
    var errorDescription: String? { switch self { case .search(let message): return message } }
}
