import Foundation
import Testing

// MARK: - Fixtures

/// A configurable pull request and ticket source, used wherever a test just needs a fixed
/// snapshot behind `connect`. `reads`/`ticketReads` let a retired-model test prove no call landed.
private actor ModelFixture: DashboardService, DashboardTicketService {
    var reads = 0
    var ticketReads = 0
    var projects: [DashboardProject]
    var tickets: [DashboardTicketRow]
    init(projects: [DashboardProject] = [], tickets: [DashboardTicketRow] = []) {
        self.projects = projects
        self.tickets = tickets
    }
    func snapshot() async throws -> [DashboardProject] { reads += 1; return projects }
    func myTickets() async throws -> [DashboardTicketRow] { ticketReads += 1; return tickets }
}

/// A snapshot source whose first call blocks until released, so a test can start it, start a
/// second call that finishes first, and only then let the first one land — proving a stale read
/// cannot overwrite what a newer one already published.
private actor SequencedSnapshot: DashboardService {
    private var startContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var started: Set<Int> = []
    private var proceedContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var proceeded: Set<Int> = []
    private var callCount = 0
    let results: [[DashboardProject]]
    init(_ results: [[DashboardProject]]) { self.results = results }

    func snapshot() async throws -> [DashboardProject] {
        callCount += 1
        let index = callCount
        markStarted(index)
        if index == 1 { await waitToProceed(index) }
        return results[index - 1]
    }
    func waitForStart(_ index: Int) async {
        if started.contains(index) { return }
        await withCheckedContinuation { startContinuations[index] = $0 }
    }
    func proceed(_ index: Int) {
        proceeded.insert(index)
        proceedContinuations[index]?.resume(); proceedContinuations[index] = nil
    }
    private func markStarted(_ index: Int) {
        started.insert(index)
        startContinuations[index]?.resume(); startContinuations[index] = nil
    }
    private func waitToProceed(_ index: Int) async {
        if proceeded.contains(index) { return }
        await withCheckedContinuation { proceedContinuations[index] = $0 }
    }
}

private func makePR(
    _ number: Int, category: String = "mine", state: String = "OPEN", url: String? = nil,
    ci status: String? = nil, conclusion: String? = nil, isDraft: Bool? = nil, reviewDecision: String? = nil,
    jiraKeys: [String]? = nil, createdAt: String? = nil, error: String? = nil, repo: String? = nil,
    author: String? = nil, awaitingMyReview: Bool? = nil, title: String? = nil
) -> DashboardPR {
    DashboardPR(number: number, title: title, url: url ?? "https://github.com/o/r/pull/\(number)", repo: repo, state: state,
        category: category, awaitingMyReview: awaitingMyReview, isDraft: isDraft, reviewDecision: reviewDecision,
        headRefName: nil, author: author.map { DashboardPR.Author(login: $0) }, createdAt: createdAt, labels: nil, jiraKeys: jiraKeys,
        ci: status.map { TrayPR.CI(status: $0, conclusion: conclusion) }, error: error)
}

private func makeProject(_ id: String, name: String = "Proj", repo: String = "o/r", prs: [DashboardPR],
                          lastSynced: String? = "2026-01-01T00:00:00Z", syncError: String? = nil) -> DashboardProject {
    DashboardProject(id: id, name: name, repo: repo, prs: prs, lastSynced: lastSynced, syncError: syncError)
}

private func rows(_ project: DashboardProject) -> [DashboardRow] {
    project.prs.compactMap { pr in
        guard let address = pr.url, let url = safeWebURL(address) else { return nil }
        return DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
    }
}

private func makeTicket(_ key: String, status: String, category: String? = nil, priority: String = "Medium",
                         summary: String? = nil, reporter: String? = nil) -> JiraTicket {
    JiraTicket(key: key, summary: summary ?? key, status: status, type: "Task", priority: priority,
               statusCategory: category, reporter: reporter)
}

private func makeTicketRow(_ ticket: JiraTicket) -> DashboardTicketRow {
    DashboardTicketRow(ticket: ticket, url: URL(string: "https://j/browse/\(ticket.key)")!)
}

// MARK: - DashboardPullRequestsModel

