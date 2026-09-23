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

/// How long ago, in one cell's worth of text: 12m, 4h, 3d. Empty when the date is unknown,
/// so a column of a field the backend did not send reads as blank rather than as "now".
func compactAge(_ date: Date?) -> String {
    guard let date else { return "" }
    let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
    if seconds < 3_600 { return "\(max(1, seconds / 60))m" }
    if seconds < 86_400 { return "\(seconds / 3_600)h" }
    return "\(seconds / 86_400)d"
}

struct DashboardRow: Identifiable, Equatable, Sendable {
    let projectID: String
    let projectName: String
    let pr: DashboardPR
    let url: URL
    /// Worked out once, when the row is built: the views and the search read these on every render
    /// and every keystroke, and each would otherwise re-parse the date or re-join the strings.
    let created: Date?
    let detail: String
    let dateLabel: String?
    let searchText: String

    init(projectID: String, projectName: String, pr: DashboardPR, url: URL) {
        self.projectID = projectID
        self.projectName = projectName
        self.pr = pr
        self.url = url
        created = pr.createdAt.flatMap(backendTimestamp)
        detail = [pr.repo ?? projectName, pr.headRefName, pr.author?.login].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        dateLabel = created?.formatted(date: .abbreviated, time: .omitted)
        searchText = ([pr.title ?? "Pull request", pr.number.map { "#\($0)" } ?? "PR", projectName, detail]
            + (pr.labels ?? []).map(\.name) + (pr.jiraKeys ?? [])).joined(separator: " ")
    }
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
    /// The CI state the row's glyph draws; `ciLabel` is its phrasing for help and VoiceOver.
    enum Checks: Equatable { case passing, failing, running, unknown }
    var checks: Checks {
        if ciRunning { return .running }
        switch pr.ci?.conclusion {
        case "success": return .passing
        case "failure": return .failing
        default: return .unknown
        }
    }
    var author: String { pr.author?.login ?? "" }
    /// Compact age at the row's trailing edge: 12m, 4h, 3d. Relative to now, so not stored.
    var ageLabel: String { compactAge(created) }
    var reviewLabel: String? {
        if pr.isDraft == true { return "Draft" }
        switch pr.reviewDecision {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        default: return nil
        }
    }
    /// Lists run newest first; a row with no date counts as oldest, so it sorts last.
    var sortDate: Date { created ?? .distantPast }
}

struct OpenPageRequest: Encodable, Equatable, Sendable {
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
    /// Open in Tab from a row menu: always a tab, even when the page has a session, and opened
    /// behind the current screen so the list keeps focus. Sent as `standalone`, so the saved tab is
    /// never mistaken for the session's own (`SavedTab.standalone`).
    var inTab = false
    var projectID: String? = nil
    /// The Jira keys a PR references: a session started from one of those tickets is the PR's too.
    var jiraKeys: [String] = []
    /// The agent a New Session menu item chose; nil starts the default agent.
    var agent: SessionAgent? = nil

    private enum CodingKeys: String, CodingKey { case id, url, kind, title, repo, branch, category, login, inTab = "standalone" }

    /// A session start already says what failed; a page open needs the surface's own words.
    func failure(_ description: String, _ error: any Error) -> String {
        inSession ? error.localizedDescription : "\(description): \(error.localizedDescription)"
    }
}

/// A Jira ticket assigned to the user, as the home screen's Tickets section and My Tickets show it.
struct DashboardTicketRow: Identifiable, Equatable, Sendable {
    let ticket: JiraTicket
    let url: URL
    /// My Tickets' Session column sort key. A row cannot know its own session — the lookup lives on
    /// the view model — and `Table` orders only by key path, so the table fills this in before sorting.
    var sessionName = ""
    /// The number of the pull request that references this ticket, `#123`, or empty for none.
    /// Also filled by the table: the link is drawn from the dashboard's rows, not from Jira.
    var pullRequest = ""
    var id: String { ticket.key }
    var title: String { ticket.summary ?? ticket.key }
    var status: String { ticket.status ?? "" }
    var type: String { ticket.type ?? "" }
    var priority: String { ticket.priority ?? "" }
    /// Read from Jira's words once, when the row is built: sorting and filtering ask for these
    /// on every comparison, and each would otherwise redo the string matching.
    let stage: TicketStage
    let level: TicketPriority
    /// The labels as one string, the table's sort key for that column.
    let sortLabels: String
    /// What the dashboard's search reads: the key, words and people a ticket is known by.
    let searchText: String

