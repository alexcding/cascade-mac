import AppKit
import Foundation
import SwiftUI
import Testing

private actor RefreshTransport: BackendTransport {
    var requests: [URLRequest] = []
    var includesProject = true
    private var includesTab = false
    private var includesSession = false
    func addSession() { includesSession = true }
    private var holdTabs = false
    private var heldTabs: CheckedContinuation<Void, Never>?
    var tabsAreHeld: Bool { heldTabs != nil }
    func holdNextTabs() { holdTabs = true }
    func addTab() { includesTab = true }
    func removeTab() { includesTab = false }
    func releaseTabs(holdNext: Bool = false) { holdTabs = holdNext; heldTabs?.resume(); heldTabs = nil }
    func removeProject() { includesProject = false }
    func reset() { requests.removeAll() }
    var paths: [String] { requests.compactMap { $0.url?.path } }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let body: String
        switch url.path {
        case Routes.PROJECTS:
            body = includesProject ? #"[{"id":"p","name":"Project","repo":"example/repo","workspace":"/fixture","jiraProjectKey":"REC"}]"# : "[]"
        case Routes.TABS:
            body = includesTab ? #"{"tabs":[{"id":"t","kind":"web","title":"New tab","url":"https://example.test"}]}"# : #"{"tabs":[]}"#
        case Routes.TASKS:
            body = includesSession ? #"[{"id":"s","projectId":"p","workspace":"/fixture","worktree":"/fixture/work","title":"Session","branch":"feature","url":"","pinned":true}]"# : "[]"
        case Routes.DASHBOARD, Routes.PRS_TRAY: body = "[]"
        case Routes.projectJira("p"), Routes.projectBoard("p"): body = #"{"items":[]}"#
        case Routes.projectPrs("p"): body = #"{"prs":[],"refreshing":false}"#
        case Routes.JIRA_SITE: body = #"{"baseUrl":"https://jira.example.test"}"#
        default: body = "{}"
        }
        if url.path == Routes.TABS, holdTabs {
            holdTabs = false
            await withCheckedContinuation { heldTabs = $0 }
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class RefreshRuntime: BackendRuntimeServing {
    var onEvent: (BackendRuntimeEvent) -> Void = { _ in }
    let transport = RefreshTransport()
    func start() throws -> APIClient {
        try APIClient(baseURL: URL(string: "http://127.0.0.1:43187")!, transport: transport)
    }
    func startEvents() { onEvent(.connected) }
    func stopEvents() {}
    func stop() {}
    func emit(_ type: String, project: String? = nil, id: String? = nil, scope: String? = nil) {
        onEvent(.message(ServerEvent(type: type, projectId: project, id: id, scope: scope)))
    }
}

@MainActor private func refreshApp(_ runtime: RefreshRuntime, preferences: UserDefaults) -> AppViewModel {
    _ = NSApplication.shared
    return AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }), backendRuntime: runtime,
        shellFactory: NativeShellFeatureFactory(preferences: preferences),
        platformFactory: NativeAppPlatformFactory(configuration: { throw BackendError.configuration("No test terminal") }),
        welcomeStore: TransientWelcomeStore(shown: true),
        selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
}

@MainActor private func refreshEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw BackendError.operation("Refresh did not complete") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test func sidebarFirstLayoutHasNavigationBeforeAsyncLoading() throws {
    let suite = "sidebar-first-layout-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = refreshApp(RefreshRuntime(), preferences: preferences)
    let initial = model.root.entries
    let hosting = NSHostingView(rootView: SidebarView(viewModel: model.root))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 420),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }
    let list = try #require(outline(in: hosting))
    // No await or run-loop turn: inspect and render the first layout, before the
    // scheduled sidebar load or backend startup can supply any rows.
    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("craft-sidebar-first-layout.png")
            try png.write(to: path)
            print("First sidebar layout: \(path.path)")
        }
    }
    #expect(initial.map(\.id) == ["overview", "label:projects", "label:tabs"])
    #expect(model.root.entries == initial)
    #expect(list.numberOfRows == 3)
    #expect((list.item(atRow: 0) as? CocoaSidebar.Node)?.entry.id == "overview")
}

@MainActor @Test func snapshotEventsBatchWithoutReloadingInventoryAndLegacyEventsStillReload() async throws {
    let suite = "refresh-events-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    let model = refreshApp(runtime, preferences: preferences)
    await model.start()
    try await refreshEventually { model.lastUpdate != nil && model.dashboard?.loading == false && !model.shell.trayLoading && !model.shell.usageLoading }
    await transport.reset()

    for _ in 0..<20 {
        runtime.emit("sync", project: "p", scope: "prs")
        runtime.emit("sync", project: "q", scope: "prs")
    }
    try await refreshEventually { await transport.paths.count >= 2 }
    #expect(await transport.paths.sorted() == [Routes.DASHBOARD, Routes.PRS_TRAY].sorted())
    await transport.reset()

    runtime.emit("tasks"); runtime.emit("tabs")
    try await refreshEventually { await transport.paths.count >= 2 }
    #expect(await transport.paths.sorted() == [Routes.TASKS, Routes.TABS].sorted())
    await transport.reset()

    runtime.emit("sync", scope: "usage")
    try await refreshEventually { await transport.paths.count == 1 }
    #expect(await transport.paths == [Routes.USAGE])
    await transport.reset()

    // A project mutation (or older backend) still refreshes inventory and removes retired screens.
    model.select(.project("p"))
    #expect(model.projectModels["p"] != nil)
    await transport.removeProject()
    runtime.emit("sync", project: "p")
    try await refreshEventually { model.projects.isEmpty && model.projectModels["p"] == nil }
    let paths = await transport.paths
    #expect(paths.contains(Routes.PROJECTS) && paths.contains(Routes.TASKS) && paths.contains(Routes.TABS))
    await model.stop()
}