@MainActor @Test func deriveSortsRowsNewestFirstAndDropsDuplicatesNonOpenAndErrored() async throws {
    let json = """
    [{"id":"p1","name":"Alpha","repo":"o/a","lastSynced":"2026-01-01T00:00:00Z","syncError":null,"prs":[
      {"number":10,"title":"Newer mine","url":"https://github.com/o/a/pull/10","state":"OPEN","category":"mine","createdAt":"2026-01-05T00:00:00Z"},
      {"number":11,"title":"Older mine","url":"https://github.com/o/a/pull/11","state":"OPEN","category":"mine","createdAt":"2026-01-01T00:00:00Z"},
      {"number":12,"title":"Duplicate loses","url":"https://github.com/o/a/pull/11","state":"OPEN","category":"mine","createdAt":"2026-01-09T00:00:00Z"},
      {"number":13,"title":"Closed","url":"https://github.com/o/a/pull/13","state":"CLOSED","category":"mine"},
      {"number":14,"title":"Errored","url":"https://github.com/o/a/pull/14","state":"OPEN","category":"mine","error":"boom"},
      {"number":15,"title":"Unsafe","url":"file:///tmp/x","state":"OPEN","category":"mine"}
    ]},
    {"id":"p2","name":"Beta","repo":"o/b","lastSynced":"2026-01-01T00:00:00Z","prs":[
      {"number":20,"title":"Newer review","url":"https://github.com/o/b/pull/20","state":"OPEN","category":"review","createdAt":"2026-01-08T00:00:00Z"},
      {"number":21,"title":"Older review","url":"https://github.com/o/b/pull/21","state":"OPEN","category":"review","createdAt":"2026-01-02T00:00:00Z"}
    ]}]
    """
    let projects = try JSONDecoder().decode([DashboardProject].self, from: Data(json.utf8))
    let snapshot = await DashboardPullRequestsModel.derive(projects)
    // #11 arrives before the #12 duplicate that shares its url, so #11 wins and #12 is dropped.
    #expect(snapshot.mine.map(\.pr.number) == [10, 11])
    #expect(snapshot.reviews.map(\.pr.number) == [20, 21])
    #expect(snapshot.counts[.all] == 2)
}

@MainActor @Test func deriveCountsPerFilterAcrossCheckStatesAndReviewDecisions() async throws {
    let project = makeProject("p", prs: [
        makePR(1, ci: "completed", conclusion: "success"),
        makePR(2, ci: "completed", conclusion: "failure"),
        makePR(3, ci: "in_progress"),
        makePR(4, reviewDecision: "CHANGES_REQUESTED"),
        makePR(5, reviewDecision: "APPROVED"),
        makePR(6, isDraft: true),
    ])
    let snapshot = await DashboardPullRequestsModel.derive([project])
    #expect(snapshot.counts[.all] == 6)
    #expect(snapshot.counts[.failing] == 1)
    #expect(snapshot.counts[.running] == 1)
    #expect(snapshot.counts[.changesRequested] == 1)
    #expect(snapshot.counts[.approved] == 1)
    #expect(snapshot.counts[.drafts] == 1)
}

@MainActor @Test func deriveLinkedPRsPicksTheLowestPRNumber() async throws {
    let project = makeProject("p", prs: [
        makePR(5, jiraKeys: ["REC-1"]),
        makePR(2, jiraKeys: ["REC-1"]),
        makePR(9, category: "other", jiraKeys: ["REC-9"], awaitingMyReview: false),
    ])
    let snapshot = await DashboardPullRequestsModel.derive([project])
    #expect(snapshot.linkedPRs == ["REC-1": "#2"])
}

@MainActor @Test func tileFootnoteIsSingularAndPluralForDraftsAndApproved() {
    let project = makeProject("p", prs: [makePR(1)])
    let one = rows(project)
    let singular = DashboardPullRequestsModel.Tile(mine: one, counts: [.drafts: 1, .approved: 0])
    #expect(singular.footnote == "1 draft · 0 approved")
    #expect(singular.count == 1)

    let five = makeProject("p", prs: (1...5).map { makePR($0) })
    let plural = DashboardPullRequestsModel.Tile(mine: rows(five), counts: [.drafts: 2, .approved: 3])
    #expect(plural.footnote == "2 drafts · 3 approved")
    #expect(plural.count == 5)
}

