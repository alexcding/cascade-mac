import AppKit
import Foundation
import SwiftUI
import Testing

private actor RefreshTransport: BackendTransport {
    var requests: [URLRequest] = []
    var includesProject = true
    private var includesSession = false
    func addSession() { includesSession = true }
    func removeProject() { includesProject = false }
    func reset() { requests.removeAll() }
    var paths: [String] { requests.compactMap { $0.url?.path } }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let body: String
        switch url.path {
        case Routes.PROJECTS:
            body = includesProject ? #"[{"id":"p","name":"Project","repo":"example/repo","workspace":"/fixture","jiraProjectKey":"REC","boardEnabled":true}]"# : "[]"
        case Routes.TASKS:
            body = includesSession ? #"[{"id":"s","projectId":"p","workspace":"/fixture","worktree":"/fixture/work","title":"Session","branch":"feature","url":"","pinned":true}]"# : "[]"
        case Routes.DASHBOARD:
            body = includesProject ? #"[{"id":"p","name":"Project","repo":"example/repo","jiraProjectKey":"REC","prs":[],"lastSynced":null,"syncError":null}]"# : "[]"
        case Routes.PRS_TRAY: body = "[]"
        case Routes.projectBoard("p"): body = #"{"items":[]}"#
        case Routes.JIRA_SITE: body = #"{"baseUrl":"https://jira.example.test"}"#
        default: body = "{}"
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

@MainActor private func refreshApp(_ runtime: RefreshRuntime, preferences: UserDefaults,
                                    desktop: any DesktopActions = NativeDesktopActions()) -> AppViewModel {
    _ = NSApplication.shared
    return AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }), desktop: desktop, backendRuntime: runtime,
        shellFactory: NativeShellFeatureFactory(preferences: preferences, fileIcons: nil),
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
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-sidebar-first-layout.png")
            try png.write(to: path)
            print("First sidebar layout: \(path.path)")
        }
    }
    #expect(initial.map(\.id) == ["overview", "automation", "label:projects"])
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
    try await refreshEventually { model.lastUpdate != nil && model.dashboard?.prs.loading == false && !model.shell.trayLoading && !model.shell.usageLoading }
    await transport.reset()

    for _ in 0..<20 {
        runtime.emit("sync", project: "p", scope: "prs")
        runtime.emit("sync", project: "q", scope: "prs")
    }
    try await refreshEventually { await transport.paths.count >= 2 }
    #expect(await transport.paths.sorted() == [Routes.DASHBOARD, Routes.PRS_TRAY].sorted())
    await transport.reset()

    runtime.emit("tasks")
    try await refreshEventually { await transport.paths.count >= 1 }
    #expect(await transport.paths == [Routes.TASKS])
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
    #expect(paths.contains(Routes.PROJECTS) && paths.contains(Routes.TASKS))
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
    await model.stop()
}

