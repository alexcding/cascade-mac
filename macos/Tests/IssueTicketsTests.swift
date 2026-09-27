import Foundation
import Testing

actor IssueFixture: IssueService {
    var fails = false
    var rejectStatus = false
    var status = IssueStatus.open
    var searches: [(query: String, repos: [String])] = []
    var statusCalls: [(repo: String, number: Int, status: String)] = []
    var saved: [String] = []
    func fail(_ value: Bool) { fails = value }
    func reject(_ value: Bool) { rejectStatus = value }
    func confirm(_ value: String) { status = value }
    func snapshot(projectID: String) async throws -> TicketSnapshot {
        try await Task.sleep(for: .milliseconds(20))
        if fails { throw BackendError.operation("Issues offline") }
        return TicketSnapshot(items: [
            Ticket(key: "#7", summary: "Crash on launch", status: status, assignee: "Octo", source: .github,
                   number: 7, repo: "o/r", url: "https://github.com/o/r/issues/7")
        ], jql: "is:open")
    }
    func search(_ query: String, repos: [String]) async throws -> TicketSnapshot {
        searches.append((query, repos))
        if fails { throw BackendError.operation("Issues search offline") }
        return TicketSnapshot(items: [
            Ticket(key: "#7", summary: query, status: status, assignee: "Octo", source: .github,
                   number: 7, repo: "o/r", url: "https://github.com/o/r/issues/7")
        ], jql: query)
    }
    func searchAllProjects(_ query: String) async throws -> TicketSnapshot { try await search(query, repos: []) }
    func setStatus(repo: String, number: Int, status: String) async throws {
        statusCalls.append((repo, number, status))
        try await Task.sleep(for: .milliseconds(20))
        if rejectStatus { throw BackendError.operation("Status change rejected") }
    }
    func syncAfterMutation(projectID: String) async throws {}
    func lookup(url: String) async throws -> Ticket? { nil }
    func settings() async throws -> [String: String] {
        try await Task.sleep(for: .milliseconds(60))
        return ["issue_filter_p": #"{"assignee":"Octo"}"#]
    }
    func saveFilters(_ filters: String, projectID: String) async throws { saved.append(filters) }
}

@MainActor private struct IssueFixturePageActions: PageActionServing {
    let open: (OpenPageRequest) async throws -> Void
    func openPage(_ request: OpenPageRequest) async throws { try await open(request) }
    func openBrowser(_ url: URL) -> Bool { true }
}

@MainActor private func issueModel(_ service: IssueFixture,
                                    open: @escaping (OpenPageRequest) async throws -> Void = { _ in }) -> TicketsViewModel {
    TicketsViewModel(project: Project(id: "p", name: "Native", repo: "o/r", color: nil, workspace: "/tmp"),
                      provider: IssueTicketProvider(service: service), pageActions: IssueFixturePageActions(open: open))
}

@MainActor private func waitForIssues(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor @Test func issueSnapshotOffersTheOtherTwoStatuses() async throws {
    let model = issueModel(IssueFixture())
    model.refresh()
    try await waitForIssues { !model.loading }
    let ticket = try #require(model.items.first)
    #expect(ticket.status == IssueStatus.open)
    #expect(model.nextStatuses(ticket) == [IssueStatus.closed, IssueStatus.notPlanned])
    await model.stop()
}

@MainActor @Test func issueTransitionCallsSetStatusAndShowsItBeforeConfirmation() async throws {
    let service = IssueFixture()
    let model = issueModel(service)
    model.refresh()
    try await waitForIssues { !model.loading }
    let ticket = try #require(model.items.first)
    await model.transition(ticket, to: IssueStatus.closed)
    #expect(model.items.first?.status == IssueStatus.closed)
    let calls = await service.statusCalls
    #expect(calls.count == 1 && calls[0].repo == "o/r" && calls[0].number == 7 && calls[0].status == IssueStatus.closed)
    #expect(model.snapshot?.items.first?.status == IssueStatus.open)
    await model.stop()
}

@MainActor @Test func issueTicketURLOnlyAcceptsItsOwnIssuePage() async throws {
    let model = issueModel(IssueFixture())
    let ticket = Ticket(key: "#7", source: .github, number: 7, repo: "o/r", url: "https://github.com/o/r/issues/7")
    #expect(model.ticketURL(ticket)?.absoluteString == "https://github.com/o/r/issues/7")
    let pull = Ticket(key: "#7", source: .github, number: 7, repo: "o/r", url: "https://github.com/o/r/pull/7")
    #expect(model.ticketURL(pull) == nil)
    let elsewhere = Ticket(key: "#7", source: .github, number: 7, repo: "o/r", url: "https://example.com/o/r/issues/7")
    #expect(model.ticketURL(elsewhere) == nil)
    let noURL = Ticket(key: "#7", source: .github, number: 7, repo: "o/r")
    #expect(model.ticketURL(noURL) == nil)
    await model.stop()
}

@MainActor @Test func issueOpenEmitsAnIssuePageRequest() async throws {
    var opened: OpenPageRequest?
    let model = issueModel(IssueFixture(), open: { opened = $0 })
    model.onAction = { [weak model] in if case .open(let request) = $0 { model?.navigation.open(request) } }
    model.refresh()
    try await waitForIssues { !model.loading }
    let ticket = try #require(model.items.first)
    model.open(ticket)
    await model.navigation.waitForOpen()
    #expect(opened?.kind == "issue" && opened?.url == "https://github.com/o/r/issues/7")
    await model.stop()
}

@MainActor @Test func issueSearchLooksUpAcrossTheProjectRepo() async throws {
    let service = IssueFixture()
    let model = issueModel(service)
    model.query = "#7"
    await model.search()
    let searches = await service.searches
    #expect(searches.count == 1 && searches[0].query == "#7" && searches[0].repos == ["o/r"])
    await model.stop()
}

@MainActor @Test func issueSavedFiltersLoadFromIssueFilterSetting() async throws {
    let model = issueModel(IssueFixture())
    model.refresh()
    try await waitForIssues { model.filters["assignee"] == "Octo" }
    #expect(model.filters["assignee"] == "Octo")
    await model.stop()
}

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
