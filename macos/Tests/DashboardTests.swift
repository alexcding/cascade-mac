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

@MainActor @Test func dashboardFilterBarNarrowsRowsAndLeavesTicketsToTheAllSegment() async throws {
    let service = DashboardFixture()
    let model = DashboardViewModel(pageActions: ProjectPageActions())
    model.connect(service)
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }

    #expect(!model.filtering)
    #expect(model.visibleMine.map(\.pr.number) == [1])
    #expect(model.visibleReviews.map(\.pr.number) == [2, 4])

    // Failing reads the checks alone: #4 has no checks at all, and #1 is still running, so
    // neither survives the segment even though #1 carries a stale failing conclusion.
    model.filter = .failing
    #expect(model.filtering)
    #expect(model.visibleMine.isEmpty)
    #expect(model.visibleReviews.map(\.pr.number) == [2])

    // The search runs over the row's own text and is independent of the segment.
    model.filter = .all
    model.query = "legacy"
    #expect(model.visibleMine.isEmpty)
    #expect(model.visibleReviews.map(\.pr.number) == [4])
    #expect(model.visibleTickets.isEmpty)

    model.clearFilter()
    #expect(!model.filtering)
    #expect(model.visibleMine.map(\.pr.number) == [1])
    #expect(model.visibleReviews.map(\.pr.number) == [2, 4])

    // A queued run outranks its stale conclusion, and the column says so in words.
    #expect(model.visibleMine[0].checks == .running && model.visibleMine[0].checksTitle == "Running")
    #expect(model.visibleReviews[0].checks == .failing && model.visibleReviews[0].checksTitle == "Failing")
    #expect(model.visibleReviews[1].checks == .unknown && model.visibleReviews[1].checksTitle == "No checks")

    // Labels survive the lean snapshot, in order, and a row without any reports none rather than nil.
    // Age sorts by age: the youngest first when ascending, which is the opposite order to the
    // creation dates under it. Neither fixture PR carries a date, so both land at the oldest end.
    #expect(model.visibleMine[0].sortAge == -Date.distantPast.timeIntervalSinceReferenceDate)

    #expect(model.visibleMine[0].tags.map(\.name) == ["bug", "ui", "needs-qa"])
    #expect(model.visibleMine[0].sortTags == "bug ui needs-qa")
    #expect(model.visibleReviews[0].tags.isEmpty)
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
    #expect(rows[0].inProgress && rows[0].urgent)
    #expect(rows[1].labels.isEmpty && rows[1].reporter.isEmpty && rows[1].project == "OPS")
    #expect(!rows[1].inProgress && !rows[1].urgent)

    // The stamped sort keys start empty: the table fills them from its own live lookups.
    #expect(rows[0].sessionName.isEmpty && rows[0].pullRequest.isEmpty)
}