@MainActor @Test func jiraEventsRefreshOnlyTheMatchingVisibleSnapshotAndStopCancelsQueuedEvents() async throws {
    let suite = "refresh-jira-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    let model = refreshApp(runtime, preferences: preferences)
    await model.start()
    try await refreshEventually { model.lastUpdate != nil && model.dashboard?.prs.loading == false && !model.shell.trayLoading && !model.shell.usageLoading }
    // A project page lists no tickets, so its own Jira sync fetches nothing; and Start reads no
    // branch list until it is on screen.
    model.select(.project("p"))
    await transport.reset()
    runtime.emit("jira-sync", id: "p"); runtime.emit("jira-sync", id: "q")
    try await Task.sleep(for: .milliseconds(250))
    #expect(await transport.paths.isEmpty)

    // The sprint board is the project's Board tab: it loads only while shown, and follows only
    // its own project's syncs.
    let page = try #require(model.projectModels["p"])
    page.selectSection(.board)
    let board = try #require(page.board)
    try await refreshEventually { board.snapshot != nil && !board.loading }
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

/// A tray click on a review selects the session that already owns the PR; a PR with no session
/// opens in the system browser. Neither starts a session.
@MainActor @Test func aTrayReviewSelectsItsSessionOrOpensTheBrowserAndNeverStartsOne() async throws {
    let suite = "tray-review-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    await transport.addSession()
    let desktop = ProjectPageActions()
    let model = refreshApp(runtime, preferences: preferences, desktop: desktop)
    await model.start()
    try await refreshEventually { model.sessions.contains { $0.id == "s" } }
    func review(_ number: Int, branch: String) -> OpenPageRequest {
        var request = OpenPageRequest(url: "https://github.com/example/repo/pull/\(number)", kind: "github", title: "PR #\(number)",
                                      repo: "example/repo", branch: branch, category: "review")
        request.projectID = "p"
        return request
    }
    func posts(to path: String) async -> Int { await transport.requests.filter { $0.httpMethod == "POST" && $0.url?.path == path }.count }
    // A start looks the pull request up, then asks the backend for the session in one request.
    func starts() async -> Int {
        let lookups = await transport.requests.filter { $0.url?.path == Routes.PR_LOOKUP }.count
        return await lookups + posts(to: Routes.SESSIONS) + posts(to: Routes.WORKTREE) + posts(to: Routes.TASKS)
    }

    await transport.reset()
    #expect(try await model.openTrayReview(review(7, branch: "feature")))
    #expect(model.selection == .session("s"))
    #expect(await starts() == 0)
    #expect(desktop.browsers.isEmpty)

    await transport.reset()
    #expect(try await !model.openTrayReview(review(8, branch: "elsewhere")))
    #expect(desktop.browsers.map(\.absoluteString) == ["https://github.com/example/repo/pull/8"])
    #expect(await starts() == 0)
    await model.stop()
}

/// A row's New Session opens the page's project on Start with the page filled in; nothing is
/// created until Start is submitted.
@MainActor @Test func aRowsNewSessionOpensItsProjectsStartWithThePageAndCreatesNothing() async throws {
    let suite = "row-new-session-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    let desktop = ProjectPageActions()
    let model = refreshApp(runtime, preferences: preferences, desktop: desktop)
    await model.start()
    try await refreshEventually { model.lastUpdate != nil && model.connection == "Connected" }
    await transport.reset()
    var request = OpenPageRequest(url: "https://github.com/example/repo/pull/9", kind: "github", title: "PR #9")
    request.inSession = true; request.projectID = "p"
    try await model.openPage(request)
    #expect(model.selection == .project("p"))
    #expect(model.projectModels["p"]?.section == .start && model.projectModels["p"]?.composer.text == request.url)
    let creates = await transport.requests.filter {
        $0.httpMethod == "POST" && [Routes.SESSIONS, Routes.WORKTREE, Routes.TASKS].contains($0.url?.path ?? "")
    }
    #expect(creates.isEmpty && model.sessions.isEmpty && desktop.browsers.isEmpty)
    await model.stop()
}

/// A notice for a page with a session selects it and says so, so the window comes up; any other
/// page goes to the system browser and says it stayed out of Cascade.
@MainActor @Test func aNotificationPageIsInCascadeOnlyForItsSession() async throws {
    let suite = "notification-page-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    await transport.addSession()
    let desktop = ProjectPageActions()
    let model = refreshApp(runtime, preferences: preferences, desktop: desktop)
    await model.start()
    try await refreshEventually { model.sessions.contains { $0.id == "s" } }
    func page(_ number: Int, branch: String) -> OpenPageRequest {
        var request = OpenPageRequest(url: "https://github.com/example/repo/pull/\(number)", kind: "github", title: "PR #\(number)",
                                      repo: "example/repo", branch: branch)
        request.projectID = "p"
        return request
    }
    #expect(try await model.openNotificationPage(page(7, branch: "feature")))
    #expect(model.selection == .session("s") && desktop.browsers.isEmpty)
    #expect(try await !model.openNotificationPage(page(8, branch: "elsewhere")))
    #expect(desktop.browsers.map(\.absoluteString) == ["https://github.com/example/repo/pull/8"])
    await model.stop()
}
