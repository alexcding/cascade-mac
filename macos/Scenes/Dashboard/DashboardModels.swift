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
    /// The GitHub issues the PR closes when it merges, as `owner/repo#12`.
    var issueKeys: [String]? = nil
    /// Every ticket the PR stands for: its Jira keys and the issues it closes.
    var ticketKeys: [String] { (jiraKeys ?? []) + (issueKeys ?? []) }
    /// The same tickets as a row's chips show them: a Jira key as it is, an issue in the PR's own
    /// repo as `#12`, and one elsewhere as `repo#12`.
    var ticketLabels: [String] {
        let own = (repo ?? "").lowercased()
        return (jiraKeys ?? []) + (issueKeys ?? []).map { key in
            guard let hash = key.lastIndex(of: "#") else { return key }
            let issueRepo = String(key[..<hash])
            return issueRepo == own ? String(key[hash...]) : "\(issueRepo.split(separator: "/").last ?? "")\(key[hash...])"
        }
    }
}

struct DashboardProject: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let repo: String
    let prs: [DashboardPR]
    let lastSynced: String?
    let syncError: String?
    var jiraProjectKey: String? = nil
    var issuesEnabled: Bool? = nil

    /// A Jira project key, which is what My Tickets matches Jira tickets by.
    var hasJira: Bool { !jiraKeys.isEmpty }
    /// The Jira project keys this project's tickets carry (`JiraKeys`).
    var jiraKeys: [String] { JiraKeys.parse(jiraProjectKey) }
    /// A repo whose GitHub issues appear in My Tickets.
    var hasIssues: Bool { !repo.isEmpty && issuesEnabled != false }
    /// Whether My Tickets can narrow to this project: its Jira keys or its repo claim tickets.
    var claimsTickets: Bool { hasJira || hasIssues }

    /// Whether `ticket` is this project's: a Jira key under one of its keys, or an issue in its repo.
    func owns(_ ticket: Ticket) -> Bool {
        switch ticket.source {
        case .jira: owns(ticket: ticket.key)
        case .github: hasIssues && (ticket.repo ?? "").lowercased() == repo.lowercased()
        }
    }

    /// Whether `key`, a Jira issue key such as `APP-12`, belongs to one of this project's Jira keys.
    func owns(ticket key: String) -> Bool {
        guard let prefix = key.split(separator: "-").first?.uppercased() else { return false }
        return jiraKeys.contains(prefix)
    }
}

