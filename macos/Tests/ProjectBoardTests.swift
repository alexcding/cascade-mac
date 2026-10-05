import Foundation
import Testing

/// A dashboard backend with Jira: projects and the user's tickets.
private struct BoardDashboardFixture: DashboardService, DashboardTicketService {
    var projects: [DashboardProject]
    var tickets: [DashboardTicketRow] = []
    func snapshot() async throws -> [DashboardProject] { projects }
    func myTickets() async throws -> [DashboardTicketRow] { tickets }
}

/// One sprint with one ticket, on a Jira site, so a card can resolve its link.
private struct BoardFixture: BoardService {
    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot {
        try JSONDecoder().decode(BoardSnapshot.self, from: Data(#"{"items":[{"key":"WEB-1","summary":"Login","status":"To Do"}]}"#.utf8))
    }
    func site() async throws -> JiraSite { JiraSite(baseUrl: "https://jira.example.test") }
    func saveQuery(_ value: String, projectID: String) async throws {}
    func transition(key: String, status: String) async throws {}
    func assign(key: String, assignee: String) async throws {}
}

private func jiraProject(_ id: String, key: String? = nil) -> DashboardProject {
    DashboardProject(id: id, name: id.capitalized, repo: "", prs: [], lastSynced: "2026-01-01T00:00:00Z", syncError: nil,
                     jiraProjectKey: key)
}

private func ticketRow(_ key: String) -> DashboardTicketRow {
    DashboardTicketRow(ticket: Ticket(key: key, summary: key, status: "To Do"), url: URL(string: "https://jira.example.test/browse/\(key)")!)
}

@MainActor private func connectedDashboard(_ root: AppCoordinator, _ actions: ProjectPageActions,
                                           projects: [DashboardProject], tickets: [DashboardTicketRow] = []) async -> DashboardViewModel {
    let model = DashboardViewModel(pageActions: actions)
    root.installDashboard(model)
    model.connect(BoardDashboardFixture(projects: projects, tickets: tickets))
    while model.prs.loading || model.tickets.loading || model.prs.projects.isEmpty { await Task.yield() }
    return model
}

@MainActor private func makeRoot() -> AppCoordinator { AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })) }

@MainActor @Test(.timeLimit(.minutes(1))) func ticketsListNarrowsToAProjectByJiraKey() async throws {
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")],
        tickets: [ticketRow("WEB-1"), ticketRow("OPS-7"), ticketRow("WEB-2")])
    #expect(model.tickets.screenRows.count == 3 && model.tickets.pageCounts[.all] == 3)
    model.selectProject("web")
    #expect(Set(model.tickets.screenRows.map(\.id)) == ["WEB-1", "WEB-2"])
    // One menu narrows every tab: the pull requests follow the same project.
    #expect(model.project == "web" && model.prs.project == "web" && model.projectTracksTickets)
    #expect(model.tickets.pageCounts[.all] == 2)
    model.selectProject(nil)
    #expect(model.tickets.screenRows.count == 3)
}

@MainActor @Test(.timeLimit(.minutes(1))) func ticketsShowOnlyTheTrackedProjects() async throws {
    // "web" lists two keys, the way the project field allows; "OTHER" belongs to no project.
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(),
        projects: [jiraProject("web", key: "WEB, www"), jiraProject("plain")],
        tickets: [ticketRow("WEB-1"), ticketRow("OTHER-3"), ticketRow("WWW-2")])
    while model.tickets.rows.isEmpty { await Task.yield() }
    #expect(Set(model.tickets.rows.map(\.id)) == ["WEB-1", "WWW-2"])
    #expect(model.tickets.pageCounts[.all] == 2 && model.tickets.screenRows.count == 2)
    // Removing the project's key drops its tickets everywhere, the overview's count included.
    model.tickets.projects = [jiraProject("web"), jiraProject("plain")]
    #expect(model.tickets.rows.isEmpty && model.tickets.pageCounts[.all] == 0)
    #expect(!model.tickets.fetchedNothing, "Jira did return tickets; none are tracked")
}

@Test func jiraKeysComeFromTheProjectKeyField() {
    #expect(jiraProject("x", key: "App, ops").jiraKeys == ["APP", "OPS"])
    #expect(jiraProject("x", key: "App").hasJira && jiraProject("x", key: "App").owns(ticket: "app-12"))
    #expect(jiraProject("m").jiraKeys.isEmpty && !jiraProject("m").hasJira)
    // A field of only commas and spaces names no key, so the project has no Jira rather than
    // one that silently claims no tickets.
    #expect(!jiraProject("c", key: " , ").hasJira && jiraProject("c", key: " , ").jiraKeys.isEmpty)
    #expect(!Project(id: "c", name: "C", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: ",").hasJira)
    #expect(Project(id: "k", name: "K", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: "app").hasJira)
}

