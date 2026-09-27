import Foundation
import Testing

@Test func sessionPageParsesIssuesAndDistinguishesPulls() {
    let issue = SessionPage.parse("https://github.com/Owner/Repo/issues/12")
    #expect(issue?.kind == "issue" && issue?.key == "owner/repo#12")
    #expect(issue?.issueNumber == 12 && issue?.issueRepo == "owner/repo")
    let pull = SessionPage.parse("https://github.com/Owner/Repo/pull/12")
    #expect(pull?.kind == "github")
    #expect(SessionPage.issueBranch(number: 12, title: "Fix: crash on launch!") == "12-fix-crash-on-launch")
}

@Test func decodingTicketsMixesJiraAndGitHubSources() throws {
    let json = #"""
    [{"key":"REC-1"},{"source":"github","key":"#3","number":3,"repo":"o/r","url":"https://github.com/o/r/issues/3"}]
    """#
    let tickets = try JSONDecoder().decode([Ticket].self, from: Data(json.utf8))
    #expect(tickets.map(\.source) == [.jira, .github])
    let issue = tickets[1]
    #expect(issue.id == "o/r#3" && issue.sessionKey == "o/r#3")
}

@Test func trackedKeepsIssuesFromOwnedReposOnly() {
    let owning = DashboardProject(id: "p1", name: "Native", repo: "O/R", prs: [], lastSynced: nil, syncError: nil)
    let disabled = DashboardProject(id: "p2", name: "Off", repo: "O/R", prs: [], lastSynced: nil, syncError: nil, issuesEnabled: false)
    let owned = DashboardTicketRow(ticket: Ticket(key: "#3", source: .github, number: 3, repo: "o/r"), url: URL(string: "https://github.com/o/r/issues/3")!)
    let elsewhere = DashboardTicketRow(ticket: Ticket(key: "#4", source: .github, number: 4, repo: "a/b"), url: URL(string: "https://github.com/a/b/issues/4")!)
    #expect(DashboardTicketsModel.tracked([owned], in: [owning]).map(\.id) == [owned.id])
    #expect(DashboardTicketsModel.tracked([elsewhere], in: [owning]).isEmpty)
    #expect(DashboardTicketsModel.tracked([owned], in: [disabled]).isEmpty)
}

@Test func stampLinksAnIssueRowToItsPullRequestByUppercasedSessionKey() {
    let row = DashboardTicketRow(ticket: Ticket(key: "#3", source: .github, number: 3, repo: "o/r"), url: URL(string: "https://github.com/o/r/issues/3")!)
    #expect(row.linkKey == "O/R#3")
    let stamped = DashboardTicketsModel.stamp([row], linked: ["O/R#3": "#5"])
    #expect(stamped.first?.pullRequest == "#5")
}

// An issue page's key is lowercase and a PR's linked keys are compared uppercased: the PR that
// closes the issue must still lend its URL and branch, so its session wins over a newer one
// that only shares the key.
@Test func issuePageInheritsThePullRequestThatClosesIt() throws {
    func session(_ id: String, branch: String, url: String, createdAt: String) -> WorkspaceSession {
        WorkspaceSession(id: id, projectId: "p", workspace: "/tmp/r", worktree: "/tmp/r/\(id)", title: id, branch: branch,
                         url: url, createdAt: createdAt, pinned: false, jiraKey: "o/r#12")
    }
    let fromIssue = session("issue", branch: "12-crash", url: "https://github.com/o/r/issues/12", createdAt: "2026-09-02")
    let withPR = session("pr", branch: "fix-crash", url: "session:pr", createdAt: "2026-09-01")
    let pr = SessionResolver.PullRequest(projectID: "p", url: "https://github.com/o/r/pull/40", branch: "fix-crash", jiraKeys: ["O/R#12"])
    let page = try #require(SessionPage.parse("https://github.com/o/r/issues/12"))
    let request = OpenPageRequest(url: page.url, kind: "issue", title: "#12")
    // The session whose worktree produced the closing PR shares key, branch and PR URL (7) and beats
    // the one started from the issue page (URL and key, 5) — the PR row and the issue row agree.
    // With the key compared case-sensitively it scored only 1 and lost.
    #expect(SessionResolver.resolve(request, page: page, projectID: "p", sessions: [fromIssue, withPR], pullRequests: [pr])?.id == "pr")
    // Without it, the PR's branch and URL decide, not the newer key-only session.
    let keyOnly = session("key", branch: "other", url: "session:key", createdAt: "2026-09-03")
    #expect(SessionResolver.resolve(request, page: page, projectID: "p", sessions: [keyOnly, withPR], pullRequests: [pr])?.id == "pr")
}

// My Tickets' Mine is every Jira ticket (its search is the user's own) and the issues the backend
// marked `mine`; Others is every other open issue, unassigned ones included.
@Test func myTicketsSplitsMineFromOthersByTheBackendsMark() throws {
    let tickets = try JSONDecoder().decode([Ticket].self, from: Data(#"""
    [{"key":"REC-1"},
     {"source":"github","key":"#1","number":1,"repo":"o/r","url":"https://github.com/o/r/issues/1","mine":true},
     {"source":"github","key":"#2","number":2,"repo":"o/r","url":"https://github.com/o/r/issues/2","mine":false},
     {"source":"github","key":"#3","number":3,"repo":"o/r","url":"https://github.com/o/r/issues/3"}]
    """#.utf8))
    let rows = tickets.map { DashboardTicketRow(ticket: $0, url: URL(string: $0.url ?? "https://jira.example.test/browse/\($0.key)")!) }
    let (mine, others) = DashboardTicketsModel.split(rows)
    #expect(mine.map(\.ticket.key) == ["REC-1", "#1"])
    #expect(others.map(\.ticket.key) == ["#2", "#3"])
}
