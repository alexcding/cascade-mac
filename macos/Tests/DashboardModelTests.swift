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
    var ticketWhys: [TicketRead] = []
    func myTicketsReport(_ read: TicketRead) async throws -> (rows: [DashboardTicketRow], warning: String?) {
        ticketWhys.append(read)
        return (try await myTickets(), nil)
    }
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
                          lastSynced: String? = "2026-01-01T00:00:00Z", syncError: String? = nil, jiraKey: String? = nil) -> DashboardProject {
    DashboardProject(id: id, name: name, repo: repo, prs: prs, lastSynced: lastSynced, syncError: syncError, jiraProjectKey: jiraKey)
}

/// A project whose Jira keys claim the given tickets, so the dashboard shows them.
private func tracking(_ keys: String...) -> DashboardProject { makeProject("jira", prs: [], jiraKey: keys.joined(separator: ", ")) }

private func rows(_ project: DashboardProject) -> [DashboardRow] {
    project.prs.compactMap { pr in
        guard let address = pr.url, let url = safeWebURL(address) else { return nil }
        return DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
    }
}

/// A ticket as the backend would send it: `stage`, `level` and `reopened` are its reading of the
/// fixture's status and priority names (`tickets.rs`), spelled out here so the rows under test
/// carry what the app is actually given.
private func makeTicket(_ key: String, status: String, category: String? = nil, priority: String = "Medium",
                         summary: String? = nil, reporter: String? = nil) -> Ticket {
    let stage: String
    switch status {
    case "Blocked": stage = "blocked"
    case "In PR Review", "Reopened": stage = "inProgress"
    default: stage = "toDo"
    }
    return Ticket(key: key, summary: summary ?? key, status: status, type: "Task", priority: priority,
                  statusCategory: category, reporter: reporter,
                  stage: stage, level: priority.lowercased(), reopened: status == "Reopened")
}

