import Foundation
import Testing

private final class BoardFixture: BoardService, @unchecked Sendable {
    private let lock = NSLock()
    private var board: BoardSnapshot
    private var _snapshots = 0, _transitions: [String] = [], _queries: [String] = []
    var failTransitions = false

    init(_ board: BoardSnapshot) { self.board = board }
    var snapshots: Int { lock.withLock { _snapshots } }
    var transitions: [String] { lock.withLock { _transitions } }
    var queries: [String] { lock.withLock { _queries } }
    func replace(_ board: BoardSnapshot) { lock.withLock { self.board = board } }

    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot {
        lock.withLock { _snapshots += 1; return board }
    }
    func site() async throws -> JiraSite { JiraSite(baseUrl: "https://jira.test", me: JiraAccount(email: "ME@example.test")) }
    func settings() async throws -> [String: String] { [:] }
    func saveFilter(_ value: String, projectID: String) async throws {}
    func saveQuery(_ value: String, projectID: String) async throws { lock.withLock { _queries.append(value) } }
    func transition(key: String, status: String) async throws {
        lock.withLock { _transitions.append("\(key)→\(status)") }
        if failTransitions { throw BackendError.operation("Transition not allowed") }
    }
    func assign(key: String, assignee: String) async throws {}
}

private struct BoardPageActions: PageActionServing {
    func openPage(_ request: OpenPageRequest) async throws {}
    func openBrowser(_ url: URL) -> Bool { true }
}

private func ticket(_ key: String, _ status: String, _ statusId: String, category: String? = nil, email: String? = nil) -> JiraTicket {
    JiraTicket(key: key, summary: key, status: status, statusId: statusId, statusCategory: category, assigneeEmail: email)
}

/// "To Do" holds two statuses, "Done" one; REC-9 sits in a status no column claims.
private func configuredBoard() -> BoardSnapshot {
    BoardSnapshot(items: [ticket("REC-1", "Ready", "1", email: "me@example.test"), ticket("REC-2", "Doing", "3"), ticket("REC-9", "Parked", "9")],
                  sprint: BoardSprint(name: "Sprint 4"), query: "",
                  columns: [BoardColumn(name: "To Do", statusIds: ["1", "2"], statuses: [.init(id: "1", name: "Ready"), .init(id: "2", name: "Spec")]),
                            BoardColumn(name: "In Progress", statusIds: ["3"], statuses: [.init(id: "3", name: "Doing")])])
}

@MainActor private func loadedBoard(_ fixture: BoardFixture) async -> WebBoardViewModel {
    let model = WebBoardViewModel(projectID: "p", service: fixture, pageActions: BoardPageActions())
    model.active = true
    await settle(model)
    return model
}

@MainActor private func settle(_ model: WebBoardViewModel) async {
    while model.loading || !model.busy.isEmpty { await Task.yield() }
}

@Test func boardGroupsConfiguredColumnsIntoStatusLanesWithAnOtherBucket() {
    let groups = BoardGroup.build(configuredBoard().items, columns: configuredBoard().columns)
    #expect(groups.map(\.name) == ["To Do", "In Progress", "Other"])
    #expect(groups[0].lanes.map(\.status) == ["Ready", "Spec"] && groups[0].isGrouped && groups[0].total == 1)
    #expect(groups[0].lanes[1].tickets.isEmpty) // an empty status is still a drop zone
    #expect(!groups[1].isGrouped)
    #expect(groups[2].lanes.map(\.status) == [""] && groups[2].lanes[0].tickets.map(\.key) == ["REC-9"])
}

@Test func boardWithoutConfigOrdersStatusesByWorkflowCategory() {
    let items = [ticket("A-1", "Shipped", "5", category: "done"), ticket("A-2", "Review", "4", category: "indeterminate"),
                 ticket("A-3", "Backlog", "1", category: "new"), ticket("A-4", "Blocked", "6")]
    #expect(BoardGroup.build(items, columns: nil).map(\.name) == ["Backlog", "Blocked", "Review", "Shipped"])
}

@MainActor @Test(.timeLimit(.minutes(1))) func boardDisplayListsFollowFiltersColumnsAndReplacementSnapshots() async {
    var board = configuredBoard()
    board.items[0].assigneeId = "z"; board.items[0].assignee = "Zoe"
    board.items[1].assigneeId = "a"; board.items[1].assignee = "Alice"
    let fixture = BoardFixture(board), model = await loadedBoard(fixture)
    #expect(model.assignees.map(\.name) == ["Alice", "Zoe"])
    #expect(model.columns == ["Ready", "Spec", "Doing", "Parked"])
    model.setAssigneeFilter("z")
    #expect(model.tickets.map(\.key) == ["REC-1"] && model.groups[0].total == 1)
    model.setAssigneeFilter(WebBoardViewModel.unassigned)
    #expect(model.tickets.map(\.key) == ["REC-9"] && model.showsUnassignedFilter)
    model.setAssigneeFilter("")
    #expect(model.tickets.count == 3)

    // Column-only changes must regroup unchanged tickets too.
    board.columns = [BoardColumn(name: "Combined", statusIds: ["1", "2", "3"])]
    fixture.replace(board); model.refresh(); await settle(model)
    #expect(model.groups.map(\.name) == ["Combined", "Other"] && model.groups[0].total == 2)
    fixture.replace(BoardSnapshot(items: [])); model.refresh(); await settle(model)
    #expect(model.items.isEmpty && model.tickets.isEmpty && model.groups.isEmpty)
    #expect(model.assignees.isEmpty && model.columns.isEmpty && !model.showsUnassignedFilter)
    model.retire()
}

