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
    model.selectTicketProject("web")
    #expect(Set(model.tickets.screenRows.map(\.id)) == ["WEB-1", "WEB-2"])
    #expect(model.tickets.pageCounts[.all] == 2 && model.tickets.counts[.all] == 3, "The overview tile still counts every ticket")
    model.selectTicketProject(nil)
    #expect(model.tickets.screenRows.count == 3)
}

@MainActor @Test(.timeLimit(.minutes(1))) func ticketsShowOnlyTheTrackedProjects() async throws {
    // "web" lists two keys, the way the project field allows; "OTHER" belongs to no project.
    let model = await connectedDashboard(makeRoot(), ProjectPageActions(),
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

@MainActor @Test(.timeLimit(.minutes(1))) func overviewEntriesOpenWhatTheyCountWhileTheTabKeepsItsPlace() async throws {
    let root = makeRoot()
    let model = await connectedDashboard(root, ProjectPageActions(),
        projects: [jiraProject("web", key: "WEB"), jiraProject("ops", key: "OPS")],
        tickets: [ticketRow("WEB-1"), ticketRow("OPS-2")])
    root.navigate(to: .overview)
    model.showTickets(); model.selectTicketProject("ops")
    // The Tickets tab returns to My Tickets as it was left.
    root.navigate(to: .overview); model.selectTab(.tickets)
    #expect(model.tickets.project?.id == "ops")
    // An overview badge opens the list it counts: every project, under its tag.
    root.navigate(to: .overview); model.showTickets(.urgent)
    #expect(model.tickets.project == nil && model.tickets.filter == .urgent)
    // The pull request tiles likewise open every project's, unfiltered.
    model.selectTab(.pullRequests); model.prs.project = "web"; model.prs.filter = .failing
    model.showPullRequests(.review)
    #expect(model.prs.author == .review && model.prs.project == nil && model.prs.filter == .all)
}

// MARK: - The project's Board tab

private func boardProject(key: String? = "WEB", enabled: Bool? = true) -> Project {
    Project(id: "web", name: "Web", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: key, boardEnabled: enabled)
}

@MainActor private func boardPage(_ project: Project, actions: ProjectPageActions = ProjectPageActions()) -> ProjectPageViewModel {
    let editor = ProjectEditorViewModel(project: project, service: ProjectPageService(), chooseFolder: { nil })
    return ProjectPageViewModel(project: project, editor: editor,
                                composer: ProjectComposerModel(project: project, agent: .claude, operations: nil), pageActions: actions)
}

@MainActor @Test func theBoardTabIsOfferedOnlyWhenTurnedOnForAJiraProject() {
    #expect(boardPage(boardProject()).sections == [.start, .board, .orchestration, .settings])
    #expect(!boardPage(boardProject(enabled: false)).sections.contains(.board))
    #expect(!boardPage(boardProject(enabled: nil)).sections.contains(.board), "An older backend reads as off")
    #expect(!boardPage(boardProject(key: nil)).sections.contains(.board), "A board needs a Jira key")
    let off = boardPage(boardProject(enabled: false))
    off.connectBoard(BoardFixture())
    off.selectSection(.board)
    #expect(off.section == .start && off.board == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func theBoardRunsOnlyWhileItsTabIsShownAndFollowsTheToggle() throws {
    let root = makeRoot()
    root.appearance = .dark
    let model = boardPage(boardProject())
    #expect(model.board == nil, "No board before a backend connects")
    model.connectBoard(BoardFixture())
    root.installProject(model, runtime: nil)
    let board = try #require(model.board)
    #expect(board.projectID == "web" && !board.active && board.appearance == .dark)
    root.navigate(to: .project("web"))
    #expect(!board.active, "Start is showing, not the board")
    model.selectSection(.board)
    #expect(board.active)
    root.appearance = .light
    #expect(board.appearance == .light)
    root.navigate(to: .terminal)
    #expect(!board.active)
    root.navigate(to: .project("web"))
    #expect(board.active, "The project returns to the tab it was left on")
    model.connectBoard(nil)
    #expect(!board.active && model.board === board, "A stopped backend idles the board and keeps it")
    model.connectBoard(BoardFixture())
    #expect(board.active)
    // Turning the board off retires it and leaves the page on Start; turning it on builds anew.
    model.update(boardProject(enabled: false))
    #expect(board.retired && model.board == nil && model.section == .start && !model.sections.contains(.board))
    model.update(boardProject())
    let rebuilt = try #require(model.board)
    #expect(rebuilt !== board && !rebuilt.active)
    root.projectCoordinators["web"]?.retire()
    #expect(rebuilt.retired && !rebuilt.active && model.board == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectBoardCardOpensAreGatedByTheCoordinator() async throws {
    let root = makeRoot(), actions = ProjectPageActions()
    let model = boardPage(boardProject(), actions: actions)
    model.connectBoard(BoardFixture())
    // The coordinator holds its runtime weakly, so the test keeps it.
    let runtime = ProjectPageRuntime()
    let coordinator = root.installProject(model, runtime: runtime)
    root.navigate(to: .project("web")); model.selectSection(.board)
    let board = try #require(model.board)
    while board.siteURL == nil || board.tickets.isEmpty { await Task.yield() }
    let ticket = try #require(board.tickets.first)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.navigated == ["https://jira.example.test/browse/WEB-1"] && actions.opened.last?.projectID == "web")
    coordinator.canPresent = { false }
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.opened.count == 1, "A blocked project page stays silent")
    coordinator.canPresent = { true }
    model.selectSection(.settings)
    board.open(ticket); await board.navigation.waitForOpen()
    #expect(actions.opened.count == 1, "A board that is not shown opens nothing")
    model.selectSection(.board)
    board.openSession(ticket); await board.navigation.waitForOpen()
    #expect(actions.opened.count == 2 && actions.opened.last?.inSession == true)
    coordinator.retire()
    board.show(appearance: .system); board.open(ticket)
    #expect(board.retired && !board.active && actions.opened.count == 2)
}

@MainActor @Test func boardURLsOpenTheirProject() throws {
    let link = try #require(CascadeRouter().deepLink(for: URL(string: "cascade://app/projects/ops/board")!))
    #expect(link.destination == .project("ops") && link.droppingFirst().first == .projectBoard(projectID: "ops"))
    #expect(DeepLink([.destination(.terminal), .projectBoard(projectID: "ops")]).destination == nil)
}
