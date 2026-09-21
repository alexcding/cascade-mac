import Foundation
import Testing

private actor HeldLogsService: LogService {
    var readGate: ProjectPageGate?
    var clearGate: ProjectPageGate?
    var cleared: [String] = []
    var deleted = false
    func holdRead(_ gate: ProjectPageGate) { readGate = gate }
    func holdClear(_ gate: ProjectPageGate) { clearGate = gate }
    func categories() -> [String] { ["event", "poller"] }
    func entries(category: String, errorsOnly: Bool) async throws -> [LogEntry] {
        let wasDeleted = deleted
        if let gate = readGate { readGate = nil; try await gate.wait() }
        if wasDeleted { return [] }
        return try JSONDecoder().decode([LogEntry].self, from: Data(#"""
        [{"seq":1,"category":"event","level":"info","type":"pr_opened","payload":"{\"pr\":{\"number\":42,\"title\":\"Native UI\",\"url\":\"https://github.com/o/r/pull/42\"}}","created_at":"2026-09-12T12:00:00Z"}]
        """#.utf8))
    }
    func clear(category: String) async throws {
        cleared.append(category)
        if let gate = clearGate { clearGate = nil; try await gate.wait() }
        deleted = true
    }
}

@MainActor private func loadedLogs(_ service: HeldLogsService, actions: ProjectPageActions) async -> LogsViewModel {
    let model = NativeLogsFeatureFactory().logs(pageActions: actions, copy: actions.copy)
    model.connect(service); model.refresh()
    while model.loading { await Task.yield() }
    return model
}

@MainActor @Test(.timeLimit(.minutes(1))) func logsClearRequestsRejectCancelledForeignAndReconnectedConfirmations() async throws {
    let service = HeldLogsService(), actions = ProjectPageActions()
    let model = await loadedLogs(service, actions: actions), child = LogsCoordinator(model: model)
    let foreign = await loadedLogs(service, actions: actions)
    model.requestClear()
    let cancelled = try #require(child.confirmation)
    child.cancel(id: UUID())
    #expect(child.confirmation == cancelled)
    child.cancel(id: cancelled.id)
    #expect(await model.clear(cancelled) == false)
    #expect(await foreign.clear(cancelled) == false)
    model.requestClear()
    let original = try #require(child.confirmation)
    model.requestClear() // repeated clicks must not replace the reviewed token
    #expect(child.confirmation == original && model.canClear(original))
    model.connect(HeldLogsService())
    await child.confirm(id: original.id)
    #expect(child.confirmation == original && !model.canClear(original))
    #expect(model.clearFailure(for: original)?.contains("connection") == true)
    #expect(await service.cleared.isEmpty)
    child.retire(); await foreign.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func logsClearCoalescesWritesAndNeverAppliesAcrossConnections(reconnect: Bool) async throws {
    let service = HeldLogsService(), actions = ProjectPageActions(), gate = ProjectPageGate()
    let model = await loadedLogs(service, actions: actions), child = LogsCoordinator(model: model)
    await service.holdClear(gate)
    model.requestClear()
    let request = try #require(child.confirmation)
    let clear = Task { await child.confirm(id: request.id) }
    await gate.waitForStart()
    await child.confirm(id: request.id); child.cancel(id: request.id)
    #expect(model.clearing && child.confirmation == request && !model.canRequestClear)
    #expect(await service.cleared == ["event"])
    if reconnect {
        model.connect(HeldLogsService()); model.refresh()
        while model.loading { await Task.yield() }
        #expect(model.rows.count == 1)
    }
    await gate.finish(); await clear.value
    while model.loading { await Task.yield() }
    #expect(model.rows.count == (reconnect ? 1 : 0))
    #expect(!model.clearing && child.confirmation == nil && model.error == nil)
    child.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func logsClearingInvalidatesHeldReadsWithoutWaitingForTheirTransport() async throws {
    let service = HeldLogsService(), actions = ProjectPageActions(), gate = ProjectPageGate()
    let model = await loadedLogs(service, actions: actions), child = LogsCoordinator(model: model)
    await service.holdRead(gate); model.refresh(); await gate.waitForStart()
    model.requestClear(); await child.confirm(id: try #require(child.confirmation).id)
    while model.loading { await Task.yield() }
    #expect(model.rows.isEmpty && child.confirmation == nil)
    await gate.finish()
    model.refresh()
    while model.loading { await Task.yield() }
    #expect(model.rows.isEmpty && model.error == nil)
    child.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func logsStoppingOldConnectionCannotDisconnectItsReplacement() async throws {
    let old = HeldLogsService(), fresh = HeldLogsService(), actions = ProjectPageActions(), gate = ProjectPageGate()
    let model = await loadedLogs(old, actions: actions)
    await old.holdRead(gate); model.refresh(); await gate.waitForStart()
    let stop = Task { await model.stop() }
    while model.canRequestClear { await Task.yield() }
    model.connect(fresh); model.refresh()
    while model.loading { await Task.yield() }
    await gate.finish(); await stop.value
    #expect(model.canRequestClear && model.rows.count == 1 && model.error == nil)
    model.retire()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["category", "errors", "search", "leave", "dialog", "clear", "disconnect", "replace"])
func logsActionsCancelWhenTheirModelOrPresentationChanges(change: String) async throws {
    let service = HeldLogsService(), actions = ProjectPageActions(), gate = ProjectPageGate()
    let model = await loadedLogs(service, actions: actions)
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installLogs(model)
    let settingsChild = root.installSettings(settingsFixtureModel(), runtime: SettingsRuntimeFixture())
    settingsChild.model.section = .activity
    root.setSettingsPresented(true)
    actions.gate = gate
    let row = try #require(model.rows.first)
    model.open(row); model.open(row); await gate.waitForStart()
    #expect(actions.opened.count == 1)
    model.category = "event"; model.errorsOnly = false; model.search = ""
    #expect(model.navigation.opening == row.link)
    switch change {
    case "category": model.category = "poller"
    case "errors": model.errorsOnly = true
    case "search": model.search = "no match"
    case "leave": root.setSettingsPresented(false)
    case "dialog": root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    case "clear": model.requestClear()
    case "disconnect": await model.stop()
    default: root.installLogs(await loadedLogs(service, actions: actions))
    }
    #expect(model.navigation.opening == nil)
    await gate.finish(); await Task.yield()
    #expect(actions.navigated.isEmpty && model.navigation.error == nil)
    child.retire(); root.logsCoordinator?.retire(); settingsChild.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func logsCoordinatorValidatesCurrentRowsOwnershipAndPresentationBeforeActions() async throws {
    let service = HeldLogsService(), actions = ProjectPageActions()
    let model = await loadedLogs(service, actions: actions)
    var root: AppCoordinator? = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = try #require(root).installLogs(model)
    let row = try #require(model.rows.first)
    model.open(row); model.copyEntry(row); model.requestClear()
    #expect(actions.copied.isEmpty && actions.opened.isEmpty && child.confirmation == nil)
    let settingsChild = try #require(root).installSettings(settingsFixtureModel(), runtime: SettingsRuntimeFixture())
    settingsChild.model.section = .activity
    root?.setSettingsPresented(true)
    model.search = "hidden"; model.open(row); model.copyEntry(row)
    #expect(actions.copied.isEmpty && actions.opened.isEmpty)
    model.search = ""
    actions.failOpen = true; model.open(row); await model.navigation.waitForOpen()
    #expect(model.navigation.error?.contains("Fixture open failed") == true && model.error == nil)
    model.refresh(); while model.loading { await Task.yield() }
    #expect(model.navigation.error != nil)
    model.copyEntry(row)
    #expect(actions.copied.first?.contains(row.payload!) == true)
    model.requestClear()
    // The confirmation is a sheet on the Settings window: deep links wait for it, but the main
    // window's own presentations do not.
    #expect(root?.canRoute == false && root?.canPresent == true)
    child.cancel(id: try #require(child.confirmation).id)
    #expect(root?.canRoute == true)
    root = nil
    model.copyEntry(row); model.requestClear()
    #expect(actions.copied.count == 1 && child.confirmation == nil)
    child.retire()
}
