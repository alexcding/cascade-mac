import Foundation
import Testing

private struct SessionRowService: DashboardService {
    func snapshot() async throws -> [DashboardProject] {
        try JSONDecoder().decode([DashboardProject].self, from: Data(#"""
        [{"id":"p","name":"Native","repo":"o/r","lastSynced":"2026-09-12T12:00:00Z","prs":[
          {"number":1,"title":"Mine","url":"https://github.com/o/r/pull/1","state":"OPEN","category":"mine","headRefName":"feature/one"}
        ]}]
        """#.utf8))
    }
}

private func session(_ id: String, project: String = "w", branch: String = "", url: String? = nil, jiraKey: String? = nil) -> WorkspaceSession {
    WorkspaceSession(id: id, projectId: project, workspace: "/tmp/widgets", worktree: "/tmp/widgets/\(id)", title: id, branch: branch,
                     url: url ?? "session:\(id)", createdAt: nil, pinned: false, jiraKey: jiraKey)
}

@MainActor @Test func dashboardOpenInSessionMarksTheRequestAndNamesItsProject() async throws {
    let actions = ProjectPageActions()
    let model = DashboardViewModel(pageActions: actions), coordinator = DashboardCoordinator(model: model)
    model.connect(SessionRowService())
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    let row = try #require(model.prs.mine.first)
    model.open(row); await model.navigation.waitForOpen()
    #expect(actions.opened.last?.inSession == false && actions.opened.last?.projectID == "p", "A tab open names the row's project too, so its session lookup matches the badge's")
    #expect(actions.opened.last?.inTab == false, "A click keeps the page's session routing")
    model.open(row, inTab: true); await model.navigation.waitForOpen()
    #expect(actions.opened.last?.inTab == true && actions.opened.last?.inSession == false, "The menu's Open in Tab asks for a tab regardless of any session")
    model.openSession(row); await model.navigation.waitForOpen()
    let opened = try #require(actions.opened.last)
    #expect(opened.inSession && opened.projectID == "p" && opened.branch == "feature/one" && opened.url == row.url.absoluteString)
    #expect(opened.agent == nil, "Go to Session names no agent: the default starts one if needed")
    model.openSession(row, agent: .codex); await model.navigation.waitForOpen()
    #expect(actions.opened.last?.agent == .codex)
    // A session start already says what failed; a tab open keeps the dashboard's words.
    actions.failOpen = true
    model.openSession(row); await model.navigation.waitForOpen()
    #expect(model.navigation.error == "Fixture open failed")
    model.open(row); await model.navigation.waitForOpen()
    #expect(model.navigation.error == "Could not open pull request: Fixture open failed")
    await model.stop(); coordinator.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func openInSessionIsNotDroppedWhileTheSameRowOpensInATab() async throws {
    let gate = ProjectPageGate(), actions = ProjectPageActions()
    actions.gate = gate
    let navigation = PageActionViewModel(service: actions)
    let tab = OpenPageRequest(url: "https://github.com/o/r/pull/1", kind: "github", title: "#1")
    var inSession = tab; inSession.inSession = true
    navigation.open(tab)
    await gate.waitForStart()
    navigation.open(tab) // A repeat of the request in flight is still ignored.
    navigation.open(inSession)
    await gate.finish()
    await navigation.waitForOpen()
    #expect(actions.opened.map(\.inSession) == [false, true])
    #expect(actions.navigated == [tab.url]) // Only the session request landed; the tab open was superseded.
}

@Test func openInSessionRoutingNeverReachesTheBackend() throws {
    var request = OpenPageRequest(url: "https://github.com/o/r/pull/1", kind: "github", title: "#1", branch: "feature/one")
    request.inSession = true; request.projectID = "p"
    let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(body["inSession"] == nil && body["projectID"] == nil)
    #expect(body["url"] as? String == request.url && body["branch"] as? String == "feature/one")
    // The coding keys are written by hand: a field added without one would silently never be sent.
    request.id = "draft"
    let sent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    let fields = Set(Mirror(reflecting: request).children.compactMap(\.label))
    #expect(Set(sent.keys) == fields.subtracting(["inSession", "inTab", "projectID", "jiraKeys", "agent"]).union(["standalone"]))
    #expect(sent["standalone"] as? Bool == false)
}

@MainActor @Test func aPageFindsTheSessionItAlreadyHas() {
    let widgets = Project(id: "w", name: "Widgets", repo: "acme/widgets", color: nil, workspace: "/tmp/widgets", jiraProjectKey: "WID")
    let jql = Project(id: "j", name: "JQL only", repo: "acme/jql", color: nil, workspace: "/tmp/jql", jiraProjectKey: nil)
    let projects = [widgets, jql]
    let pr = "https://github.com/acme/widgets/pull/7", ticket = "https://acme.atlassian.net/browse/OPS-12"
    func find(_ request: OpenPageRequest, _ sessions: [WorkspaceSession]) -> String? {
        AppViewModel.pageSession(for: request, sessions: sessions, projects: projects)?.id
    }
    var request = OpenPageRequest(url: pr, kind: "github", title: "#7", branch: "main")
    // The page's own session wins over an earlier one that only shares its branch.
    #expect(find(request, [session("shared", branch: "main"), session("own", branch: "fork-main", url: pr)]) == "own")
    #expect(find(request, [session("shared", branch: "main")]) == "shared")
    #expect(find(request, [session("foreign", project: "j", branch: "main")]) == nil)
    // Two projects can track one repository: another project's session for this page is not this row's.
    request.projectID = "w"
    #expect(find(request, [session("theirs", project: "j", url: pr), session("ours", project: "w", url: pr)]) == "ours")
    #expect(find(request, [session("theirs", project: "j", url: pr)]) == nil)
    // A row with no branch matches nothing by branch.
    request = OpenPageRequest(url: pr, kind: "github", title: "#7")
    #expect(find(request, [session("blank", branch: "")]) == nil)
    // A PR pushed from a branch named differently from its ticket's session still belongs to that session.
    request.branch = "me/fix/WID-3-thing"; request.jiraKeys = ["WID-3"]
    #expect(find(request, [session("ticket", branch: "WID-3-thing", jiraKey: "wid-3")]) == "ticket")
    #expect(find(request, [session("other", branch: "WID-4-thing", jiraKey: "WID-4")]) == nil)
    #expect(find(request, [session("nokey", branch: "WID-3-thing")]) == nil)
    // A JQL project lists tickets no key prefix would find: the row's own project decides.
    var jira = OpenPageRequest(url: ticket, kind: "jira", title: "OPS-12")
    #expect(AppViewModel.pageSessionProject(for: jira, in: projects) == nil)
    jira.projectID = "j"
    #expect(AppViewModel.pageSessionProject(for: jira, in: projects)?.id == "j")
    #expect(find(jira, [session("other", project: "w", jiraKey: "OPS-12"), session("ticket", project: "j", jiraKey: "ops-12")]) == "ticket")
    // Not a PR or ticket page: nothing to match.
    #expect(find(OpenPageRequest(url: "https://example.com", kind: "web", title: ""), [session("any", url: "https://example.com")]) == nil)
}

@MainActor @Test func aTicketAndItsPullRequestResolveToTheSameSession() {
    let widgets = Project(id: "w", name: "Widgets", repo: "acme/widgets", color: nil, workspace: "/tmp/widgets", jiraProjectKey: "WID")
    let prURL = "https://github.com/acme/widgets/pull/9", ticketURL = "https://acme.atlassian.net/browse/WID-3"
    let prs = [SessionResolver.PullRequest(projectID: "w", url: prURL, branch: "me/fix/WID-3-thing", jiraKeys: ["WID-3"])]
    func find(_ request: OpenPageRequest, _ sessions: [WorkspaceSession]) -> String? {
        AppViewModel.pageSession(for: request, sessions: sessions, projects: [widgets], pullRequests: prs)?.id
    }
    var pr = OpenPageRequest(url: prURL, kind: "github", title: "#9", branch: "me/fix/WID-3-thing")
    pr.jiraKeys = ["WID-3"]
    let ticket = OpenPageRequest(url: ticketURL, kind: "jira", title: "WID-3")
    // The ticket's session pushed the PR from its worktree: both rows land on it, even beside a
    // second session that only carries the key.
    let worked = session("worked", branch: "me/fix/WID-3-thing", url: ticketURL, jiraKey: "WID-3")
    let keyOnly = session("key-only", branch: "WID-3-other", url: "session:key-only", jiraKey: "WID-3")
    #expect(find(pr, [keyOnly, worked]) == "worked" && find(ticket, [keyOnly, worked]) == "worked")
    // A session started from the PR, with no key recorded, is still the ticket's through the PR.
    let fromPR = session("from-pr", branch: "me/fix/WID-3-thing", url: prURL)
    #expect(find(ticket, [fromPR]) == "from-pr" && find(pr, [fromPR]) == "from-pr")
    // Started from the PR versus started from the ticket with a different branch: the PR's worktree wins.
    #expect(find(ticket, [keyOnly, fromPR]) == "from-pr")
    // Only a shared key, no PR: the ticket's session is found; a stranger is not.
    #expect(find(ticket, [keyOnly]) == "key-only")
    #expect(find(pr, [session("stranger", branch: "other", jiraKey: "WID-9")]) == nil)
    // Equal evidence: the newest session wins.
    let older = WorkspaceSession(id: "older", projectId: "w", workspace: "/tmp/widgets", worktree: "/tmp/a", title: "a", branch: "", url: ticketURL, createdAt: "2026-01-01T00:00:00Z", pinned: false, jiraKey: "WID-3")
    let newer = WorkspaceSession(id: "newer", projectId: "w", workspace: "/tmp/widgets", worktree: "/tmp/b", title: "b", branch: "", url: ticketURL, createdAt: "2026-02-01T00:00:00Z", pinned: false, jiraKey: "WID-3")
    #expect(find(ticket, [older, newer]) == "newer")
}