/// How long ago, in one cell's worth of text: 12m, 4h, 3d. Empty when the date is unknown,
/// so a column of a field the backend did not send reads as blank rather than as "now".
func compactAge(_ date: Date?) -> String {
    guard let date else { return "" }
    let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
    if seconds < 3_600 { return String(localized: "\(max(1, seconds / 60))m") }
    if seconds < 86_400 { return String(localized: "\(seconds / 3_600)h") }
    return String(localized: "\(seconds / 86_400)d")
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
        searchText = ([pr.title ?? String(localized: "Pull request"), pr.number.map { "#\($0)" } ?? "PR", projectName, detail]
            + (pr.labels ?? []).map(\.name) + (pr.jiraKeys ?? [])).joined(separator: " ")
    }
    var id: String { "\(projectID):\(url.absoluteString)" }
    var title: String { pr.title ?? String(localized: "Pull request") }
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
        if ciRunning { return String(localized: "CI running") }
        switch pr.ci?.conclusion {
        case "success": return String(localized: "CI passed")
        case "failure": return String(localized: "CI failed")
        case "cancelled": return String(localized: "CI cancelled")
        default: return String(localized: "No checks")
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
        if pr.isDraft == true { return String(localized: "Draft") }
        switch pr.reviewDecision {
        case "APPROVED": return String(localized: "Approved")
        case "CHANGES_REQUESTED": return String(localized: "Changes requested")
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

/// A Jira ticket or GitHub issue assigned to the user, as the home screen's Tickets section and My Tickets show it.
struct DashboardTicketRow: Identifiable, Equatable, Sendable {
    let ticket: Ticket
    let url: URL
    /// My Tickets' Session column sort key. A row cannot know its own session — the lookup lives on
    /// the view model — and `Table` orders only by key path, so the table fills this in before sorting.
    var sessionName = ""
    /// The number of the pull request that references this ticket, `#123`, or empty for none.
    /// Also filled by the table: the link is drawn from the dashboard's rows, not from Jira.
    var pullRequest = ""
    var id: String { ticket.id }
    /// The key pull requests link this ticket by: the Jira key, or `owner/repo#12`.
    var linkKey: String { ticket.sessionKey.uppercased() }
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

    init(ticket: Ticket, url: URL) {
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
    /// The key's project prefix, or an issue's repository — the Project column, which earns its
    /// place only once the dashboard tracks more than one project, so it opens hidden.
    var project: String { ticket.projectKey }
    var labels: [String] { ticket.labels ?? [] }
    var reporter: String { ticket.reporter ?? "" }
    /// The project is resolved from the key or repo when the page opens, so none is fixed here.
    var openPageRequest: OpenPageRequest {
        OpenPageRequest(url: url.absoluteString, kind: ticket.source.pageKind, title: "\(ticket.key) \(ticket.summary ?? "")",
                        repo: ticket.repo ?? "", jiraKeys: [ticket.sessionKey])
    }
}

/// Where a ticket sits in its workflow, read from Jira's status name first and its category second:
/// a Jira board names "Ready for Development" as in progress, but nobody has started it yet.
enum TicketStage: String, CaseIterable, Identifiable, Sendable {
    case toDo, inProgress, pendingRelease, blocked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toDo: return String(localized: "To do")
        case .inProgress: return String(localized: "In progress")
        case .pendingRelease: return String(localized: "Pending release")
        case .blocked: return String(localized: "Blocked")
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
        case .urgent: return String(localized: "Urgent")
        case .high: return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low: return String(localized: "Low")
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

/// The dashboard's Tickets section: the Jira tickets and GitHub issues assigned to the user across
/// every project. Separate from `DashboardService` so fixtures without tickets keep conforming.
protocol DashboardTicketService: Sendable {
    func myTickets() async throws -> [DashboardTicketRow]
    /// The tickets, and what one source could not load while another did. Throws only when
    /// every source failed.
    func myTicketsReport() async throws -> (rows: [DashboardTicketRow], warning: String?)
}

extension DashboardTicketService {
    func myTicketsReport() async throws -> (rows: [DashboardTicketRow], warning: String?) { (try await myTickets(), nil) }
}

struct APIDashboardService: DashboardService, DashboardTicketService {
    static let myTicketsJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    let api: APIClient
    func snapshot() async throws -> [DashboardProject] { try await api.get(Routes.DASHBOARD) }
    func syncPRs() async throws {
        let _: OperationOK = try await api.request(APIClient.query(Routes.POLL, ["scope": "prs"]), method: "POST", body: [String: String]())
    }
    /// My Tickets' issues in two searches, so the user's own are never crowded out: every open
    /// issue assigned to them, and the most recently touched of everyone else's, capped.
    static let myIssuesQuery = "is:open assignee:@me sort:updated-desc"
    static let othersIssuesQuery = "is:open -assignee:@me sort:updated-desc"
    static let othersIssuesLimit = 100
    func myTickets() async throws -> [DashboardTicketRow] { try await myTicketsReport().rows }
    /// One search's rows, and what it had to say beside them.
    private struct Found: Sendable {
        var rows: [DashboardTicketRow]
        var note: String? = nil
    }
    /// Jira, the user's issues and everyone else's, at once and apart: any one failing leaves the
    /// others' rows, with its error in the warning, so the user's own never vanish with the rest.
    func myTicketsReport() async throws -> (rows: [DashboardTicketRow], warning: String?) {
        async let jira = Self.attempt { Found(rows: try await myJiraTickets()) }
        async let mine = Self.attempt { try await issues(Self.myIssuesQuery, limit: 200) }
        async let others = Self.attempt { try await issues(Self.othersIssuesQuery, limit: Self.othersIssuesLimit) }
        let results = [(TicketSource.jira.label, await jira),
                       (String(localized: "Your GitHub issues"), await mine),
                       (String(localized: "Other GitHub issues"), await others)]
        var rows: [DashboardTicketRow] = [], notes: [String] = [], failures: [any Error] = []
        var seen = Set<String>()
        for (label, result) in results {
            switch result {
            case .success(let found):
                // The user's issues come first; one both searches return stays theirs.
                rows += found.rows.filter { seen.insert($0.id).inserted }
                if let note = found.note, !notes.contains(note) { notes.append(note) }
            case .failure(let error):
                failures.append(error)
                notes.append("\(label): \(error.localizedDescription)")
            }
        }
        // Only when every search failed: one that answered with no tickets still answered.
        if let first = failures.first, failures.count == results.count { throw first }
        return (rows, notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }
    private static func attempt(_ body: @Sendable () async throws -> Found) async -> Result<Found, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
    private func myJiraTickets() async throws -> [DashboardTicketRow] {
        let site: JiraSite = try await api.get(Routes.JIRA_SITE, timeout: 30)
        guard let base = URL(string: site.baseUrl) else { return [] }
        let result: TicketSnapshot = try await api.request(Routes.JIRA_SEARCH, method: "POST", body: ["jql": Self.myTicketsJQL])
        if let error = result.error, !error.isEmpty { throw DashboardTicketError.search(error) }
        return result.items.map { DashboardTicketRow(ticket: $0, url: base.appending(path: "browse").appending(path: $0.key)) }
    }
    /// Open issues in the project repos that list their issues, each marked `mine` by the backend,
    /// with the backend's warning when it could not tell whose they are.
    private func issues(_ query: String, limit: Int) async throws -> Found {
        struct Body: Encodable, Sendable { let query: String; let allProjects = true; let limit: Int }
        let result: TicketSnapshot = try await api.request(Routes.ISSUES_SEARCH, method: "POST", body: Body(query: query, limit: limit), timeout: 60)
        if let error = result.error, !error.isEmpty { throw DashboardTicketError.search(error) }
        let rows = result.items.compactMap { ticket in
            ticket.url.flatMap(safeWebURL).map { DashboardTicketRow(ticket: ticket, url: $0) }
        }
        return Found(rows: rows, note: result.warning)
    }
}

enum DashboardTicketError: LocalizedError {
    case search(String)
    var errorDescription: String? { switch self { case .search(let message): return message } }
}