@MainActor @Test(.timeLimit(.minutes(1))) func overviewTotalsOpenWhatTheyCountWhileTheTabKeepsItsPlace() async throws {
    let root = makeRoot()
    let model = await connectedDashboard(root, ProjectPageActions(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")],
        tickets: [ticketRow("WEB-1"), ticketRow("OPS-2")])
    root.navigate(to: .overview)
    model.showTickets(); model.selectProject("ops")
    // The Tickets tab returns to the list as it was left.
    model.selectTab(.overview); model.selectTab(.tickets)
    #expect(model.tickets.project?.id == "ops")
    // An Overview total opens the list it counts, in the project picked.
    model.selectTab(.overview); model.tickets.author = .others; model.showTickets(.urgent)
    #expect(model.tickets.project?.id == "ops" && model.tickets.author == .mine && model.tickets.filter == .urgent && model.tab == .tickets)
    model.selectTab(.overview); model.showPullRequests(.mine, filter: .failing)
    #expect(model.tab == .pullRequests && model.prs.author == .mine && model.prs.filter == .failing && model.prs.project == "ops")
    model.showPullRequests(.review)
    #expect(model.prs.author == .review && model.prs.filter == .all && model.project == "ops")
}

// MARK: - Projects' Board tab

@MainActor @Test(.timeLimit(.minutes(1))) func boardCardOpensAreGatedByTheTabAndTheCoordinator() async throws {
    let root = makeRoot(), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions, projects: [jiraProject("web", key: "WEB")])
    let coordinator = try #require(root.dashboardCoordinator)
    model.boardProjectIDs = ["web"]
    model.connectBoards(BoardFixture())
    root.navigate(to: .overview)
    model.selectProject("web"); model.selectTab(.board)
    let board = try #require(model.board)
    while board.siteURL == nil || board.tickets.isEmpty { await Task.yield() }
    let ticket = try #require(board.tickets.first)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.navigated == ["https://jira.example.test/browse/WEB-1"])
    coordinator.canPresent = { false }
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.navigated.count == 1, "A blocked page stays silent")
    coordinator.canPresent = { true }
    model.selectTab(.tickets)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.navigated.count == 1, "A board that is not shown opens nothing")
    model.selectTab(.board)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.navigated.count == 2)
    coordinator.retire()
    #expect(board.retired && !board.active)
}

@MainActor @Test func boardLinksOpenProjectsBoardTabOnTheirProject() async throws {
    let root = makeRoot()
    let model = await connectedDashboard(root, ProjectPageActions(), projects: [jiraProject("web", key: "WEB")])
    model.boardProjectIDs = ["web"]
    root.navigate(to: Route.projectBoard(projectID: "web"))
    #expect(root.selection == .overview && model.tab == .board && model.project == "web")
}

@MainActor @Test func boardURLsOpenTheirProject() throws {
    let link = try #require(CascadeRouter().deepLink(for: URL(string: "cascade://app/projects/ops/board")!))
    #expect(link.destination == .project("ops") && link.droppingFirst().first == .projectBoard(projectID: "ops"))
    #expect(DeepLink([.destination(.terminal), .projectBoard(projectID: "ops")]).destination == nil)
}


@MainActor @Test(.timeLimit(.minutes(1))) func boardTabShowsThePickedProjectsBoardWhileOnScreen() async throws {
    let root = makeRoot()
    let model = await connectedDashboard(root, ProjectPageActions(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")])
    // No project shows a board: no Board tab, and picking it stays on Overview.
    #expect(!model.tabs.contains(.board))
    model.selectTab(.board)
    #expect(model.tab == .overview)
    model.boardProjectIDs = ["web"]
    model.connectBoards(BoardFixture())
    model.selectTab(.board)
    #expect(model.tabs.last == .board && model.tab == .board && model.board == nil, "Every project is picked")
    // Picking a project with a board builds it; it loads only while Projects is on screen.
    model.selectProject("web")
    let board = try #require(model.board)
    #expect(board.projectID == "web")
    root.navigate(to: .overview)
    #expect(board.active)
    root.navigate(to: .automation)
    #expect(!board.active)
    // A project without one has no board, and the old one is retired.
    model.selectProject("ops")
    #expect(model.board == nil && board.retired)
    // Turning the last board off leaves the tab.
    model.boardProjectIDs = []
    #expect(model.tab == .overview && !model.tabs.contains(.board))
    model.retire()
}

@MainActor @Test func aBoardProjectCanBePickedBeforeThePullRequestsArrive() {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.boardProjectIDs = ["web"]
    model.selectProject("web")
    #expect(model.project == "web" && model.projectShowsBoard, "A board link at launch keeps its project")
    model.selectProject("unknown")
    #expect(model.project == nil)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func aStoppedBackendIdlesTheBoardTabAndKeepsIt() async throws {
    let root = makeRoot()
    let model = await connectedDashboard(root, ProjectPageActions(), projects: [jiraProject("web", key: "WEB")])
    model.boardProjectIDs = ["web"]
    model.connectBoards(BoardFixture())
    root.navigate(to: .overview)
    model.selectProject("web"); model.selectTab(.board)
    let board = try #require(model.board)
    #expect(board.active)
    model.connectBoards(nil)
    #expect(!board.active && model.board === board, "A stopped backend idles the board and keeps its filters")
    model.connectBoards(BoardFixture())
    #expect(board.active)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectSummariesFollowTheirSources() async throws {
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(),
        projects: [jiraProject("web", key: "WEB")], tickets: [ticketRow("WEB-1")])
    while model.tickets.rows.isEmpty { await Task.yield() }
    #expect(model.projectSummaries.first?.tickets == 1)
    model.sessionCounts = ["web": 2]
    #expect(model.projectSummaries.first?.sessions == 2)
    model.retire()
}
