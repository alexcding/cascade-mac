import Foundation
import Testing

@MainActor private func ticketProject(_ actions: ProjectPageActions) async throws -> (ProjectPageViewModel, JiraFixture) {
    let service = JiraFixture()
    let project = Project(id: "ticket-actions", name: "Tickets", repo: "fixture/repo", color: nil, workspace: "/tmp", jiraProjectKey: "REC")
    let base = URL(string: "http://127.0.0.1:1")!, api = try APIClient(baseURL: base)
    let factory = NativeProjectFeatureFactory(creation: NativeCreationFlowFactory(chooseFolder: { nil }), copy: actions.copyLink)
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
    tickets.open(ticket); tickets.copyLink(ticket)
    #expect(actions.opened.isEmpty && actions.copied.isEmpty)
    root.navigate(to: .project(model.project.id))
    tickets.copyLink(ticket) // PR section cannot accept hidden ticket actions.
    #expect(actions.copied.isEmpty)
    model.selectSection(.tickets)
    tickets.copyLink(ticket)
    tickets.open(ticket); await tickets.navigation.waitForOpen()
    #expect(actions.opened.first?.kind == "jira" && actions.opened.first?.title == "REC-1 Login crash")
    #expect(actions.copied == ["https://jira.example.test/browse/REC-1"])
    tickets.copyLink(JiraTicket(key: "FOREIGN-99"))
    #expect(actions.copied.count == 1)
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    tickets.open(ticket); tickets.copyLink(ticket)
    #expect(actions.opened.count == 1 && actions.copied.count == 1)
    root.dismissSheet(id: try #require(root.sheet).id)
    runtime.owns = false; tickets.copyLink(ticket)
    #expect(actions.copied.count == 1, "An unowned page refuses ticket actions")
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
    case "filter": tickets.filterText = "Completed"
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