@Test func sprintBusinessDaysSkipWeekends() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let friday = try #require(ISO8601DateFormatter().date(from: "2026-09-18T09:00:00Z"))
    #expect(WebBoardViewModel.businessDays(until: "2026-09-22T17:00:00.000Z", from: friday, calendar: calendar) == 2)
    #expect(WebBoardViewModel.businessDays(until: "2026-09-18", from: friday, calendar: calendar) == 0)
    #expect(WebBoardViewModel.businessDays(until: "not a date", from: friday, calendar: calendar) == 0)
    // A date-only end date is the local day, even west of UTC.
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    #expect(WebBoardViewModel.businessDays(until: "2026-09-22", from: friday, calendar: calendar) == 2)
}

@MainActor @Test(.timeLimit(.minutes(1))) func boardMovesCardsAtOnceAndHoldsThemUntilJiraCatchesUp() async {
    let fixture = BoardFixture(configuredBoard()), model = await loadedBoard(fixture)
    var clock = Date()
    model.now = { clock }
    #expect(model.isMine(model.items[0]) && !model.isMine(model.items[1]))
    let card = model.items[0], spec = model.groups[0].lanes[1]
    model.beginDrag(card)
    #expect(model.draggingKey == "REC-1")
    #expect(model.drop("REC-1", on: spec))
    #expect(model.draggingKey == nil)
    #expect(model.groups[0].lanes[1].tickets.map(\.key) == ["REC-1"]) // moved before Jira answered
    await settle(model)
    #expect(fixture.transitions == ["REC-1→Spec"] && model.notice == "REC-1 → Spec")
    // The re-sync still reports the old status (search lag): the card stays put.
    #expect(model.items[0].status == "Spec")
    // Once Jira reports the move, the overlay is released.
    var confirmed = configuredBoard(); confirmed.items[0].status = "Spec"; confirmed.items[0].statusId = "2"
    fixture.replace(confirmed); model.refresh(); await settle(model)
    #expect(model.pendingMoves.isEmpty && model.items[0].status == "Spec")
    // An unconfirmed move expires after five minutes.
    model.move(model.items[1], to: "Ready"); await settle(model)
    #expect(model.items[1].status == "Ready")
    clock += PendingBoardMove.lifetime + 1
    model.refresh(); await settle(model)
    #expect(model.items[1].status == "Doing")
}

@MainActor @Test(.timeLimit(.minutes(1))) func boardPutsAFailedMoveBackAndRefusesUnmappedDrops() async {
    let fixture = BoardFixture(configuredBoard()), model = await loadedBoard(fixture)
    fixture.failTransitions = true
    model.move(model.items[0], to: "Doing")
    #expect(model.items[0].status == "Doing")
    await settle(model)
    #expect(model.items[0].status == "Ready" && model.pendingMoves.isEmpty && model.error == "Transition not allowed")

    let other = model.groups[2].lanes[0], ready = model.groups[0].lanes[0]
    model.beginDrag(model.items[1])
    #expect(!model.drop("REC-2", on: other))
    #expect(model.error == WebBoardViewModel.unmappedDrop && model.draggingKey == nil)
    // Dropping back where the card came from is a no-op.
    #expect(model.drop("REC-1", on: ready))
    #expect(fixture.transitions == ["REC-1→Doing"])
}

@MainActor @Test(.timeLimit(.minutes(1))) func boardHoldsRefreshesUntilTheDragEnds() async {
    let fixture = BoardFixture(configuredBoard()), model = await loadedBoard(fixture)
    let before = fixture.snapshots
    model.beginDrag(model.items[0])
    model.target(model.groups[0].lanes[1], true)
    #expect(model.dropTarget == "2")
    model.refresh(); model.refresh(force: true)
    #expect(!model.loading && fixture.snapshots == before)
    // A watcher from an earlier drag of the same card can't end this one.
    let first = model.dragID
    model.endDrag(); model.beginDrag(model.items[0])
    #expect(model.dragID != first && model.draggingKey == "REC-1")
    model.endDrag(first)
    #expect(model.draggingKey == "REC-1")
    model.endDrag(model.dragID)
    #expect(model.dropTarget == nil && model.draggingKey == nil)
    await settle(model)
    #expect(fixture.snapshots == before + 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func boardExplainsAnEmptyBoardAndSavesTheQuery() async {
    var empty = configuredBoard(); empty.items = []
    let fixture = BoardFixture(empty), model = await loadedBoard(fixture)
    #expect(model.emptyMessage == "No active sprint, or no tickets in it.")
    model.queryDraft = "  component = iOS "
    model.applyQuery()
    while fixture.queries.isEmpty || model.notice == nil { await Task.yield() }
    await settle(model)
    #expect(fixture.queries == ["component = iOS"] && model.notice == "Jira filter saved")

    empty.query = "component = iOS"; fixture.replace(empty)
    model.refresh(); await settle(model)
    #expect(model.emptyMessage == "No tickets match “component = iOS” in the active sprint.")
    fixture.replace(configuredBoard()); model.refresh(); await settle(model)
    model.setAssigneeFilter("nobody")
    #expect(model.emptyMessage == "No tickets match this filter.")
    #expect(model.sprintTitle == "Sprint 4")
}