@MainActor @Test func tileDotsPutFailingFirstAndNeverCutAFailingOne() {
    // Ten of each state, so the 20-dot cap drops twenty, and the dropped ones must be the calmer states.
    var prs: [DashboardPR] = []
    for i in 0..<10 { prs.append(makePR(i, ci: "completed", conclusion: "success")) }
    for i in 10..<20 { prs.append(makePR(i)) }
    for i in 20..<30 { prs.append(makePR(i, ci: "in_progress")) }
    for i in 30..<40 { prs.append(makePR(i, ci: "completed", conclusion: "failure")) }
    let mine = rows(makeProject("p", prs: prs))
    let tile = DashboardPullRequestsModel.Tile(mine: mine, counts: [:])
    #expect(DashboardPullRequestsModel.Tile.dotLimit == 20 && tile.dots.count == 20)
    #expect(tile.dots[0..<10].allSatisfy { $0.checks == .failing })
    #expect(tile.dots[10..<20].allSatisfy { $0.checks == .running })
    #expect(!tile.dots.contains { $0.checks == .unknown || $0.checks == .passing })
}

@MainActor @Test func reviewTileReportsTheLastRowsAgeRepoCountAndDedupedAuthors() {
    // `reviews` arrives newest first; the longest-waiting review is last.
    let reviews: [DashboardRow] = [
        rows(makeProject("p", prs: [makePR(1, createdAt: "2026-09-20T00:00:00Z", repo: "o/a", author: "alice")]))[0],
        rows(makeProject("p", prs: [makePR(2, createdAt: "2026-09-19T00:00:00Z", repo: "o/b", author: "bob")]))[0],
        rows(makeProject("p", prs: [makePR(3, createdAt: "2026-09-18T00:00:00Z", repo: "o/a", author: "alice")]))[0],
        rows(makeProject("p", prs: [makePR(4, createdAt: "2026-09-17T00:00:00Z", repo: "o/a", author: "carol")]))[0],
        rows(makeProject("p", prs: [makePR(5, createdAt: "2020-01-01T00:00:00Z", repo: "o/c", author: "dave")]))[0],
    ]
    let tile = DashboardPullRequestsModel.ReviewTile(reviews: reviews)
    #expect(tile.count == 5)
    #expect(tile.oldestAge?.hasSuffix("d") == true)
    #expect(tile.footnote == "across 3 repos")
    #expect(tile.authors == ["alice", "bob", "carol"])
}

@MainActor @Test func deriveWarningsOrderSyncErrorFirstThenPRErrorsThenWaitingMessage() async throws {
    let project = makeProject("p", name: "Foo", prs: [makePR(1, error: "boom")], lastSynced: nil, syncError: "Sync failed")
    let snapshot = await DashboardPullRequestsModel.derive([project])
    #expect(snapshot.warnings == ["Foo: Sync failed", "Foo: boom", "Foo: waiting for the first sync."])
}

@MainActor @Test func groupKeepsProjectOrderAndDropsEmptyProjects() {
    let p1 = makeProject("p1", name: "One", prs: [])
    let p2 = makeProject("p2", name: "Two", prs: [])
    let p3 = makeProject("p3", name: "Three", prs: [])
    let row1 = rows(makeProject("p1", prs: [makePR(1)]))[0]
    let row3 = rows(makeProject("p3", prs: [makePR(3)]))[0]
    let groups = DashboardPullRequestsModel.group([row1, row3], in: [p1, p2, p3], by: .all)
    #expect(groups.map(\.project.id) == ["p1", "p3"])
    #expect(groups.map { $0.rows.map(\.pr.number) } == [[1], [3]])
}

