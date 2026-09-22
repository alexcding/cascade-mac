import Foundation
import Testing

// Which session a PR or ticket row belongs to, and how the rows report it.

private let widgets = Project(id: "w", name: "Widgets", repo: "acme/widgets", color: nil, workspace: "/tmp/widgets", jiraProjectKey: "WID")
private let prURL = "https://github.com/acme/widgets/pull/9", ticketURL = "https://acme.atlassian.net/browse/WID-3"

private func routed(_ id: String, project: String = "w", branch: String = "", url: String? = nil, jiraKey: String? = nil,
                    createdAt: String? = nil) -> WorkspaceSession {
    WorkspaceSession(id: id, projectId: project, workspace: "/tmp/widgets", worktree: "/tmp/widgets/\(id)", title: id, branch: branch,
                     url: url ?? "session:\(id)", createdAt: createdAt, pinned: false, jiraKey: jiraKey)
}

@MainActor @Test func resolverOnlyTiesSessionsThroughOpenPullRequestsOfTheRowsProject() throws {
    let projects = try JSONDecoder().decode([DashboardProject].self, from: Data(#"""
    [{"id":"w","name":"Widgets","repo":"acme/widgets","prs":[
      {"number":9,"url":"https://github.com/acme/widgets/pull/9","state":"OPEN","headRefName":"me/fix/WID-3-thing","jiraKeys":["WID-3"]},
      {"number":8,"url":"https://github.com/acme/widgets/pull/8","state":"MERGED","headRefName":"old/WID-3","jiraKeys":["WID-3"]},
      {"number":7,"state":"OPEN","headRefName":"no-url","jiraKeys":["WID-3"]}
    ]},{"id":"j","name":"Other","repo":"acme/jql","prs":[
      {"number":1,"url":"https://github.com/acme/jql/pull/1","state":"OPEN","headRefName":"theirs/WID-3","jiraKeys":["WID-3"]}
    ]}]
    """#.utf8))
    let prs = SessionResolver.pullRequests(projects)
    // Merged PRs and PRs with no page drop out; the rest keep their project.
    #expect(prs.map(\.url) == [prURL, "https://github.com/acme/jql/pull/1"] && prs.map(\.projectID) == ["w", "j"])
    let ticket = OpenPageRequest(url: ticketURL, kind: "jira", title: "WID-3")
    func find(_ request: OpenPageRequest, _ sessions: [WorkspaceSession]) -> String? {
        AppViewModel.pageSession(for: request, sessions: sessions, projects: [widgets], pullRequests: prs)?.id
    }
    // The ticket reaches the session on its open PR's branch, not the one on the merged PR's branch,
    // and never through another project's PR.
    let open = routed("open", branch: "me/fix/WID-3-thing"), merged = routed("merged", branch: "old/WID-3")
    let foreign = routed("foreign", branch: "theirs/WID-3")
    #expect(find(ticket, [merged, foreign, open]) == "open")
    #expect(find(ticket, [merged, foreign]) == nil)
    // A session with no branch inherits nothing from a PR with no branch.
    var blankPR = OpenPageRequest(url: prURL, kind: "github", title: "#9")
    blankPR.jiraKeys = []
    #expect(find(blankPR, [routed("blank")]) == nil)
    // Keys compare case-insensitively; a key match alone still counts.
    var keyed = blankPR; keyed.jiraKeys = ["wid-3"]
    #expect(find(keyed, [routed("ticket", jiraKey: "WID-3")]) == "ticket")
}

@MainActor @Test func resolverNeedsAPageAndAWorkspaceProject() {
    let session = routed("s", url: "https://example.com/not-a-page")
    #expect(AppViewModel.pageSession(for: OpenPageRequest(url: session.url, kind: "web", title: ""), sessions: [session], projects: [widgets]) == nil)
    // The row's project without a workspace has nowhere to hold a session.
    let bare = Project(id: "b", name: "Bare", repo: "acme/widgets", color: nil, workspace: "", jiraProjectKey: nil)
    var request = OpenPageRequest(url: prURL, kind: "github", title: "#9", branch: "x")
    request.projectID = "b"
    #expect(AppViewModel.pageSessionProject(for: request, in: [bare, widgets]) == nil)
    // Without a row project, the page's repository picks it, and only that project's sessions count.
    request.projectID = nil
    #expect(AppViewModel.pageSessionProject(for: request, in: [bare, widgets])?.id == "w")
    #expect(AppViewModel.pageSession(for: request, sessions: [routed("theirs", project: "b", branch: "x"), routed("ours", branch: "x")], projects: [bare, widgets])?.id == "ours")
    // Sessions outside every project never match by URL either.
    #expect(AppViewModel.pageSession(for: request, sessions: [routed("stray", project: "zzz", url: prURL)], projects: [bare, widgets]) == nil)
    // A page no workspace project tracks has nothing to scope a branch or key by: only its own session counts.
    let untracked = OpenPageRequest(url: "https://github.com/acme/elsewhere/pull/2", kind: "github", title: "#2", branch: "x")
    #expect(AppViewModel.pageSession(for: untracked, sessions: [routed("same-branch", branch: "x")], projects: [widgets]) == nil)
    #expect(AppViewModel.pageSession(for: untracked, sessions: [routed("own", url: untracked.url)], projects: [widgets])?.id == "own")
}

private actor KeyStartService: SessionCreating {
    let draft: SessionDraft
    private(set) var createdDraft: SessionDraft?
    init(_ draft: SessionDraft) { self.draft = draft }
    func references(_ project: Project) -> GitReferences { GitReferences(branches: [.init(name: "main")], defaultBranch: "main") }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft, workflow: Bool) -> SessionDraft { self.draft }
    func switchMainCheckout(to branch: String, project: Project) {}
    func create(project: Project, draft: SessionDraft, requireExactBranch: Bool) -> WorkspaceSession {
        createdDraft = draft
        return WorkspaceSession(id: "page", projectId: project.id, workspace: project.workspace, worktree: "/tmp/new",
                                title: draft.title, branch: draft.branch, url: draft.url, createdAt: nil, pinned: false, jiraKey: draft.jiraKey)
    }
}

@Test func aSessionStartedFromAPullRequestRecordsItsTicket() async {
    var pr = SessionDraft(); pr.url = prURL; pr.kind = "github"; pr.branch = "me/fix/WID-3-thing"
    let fromPR = KeyStartService(pr)
    guard case .created(let session) = await PageSessionStart.run(url: prURL, project: widgets, agent: .shell, jiraKey: "wid-3", operations: fromPR) else {
        Issue.record("The PR page should create its session"); return
    }
    #expect(session.jiraKey == "WID-3")
    // A ticket page's own key is never overwritten by the row's.
    var ticket = SessionDraft(); ticket.url = ticketURL; ticket.kind = "jira"; ticket.jiraKey = "WID-3"; ticket.branch = "WID-3-thing"
    let fromTicket = KeyStartService(ticket)
    _ = await PageSessionStart.run(url: ticketURL, project: widgets, agent: .shell, jiraKey: "WID-9", operations: fromTicket)
    let created = await fromTicket.createdDraft
    #expect(created?.jiraKey == "WID-3")
    // No key known: none recorded.
    let plain = KeyStartService(pr)
    _ = await PageSessionStart.run(url: prURL, project: widgets, agent: .shell, operations: plain)
    let plainDraft = await plain.createdDraft
    #expect(plainDraft?.jiraKey == "")
}

@MainActor private final class RoutingPageActions: PageActionServing {
    var sessionURLs: Set<String> = []
    var asked: [OpenPageRequest] = []
    func openPage(_ request: OpenPageRequest) async throws {}
    func pageSession(_ request: OpenPageRequest) -> PageSessionMark? { asked.append(request); return sessionURLs.contains(request.url) ? PageSessionMark(cli: "claude") : nil }
}

private struct RoutingRows: DashboardService {
    func snapshot() async throws -> [DashboardProject] {
        try JSONDecoder().decode([DashboardProject].self, from: Data(#"""
        [{"id":"w","name":"Widgets","repo":"acme/widgets","lastSynced":"2026-09-12T12:00:00Z","prs":[
          {"number":9,"title":"Worked","url":"https://github.com/acme/widgets/pull/9","state":"OPEN","category":"mine","headRefName":"me/fix/WID-3-thing","jiraKeys":["WID-3"]},
          {"number":5,"title":"Fresh","url":"https://github.com/acme/widgets/pull/5","state":"OPEN","category":"mine","headRefName":"fresh"}
        ]}]
        """#.utf8))
    }
}

@MainActor @Test func dashboardRowsReportTheirSessionWithTheSessionRequest() async throws {
    let actions = RoutingPageActions()
    actions.sessionURLs = [prURL]
    let model = DashboardViewModel(pageActions: actions), coordinator = DashboardCoordinator(model: model)
    model.connect(RoutingRows())
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    let worked = try #require(model.mine.first { $0.pr.number == 9 }), fresh = try #require(model.mine.first { $0.pr.number == 5 })
    #expect(model.sessionMark(worked)?.cli == "claude" && model.sessionMark(fresh) == nil)
    // The lookup is asked exactly what Open in Session would send: the row's project, branch and keys.
    let asked = try #require(actions.asked.first)
    #expect(asked.inSession && asked.projectID == "w" && asked.branch == "me/fix/WID-3-thing" && asked.jiraKeys == ["WID-3"])
    await model.stop(); coordinator.retire()
}

@MainActor @Test func pageActionsDefaultToNoSessionAndNativeOnesAskTheApp() {
    struct Bare: PageActionServing { func openPage(_ request: OpenPageRequest) async throws {} }
    let request = OpenPageRequest(url: prURL, kind: "github", title: "#9")
    #expect(Bare().pageSession(request) == nil)
    var seen: [String] = []
    let native = NativePageActionService(open: { _ in }, session: { seen.append($0.url); return PageSessionMark(cli: "codex") })
    #expect(native.pageSession(request)?.glyph == "⠿" && seen == [prURL])
    #expect(NativePageActionService(open: { _ in }).pageSession(request) == nil)
    let navigation = PageActionViewModel(service: native)
    #expect(navigation.pageSession(request)?.agentName == "Codex" && seen.count == 2)
    #expect(PageSessionMark(cli: "claude").glyph == "✻" && PageSessionMark(cli: nil).label == "Has a shell session")
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectPullRequestAndTicketRowsReportTheirSessions() async throws {
    let service = JiraFixture()
    let project = Project(id: "w", name: "Widgets", repo: "acme/widgets", color: nil, workspace: "/tmp", jiraProjectKey: "REC")
    let base = URL(string: "http://127.0.0.1:1")!, api = try APIClient(baseURL: base)
    let factory = NativeProjectFeatureFactory(creation: NativeCreationFlowFactory(chooseFolder: { nil }))
    var asked: [OpenPageRequest] = []
    let model = factory.project(project, services: .init(projects: ProjectPageService(), tickets: service,
        workflows: APIWorkflowService(api: api), automation: APIAutomationService(api: api), api: api, baseURL: base),
        openPage: { _ in }, session: { asked.append($0); return $0.url.hasSuffix("REC-1") ? PageSessionMark(cli: "") : nil })
    let tickets = try #require(model.tickets)
    tickets.refresh()
    while tickets.baseURL == nil || tickets.loading { await Task.yield() }
    let login = try #require(tickets.rows.first { $0.key == "REC-1" }), done = try #require(tickets.rows.first { $0.key == "REC-2" })
    #expect(tickets.sessionMark(login) != nil && tickets.sessionMark(done) == nil)
    let ticketAsk = try #require(asked.first)
    #expect(ticketAsk.inSession && ticketAsk.projectID == "w" && ticketAsk.kind == "jira" && ticketAsk.url == "https://jira.example.test/browse/REC-1")
    #expect(tickets.sessionMark(JiraTicket(key: "FOREIGN-99")) == nil)
    // PR rows ask with the row's project and branch.
    let row = try JSONDecoder().decode([DashboardProject].self, from: Data(#"""
    [{"id":"w","name":"Widgets","repo":"acme/widgets","prs":[{"number":1,"title":"REC-1 fix","url":"https://github.com/acme/widgets/pull/REC-1","state":"OPEN","category":"mine","headRefName":"REC-1-fix","jiraKeys":["REC-1"]}]}]
    """#.utf8)).flatMap { project in project.prs.compactMap { pr in
        URL(string: pr.url ?? "").map { DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: $0) } } }
    let pr = try #require(row.first)
    #expect(model.sessionMark(pr) != nil)
    let prAsk = try #require(asked.last)
    #expect(prAsk.inSession && prAsk.projectID == "w" && prAsk.branch == "REC-1-fix" && prAsk.jiraKeys == ["REC-1"])
    // A project page with no page actions has no sessions to report.
    #expect(ProjectPageViewModel(project: project, service: ProjectPageService(), editor: model.editor).sessionMark(pr) == nil)
    await tickets.stop()
}

private struct RoutingBoard: BoardService {
    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot {
        BoardSnapshot(items: [JiraTicket(key: "REC-1", summary: "one", status: "Ready", statusId: "1"), JiraTicket(key: "REC-2", summary: "two", status: "Ready", statusId: "1")],
                      sprint: nil, query: "", columns: [BoardColumn(name: "To Do", statusIds: ["1"], statuses: [.init(id: "1", name: "Ready")])])
    }
    func site() async throws -> JiraSite { JiraSite(baseUrl: "https://jira.test") }
    func settings() async throws -> [String: String] { [:] }
    func saveFilter(_ value: String, projectID: String) async throws {}
    func saveQuery(_ value: String, projectID: String) async throws {}
    func transition(key: String, status: String) async throws {}
    func assign(key: String, assignee: String) async throws {}
}

@MainActor @Test(.timeLimit(.minutes(1))) func boardCardsReportTheirSessionsOnceTheSiteIsKnown() async {
    let actions = RoutingPageActions()
    actions.sessionURLs = ["https://jira.test/browse/REC-1"]
    let model = WebBoardViewModel(projectID: "w", service: RoutingBoard(), pageActions: actions)
    let one = JiraTicket(key: "REC-1", summary: "one", status: "Ready", statusId: "1")
    // Before the site is known there is no ticket URL, so no session either — and nothing is asked.
    #expect(model.sessionMark(one) == nil && actions.asked.isEmpty)
    model.active = true
    while model.loading || model.siteURL == nil { await Task.yield() }
    #expect(model.sessionMark(one)?.cli == "claude" && model.sessionMark(JiraTicket(key: "REC-2", summary: "two", status: "Ready", statusId: "1")) == nil)
    let asked = actions.asked.first
    #expect(asked?.inSession == true && asked?.projectID == "w" && asked?.kind == "jira" && asked?.url == "https://jira.test/browse/REC-1")
}
