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
        [{"id":"p","name":"Native","repo":"o/r","lastSynced":"2026-09-12T12:00:00Z","prs":[
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

@MainActor @Test func dashboardGroupsReviewOrbitFiltersAndRetainsSnapshotOnFailure() async throws {
    let service = DashboardFixture()
    let actions = ProjectPageActions()
    let model = DashboardViewModel(pageActions: actions), coordinator = DashboardCoordinator(model: model)
    model.connect(service)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.mine.map(\.pr.number) == [1])
    #expect(model.reviews.map(\.pr.number) == [2, 4])
    #expect(model.mine[0].ciLabel == "CI running")
    #expect(model.reviews[0].reviewLabel == "Approved")
    #expect(model.warnings == ["Native: Sync unavailable"])
    let row = try #require(model.reviews.first { $0.pr.number == 2 })
    model.open(row); await model.navigation.waitForOpen()
    let opened = actions.opened.last
    #expect(opened?.category == "review" && opened?.url == row.url.absoluteString)
    await service.setFailure()
    model.refresh()
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.visibleRows.contains(row))
    #expect(model.updated != nil && model.error == "Fixture offline")
    await model.stop()
    coordinator.retire()
}

@MainActor @Test func dashboardOpenFailurePreservesNavigationAndAllowsRetry() async throws {
    let service = DashboardFixture()
    let actions = ProjectPageActions(); actions.failOpen = true
    let model = DashboardViewModel(pageActions: actions), coordinator = DashboardCoordinator(model: model)
    model.connect(service)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    let row = try #require(model.mine.first)
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
    while model.loading { await Task.yield() }
    return model
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardCoordinatorOwnsVisibleRowsAndPreservesFeedbackAcrossSnapshotReads() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions: actions), row = try #require(model.reviews.first)
    #expect(root.dashboardCoordinator?.model === model)
    root.navigate(to: .terminal); model.open(row); model.openSession(row); await model.navigation.waitForOpen()
    #expect(actions.opened.isEmpty)
    root.navigate(to: .overview)
    actions.failOpen = true; model.open(row); await model.navigation.waitForOpen()
    let error = try #require(model.navigation.error)
    model.refresh(); while model.loading { await Task.yield() }
    #expect(model.navigation.error == error && model.error == nil)
    actions.failOpen = false; model.open(row); await model.navigation.waitForOpen()
    #expect(actions.opened.last?.category == "review" && model.navigation.error == nil)
    let hidden = try #require(model.rows.first { $0.pr.number == 3 })
    model.open(hidden); model.openSession(hidden); await model.navigation.waitForOpen()
    #expect(!actions.opened.contains { $0.url == hidden.url.absoluteString })
    root.dashboardCoordinator?.retire()
    model.connect(DashboardFixture()); model.open(row)
    #expect(model.retired && !model.loading && actions.opened.count == 2)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["leave", "dialog", "restart", "disconnect", "retire", "replace"])
func dashboardPendingOpenCancelsWhenItsOwnerOrSelectionChanges(change: String) async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions: actions), row = try #require(model.mine.first)
    let gate = ProjectPageGate(); actions.gate = gate
    model.open(row); model.open(row); await gate.waitForStart()
    #expect(actions.opened.count == 1)
    root.presentRemoval { nil }; root.presentBuild { nil }
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
    let first = try #require(model.mine.first), second = try #require(model.reviews.first)
    let gate = ProjectPageGate(); actions.gate = gate
    model.open(first); await gate.waitForStart()
    model.open(second); await model.navigation.waitForOpen()
    await gate.finish(failing: true); await Task.yield()
    #expect(actions.navigated == [second.url.absoluteString] && model.navigation.error == nil)
    root = nil
    model.open(first); model.openSession(first); await model.navigation.waitForOpen()
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
    model.connect(service); while model.loading { await Task.yield() }
    let gate = ProjectPageGate(); actions.gate = gate
    model.open(try #require(model.mine.first)); await gate.waitForStart()
    await service.removeRows(); model.refresh(); while model.loading { await Task.yield() }
    #expect(model.navigation.opening == nil && model.projects.isEmpty)
    #expect(model.rows.isEmpty && model.visibleRows.isEmpty && model.mine.isEmpty && model.reviews.isEmpty && model.warnings.isEmpty)
    // An empty dashboard is not a filtered-out one: the view shows "Nothing matches this filter"
    // only while `filtering`, so an emptied snapshot must leave it false.
    #expect(!model.filtering && model.visibleMine.isEmpty && model.visibleReviews.isEmpty && model.visibleTickets.isEmpty)
    await gate.finish(); await Task.yield()
    #expect(actions.navigated.isEmpty)
    child.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardPublishesDerivedRowsBeforeSnapshotCallbacks() async {
    let service = DashboardFixture(), model = DashboardViewModel(pageActions: ProjectPageActions())
    var snapshots = 0
    model.snapshotChanged = {
        snapshots += 1
        #expect(model.mine.map(\.pr.number) == [1])
        #expect(model.reviews.map(\.pr.number) == [2, 4])
        #expect(model.warnings == ["Native: Sync unavailable"])
    }
    model.connect(service)
    while model.loading { await Task.yield() }
    model.refresh()
    while model.loading { await Task.yield() }
    #expect(snapshots == 1)
    model.snapshotChanged = {}
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardOldDisconnectCannotClearReplacementConnectionOrSnapshot() async throws {
    let actions = ProjectPageActions(), model = DashboardViewModel(pageActions: actions)
    let old = HeldDashboardSnapshot(), current = DashboardFixture()
    model.connect(old); await old.gate.waitForStart()
    let stopping = Task { await model.stop() }
    while model.loading { await Task.yield() }
    model.connect(current); while model.loading { await Task.yield() }
    #expect(!model.projects.isEmpty)
    await old.gate.finish(); await stopping.value
    #expect(!model.projects.isEmpty)
    model.refresh(); while model.loading { await Task.yield() }
    #expect(await current.reads == 2)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardRefusesToOpenCachedRowsWhileDisconnectedOrRetired() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), actions = ProjectPageActions()
    let model = await connectedDashboard(root, actions: actions), row = try #require(model.mine.first)
    await model.stop()
    model.open(row)
    #expect(actions.opened.isEmpty && model.navigation.error == "Connect to open pull requests in Craft.")
    model.openSession(row)
    #expect(actions.opened.isEmpty && model.navigation.error == "Connect to open pull requests in Craft.")
    root.dashboardCoordinator?.retire()
    model.open(row); model.openSession(row); await model.navigation.waitForOpen()
    #expect(actions.opened.isEmpty)
}

@MainActor @Test func dashboardSearchNarrowsRowsAndClears() async throws {
    let service = DashboardFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }

    #expect(!model.filtering)
    #expect(model.visibleMine.map(\.pr.number) == [1])
    #expect(model.visibleReviews.map(\.pr.number) == [2, 4])

    // The search runs over the row's own text.
    model.query = "legacy"
    #expect(model.filtering)
    #expect(model.visibleMine.isEmpty)
    #expect(model.visibleReviews.map(\.pr.number) == [4])
    #expect(model.visibleTickets.isEmpty)

    model.clearFilter()
    #expect(!model.filtering)
    #expect(model.visibleMine.map(\.pr.number) == [1])
    #expect(model.visibleReviews.map(\.pr.number) == [2, 4])

    // A queued run outranks its stale conclusion.
    #expect(model.visibleMine[0].checks == .running && model.visibleMine[0].ciLabel == "CI running")
    #expect(model.visibleReviews[0].checks == .failing && model.visibleReviews[1].checks == .unknown)
    // Neither fixture PR carries a date, so both count as oldest.
    #expect(model.visibleMine[0].sortDate == .distantPast)
    // A pale label keeps its own colour; a missing or malformed one falls back instead of going wrong.
    // Theme colours are dynamic NSColors built fresh per access, so compare resolved components.
    func rgb(_ color: Color) -> [Int] {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return [] }
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }
    #expect(rgb(Theme.tagTint("ededed")) == [0xED, 0xED, 0xED])
    #expect(rgb(Theme.tagTint("#d73a4a")) == [0xD7, 0x3A, 0x4A])
    #expect(rgb(Theme.tagTint(nil)) == rgb(Theme.textSecondary))
    #expect(rgb(Theme.tagTint("nothex")) == rgb(Theme.textSecondary))

    // The filter field reaches label names, so a tag is searchable whether or not its column is shown.
    model.query = "needs-qa"
    #expect(model.visibleMine.map(\.pr.number) == [1] && model.visibleReviews.isEmpty)
    model.clearFilter()

    await model.stop()
    model.retire()
}

