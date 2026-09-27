import Foundation
import Testing

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
    let ticket = Ticket(key: "REC-1", summary: "Login crash")
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
