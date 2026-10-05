import Foundation

/// One project's numbers on Projects: its open pull requests, the ones waiting on the user, their
/// checks, its tickets and sessions, and when it last synced.
struct DashboardProjectSummary: Identifiable, Equatable {
    let id: String
    let name: String
    /// Where its tickets come from: its Jira keys, the repository's issues, or nothing.
    let tracker: String
    var open = 0
    var waiting = 0
    var passing = 0
    var running = 0
    var failing = 0
    var tickets = 0
    var sessions = 0
    var synced: Date?
    var syncError: String?

    /// The checks in a few words, worst first: what fails, else what runs, else that all pass.
    var checks: String {
        if failing > 0 { return String(localized: "\(failing) failing") }
        if running > 0 { return String(localized: "\(running) running") }
        return passing > 0 ? String(localized: "Passing") : String(localized: "No checks")
    }
}

extension DashboardViewModel {
    /// Every project the dashboard reads, in its order, with what Projects shows for it. Rows and
    /// tickets are what the pull request and ticket models already hold; nothing is fetched here.
    /// Worked out when those or the session counts change (`projectSummaries`), never per redraw.
    func makeProjectSummaries() -> [DashboardProjectSummary] {
        let rows = prs.mine + prs.reviews + prs.others
        let tickets = self.tickets.rows
        return prs.projects.map { project in
            var summary = DashboardProjectSummary(id: project.id, name: project.name, tracker: Self.tracker(of: project))
            for row in rows where row.projectID == project.id {
                summary.open += 1
                if !row.isMine && row.inReviewGroup { summary.waiting += 1 }
                switch row.checks {
                case .passing: summary.passing += 1
                case .running: summary.running += 1
                case .failing: summary.failing += 1
                case .unknown: break
                }
            }
            summary.tickets = tickets.filter { project.owns($0.ticket) }.count
            summary.sessions = sessionCounts[project.id] ?? 0
            summary.synced = project.lastSynced.flatMap(backendTimestamp)
            summary.syncError = project.syncError
            return summary
        }
    }

    private static func tracker(of project: DashboardProject) -> String {
        if project.hasJira { return String(localized: "Jira \(project.jiraKeys.joined(separator: ", "))") }
        if project.hasIssues { return String(localized: "GitHub issues") }
        return String(localized: "No tracker")
    }
}