@MainActor @Test func sidebarSnapshotFollowsInventoryDraftsAndLiveAgentState() async throws {
    let suite = "sidebar-snapshot-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime()
    await runtime.transport.addSession()
    let model = refreshApp(runtime, preferences: preferences)
    await model.start()
    try await refreshEventually { model.lastUpdate != nil && model.root.pinnedIDs == ["s"] }
    #expect(model.root.entries.flatMap(\.descendants).contains { $0.id == "pin:s" })
    let terminal = try #require(model.terminals["task:s"])
    terminal.agentTurns.bind(terminalID: "sidebar-test")
    terminal.agentTurns.setStreamAvailable(true)
    func busy() -> Bool {
        guard let entry = model.root.entries.flatMap(\.descendants).first(where: { $0.id == "pin:s" }),
              case .session(let status, _) = entry.role else { return false }
        return status.busy && status.cli == "claude"
    }
    terminal.agentTurns.receive(ServerEvent(type: "agent-turn-start", projectId: nil, id: nil, runId: "sidebar-test", cli: "claude", sessionId: "conversation"))
    try await refreshEventually { busy() }
    terminal.agentTurns.receive(ServerEvent(type: "agent-turn-done", projectId: nil, id: nil, runId: "sidebar-test", cli: "claude", sessionId: "conversation"))
    try await refreshEventually { !busy() }
    model.newTab()
    let draft = try #require(model.draftTabs.first)
    try await refreshEventually { model.root.entries.contains { $0.destination == .tab(draft.id) } }
    model.closeTab(draft.id)
    try await refreshEventually { !model.root.entries.contains { $0.destination == .tab(draft.id) } }
    await model.stop()
}

@MainActor @Test func jiraEventsRefreshOnlyTheMatchingVisibleSnapshotAndStopCancelsQueuedEvents() async throws {
    let suite = "refresh-jira-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    let model = refreshApp(runtime, preferences: preferences)
    await model.start()
    try await refreshEventually { model.lastUpdate != nil && model.dashboard?.loading == false && !model.shell.trayLoading && !model.shell.usageLoading }
    model.select(.project("p"))
    let project = try #require(model.projectModels["p"])
    project.setSection(.tickets)
    project.tickets?.refresh()
    try await refreshEventually { project.tickets?.baseURL != nil && project.tickets?.loading == false }
    await transport.reset()
    runtime.emit("jira-sync", id: "q"); runtime.emit("jira-sync", id: "board:p")
    try await Task.sleep(for: .milliseconds(250))
    #expect(await transport.paths.isEmpty)
    for _ in 0..<10 { runtime.emit("jira-sync", id: "p") }
    try await refreshEventually { await transport.paths.count >= 1 }
    #expect(await transport.paths == [Routes.projectJira("p")])

    project.setSection(.board)
    try await refreshEventually { project.board?.snapshot != nil && project.board?.loading == false }
    await transport.reset()
    runtime.emit("jira-sync", id: "p"); runtime.emit("jira-sync", id: "board:q")
    try await Task.sleep(for: .milliseconds(250))
    #expect(await transport.paths.isEmpty)
    runtime.emit("jira-sync", id: "board:p")
    try await refreshEventually { await transport.paths.count >= 2 }
    #expect(await transport.paths.sorted() == [Routes.projectBoard("p"), Routes.JIRA_SITE].sorted())
    await transport.reset()
    runtime.emit("sync", project: "p", scope: "prs")
    await model.stop()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await transport.paths.isEmpty)
}

@Test func jiraMutationSyncOnlyForcesTheRequestedProjectsSnapshots() async throws {
    let transport = RefreshTransport()
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:43187")!, transport: transport)
    try await APIJiraService(api: api).syncAfterMutation(projectID: "p")
    let requests = await transport.requests
    #expect(requests.compactMap { $0.url?.path }.sorted() == [Routes.projectJira("p"), Routes.projectBoard("p")].sorted())
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.query == "refresh=1" })
}

@MainActor @Test func tabChangeDuringWideRefreshRetriesOnlyTabsAndRejectsTheirStaleResponse() async throws {
    let suite = "refresh-inventory-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    let model = refreshApp(runtime, preferences: preferences)
    await transport.addTab()
    await model.start()
    try await refreshEventually { model.lastUpdate != nil && model.dashboard?.loading == false && !model.shell.trayLoading && !model.shell.usageLoading }
    await transport.reset()
    await transport.removeTab()
    await transport.holdNextTabs()
    model.refresh()
    try await refreshEventually { await transport.tabsAreHeld }
    // The held response contains no tabs. Only the trailing tabs read should see this edit.
    await transport.addTab()
    runtime.emit("tabs")
    runtime.emit("sync", scope: "usage")
    // The usage read is a marker that the event batch has invalidated tabs while the wide
    // read is still suspended (the first usage read belongs to the explicit full refresh).
    try await refreshEventually { await transport.paths.filter { $0 == Routes.USAGE }.count == 2 }
    await transport.releaseTabs(holdNext: true)
    try await refreshEventually { await transport.tabsAreHeld }
    #expect(model.tabs.map(\.id) == ["t"]) // The stale empty response must not remove the tab.
    await transport.releaseTabs()
    try await refreshEventually { model.tabs.map(\.id) == ["t"] }
    let paths = await transport.paths
    #expect(paths.filter { $0 == Routes.PROJECTS }.count == 1)
    #expect(paths.filter { $0 == Routes.TASKS }.count == 1)
    #expect(paths.filter { $0 == Routes.TABS }.count == 2)
    #expect(model.projects.map(\.id) == ["p"])
    await model.stop()
}
