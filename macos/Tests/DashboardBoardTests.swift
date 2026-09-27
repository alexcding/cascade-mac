import Foundation
import Testing

/// A dashboard backend with Jira: projects and the user's tickets, plus a board service whose
/// requests go nowhere, since these tests drive the board's presentation, not its data.
private struct BoardDashboardFixture: DashboardService, DashboardTicketService, DashboardBoardSource {
    var projects: [DashboardProject]
    var tickets: [DashboardTicketRow] = []
    func snapshot() async throws -> [DashboardProject] { projects }
    func myTickets() async throws -> [DashboardTicketRow] { tickets }
    var boardService: any BoardService { BoardFixture() }
}

/// One sprint with one ticket, on a Jira site, so a card can resolve its link.
private struct BoardFixture: BoardService {
    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot {
        try JSONDecoder().decode(BoardSnapshot.self, from: Data(#"{"items":[{"key":"WEB-1","summary":"Login","status":"To Do"}]}"#.utf8))
    }
    func site() async throws -> JiraSite { JiraSite(baseUrl: "https://jira.example.test") }
    func settings() async throws -> [String: String] { [:] }
    func saveFilter(_ value: String, projectID: String) async throws {}
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

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "dashboard-board-\(UUID().uuidString)")! }

@MainActor private func connectedDashboard(_ root: AppCoordinator, _ actions: ProjectPageActions, _ defaults: UserDefaults,
                                           projects: [DashboardProject], tickets: [DashboardTicketRow] = []) async -> DashboardViewModel {
    let model = DashboardViewModel(pageActions: actions, defaults: defaults)
    root.installDashboard(model)
    model.connect(BoardDashboardFixture(projects: projects, tickets: tickets))
    while model.prs.loading || model.tickets.loading || model.prs.projects.isEmpty { await Task.yield() }
    return model
}

@MainActor private func makeRoot() -> AppCoordinator { AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })) }

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardBoardRunsOnlyAsTheShownTicketsBoardAndFollowsAppearance() async throws {
    let root = makeRoot(), actions = ProjectPageActions()
    root.appearance = .dark
    let model = await connectedDashboard(root, actions, freshDefaults(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("plain"), jiraProject("ops", key: "OPS")])
    // Only Jira projects get a board.
    #expect(model.board.projects.map(\.id) == ["web", "ops"])
    let board = try #require(model.board.board)
    #expect(board.projectID == "web" && !board.active && board.appearance == .dark)
    root.navigate(to: .overview); model.showTickets()
    #expect(model.ticketsShown && !board.active, "The list is showing, not the board")
    model.setTicketsMode(.board)
    #expect(!board.active, "Every project is picked, so no board is drawn or loaded")
    model.selectTicketProject("web")
    #expect(board.active)
    root.appearance = .light
    #expect(board.appearance == .light)
    root.navigate(to: .terminal)
    #expect(!board.active)
    root.navigate(to: .overview)
    #expect(!model.ticketsShown && !board.active, "Overview lands on the Dashboard's home")
    model.selectTab(.tickets)
    #expect(board.active, "The Tickets tab returns to the board it was left on")
    root.dashboardCoordinator?.retire()
    #expect(board.retired && !board.active)
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardBoardSwitchesProjectsRemembersThePickAndSharesItWithTheList() async throws {
    let defaults = freshDefaults(), actions = ProjectPageActions()
    let projects = [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS"), jiraProject("data", key: "DATA")]
    let model = await connectedDashboard(makeRoot(), actions, defaults, projects: projects)
    let first = try #require(model.board.board)
    model.setTicketsMode(.board)
    model.selectTicketProject("ops")
    let second = try #require(model.board.board)
    #expect(first.retired && second !== first && second.projectID == "ops")
    #expect(model.tickets.project?.id == "ops", "The list follows the board's project")
    // A board has no "every project"; the list does.
    #expect(model.ticketProjects.map(\.id) == ["web", "ops", "data"])
    model.setTicketsMode(.list)
    #expect(model.ticketProjects.map(\.id) == ["web", "ops", "data"])
    model.selectTicketProject(nil)
    #expect(model.tickets.project == nil && model.board.project?.id == "ops")
    // The next launch opens the board on the project picked last.
    let again = await connectedDashboard(makeRoot(), actions, defaults, projects: projects)
    #expect(again.board.project?.id == "ops")
    // A project that loses Jira gives way to the first one left.
    model.board.update(projects: [projects[0], jiraProject("ops"), projects[2]])
    #expect(model.board.project?.id == "web" && second.retired)
}

@MainActor @Test(.timeLimit(.minutes(1))) func ticketsListNarrowsToAProjectByJiraKey() async throws {
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(), freshDefaults(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")],
        tickets: [ticketRow("WEB-1"), ticketRow("OPS-7"), ticketRow("WEB-2")])
    #expect(model.tickets.screenRows.count == 3 && model.tickets.pageCounts[.all] == 3)
    model.selectTicketProject("web")
    #expect(Set(model.tickets.screenRows.map(\.id)) == ["WEB-1", "WEB-2"])
    #expect(model.tickets.pageCounts[.all] == 2 && model.tickets.counts[.all] == 3, "The overview tile still counts every ticket")
    model.selectTicketProject(nil)
    #expect(model.tickets.screenRows.count == 3)
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardBoardCardOpensAreGatedByTheCoordinator() async throws {
    let root = makeRoot(), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions, freshDefaults(), projects: [jiraProject("web", key: "WEB")])
    let board = try #require(model.board.board)
    root.navigate(to: .overview); model.showTickets(); model.setTicketsMode(.board); model.selectTicketProject("web")
    while board.siteURL == nil || board.tickets.isEmpty { await Task.yield() }
    let ticket = try #require(board.tickets.first)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.navigated == ["https://jira.example.test/browse/WEB-1"] && actions.opened.last?.projectID == "web")
    root.dashboardCoordinator?.canPresent = { false }
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.opened.count == 1, "A blocked dashboard stays silent")
    root.dashboardCoordinator?.canPresent = { true }
    model.setTicketsMode(.list)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.opened.count == 1, "A board that is not shown opens nothing")
    model.setTicketsMode(.board)
    board.openSession(ticket); await board.navigation.waitForOpen()
    #expect(actions.opened.count == 2 && actions.opened.last?.inSession == true)
    root.dashboardCoordinator?.retire()
    board.show(appearance: .system); board.open(ticket)
    #expect(board.retired && !board.active && actions.opened.count == 2)
}