private func makeTicketRow(_ ticket: Ticket) -> DashboardTicketRow {
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
    #expect(DashboardPullRequestsModel.counts(snapshot.mine)[.all] == 2)
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
    let counts = DashboardPullRequestsModel.counts(snapshot.mine)
    #expect(counts[.all] == 6)
    #expect(counts[.failing] == 1)
    #expect(counts[.running] == 1)
    #expect(counts[.changesRequested] == 1)
    #expect(counts[.approved] == 1)
    #expect(counts[.drafts] == 1)
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

@MainActor @Test func deriveWarningsOrderSyncErrorFirstThenPRErrorsThenWaitingMessage() async throws {
    let failed = makeProject("p", name: "Foo", prs: [makePR(1, error: "boom")], lastSynced: nil, syncError: "Sync failed")
    let unsynced = makeProject("q", name: "Bar", prs: [makePR(2, error: "bang")], lastSynced: nil)
    let snapshot = await DashboardPullRequestsModel.derive([failed, unsynced])
    // A first sync that failed says why; only one still to come is waited for.
    #expect(snapshot.warnings == ["Foo: Sync failed", "Foo: boom", "Bar: bang", "Bar: waiting for the first sync."])
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

@MainActor @Test(.timeLimit(.minutes(1))) func filterDidSetKeepsScreenRowsUrgentFirstWithinTheNarrowedTag() async throws {
    let rows = [
        makeTicketRow(makeTicket("N1", status: "Open", category: "new", priority: "Medium")),
        makeTicketRow(makeTicket("U1", status: "Open", category: "new", priority: "Urgent")),
        makeTicketRow(makeTicket("U2", status: "In PR Review", category: "indeterminate", priority: "Urgent")),
    ]
    let model = DashboardTicketsModel()
    model.projects = [tracking("N1", "U1", "U2")]
    model.connect(ModelFixture(tickets: rows))
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.screenRows.map(\.id) == ["U1", "U2", "N1"])
    model.filter = .stage(.toDo)
    #expect(model.screenRows.map(\.id) == ["U1", "N1"])
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func linkedPRsRestampsScreenRows() async throws {
    let inProgress = makeTicket("K2", status: "In PR Review", category: "indeterminate", priority: "Medium")
    let rows = [makeTicketRow(makeTicket("K1", status: "Open", category: "new", priority: "Medium")), makeTicketRow(inProgress)]
    let model = DashboardTicketsModel()
    model.projects = [tracking("K1", "K2")]
    model.connect(ModelFixture(tickets: rows))
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.screenRows.first { $0.id == "K1" }?.pullRequest == "")
    model.linkedPRs = ["K1": "#7", "K2": "#9"]
    #expect(model.screenRows.first { $0.id == "K1" }?.pullRequest == "#7")
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

// MARK: - DashboardViewModel

@MainActor @Test func showTicketsAndSelectTabChangeTheTab() {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.showTickets()
    #expect(model.tab == .tickets)
    model.selectTab(.pullRequests)
    #expect(model.tab == .pullRequests)
    // A retired page keeps the tab it had.
    model.retire()
    model.selectTab(.overview)
    #expect(model.tab == .pullRequests)
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
    #expect(model.navigation.error == "Connect to open pull requests in Cascade.")
    coordinator.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func openEmitsTheResolvedRequestAndSkipsRowsNoLongerShown() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    var emitted: [DashboardViewModel.Action] = []
    model.onAction = { emitted.append($0) }
    model.connect(ModelFixture(projects: [makeProject("p", prs: [makePR(1)])]))
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    let row = try #require(model.prs.visibleRows.first)
    model.open(row)
    #expect(emitted == [.open(row.openPageRequest)])
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
    #expect(model.prs.retired && model.tickets.retired)
}

@MainActor @Test func deriveListsEveryoneElsesOpenPullRequestsAsOthers() async throws {
    let project = makeProject("p", prs: [
        makePR(1), makePR(2, category: "review"), makePR(3, category: "other"),
        makePR(4, category: "other", state: "MERGED"),
    ])
    let snapshot = await DashboardPullRequestsModel.derive([project])
    // #2 waits on the user's review, so it is To review's, not Others'.
    #expect(snapshot.others.compactMap(\.pr.number) == [3])
    #expect(DashboardPullRequestsModel.counts(snapshot.mine)[.all] == 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func authorAndProjectNarrowGroupsAndCounts() async throws {
    let p1 = makeProject("p1", name: "One", prs: [makePR(1), makePR(2, category: "other", isDraft: true)])
    let p2 = makeProject("p2", name: "Two", repo: "o/s", prs: [
        makePR(3, url: "https://github.com/o/s/pull/3"), makePR(4, category: "other", url: "https://github.com/o/s/pull/4"),
    ])
    let model = DashboardPullRequestsModel()
    model.connect(ModelFixture(projects: [p1, p2]))
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(Set(model.groups.flatMap(\.rows).compactMap(\.pr.number)) == [1, 3])
    model.author = .others
    #expect(Set(model.groups.flatMap(\.rows).compactMap(\.pr.number)) == [2, 4])
    #expect(model.counts[.drafts] == 1)
    #expect(model.count(.mine) == 2 && model.count(.others) == 2)
    model.project = "p2"
    #expect(model.count(.mine) == 1 && model.count(.others) == 1)
    #expect(model.groups.map(\.project.id) == ["p2"])
    #expect(model.groups.flatMap(\.rows).compactMap(\.pr.number) == [4])
    #expect(model.counts[.drafts] == 0)
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func othersRowsOutsideTheReviewOrbitOpenWithTheirBranchAndTickets() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    var emitted: [DashboardViewModel.Action] = []
    model.onAction = { emitted.append($0) }
    let json = #"[{"id":"p","name":"Proj","repo":"o/r","lastSynced":"2026-01-01T00:00:00Z","prs":[{"number":7,"title":"Teammate","url":"https://github.com/o/r/pull/7","state":"OPEN","category":"other","awaitingMyReview":false,"headRefName":"REC-1-fix","jiraKeys":["REC-1"]}]}]"#
    model.connect(ModelFixture(projects: try JSONDecoder().decode([DashboardProject].self, from: Data(json.utf8))))
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.prs.visibleRows.isEmpty)
    let row = try #require(model.prs.others.first)
    model.open(row)
    #expect(emitted == [.open(row.openPageRequest)])
    let request = row.openPageRequest
    #expect(request.projectID == "p" && request.branch == "REC-1-fix" && request.jiraKeys == ["REC-1"])
    await model.stop()
}

/// My Tickets says why it reads: connecting and opening the dashboard are looks, the Refresh
/// button asks for a search now, and the read that answers the backend's report of a change is
/// an echo, which must start no search.
@MainActor @Test func myTicketsSaysWhyItReads() async throws {
    let fixture = ModelFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    // Waits for the read just asked for to have been made and finished: an echo shows no busy
    // state to wait on, so the count of reads is what says it ran.
    func settled(_ reads: Int) async throws {
        for _ in 0..<300 {
            if await fixture.ticketWhys.count == reads, !model.tickets.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    model.connect(fixture)
    try await settled(1)
    model.tickets.refresh(.now)
    try await settled(2)
    model.tickets.refresh(.echo)
    #expect(!model.tickets.loading, "an echo is nobody's refresh")
    try await settled(3)
    model.reload()
    try await settled(4)
    model.reload(look: false)
    try await settled(5)
    #expect(await fixture.ticketWhys == [.look, .now, .echo, .look, .echo])
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func overviewSummarisesEachProjectAndItsNameOpensIt() async throws {
    let project = makeProject("p", name: "App", prs: [
        makePR(1, ci: "completed", conclusion: "failure", jiraKeys: ["OPS-1"]),
        makePR(2, category: "review", ci: "in_progress", awaitingMyReview: true),
        makePR(3, category: "other", ci: "completed", conclusion: "success", awaitingMyReview: false),
        makePR(4, state: "MERGED"),
    ], jiraKey: "OPS")
    let quiet = makeProject("q", name: "Docs", repo: "o/d", prs: [], lastSynced: nil, syncError: "gone")
    let fixture = ModelFixture(projects: [project, quiet], tickets: [makeTicketRow(makeTicket("OPS-1", status: "Open"))])
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    var opened: [String] = []
    model.onAction = { if case .openProject(let id) = $0 { opened.append(id) } }
    model.connect(fixture)
    while model.prs.loading || model.tickets.loading { try await Task.sleep(for: .milliseconds(10)) }

    let summaries = model.projectSummaries
    #expect(summaries.map(\.id) == ["p", "q"])
    let app = try #require(summaries.first)
    #expect(app.tickets == 1 && app.tracker == "Jira OPS" && app.syncError == nil)
    #expect(summaries[1].syncError == "gone" && summaries[1].tracker == "GitHub issues")
    model.openProject("p"); model.openProject("missing")
    #expect(opened == ["p"], "Only a project the page shows opens")
    await model.stop()
    model.retire()
    model.openProject("p")
    #expect(opened == ["p"], "A retired page opens nothing")
}

@MainActor @Test(.timeLimit(.minutes(1))) func overviewLanesMatchEachSessionToItsBranchPullRequestAndSortByStage() async throws {
    func pr(_ number: Int, branch: String, additions: Int? = nil) -> DashboardPR {
        DashboardPR(number: number, title: nil, url: "https://github.com/o/r/pull/\(number)", repo: nil, state: "OPEN", category: "mine",
                    awaitingMyReview: nil, isDraft: nil, reviewDecision: "APPROVED", headRefName: branch, author: nil, createdAt: nil,
                    labels: nil, jiraKeys: nil, ci: nil, error: nil, additions: additions, deletions: 3, changedFiles: 2)
    }
    func session(_ id: String, _ project: String, branch: String, _ state: DashboardSession.State) -> DashboardSession {
        DashboardSession(id: id, projectID: project, title: id, branch: branch, ticket: nil, cli: "claude", state: state)
    }
    let fixture = ModelFixture(projects: [makeProject("p", prs: [pr(1, branch: "feat-a", additions: 10), pr(2, branch: "feat-b")]),
                                          makeProject("q", name: "Other", repo: "o/q", prs: [])])
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    var opened: [String] = []
    model.onAction = { if case .openSession(let id) = $0 { opened.append(id) } }
    model.sessions = [session("review", "p", branch: "feat-a", .idle), session("asks", "p", branch: "feat-b", .needsYou),
                      session("busy", "p", branch: "other", .working), session("gone", "q", branch: "feat-a", .stopped)]
    model.connect(fixture)
    while model.prs.loading || model.tickets.loading { try await Task.sleep(for: .milliseconds(10)) }

    let lanes = model.sessionLanes
    #expect(lanes.map(\.id) == ["p", "q"])
    #expect(lanes[0].rows.map(\.id) == ["asks", "busy", "review"], "Needs you, then working, then in review")
    #expect(lanes[0].rows.map(\.stage) == [.needsYou, .working, .inReview])
    #expect(lanes[0].rows[2].pr?.pr.number == 1 && lanes[0].rows[2].pr?.pr.additions == 10, "Matched by branch, with its size")
    #expect(lanes[0].rows[0].pr?.pr.number == 2, "A session that needs you keeps its pull request")
    #expect(lanes[1].rows[0].pr == nil && lanes[1].rows[0].stage == .idle && lanes[1].rows[0].stateLabel == "Stopped",
            "Another project's branch of the same name is not this session's")
    #expect(model.sessionColumns(lanes).map(\.rows.count) == [1, 1, 1, 1])

    model.selectProject("q")
    #expect(model.shownSessionLanes.map(\.id) == ["q"], "The picked project narrows the lanes")

    model.openSession("busy"); model.openSession("missing")
    #expect(opened == ["busy"], "Only a session the page shows opens")
    await model.stop()
    model.retire()
}

@Test func aSessionRowSaysWhatItsAgentDoesAndHowLongItHasRun() {
    let now = Date(timeIntervalSince1970: 100_000)
    let call = DashboardSession.Call(kind: "Bash", label: "xcodebuild test", started: now.addingTimeInterval(-30))
    let working = DashboardSessionRow(session: DashboardSession(id: "s", projectID: "p", title: "s", branch: "b", ticket: nil, cli: nil,
                                                                state: .working, call: call, agentStarted: now.addingTimeInterval(-8040)),
                                      pr: nil)
    #expect(working.activityParts == ("Bash", "xcodebuild test"))
    #expect(working.timing(now: now) == "running 30s · agent up 2h 14m")
    let stopped = DashboardSessionRow(session: DashboardSession(id: "s", projectID: "p", title: "s", branch: "b", ticket: nil, cli: nil,
                                                                state: .stopped), pr: nil)
    #expect(stopped.activityParts == ("Stopped", "") && stopped.timing(now: now) == "terminal closed")
    let asking = DashboardSessionRow(session: DashboardSession(id: "s", projectID: "p", title: "s", branch: "b", ticket: nil, cli: nil,
                                                               state: .needsYou, call: call), pr: nil)
    #expect(asking.activityParts == ("Waiting", "for your answer") && asking.stage == .needsYou)
}

@Test func aPullRequestDecodesItsSize() throws {
    let json = #"{"number":4,"state":"OPEN","additions":120,"deletions":30,"changedFiles":7}"#
    let pr = try JSONDecoder().decode(DashboardPR.self, from: Data(json.utf8))
    #expect(pr.additions == 120 && pr.deletions == 30 && pr.changedFiles == 7)
}
