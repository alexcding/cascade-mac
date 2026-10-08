import AppKit
import Foundation
import SwiftUI
import Testing

private actor DashboardFixture: DashboardService {
    var failing = false
    var reads = 0
    var empty = false
    func setFailure() { failing = true }
    func removeRows() { empty = true }
    func snapshot() async throws -> [DashboardProject] {
        reads += 1
        if failing { throw BackendError.operation("Fixture offline") }
        if empty { return [] }
        return try JSONDecoder().decode([DashboardProject].self, from: Data(#"""
        [{"id":"p","name":"Native","repo":"o/r","jiraProjectKey":"REC","lastSynced":"2026-09-12T12:00:00Z","prs":[
          {"number":1,"title":"My draft","url":"https://github.com/o/r/pull/1","state":"OPEN","category":"mine","isDraft":true,"jiraKeys":["REC-1"],"ci":{"status":"queued","conclusion":"failure"},"labels":[{"name":"bug","color":"d73a4a"},{"name":"ui","color":"ededed"},{"name":"needs-qa","color":"0e8a16"}]},
          {"number":2,"title":"Reviewed already","url":"https://github.com/o/r/pull/2","state":"OPEN","category":"other","awaitingMyReview":true,"jiraKeys":["REC-1","REC-2"],"reviewDecision":"APPROVED","ci":{"status":"completed","conclusion":"failure"}},
          {"number":3,"title":"Not in orbit","url":"https://github.com/o/r/pull/3","state":"OPEN","category":"review","awaitingMyReview":false,"jiraKeys":["REC-9"]},
          {"number":4,"title":"Legacy requested","url":"https://github.com/o/r/pull/4","state":"OPEN","category":"review"},
          {"number":5,"title":"Closed","url":"https://github.com/o/r/pull/5","state":"CLOSED","category":"mine"},
          {"number":6,"title":"Unsafe","url":"file:///tmp/local","state":"OPEN","category":"mine"},
          {"repo":"o/broken","error":"Sync unavailable"}
        ]}]
        """#.utf8))
    }
}

private actor UnreachableDashboardFixture: DashboardService {
    var down: Set<String> = ["github"]
    func recover() { down = [] }
    func snapshot() async throws -> [DashboardProject] { [] }
    func unreachable() async throws -> Set<String> { down }
}

/// One failing service is said once: the model asks which services the backend cannot reach
/// when it connects, and again whenever the backend says that changed.
@MainActor @Test func dashboardSaysOnceThatGitHubIsUnreachableAndStopsWhenItAnswers() async throws {
    let service = UnreachableDashboardFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    for _ in 0..<200 where !model.prs.unreachable { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.prs.unreachable && model.prs.warnings.isEmpty)
    // The backend says GitHub answers again (an `upstream` event): the model asks, and stops.
    await service.recover()
    model.prs.refreshUnreachable()
    for _ in 0..<200 where model.prs.unreachable { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.prs.unreachable)
    await model.stop()
    model.retire()
}

@MainActor @Test func dashboardGroupsReviewOrbitFiltersAndRetainsSnapshotOnFailure() async throws {
    let service = DashboardFixture()
    let actions = ProjectPageActions()
    let model = DashboardViewModel(pageActions: actions), coordinator = DashboardCoordinator(model: model)
    model.connect(service)
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.prs.mine.map(\.pr.number) == [1])
    #expect(model.prs.reviews.map(\.pr.number) == [2, 4])
    #expect(model.prs.mine[0].ciLabel == "CI running")
    #expect(model.prs.reviews[0].reviewLabel == "Approved")
    #expect(model.prs.warnings == ["Native: Sync unavailable"])
    #expect(model.prs.synced == ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z"))
    // The age shown is the oldest sync among projects that are syncing: one whose sync is
    // failing says so itself, and its last success is not the age of everything.
    let decoded = try JSONDecoder().decode([DashboardProject].self, from: Data(#"""
    [{"id":"a","name":"A","repo":"o/a","prs":[],"lastSynced":"2026-09-12T12:00:00.500Z","syncError":null},
     {"id":"b","name":"B","repo":"o/b","prs":[],"lastSynced":"2026-09-12T11:00:00.000Z","syncError":null},
     {"id":"c","name":"C","repo":"o/c","prs":[],"lastSynced":"2026-08-01T00:00:00.000Z","syncError":"gone"},
     {"id":"d","name":"D","repo":"","prs":[],"lastSynced":"2026-07-01T00:00:00.000Z","syncError":null}]
    """#.utf8))
    #expect(await DashboardPullRequestsModel.derive(decoded).synced == ISO8601DateFormatter().date(from: "2026-09-12T11:00:00Z"))
    let row = try #require(model.prs.reviews.first { $0.pr.number == 2 })
    model.open(row); await model.navigation.waitForOpen()
    let opened = actions.opened.last
    #expect(opened?.category == "review" && opened?.url == row.url.absoluteString)
    await service.setFailure()
    model.reload()
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.prs.visibleRows.contains(row))
    #expect(model.prs.updated != nil && model.prs.error == "Fixture offline")
    await model.stop()
    coordinator.retire()
}

@MainActor @Test func dashboardOpenFailurePreservesNavigationAndAllowsRetry() async throws {
    let service = DashboardFixture()
    let actions = ProjectPageActions(); actions.failOpen = true
    let model = DashboardViewModel(pageActions: actions), coordinator = DashboardCoordinator(model: model)
    model.connect(service)
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    let row = try #require(model.prs.mine.first)
    model.open(row); await model.navigation.waitForOpen()
    #expect(actions.navigated.isEmpty && model.navigation.error?.contains("Fixture open failed") == true && model.navigation.opening == nil)
    actions.failOpen = false
    model.open(row); await model.navigation.waitForOpen()
    #expect(actions.navigated.count == 1 && model.navigation.error == nil)
    await model.stop()
    coordinator.retire()
}

@MainActor private func connectedDashboard(_ root: AppCoordinator, actions: ProjectPageActions) async -> DashboardViewModel {
    let model = root.makeDashboard(factory: NativeDashboardFeatureFactory(), pageActions: actions)
    model.connect(DashboardFixture())
    while model.prs.loading { await Task.yield() }
    return model
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardCoordinatorOwnsVisibleRowsAndPreservesFeedbackAcrossSnapshotReads() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions: actions), row = try #require(model.prs.reviews.first)
    #expect(root.dashboardCoordinator?.model === model)
    root.navigate(to: .terminal); model.open(row); await model.navigation.waitForOpen()
    #expect(actions.opened.isEmpty)
    root.navigate(to: .overview)
    actions.failOpen = true; model.open(row); await model.navigation.waitForOpen()
    let error = try #require(model.navigation.error)
    model.reload(); while model.prs.loading { await Task.yield() }
    #expect(model.navigation.error == error && model.prs.error == nil)
    actions.failOpen = false; model.open(row); await model.navigation.waitForOpen()
    #expect(actions.opened.last?.category == "review" && model.navigation.error == nil)
    // Every open PR is shown now, Others included, so only a row the snapshot never held is refused.
    let project = try #require(model.prs.projects.first)
    let missing = try JSONDecoder().decode(DashboardPR.self, from: Data(#"{"number":999,"title":"Gone","url":"https://github.com/o/r/pull/999","state":"OPEN","category":"other"}"#.utf8))
    let hidden = DashboardRow(projectID: project.id, projectName: project.name, pr: missing, url: URL(string: missing.url!)!)
    model.open(hidden); await model.navigation.waitForOpen()
    #expect(!actions.opened.contains { $0.url == hidden.url.absoluteString })
    root.dashboardCoordinator?.retire()
    model.connect(DashboardFixture()); model.open(row)
    #expect(model.retired && !model.prs.loading && actions.opened.count == 2)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["leave", "dialog", "restart", "disconnect", "retire", "replace"])
func dashboardPendingOpenCancelsWhenItsOwnerOrSelectionChanges(change: String) async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions: actions), row = try #require(model.prs.mine.first)
    let gate = ProjectPageGate(); actions.gate = gate
    model.open(row); model.open(row); await gate.waitForStart()
    #expect(actions.opened.count == 1)
    root.presentRemoval { nil }; root.runBuild { nil }
    #expect(model.navigation.opening != nil) // Rejected presentations are not new navigation intents.
    switch change {
    case "leave": root.navigate(to: .terminal)
    case "dialog": root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    case "restart": root.presentRestart(perform: {})
    case "disconnect": await model.stop()
    case "replace": _ = root.makeDashboard(factory: NativeDashboardFeatureFactory(), pageActions: actions)
    default: root.dashboardCoordinator?.retire()
    }
    #expect(model.navigation.opening == nil)
    await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated.isEmpty && model.navigation.error == nil)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardNewerOpenSupersedesOlderAndReleasedCoordinatorCannotAct() async throws {
    var root: AppCoordinator? = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let actions = ProjectPageActions(), model = await connectedDashboard(root!, actions: actions)
    let child = try #require(root?.dashboardCoordinator)
    let first = try #require(model.prs.mine.first), second = try #require(model.prs.reviews.first)
    let gate = ProjectPageGate(); actions.gate = gate
    model.open(first); await gate.waitForStart()
    model.open(second); await model.navigation.waitForOpen()
    await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated == [second.url.absoluteString] && model.navigation.error == nil)
    root = nil
    model.open(first); await model.navigation.waitForOpen()
    #expect(actions.opened.count == 2)
    child.retire()
}

private actor HeldDashboardSnapshot: DashboardService {
    let gate = ProjectPageGate()
    func snapshot() async throws -> [DashboardProject] { try? await gate.wait(); return [] }
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardSnapshotRemovalCancelsAnOpenWithoutChangingFilters() async throws {
    let actions = ProjectPageActions(), service = DashboardFixture()
    let model = DashboardViewModel(pageActions: actions), child = DashboardCoordinator(model: model)
    model.connect(service); while model.prs.loading { await Task.yield() }
    let gate = ProjectPageGate(); actions.gate = gate
    model.open(try #require(model.prs.mine.first)); await gate.waitForStart()
    await service.removeRows(); model.reload(); while model.prs.loading { await Task.yield() }
    #expect(model.navigation.opening == nil && model.prs.projects.isEmpty)
    #expect(model.prs.visibleRows.isEmpty && model.prs.mine.isEmpty && model.prs.reviews.isEmpty && model.prs.warnings.isEmpty)
    await gate.finish(); await Task.yield()
    #expect(actions.navigated.isEmpty)
    child.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardPublishesDerivedRowsBeforeSnapshotCallbacks() async {
    let service = DashboardFixture(), model = DashboardViewModel(pageActions: ProjectPageActions())
    var snapshots = 0
    model.snapshotChanged = {
        snapshots += 1
        #expect(model.prs.mine.map(\.pr.number) == [1])
        #expect(model.prs.reviews.map(\.pr.number) == [2, 4])
        #expect(model.prs.warnings == ["Native: Sync unavailable"])
    }
    model.connect(service)
    while model.prs.loading { await Task.yield() }
    model.reload()
    while model.prs.loading { await Task.yield() }
    #expect(snapshots == 1)
    model.snapshotChanged = {}
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardOldDisconnectCannotClearReplacementConnectionOrSnapshot() async throws {
    let actions = ProjectPageActions(), model = DashboardViewModel(pageActions: actions)
    let old = HeldDashboardSnapshot(), current = DashboardFixture()
    model.connect(old); await old.gate.waitForStart()
    let stopping = Task { await model.stop() }
    while model.prs.loading { await Task.yield() }
    model.connect(current); while model.prs.loading { await Task.yield() }
    #expect(!model.prs.projects.isEmpty)
    await old.gate.finish(); await stopping.value
    #expect(!model.prs.projects.isEmpty)
    model.reload(); while model.prs.loading { await Task.yield() }
    #expect(await current.reads == 2)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardRefusesToOpenCachedRowsWhileDisconnectedOrRetired() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions: actions), row = try #require(model.prs.mine.first)
    await model.stop()
    model.open(row)
    #expect(actions.opened.isEmpty && model.navigation.error == "Connect to open pull requests in Cascade.")
    root.dashboardCoordinator?.retire()
    model.open(row); await model.navigation.waitForOpen()
    #expect(actions.opened.isEmpty)
}

@MainActor @Test func dashboardRowsCarryChecksDatesAndLabelColours() async throws {
    let service = DashboardFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.prs.mine.map(\.pr.number) == [1])
    #expect(model.prs.reviews.map(\.pr.number) == [2, 4])

    // A queued run outranks its stale conclusion.
    #expect(model.prs.mine[0].checks == .running && model.prs.mine[0].ciLabel == "CI running")
    #expect(model.prs.reviews[0].checks == .failing && model.prs.reviews[1].checks == .unknown)
    // Neither fixture PR carries a date, so both count as oldest.
    #expect(model.prs.mine[0].sortDate == .distantPast)

    await model.stop()
    model.retire()
}

@MainActor @Test func dashboardTicketColumnsCarryJiraLabelsReporterAndTheLowestLinkedPullRequest() async throws {
    let service = DashboardFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }

    // The Pull Request column is built from the rows the dashboard shows. #1 and #2 both name
    // REC-1, so the lower number wins and the column cannot flip as the snapshot reorders.
    // REC-9 belongs to #3, which is outside the review orbit, so it is not linked at all.
    #expect(model.prs.linkedPRs == ["REC-1": "#1", "REC-2": "#2"])

    // `acli` allows only a fixed field set on a search; labels and reporter are in it, and a
    // ticket without labels reports none rather than nil.
    let tickets = try JSONDecoder().decode([Ticket].self, from: Data(#"""
    [{"key":"REC-1","summary":"Ship it","status":"In Progress","type":"Task","priority":"Highest","stage":"inProgress","level":"urgent",
      "labels":["ios","created-via-claude"],"reporter":"Chen Ding"},
     {"key":"OPS-7","summary":"Rotate keys","status":"To Do","type":"Bug","priority":"Low","stage":"toDo","level":"low"}]
    """#.utf8))
    let rows = tickets.map { DashboardTicketRow(ticket: $0, url: URL(string: "https://j/browse/\($0.key)")!) }

    #expect(rows[0].labels == ["ios", "created-via-claude"])
    #expect(rows[0].sortLabels == "ios created-via-claude")
    #expect(rows[0].reporter == "Chen Ding" && rows[0].project == "REC")
    #expect(rows[0].stage == .inProgress && rows[0].urgent)
    #expect(rows[1].labels.isEmpty && rows[1].reporter.isEmpty && rows[1].project == "OPS")
    #expect(rows[1].stage == .toDo && !rows[1].urgent)

    // The stamped sort keys start empty: the table fills them from its own live lookups.
    #expect(rows[0].sessionName.isEmpty && rows[0].pullRequest.isEmpty)
}

@MainActor @Test func dashboardTicketStagesPrioritiesAndMyTicketsTags() async throws {
    // The backend reads Jira's words (`tickets.rs`); a row carries only what it was told.
    func row(_ key: String, _ stage: String?, _ level: String?, reopened: Bool = false) -> DashboardTicketRow {
        let ticket = Ticket(key: key, summary: key, status: "Open", type: "Task", priority: "", stage: stage, level: level, reopened: reopened)
        return DashboardTicketRow(ticket: ticket, url: URL(string: "https://j/browse/\(key)")!)
    }
    #expect(row("A", "toDo", "medium").stage == .toDo)
    #expect(row("C", "inProgress", "medium").stage == .inProgress)
    #expect(row("E", "pendingRelease", "low").stage == .pendingRelease)
    #expect(row("F", "blocked", "urgent").stage == .blocked)
    // A ticket from a snapshot written before the backend named stages reads as in progress and
    // Medium until the next sync, as does a name this build does not know.
    #expect(row("X", nil, nil).stage == .inProgress && row("X", nil, nil).level == .medium)
    #expect(row("Y", "mystery", "whatever").stage == .inProgress && row("Y", "mystery", "whatever").level == .medium)
    #expect(row("G", "toDo", "urgent").urgent && !row("I", "toDo", "high").urgent)

    let rows = [row("A", "toDo", "medium"), row("G", "toDo", "urgent"),
                row("D", "inProgress", "medium", reopened: true), row("F", "blocked", "low")]
    #expect(DashboardTicketsModel.Filter.urgent.matches(rows[1]) && !DashboardTicketsModel.Filter.urgent.matches(rows[0]))
    #expect(DashboardTicketsModel.Filter.stage(.blocked).matches(rows[3]))
    #expect(DashboardTicketsModel.Filter.allCases.map(\.id) == ["all", "toDo", "inProgress", "pendingRelease", "blocked", "urgent"])

    // The four levels the backend sends draw the rows' dots.
    #expect(row("J", "toDo", "urgent").level == .urgent && row("K", "toDo", "high").level == .high)
    #expect(row("L", "toDo", "low").level == .low && row("M", "toDo", "medium").level == .medium)
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardShowTicketsPicksTheTicketsTab() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    let coordinator = DashboardCoordinator(model: model)
    model.showTickets(.urgent)
    #expect(model.tickets.filter == .urgent && model.tab == .tickets)
    // Tickets is a tab of the page: nothing is pushed over it.
    #expect(coordinator.path.isEmpty)
    model.showTickets()
    #expect(coordinator.path.isEmpty && model.tickets.filter == .all)
    coordinator.retire()
}

/// The PR fixture's snapshot plus a fixed set of tickets.
private actor TicketFixture: DashboardService, DashboardTicketService {
    let prs = DashboardFixture()
    var syncs = 0
    var failSync = false
    func setSyncFailure() { failSync = true }
    func snapshot() async throws -> [DashboardProject] { try await prs.snapshot() }
    func syncPRs() async throws {
        syncs += 1
        try await Task.sleep(for: .milliseconds(20))
        if failSync { throw BackendError.operation("Sync failed") }
    }
    func myTickets() async throws -> [DashboardTicketRow] {
        let tickets = try JSONDecoder().decode([Ticket].self, from: Data(#"""
        [{"key":"REC-7","summary":"Later","status":"Open","statusCategory":"new","priority":"Medium","stage":"toDo","level":"medium"},
         {"key":"REC-6","summary":"Start next","status":"Open","statusCategory":"new","priority":"Urgent","stage":"toDo","level":"urgent"},
         {"key":"REC-1","summary":"Has a PR","status":"In PR Review","statusCategory":"indeterminate","priority":"High","stage":"inProgress","level":"high"},
         {"key":"REC-5","summary":"Doing","status":"In Development","statusCategory":"indeterminate","priority":"Low","stage":"inProgress","level":"low"},
         {"key":"REC-8","summary":"Stuck","status":"Blocked","statusCategory":"indeterminate","priority":"Low","stage":"blocked","level":"low"}]
        """#.utf8))
        return tickets.map { DashboardTicketRow(ticket: $0, url: URL(string: "https://j/browse/\($0.key)")!) }
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardTicketsTabListsUrgentFirstAndCountsInOnePass() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(TicketFixture())
    while model.prs.loading || model.tickets.loading || model.tickets.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    // The Tickets tab: urgent first, the rest in Jira's order; the tag narrows, the counts take one pass.
    #expect(model.tickets.screenRows.map(\.id) == ["REC-6", "REC-7", "REC-1", "REC-5", "REC-8"])
    let counts = model.tickets.pageCounts
    model.tickets.filter = .stage(.toDo)
    #expect(model.tickets.screenRows.map(\.id) == ["REC-6", "REC-7"])
    #expect(counts[.all] == 5 && counts[.stage(.toDo)] == 2 && counts[.stage(.inProgress)] == 2)
    #expect(counts[.stage(.blocked)] == 1 && counts[.stage(.pendingRelease)] == 0 && counts[.urgent] == 1)
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardShowPullRequestsPicksTheTabAndAuthor() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(TicketFixture())
    while model.prs.loading || model.tickets.loading || model.tickets.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    model.showPullRequests(.review)
    #expect(model.tab == .pullRequests && model.prs.author == .review)

    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardSyncPRsReloadsOnceAndReportsFailure() async throws {
    let service = TicketFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.prs.loading { try await Task.sleep(for: .milliseconds(10)) }
    let reads = await service.prs.reads
    // A second press while one sync runs is ignored; the finished sync reloads the snapshot.
    model.prs.sync(); model.prs.sync()
    #expect(model.prs.syncing)
    while model.prs.syncing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await service.syncs == 1)
    #expect(await service.prs.reads == reads + 1 && model.prs.error == nil)
    // A failed sync says so and keeps the rows it had.
    await service.setSyncFailure()
    model.prs.sync()
    while model.prs.syncing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.prs.error == "Sync failed" && !model.prs.mine.isEmpty)
    await model.stop()
    model.retire()
}
