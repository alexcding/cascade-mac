import Foundation

/// One project as Projects shows it: its name and tracker, its tickets for the top card, and a
/// sync that failed.
struct DashboardProjectSummary: Identifiable, Equatable {
    let id: String
    let name: String
    /// Where its tickets come from: its Jira keys, the repository's issues, or nothing.
    let tracker: String
    var tickets = 0
    var syncError: String?
}

extension DashboardViewModel {
    /// Every project the dashboard reads, in its order, with what Projects shows for it. Tickets
    /// are what the ticket model already holds; nothing is fetched here. Worked out when the pull
    /// requests or tickets change (`projectSummaries`), never per redraw.
    func makeProjectSummaries() -> [DashboardProjectSummary] {
        let tickets = self.tickets.rows
        return prs.projects.map { project in
            var summary = DashboardProjectSummary(id: project.id, name: project.name, tracker: Self.tracker(of: project))
            summary.tickets = tickets.filter { project.owns($0.ticket) }.count
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