@MainActor @Test(.timeLimit(.minutes(1))) func filterDidSetRecomputesGroups() async throws {
    let project = makeProject("p", prs: [makePR(1, isDraft: true), makePR(2)])
    let model = DashboardPullRequestsModel()
    model.connect(ModelFixture(projects: [project]))
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.groups.flatMap(\.rows).count == 2)
    model.filter = .drafts
    #expect(model.groups.flatMap(\.rows).map(\.pr.number) == [1])
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func retiredPullRequestsModelIgnoresRefreshSyncAndConnect() async throws {
    let model = DashboardPullRequestsModel()
    model.retire()
    let fixture = ModelFixture(projects: [makeProject("p", prs: [makePR(1)])])
    model.connect(fixture)
    model.refresh()
    model.sync()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!model.loading && !model.syncing && !model.connected)
    #expect(await fixture.reads == 0)
}

@MainActor @Test(.timeLimit(.minutes(1))) func staleSnapshotFinishingLateDoesNotOverwriteANewerOne() async throws {
    let a = [makeProject("a", prs: [makePR(1)])]
    let b = [makeProject("b", prs: [makePR(2)])]
    let service = SequencedSnapshot([a, b])
    let model = DashboardPullRequestsModel()
    model.connect(service) // call 1: blocks inside snapshot()
    await service.waitForStart(1)
    model.sync() // call 2: runs to completion and publishes `b`
    while model.syncing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.projects.map(\.id) == ["b"])
    await service.proceed(1) // call 1 lands late and must be ignored
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.projects.map(\.id) == ["b"])
    await model.stop()
}

// MARK: - DashboardTicketsModel

@MainActor @Test func countTalliesAllStageAndUrgentFilters() {
    let rows = [
        makeTicketRow(makeTicket("A", status: "Open", category: "new", priority: "Medium")),
        makeTicketRow(makeTicket("B", status: "Open", category: "new", priority: "Urgent")),
        makeTicketRow(makeTicket("C", status: "Blocked", category: "indeterminate", priority: "Low")),
        makeTicketRow(makeTicket("D", status: "In PR Review", category: "indeterminate", priority: "Low")),
    ]
    let counts = DashboardTicketsModel.count(rows)
    #expect(counts[.all] == 4)
    #expect(counts[.stage(.toDo)] == 2)
    #expect(counts[.stage(.inProgress)] == 1)
    #expect(counts[.stage(.blocked)] == 1)
    #expect(counts[.stage(.pendingRelease)] == 0)
    #expect(counts[.urgent] == 1)
}

@MainActor @Test func summarizeBuildsFootnoteAllStagesInOrderAndTotal() async {
    let rows = [
        makeTicketRow(makeTicket("A", status: "Open", category: "new", priority: "Medium")),
        makeTicketRow(makeTicket("B", status: "Open", category: "new", priority: "Medium")),
        makeTicketRow(makeTicket("C", status: "In PR Review", category: "indeterminate", priority: "Medium")),
    ]
    let summary = await DashboardTicketsModel.summarize(rows)
    #expect(summary.stages.all.map(\.stage) == TicketStage.allCases)
    #expect(summary.stages.all.map(\.count) == [2, 1, 0, 0])
    #expect(summary.stages.live.map(\.stage) == [.toDo, .inProgress])
    #expect(summary.stages.total == 3)
    #expect(summary.tile.footnote == "2 to do · 1 in progress · 0 pending release · 0 blocked")
}

@MainActor @Test func rankAttentionExcludesLinkedInProgressAndRespectsLimit() {
    let blocked = makeTicketRow(makeTicket("BLK", status: "Blocked", category: "indeterminate", priority: "Low"))
    let reopened = makeTicketRow(makeTicket("REO", status: "Reopened", category: "new", priority: "Medium"))
    let inProgress = makeTicketRow(makeTicket("INP", status: "In PR Review", category: "indeterminate", priority: "Medium"))
    let urgentToDo = makeTicketRow(makeTicket("URG", status: "Open", category: "new", priority: "Urgent"))
    let rows = [blocked, reopened, inProgress, urgentToDo]

    #expect(DashboardTicketsModel.rankAttention(rows, linked: [:], limit: 10).map(\.id) == ["BLK", "REO", "INP", "URG"])
    // A linked in-progress ticket is already represented by its pull request, so it drops out.
    #expect(DashboardTicketsModel.rankAttention(rows, linked: ["INP": "#5"], limit: 10).map(\.id) == ["BLK", "REO", "URG"])
    #expect(DashboardTicketsModel.rankAttention(rows, linked: [:], limit: 2).map(\.id) == ["BLK", "REO"])
}