@MainActor @Test(.timeLimit(.minutes(1))) func ticketsShowOnlyTheTrackedProjects() async throws {
    // "web" lists two keys, the way the project field allows; "OTHER" belongs to no project.
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(), freshDefaults(),
        projects: [jiraProject("web", key: "WEB, www"), jiraProject("plain")],
        tickets: [ticketRow("WEB-1"), ticketRow("OTHER-3"), ticketRow("WWW-2")])
    while model.tickets.rows.isEmpty { await Task.yield() }
    #expect(Set(model.tickets.rows.map(\.id)) == ["WEB-1", "WWW-2"])
    #expect(model.tickets.counts[.all] == 2 && model.tickets.screenRows.count == 2)
    // Removing the project's key drops its tickets everywhere, the overview's count included.
    model.tickets.projects = [jiraProject("web"), jiraProject("plain")]
    #expect(model.tickets.rows.isEmpty && model.tickets.counts[.all] == 0)
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

@MainActor @Test(.timeLimit(.minutes(1))) func boardLinkOpensTheDashboardBoardOnItsProjectEvenBeforeProjectsLoad() async throws {
    let root = makeRoot(), actions = ProjectPageActions()
    let model = DashboardViewModel(pageActions: actions, defaults: freshDefaults())
    root.installDashboard(model)
    // The link lands before the snapshot: the board takes the project once it arrives.
    root.navigate(to: .dashboardBoard(projectID: "ops"))
    #expect(root.selection == .overview && model.ticketsShown && model.ticketsMode == .board)
    model.connect(BoardDashboardFixture(projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")]))
    while model.prs.loading || model.prs.projects.isEmpty { await Task.yield() }
    #expect(model.board.project?.id == "ops" && model.board.board?.active == true)
    // Once loaded, a link switches straight to its project.
    root.navigate(to: .dashboardBoard(projectID: "web"))
    #expect(model.board.project?.id == "web")
}

@MainActor @Test func boardURLsAreAcceptedAsWholeLinks() throws {
    let link = try #require(CascadeRouter().deepLink(for: URL(string: "cascade://app/projects/ops/board")!))
    #expect(link.destination == .overview && link.droppingFirst().first == .dashboardBoard(projectID: "ops"))
    // Only the Dashboard carries a board; the pair is not valid under any other screen.
    #expect(DeepLink([.destination(.terminal), .dashboardBoard(projectID: "ops")]).destination == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func overviewEntriesOpenWhatTheyCountWhileTheTabKeepsItsPlace() async throws {
    let root = makeRoot()
    let model = await connectedDashboard(root, ProjectPageActions(), freshDefaults(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")],
        tickets: [ticketRow("WEB-1"), ticketRow("OPS-2")])
    root.navigate(to: .overview)
    model.showTickets(); model.setTicketsMode(.board); model.selectTicketProject("ops")
    // The Tickets tab returns to My Tickets as it was left.
    root.navigate(to: .overview); model.selectTab(.tickets)
    #expect(model.ticketsMode == .board && model.tickets.project?.id == "ops" && model.board.active)
    // An overview badge opens the list it counts: every project, under its tag.
    root.navigate(to: .overview); model.showTickets(.urgent)
    #expect(model.ticketsMode == .list && model.tickets.project == nil && model.tickets.filter == .urgent && !model.board.active)
    #expect(model.board.project?.id == "ops", "The board keeps its own project for next time")
    // The pull request tiles likewise open every project's, unfiltered.
    model.selectTab(.pullRequests); model.prs.project = "web"; model.prs.filter = .failing
    model.showPullRequests(.review)
    #expect(model.prs.author == .review && model.prs.project == nil && model.prs.filter == .all)
}

@MainActor @Test(.timeLimit(.minutes(1))) func aBoardRequestForAProjectWithoutABoardLapsesOnceProjectsLoad() async throws {
    let board = DashboardBoardModel(pageActions: ProjectPageActions(), defaults: freshDefaults())
    board.select("plain")
    board.update(projects: [jiraProject("web", key: "WEB"), jiraProject("plain")])
    #expect(board.project?.id == "web")
    // "plain" gaining Jira later must not pull the board away from the one on screen.
    board.update(projects: [jiraProject("web", key: "WEB"), jiraProject("plain", key: "PLN")])
    #expect(board.project?.id == "web")
}

// The board and the list share one project picker with All Projects in it; a board shows one
// project, so with every project picked the page draws none, and the list's pick carries over.
@MainActor @Test(.timeLimit(.minutes(1))) func theBoardShowsOnlyForTheProjectThePageIsNarrowedTo() async throws {
    let projects = [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")]
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(), freshDefaults(), projects: projects)
    model.setTicketsMode(.board)
    #expect(model.ticketProjects.map(\.id) == ["web", "ops"])
    #expect(model.tickets.project == nil && model.shownBoard == nil)
    model.selectTicketProject("ops")
    #expect(model.shownBoard?.projectID == "ops")
    model.setTicketsMode(.list)
    model.setTicketsMode(.board)
    #expect(model.shownBoard?.projectID == "ops", "The list and board keep one pick")
    model.selectTicketProject(nil)
    #expect(model.shownBoard == nil)
}