@MainActor @Test func dashboardTicketColumnsCarryJiraLabelsReporterAndTheLowestLinkedPullRequest() async throws {
    let service = DashboardFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }

    // The Pull Request column is built from the rows the dashboard shows. #1 and #2 both name
    // REC-1, so the lower number wins and the column cannot flip as the snapshot reorders.
    // REC-9 belongs to #3, which is outside the review orbit, so it is not linked at all.
    #expect(model.linkedPRs == ["REC-1": "#1", "REC-2": "#2"])

    // `acli` allows only a fixed field set on a search; labels and reporter are in it, and a
    // ticket without labels reports none rather than nil.
    let tickets = try JSONDecoder().decode([JiraTicket].self, from: Data(#"""
    [{"key":"REC-1","summary":"Ship it","status":"In Progress","type":"Task","priority":"Highest",
      "labels":["ios","created-via-claude"],"reporter":"Chen Ding"},
     {"key":"OPS-7","summary":"Rotate keys","status":"To Do","type":"Bug","priority":"Low"}]
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
    func row(_ key: String, _ status: String, _ category: String?, _ priority: String) -> DashboardTicketRow {
        let ticket = JiraTicket(key: key, summary: key, status: status, type: "Task", priority: priority, statusCategory: category)
        return DashboardTicketRow(ticket: ticket, url: URL(string: "https://j/browse/\(key)")!)
    }
    // Status names win over Jira's category: Ready for Development is "indeterminate" on the board
    // but has not been started, and Reopened is "new" but is back in someone's hands.
    #expect(row("A", "Ready for Development", "indeterminate", "Medium").stage == .toDo)
    #expect(row("B", "Open", "new", "Medium").stage == .toDo)
    #expect(row("C", "In PR Review", "indeterminate", "Medium").stage == .inProgress)
    #expect(row("D", "Reopened", "new", "Urgent").stage == .inProgress)
    #expect(row("E", "Pending Release", "indeterminate", "Low").stage == .pendingRelease)
    #expect(row("F", "Blocked - Record", "indeterminate", "Urgent").stage == .blocked)
    // This Jira's top priority is named Urgent; it counts as urgent alongside the stock names.
    #expect(row("G", "Open", "new", "Urgent").urgent && row("H", "Open", "new", "Highest").urgent)
    #expect(!row("I", "Open", "new", "High").urgent)

    // Blocked, then reopened, then in progress, then urgent to-dos; the rest wait on My Tickets.
    let rows = [row("A", "Open", "new", "Medium"), row("G", "Open", "new", "Urgent"),
                row("D", "Reopened", "new", "Medium"), row("F", "Blocked", nil, "Low")]
    #expect(rows.map(\.attentionRank) == [nil, 3, 1, 0])
    #expect(row("C", "In PR Review", "indeterminate", "Low").attentionRank == 2)
    #expect(DashboardViewModel.TicketFilter.urgent.matches(rows[1]) && !DashboardViewModel.TicketFilter.urgent.matches(rows[0]))
    #expect(DashboardViewModel.TicketFilter.stage(.blocked).matches(rows[3]))
    #expect(DashboardViewModel.TicketFilter.allCases.map(\.id) == ["all", "toDo", "inProgress", "pendingRelease", "blocked", "urgent"])

    // Priorities fold onto four levels for the rows' dots; unknown names read as Medium.
    #expect(row("J", "Open", "new", "Highest").level == .urgent && row("K", "Open", "new", "Major").level == .high)
    #expect(row("L", "Open", "new", "Trivial").level == .low && row("M", "Open", "new", "Whatever").level == .medium)
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardViewAllPushesMyTicketsAndBackPops() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    let coordinator = DashboardCoordinator(model: model)
    model.showTickets(.urgent)
    #expect(model.ticketFilter == .urgent)
    #expect(coordinator.path == [.dashboardTickets(model)])
    // A second View All while the list is up does not stack another copy.
    model.showTickets()
    #expect(coordinator.path.count == 1 && model.ticketFilter == .all)
    model.closeTickets()
    #expect(coordinator.path.isEmpty)
    coordinator.retire()
}

/// The PR fixture's snapshot plus a fixed set of tickets, for the home screen's short list.
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
        let tickets = try JSONDecoder().decode([JiraTicket].self, from: Data(#"""
        [{"key":"REC-7","summary":"Later","status":"Open","statusCategory":"new","priority":"Medium"},
         {"key":"REC-6","summary":"Start next","status":"Open","statusCategory":"new","priority":"Urgent"},
         {"key":"REC-1","summary":"Has a PR","status":"In PR Review","statusCategory":"indeterminate","priority":"High"},
         {"key":"REC-5","summary":"Doing","status":"In Development","statusCategory":"indeterminate","priority":"Low"},
         {"key":"REC-8","summary":"Stuck","status":"Blocked","statusCategory":"indeterminate","priority":"Low"}]
        """#.utf8))
        return tickets.map { DashboardTicketRow(ticket: $0, url: URL(string: "https://j/browse/\($0.key)")!) }
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardShortListSkipsWorkItsPullRequestAlreadyShows() async throws {
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(TicketFixture())
    while model.loading || model.ticketsLoading || model.tickets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    // REC-1 is in review, but PR #1 names it and is already listed; the medium to-do waits on My Tickets.
    #expect(model.attentionTickets(from: model.visibleTickets, limit: 5).map(\.id) == ["REC-8", "REC-5", "REC-6"])
    #expect(model.attentionTickets(from: model.visibleTickets, limit: 2).map(\.id) == ["REC-8", "REC-5"])

    // My Tickets: urgent first, the rest in Jira's order; the tag narrows, the counts take one pass.
    let visible = model.visibleTickets
    #expect(model.screenTickets(from: visible).map(\.id) == ["REC-6", "REC-7", "REC-1", "REC-5", "REC-8"])
    model.ticketFilter = .stage(.toDo)
    #expect(model.screenTickets(from: visible).map(\.id) == ["REC-6", "REC-7"])
    let counts = model.ticketCounts(of: visible)
    #expect(counts[.all] == 5 && counts[.stage(.toDo)] == 2 && counts[.stage(.inProgress)] == 2)
    #expect(counts[.stage(.blocked)] == 1 && counts[.stage(.pendingRelease)] == 0 && counts[.urgent] == 1)
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardSyncPRsReloadsOnceAndReportsFailure() async throws {
    let service = TicketFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    let reads = await service.prs.reads
    // A second press while one sync runs is ignored; the finished sync reloads the snapshot.
    model.syncPRs(); model.syncPRs()
    #expect(model.syncing)
    while model.syncing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await service.syncs == 1)
    #expect(await service.prs.reads == reads + 1 && model.error == nil)
    // A failed sync says so and keeps the rows it had.
    await service.setSyncFailure()
    model.syncPRs()
    while model.syncing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error == "Sync failed" && !model.mine.isEmpty)
    await model.stop()
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardBackClearsTheSharedSearch() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = root.makeDashboard(factory: NativeDashboardFeatureFactory(), pageActions: ProjectPageActions())
    model.showTickets(); model.query = "REC-12"
    model.closeTickets()
    #expect(model.query.isEmpty && root.dashboardCoordinator?.path.isEmpty == true)
    // Picking Overview while My Tickets is up does the same.
    model.showTickets(); model.query = "REC-12"
    root.navigate(to: SidebarDestination.overview)
    #expect(model.query.isEmpty && root.dashboardCoordinator?.path.isEmpty == true)
    root.dashboardCoordinator?.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func dashboardTicketsRouteOpensOnAllTickets() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = root.makeDashboard(factory: NativeDashboardFeatureFactory(), pageActions: ProjectPageActions())
    model.showTickets(.urgent); model.closeTickets()
    root.navigate(to: Route.dashboardTickets)
    #expect(model.ticketFilter == .all && root.dashboardCoordinator?.path == [.dashboardTickets(model)])
    root.dashboardCoordinator?.retire()
}
