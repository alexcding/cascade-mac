import Foundation
import Testing

@MainActor private func ticketProject(_ actions: ProjectPageActions) async throws -> (ProjectPageViewModel, JiraFixture) {
    let service = JiraFixture()
    let project = Project(id: "ticket-actions", name: "Tickets", repo: "fixture/repo", color: nil, workspace: "/tmp", jiraProjectKey: "REC")
    let base = URL(string: "http://127.0.0.1:1")!, api = try APIClient(baseURL: base)
    let factory = NativeProjectFeatureFactory(creation: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = factory.project(project, services: .init(projects: ProjectPageService(), tickets: service,
        workflows: APIWorkflowService(api: api), automation: APIAutomationService(api: api), api: api, baseURL: base), openPage: actions.openPage)
    let tickets = try #require(model.tickets)
    tickets.refresh()
    while tickets.baseURL == nil || tickets.loading { await Task.yield() }
    return (model, service)
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectTicketCallbacksRespectOwnershipSectionsAndModalGuards() async throws {
    let actions = ProjectPageActions(), (model, _) = try await ticketProject(actions)
    let tickets = try #require(model.tickets), ticket = try #require(tickets.rows.first)
    let runtime = ProjectPageRuntime(), root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installProject(model, runtime: runtime)
    tickets.open(ticket); tickets.openSession(ticket); await tickets.navigation.waitForOpen()
    #expect(actions.opened.isEmpty)
    root.navigate(to: .project(model.project.id))
    tickets.openSession(ticket); await tickets.navigation.waitForOpen() // PR section cannot accept hidden ticket actions.
    #expect(actions.opened.isEmpty)
    model.selectSection(.tickets)
    tickets.open(ticket); await tickets.navigation.waitForOpen()
    #expect(actions.opened.first?.kind == "jira" && actions.opened.first?.title == "REC-1 Login crash")
    #expect(actions.opened.first?.inSession == false)
    tickets.openSession(ticket); await tickets.navigation.waitForOpen()
    #expect(actions.opened.count == 2 && actions.opened.last?.inSession == true && actions.opened.last?.projectID == "ticket-actions")
    #expect(actions.opened.last?.url == "https://jira.example.test/browse/REC-1")
    tickets.openSession(JiraTicket(key: "FOREIGN-99")); await tickets.navigation.waitForOpen()
    #expect(actions.opened.count == 2)
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    tickets.open(ticket); tickets.openSession(ticket); await tickets.navigation.waitForOpen()
    #expect(actions.opened.count == 2)
    root.dismissSheet(id: try #require(root.sheet).id)
    runtime.owns = false; tickets.openSession(ticket); await tickets.navigation.waitForOpen()
    #expect(actions.opened.count == 2, "An unowned page refuses ticket actions")
    child.retire(); await tickets.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["leave", "dialog", "section", "disconnect", "retire", "filter", "site"])
func projectTicketNavigationCancelsWithoutClearingDrafts(change: String) async throws {
    let actions = ProjectPageActions(), (model, service) = try await ticketProject(actions)
    let tickets = try #require(model.tickets), ticket = try #require(tickets.rows.first)
    let runtime = ProjectPageRuntime(), root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installProject(model, runtime: runtime)
    root.navigate(to: .project(model.project.id)); model.selectSection(.tickets)
    tickets.query = "Unsaved search"; model.editor.draft.name = "Unsaved project"
    let gate = ProjectPageGate(); actions.gate = gate
    tickets.open(ticket); tickets.open(ticket); await gate.waitForStart()
    #expect(actions.opened.count == 1)
    switch change {
    case "leave": root.navigate(to: .overview)
    case "dialog": root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    case "section": model.selectSection(.board)
    case "disconnect": await tickets.stop()
    case "filter": tickets.setFilterText("Completed")
    case "site": await tickets.invalidateSite()
    default: child.retire()
    }
    #expect(tickets.navigation.opening == nil)
    await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated.isEmpty && tickets.navigation.error == nil)
    #expect(tickets.query == "Unsaved search" && model.editor.draft.name == "Unsaved project")
    child.retire(); tickets.connect(service); tickets.open(ticket); tickets.refresh()
    #expect(tickets.retired && actions.opened.count == 1)
    await tickets.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectTicketNavigationErrorsAndSupersedingOpensStaySeparateFromMutations() async throws {
    let actions = ProjectPageActions(), (model, service) = try await ticketProject(actions)
    let tickets = try #require(model.tickets), first = tickets.rows[0], second = tickets.rows[1]
    let child = ProjectCoordinator(model: model); model.selectSection(.tickets)
    await service.reject(true); await tickets.transition(first, to: "Blocked")
    let gate = ProjectPageGate(); actions.gate = gate
    tickets.open(first); await gate.waitForStart()
    tickets.open(second); await tickets.navigation.waitForOpen()
    await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated == ["https://jira.example.test/browse/REC-2"])
    #expect(tickets.navigation.error == nil && tickets.error == "Transition rejected")
    actions.failOpen = true; tickets.open(first); await tickets.navigation.waitForOpen()
    #expect(tickets.navigation.error?.contains("Fixture open failed") == true && tickets.error == "Transition rejected")
    actions.failOpen = false; tickets.open(first); await tickets.navigation.waitForOpen()
    #expect(tickets.navigation.error == nil)
    child.retire(); await tickets.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func jiraTicketOpenEmitsTheResolvedRequestAndSkipsRowsNoLongerShown() async throws {
    let actions = ProjectPageActions(), (model, _) = try await ticketProject(actions)
    let tickets = try #require(model.tickets), ticket = try #require(tickets.rows.first { $0.key == "REC-1" })
    var emitted: [JiraTicketsViewModel.Action] = []
    tickets.onAction = { emitted.append($0) }
    tickets.open(ticket, inTab: true)
    tickets.openSession(ticket, agent: .claude)
    var tab = OpenPageRequest(url: "https://jira.example.test/browse/REC-1", kind: "jira", title: "REC-1 Login crash")
    tab.projectID = model.project.id; tab.inTab = true
    var session = tab; session.inTab = false; session.inSession = true; session.agent = .claude
    #expect(emitted == [.open(tab), .open(session)])
    // A key these rows no longer hold resolves to nothing, so nothing reaches the coordinator.
    emitted = []
    tickets.open(JiraTicket(key: "FOREIGN-99")); tickets.openSession(JiraTicket(key: "FOREIGN-99"))
    #expect(emitted.isEmpty)
    await tickets.stop()
}

private struct BoardTicketActionService: BoardService {
    var configured = true
    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot { BoardSnapshot(items: []) }
    func site() async throws -> JiraSite { JiraSite(baseUrl: configured ? "https://jira.example.test" : "") }
    func settings() async throws -> [String: String] { [:] }
    func saveFilter(_ value: String, projectID: String) async throws {}
    func saveQuery(_ value: String, projectID: String) async throws {}
    func transition(key: String, status: String) async throws {}
    func assign(key: String, assignee: String) async throws {}
}

@MainActor @Test(.timeLimit(.minutes(1))) func webBoardOpenEmitsTheResolvedRequestAndSkipsWithNoConfiguredSite() async throws {
    let actions = ProjectPageActions()
    let board = WebBoardViewModel(projectID: "board-actions", service: BoardTicketActionService(), pageActions: actions)
    board.active = true
    while board.loading { await Task.yield() }
    var emitted: [WebBoardViewModel.Action] = []
    board.onAction = { emitted.append($0) }
    let ticket = JiraTicket(key: "REC-1", summary: "Login crash")
    board.open(ticket, inTab: true)
    board.openSession(ticket, agent: .claude)
    var tab = OpenPageRequest(url: "https://jira.example.test/browse/REC-1", kind: "jira", title: "REC-1")
    tab.projectID = "board-actions"; tab.inTab = true
    var session = tab; session.inTab = false; session.inSession = true; session.agent = .claude
    #expect(emitted == [.open(tab), .open(session)])
    // No configured Jira site resolves to nothing, so nothing reaches the coordinator.
    emitted = []
    let unconfigured = WebBoardViewModel(projectID: "board-actions", service: BoardTicketActionService(configured: false), pageActions: actions)
    unconfigured.active = true
    while unconfigured.loading { await Task.yield() }
    unconfigured.onAction = { emitted.append($0) }
    unconfigured.open(ticket); unconfigured.openSession(ticket)
    #expect(emitted.isEmpty && unconfigured.error == "Configure the Jira site before opening a ticket.")
}

@MainActor @Test(.timeLimit(.minutes(1))) func webBoardCallbacksAreOwnedAndRejectSuspendedRetiredOrForeignLinks() async throws {
    let actions = ProjectPageActions(), (model, _) = try await ticketProject(actions)
    let board = try #require(model.board)
    let child = ProjectCoordinator(model: model)
    let link = BoardTicketLink(type: "openTicket", url: "https://jira.example.test/browse/REC-1", title: "REC-1 Board ticket", external: false)
    board.request(link)
    #expect(actions.opened.isEmpty)
    model.active = true
    board.show(appearance: .system)
    board.request(link) // Still in PR section.
    #expect(actions.opened.isEmpty)
    model.selectSection(.board)
    child.canPresent = { false }; board.request(link)
    #expect(actions.opened.isEmpty)
    child.canPresent = { true }
    let gate = ProjectPageGate(); actions.gate = gate
    board.request(link); board.request(link); await gate.waitForStart()
    #expect(actions.opened.count == 1)
    board.suspend(); await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated.isEmpty && board.navigation.error == nil)
    board.show(appearance: .system)
    board.request(.init(type: "openTicket", url: "file:///tmp/secret", title: "Invalid", external: true))
    #expect(actions.opened.count == 1, "A non-web address is refused, external or not")
    board.request(link); await board.navigation.waitForOpen()
    #expect(actions.opened.last?.title == link.title && actions.navigated == [link.url])
    board.pause(); board.request(link)
    #expect(actions.opened.count == 2)
    child.retire(); board.connect(api: try APIClient(baseURL: URL(string: "http://127.0.0.1:2")!)); board.show(appearance: .system); board.request(link)
    #expect(board.retired && !board.active && actions.opened.count == 2)
    await model.tickets?.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectBoardStateFollowsRootAndSectionWithoutViewCallbacks() async throws {
    let actions = ProjectPageActions(), (model, _) = try await ticketProject(actions)
    let board = try #require(model.board), runtime = ProjectPageRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    root.appearance = .dark
    let child = root.installProject(model, runtime: runtime)
    model.selectSection(.board)
    #expect(!model.active && !board.active && board.appearance == .dark)
    root.navigate(to: .project(model.project.id))
    #expect(model.active && board.active)
    root.navigate(to: .project(model.project.id)); model.selectSection(.board)
    root.appearance = .light
    #expect(board.active && board.appearance == .light)
    let gate = ProjectPageGate(); actions.gate = gate
    let link = BoardTicketLink(type: "openTicket", url: "https://jira.example.test/browse/REC-1", title: "REC-1", external: false)
    board.request(link); await gate.waitForStart()
    root.navigate(to: .overview)
    #expect(!board.active && board.navigation.opening == nil)
    await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated.isEmpty && board.navigation.error == nil)
    root.appearance = .dark
    #expect(!board.active && board.appearance == .dark)
    root.navigate(to: .project(model.project.id))
    #expect(board.active)
    model.selectSection(.prs)
    #expect(!board.active)
    model.selectSection(.board)
    child.retire(); model.active = true; model.appearance = .light
    #expect(board.retired && !board.active)
    await model.tickets?.stop()
}