    init(ticket: JiraTicket, url: URL) {
        self.ticket = ticket
        self.url = url
        stage = TicketStage(status: ticket.status ?? "", category: ticket.statusCategory)
        level = TicketPriority(ticket.priority ?? "")
        let labels = ticket.labels ?? []
        sortLabels = labels.joined(separator: " ")
        searchText = ([ticket.key, ticket.summary ?? ticket.key, ticket.status, ticket.type, ticket.priority, ticket.reporter]
            .compactMap { $0 } + labels).joined(separator: " ")
    }
    /// One list of Jira's priority names decides both the Urgent tag and the row's urgent glyph.
    var urgent: Bool { level == .urgent }
    /// Where the ticket falls in the home screen's short list, or nil to leave it to My Tickets:
    /// blocked, then reopened, then being worked on, then urgent work not yet started. The stage
    /// comes from Jira's status category, so no workflow's status names are listed here.
    var attentionRank: Int? {
        if stage == .blocked { return 0 }
        if status.localizedCaseInsensitiveContains("reopen") { return 1 }
        if stage == .inProgress { return 2 }
        if stage == .toDo && urgent { return 3 }
        return nil
    }
    /// The key's project prefix — the Project column, which earns its place only once the
    /// dashboard tracks more than one Jira project, so it opens hidden.
    var project: String { ticket.projectKey }
    var labels: [String] { ticket.labels ?? [] }
    var reporter: String { ticket.reporter ?? "" }
    /// The project is resolved from the key when the page opens, so none is fixed here.
    var openPageRequest: OpenPageRequest {
        OpenPageRequest(url: url.absoluteString, kind: "jira", title: "\(ticket.key) \(ticket.summary ?? "")", jiraKeys: [ticket.key])
    }
}

/// Where a ticket sits in its workflow, read from Jira's status name first and its category second:
/// a Jira board names "Ready for Development" as in progress, but nobody has started it yet.
enum TicketStage: String, CaseIterable, Identifiable, Sendable {
    case toDo, inProgress, pendingRelease, blocked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toDo: return "To do"
        case .inProgress: return "In progress"
        case .pendingRelease: return "Pending release"
        case .blocked: return "Blocked"
        }
    }

    init(status: String, category: String?) {
        let status = status.lowercased()
        if status.contains("block") { self = .blocked }
        else if status.contains("release") || status.contains("done") || status.contains("resolved") || category == "done" { self = .pendingRelease }
        else if status.contains("reopen") { self = .inProgress }
        else if category == "new" || status.hasPrefix("ready for") || ["open", "to do", "backlog", "selected for development"].contains(status) { self = .toDo }
        else { self = .inProgress }
    }
}

/// Jira's priority names folded onto four levels, most pressing first; anything unrecognised
/// (or no priority at all) reads as Medium, Jira's own default. Each level draws Jira's own
/// arrow shape as well as its colour, so none depends on colour alone.
enum TicketPriority: String, CaseIterable, Identifiable, Sendable {
    case urgent, high, medium, low
    var id: String { rawValue }
    var title: String {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
    var symbol: String {
        switch self {
        case .urgent: return "chevron.up.2"
        case .high: return "chevron.up"
        case .medium: return "equal"
        case .low: return "chevron.down"
        }
    }

    init(_ name: String) {
        switch name.lowercased() {
        case "urgent", "highest", "blocker", "critical": self = .urgent
        case "high", "major": self = .high
        case "low", "lowest", "minor", "trivial": self = .low
        default: self = .medium
        }
    }
}

protocol DashboardService: Sendable {
    func snapshot() async throws -> [DashboardProject]
    func syncPRs() async throws
}

extension DashboardService {
    func syncPRs() async throws {}
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
    func syncPRs() async throws {
        let _: OperationOK = try await api.request(APIClient.query(Routes.POLL, ["scope": "prs"]), method: "POST", body: [String: String]())
    }
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