@MainActor @Test(.timeLimit(.minutes(1))) func filterDidSetKeepsScreenRowsUrgentFirstWithinTheNarrowedTag() async throws {
    let rows = [
        makeTicketRow(makeTicket("N1", status: "Open", category: "new", priority: "Medium")),
        makeTicketRow(makeTicket("U1", status: "Open", category: "new", priority: "Urgent")),
        makeTicketRow(makeTicket("U2", status: "In PR Review", category: "indeterminate", priority: "Urgent")),
    ]
    let model = DashboardTicketsModel()
    model.connect(ModelFixture(tickets: rows))
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.screenRows.map(\.id) == ["U1", "U2", "N1"])
    model.filter = .stage(.toDo)
    #expect(model.screenRows.map(\.id) == ["U1", "N1"])
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func linkedPRsRestampsScreenRowsAndRecomputesAttention() async throws {
    let inProgress = makeTicket("K2", status: "In PR Review", category: "indeterminate", priority: "Medium")
    let rows = [makeTicketRow(makeTicket("K1", status: "Open", category: "new", priority: "Medium")), makeTicketRow(inProgress)]
    let model = DashboardTicketsModel()
    model.connect(ModelFixture(tickets: rows))
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.screenRows.first { $0.id == "K1" }?.pullRequest == "")
    #expect(model.attention.map(\.id) == ["K2"])
    model.linkedPRs = ["K1": "#7", "K2": "#9"]
    #expect(model.screenRows.first { $0.id == "K1" }?.pullRequest == "#7")
    #expect(model.attention.isEmpty)
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func availableFollowsConnectNilAndService() async throws {
    let model = DashboardTicketsModel()
    #expect(!model.available)
    model.connect(ModelFixture())
    #expect(model.available)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    model.connect(nil)
    #expect(!model.available)
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func retiredTicketsModelIgnoresRefresh() async throws {
    let model = DashboardTicketsModel()
    model.retire()
    let fixture = ModelFixture(tickets: [makeTicketRow(makeTicket("A", status: "Open"))])
    model.connect(fixture)
    model.refresh()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!model.loading && !model.available)
    #expect(await fixture.ticketReads == 0)
}

// MARK: - DashboardUsageModel

@MainActor @Test func updateWithNilProducesTheDefaultTile() {
    let model = DashboardUsageModel()
    model.update(nil)
    #expect(model.tile == DashboardUsageModel.Tile())
    #expect(model.tile.footnote == "No usage yet")
    #expect(model.tile.month == 0)
    #expect(model.tile.tokensLabel == nil)
    #expect(model.tile.peak == 0.01)
}

@MainActor @Test func updateWithASnapshotComputesMonthFootnoteLinesAndPeak() throws {
    let json = """
    {"claude":{"tokens":100,"cost":13,"history":[
      {"date":"2026-09-20","tokens":50,"cost":5},{"date":"2026-09-21","tokens":50,"cost":8}]},
     "codex":{"tokens":110,"cost":9,"history":[
      {"date":"2026-09-20","tokens":40,"cost":3},{"date":"2026-09-21","tokens":70,"cost":6}]}}
    """
    let usage = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    let model = DashboardUsageModel()
    model.update(usage)
    #expect(model.tile.month == 22)
    #expect(model.tile.tokensLabel == "210 tokens")
    #expect(model.tile.footnote == "Claude $13 · Codex $9")
    #expect(model.tile.lines.map(\.key) == ["claude", "codex"])
    #expect(model.tile.lines[0].costs == [5, 8])
    #expect(model.tile.lines[1].costs == [3, 6])
    #expect(model.tile.peak == 8)
}

@MainActor @Test func retiredUsageModelIgnoresUpdate() throws {
    let json = #"{"claude":{"tokens":10,"cost":1,"history":[{"date":"2026-09-20","tokens":10,"cost":1}]}}"#
    let usage = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    let model = DashboardUsageModel()
    model.retire()
    model.update(usage)
    #expect(model.tile == DashboardUsageModel.Tile())
}

