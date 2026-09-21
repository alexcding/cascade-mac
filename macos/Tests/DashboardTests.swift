import Foundation
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
          {"number":1,"title":"My draft","url":"https://github.com/o/r/pull/1","state":"OPEN","category":"mine","isDraft":true,"ci":{"status":"queued","conclusion":"failure"}},
          {"number":2,"title":"Reviewed already","url":"https://github.com/o/r/pull/2","state":"OPEN","category":"other","awaitingMyReview":true,"reviewDecision":"APPROVED","ci":{"status":"completed","conclusion":"failure"}},
          {"number":3,"title":"Not in orbit","url":"https://github.com/o/r/pull/3","state":"OPEN","category":"review","awaitingMyReview":false},
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