// MARK: - DashboardViewModel

@MainActor @Test(.timeLimit(.minutes(1))) func searchCaptionIsSingularAndPlural() async throws {
    let project = makeProject("p", prs: [makePR(1, jiraKeys: ["REC-1"], title: "Alpha One")])
    let fixture = ModelFixture(projects: [project], tickets: [makeTicketRow(makeTicket("REC-2", status: "Open", summary: "Alpha Two"))])
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(fixture)
    while model.prs.loading || model.tickets.loading { try await Task.sleep(for: .milliseconds(10)) }

    model.query = "Alpha One"
    #expect(model.search.count == 1)
    #expect(model.search.caption == "1 result for \u{201C}Alpha One\u{201D}")

    model.query = "Alpha"
    #expect(model.search.count == 2)
    #expect(model.search.caption == "2 results for \u{201C}Alpha\u{201D}")

    model.clearFilter()
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func searchMatchesTicketReporterCaseInsensitively() async throws {
    let fixture = ModelFixture(tickets: [makeTicketRow(makeTicket("OPS-9", status: "Open", reporter: "Chen Ding"))])
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(fixture)
    while model.prs.loading || model.tickets.loading { try await Task.sleep(for: .milliseconds(10)) }

    model.query = "chen ding"
    #expect(model.search.tickets.map(\.id) == ["OPS-9"])
    model.clearFilter()
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func searchTicketsCarryTheirLinkedPullRequestNumber() async throws {
    let project = makeProject("p", prs: [makePR(3, category: "mine", jiraKeys: ["OPS-9"])])
    let fixture = ModelFixture(projects: [project], tickets: [makeTicketRow(makeTicket("OPS-9", status: "Open"))])
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(fixture)
    while model.prs.loading || model.tickets.loading { try await Task.sleep(for: .milliseconds(10)) }

    model.query = "OPS-9"
    #expect(model.search.tickets.first?.pullRequest == "#3")
    model.clearFilter()
    await model.stop()
    model.retire()
}

@MainActor @Test func showTicketsAndSelectTabClearTheQuery() {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.query = "x"
    model.showTickets()
    #expect(model.query.isEmpty)
    model.query = "y"
    model.selectTab(.pullRequests)
    #expect(model.query.isEmpty)
}

@MainActor @Test func tileValuesSurviveShowAndCloseTickets() {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.tileValues = ["mine": 5]
    model.showTickets()
    model.closeTickets()
    #expect(model.tileValues == ["mine": 5])
}

@MainActor @Test(.timeLimit(.minutes(1))) func disconnectedOpenWarnsOnlyWhenTheDashboardCanPresent() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    let coordinator = DashboardCoordinator(model: model)
    model.connect(ModelFixture(projects: [makeProject("p", prs: [makePR(1)])]))
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    let row = try #require(model.prs.visibleRows.first)
    await model.stop()
    // A hidden or blocked dashboard stays silent: the coordinator's gate runs before the check.
    coordinator.canPresent = { false }
    model.open(row)
    #expect(model.navigation.error == nil)
    coordinator.canPresent = { true }
    model.open(row)
    #expect(model.navigation.error == "Connect to open pull requests in Craft.")
    coordinator.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func openEmitsTheResolvedRequestAndSkipsRowsNoLongerShown() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    var emitted: [DashboardViewModel.Action] = []
    model.onAction = { emitted.append($0) }
    model.connect(ModelFixture(projects: [makeProject("p", prs: [makePR(1)])]))
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    let row = try #require(model.prs.visibleRows.first)
    model.open(row, inTab: true)
    model.openSession(row, agent: .claude)
    var tab = row.openPageRequest; tab.inTab = true
    #expect(emitted == [.open(tab), .open(DashboardViewModel.sessionRequest(row, agent: .claude))])
    // A row the snapshot no longer holds resolves to nothing, so nothing reaches the coordinator.
    emitted = []
    model.open(rows(makeProject("gone", prs: [makePR(999)]))[0])
    #expect(emitted.isEmpty)
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func retireRetiresAllThreeChildModels() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(ModelFixture())
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    model.retire()
    #expect(model.prs.retired && model.tickets.retired && model.usage.retired)
}
