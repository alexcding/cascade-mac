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
    /// The bodies of the ticket searches asked for, as text.
    var searches: [String] {
        requests.filter { [Routes.JIRA_SEARCH, Routes.ISSUES_SEARCH].contains($0.url?.path ?? "") }
            .map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    }
    /// The reads marked as someone looking (`?look=1`), which the backend may sync behind.
    var looks: [String] { requests.compactMap { $0.url }.filter { $0.query == "look=1" }.map(\.path) }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let body: String
        var status = 200
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
        // The chat engine is down: every chat listing fails.
        case Routes.CHAT_RPC: body = #"{"error":{"message":"chats are not available"}}"#; status = 503
        default: body = "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
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
    #expect(initial.map(\.id) == ["new-session", "overview", "automation", "label:projects", "label:chats"])
    #expect(model.root.entries == initial)
    #expect(list.numberOfRows == 5)
    #expect((list.item(atRow: 0) as? CocoaSidebar.Node)?.entry.id == "new-session")
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
    // Reads that answer the backend's own report are never looks: one that could start a sync
    // would have each sync's report start the next.
    #expect(await transport.looks.isEmpty)
    await transport.reset()

    runtime.emit("tasks")
    try await refreshEventually { await transport.paths.count >= 1 }
    #expect(await transport.paths == [Routes.TASKS])
    await transport.reset()

    runtime.emit("sync", scope: "usage")
    try await refreshEventually { await transport.paths.count == 1 }
    #expect(await transport.paths == [Routes.USAGE])
    await transport.reset()

    // A service that stopped answering, or answers again, costs one read: which ones are down.
    runtime.emit("upstream")
    try await refreshEventually { await transport.paths.count == 1 }
    #expect(await transport.paths == [Routes.UPSTREAMS])
    await transport.reset()

    // The backend searched My Tickets again behind a look and the answer changed: the tickets
    // are read again, as an echo that starts no search, and nothing else is.
    runtime.emit("sync", scope: "tickets")
    try await refreshEventually { await transport.paths.contains(Routes.ISSUES_SEARCH) && model.dashboard?.tickets.loading == false }
    #expect(await transport.paths.allSatisfy { [Routes.JIRA_SITE, Routes.JIRA_SEARCH, Routes.ISSUES_SEARCH].contains($0) })
    #expect(await transport.searches.allSatisfy { $0.contains(#""kept":true"#) && $0.contains(#""look":false"#) && $0.contains(#""fresh":false"#) })
    await transport.reset()

    // Someone looking at the dashboard reads its snapshot again, and nothing else: the backend
    // syncs behind that read what has gone stale.
    model.attend()
    try await refreshEventually { await transport.paths.count == 1 }
    #expect(await transport.paths == [Routes.DASHBOARD])
    #expect(await transport.looks == [Routes.DASHBOARD])
    await transport.reset()

    // A refresh someone asked for (the tray opened, a reload) looks at both.
    model.refresh()
    try await refreshEventually { await transport.looks.count >= 2 }
    #expect(Set(await transport.looks) == [Routes.DASHBOARD, Routes.PRS_TRAY])
    try await refreshEventually { model.dashboard?.prs.loading == false && !model.shell.trayLoading && !model.shell.usageLoading }
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

/// Chat events missed (the backend's `reload`, or a reconnect) have the chat list read again,
/// even when its first listing failed and there is nothing loaded to bring up to date.
@MainActor @Test func missedEventsReadTheChatsAgainEvenAfterAFailedListing() async throws {
    let suite = "refresh-chats-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    let model = refreshApp(runtime, preferences: preferences)
    await model.start()
    try await refreshEventually { model.chats.error != nil }
    #expect(!model.chats.loaded)
    await transport.reset()

    runtime.emit("reload")
    try await refreshEventually { await transport.paths.contains(Routes.CHAT_RPC) }
    try await refreshEventually { model.dashboard?.prs.loading == false && !model.shell.trayLoading }
    await transport.reset()

    runtime.onEvent(.connected)
    try await refreshEventually { await transport.paths.contains(Routes.CHAT_RPC) }
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
    #expect(!model.hasRunningSessions, "Quit is silent with nothing at work")
    terminal.agentTurns.receive(ServerEvent(type: "agent-turn-start", projectId: nil, id: nil, runId: "sidebar-test", cli: "claude", sessionId: "conversation"))
    try await refreshEventually { busy() }
    #expect(model.hasRunningSessions, "Quit asks while a turn runs")
    terminal.agentTurns.receive(ServerEvent(type: "agent-turn-done", projectId: nil, id: nil, runId: "sidebar-test", cli: "claude", sessionId: "conversation"))
    try await refreshEventually { !busy() }
    #expect(!model.hasRunningSessions)
    terminal.agentTurns.receivePermission(ServerEvent(type: "agent-permission", projectId: nil, id: "ask", runId: "sidebar-test", outcome: nil))
    #expect(model.hasRunningSessions, "Quit asks while the agent waits on a person")
    terminal.agentTurns.receivePermission(ServerEvent(type: "agent-permission-done", projectId: nil, id: "ask", runId: "sidebar-test", outcome: "answered"))
    #expect(!model.hasRunningSessions)
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

    // The sprint board is Projects' Board tab: it loads only while shown, and follows only its
    // own project's syncs.
    model.select(.overview)
    let dashboard = try #require(model.dashboard)
    dashboard.selectProject("p"); dashboard.selectTab(.board)
    let board = try #require(dashboard.board)
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

/// Every PR or ticket click — a row, a tray review, a notice — goes to the page's session; a page with
/// none opens its project's Start with the link and its ticket filled in, creating nothing; a page no
/// project claims opens nothing anywhere, the browser included, and says why.
@MainActor @Test func aPageClickGoesToItsSessionOrItsProjectsStartAndNeverElsewhere() async throws {
    enum Surface: CaseIterable { case row, tray, notification }
    for surface in Surface.allCases {
        let suite = "page-click-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let runtime = RefreshRuntime(), transport = runtime.transport
        await transport.addSession()
        let desktop = ProjectPageActions()
        let model = refreshApp(runtime, preferences: preferences, desktop: desktop)
        var windows = 0
        model.showMainWindow = { windows += 1 }
        await model.start()
        try await refreshEventually { model.sessions.contains { $0.id == "s" } && model.connection == "Connected" }
        func page(_ url: String, branch: String, project: String? = "p") -> OpenPageRequest {
            var request = OpenPageRequest(url: url, kind: "github", title: "PR", repo: "example/repo", branch: branch, category: "review")
            request.projectID = project; request.jiraKeys = ["REC-8"]
            return request
        }
        func open(_ request: OpenPageRequest) async throws {
            switch surface {
            case .row: try await model.openPage(request)
            case .tray: try await model.openTrayReview(request)
            case .notification: _ = try await model.openNotificationPage(request)
            }
        }
        func creates() async -> Int {
            let requests = await transport.requests
            return requests.filter {
                $0.httpMethod == "POST" && [Routes.SESSIONS, Routes.WORKTREE, Routes.TASKS].contains($0.url?.path ?? "")
            }.count
        }
        model.select(.overview)
        await transport.reset()
        try await open(page("https://github.com/example/repo/pull/7", branch: "feature"))
        #expect(model.selection == .session("s"), "\(surface)")

        try await open(page("https://github.com/example/repo/pull/8", branch: "elsewhere"))
        #expect(model.selection == .newSession, "\(surface)")
        let newTask = try #require(model.coordinator.newSession)
        let start = try #require(newTask.composer)
        #expect(newTask.projectID == "p" && start.text == "https://github.com/example/repo/pull/8", "\(surface)")
        #expect(start.linkedKey?.key == "REC-8", "\(surface)")
        let started = await creates()
        #expect(started == 0 && model.sessions.map(\.id) == ["s"], "\(surface)")

        model.select(.overview)
        await #expect(throws: BackendError.self) {
            try await open(page("https://github.com/someone/else/pull/3", branch: "x", project: nil))
        }
        let startedElsewhere = await creates()
        #expect(model.selection == .overview && desktop.browsers.isEmpty && startedElsewhere == 0, "\(surface)")
        if surface != .row {
            // From outside the window, the reason is where the app reports errors.
            #expect(model.error == "No project with a workspace matches this page.", "\(surface)")
        }
        // The tray brings the window up itself for a failure; the notice's coordinator does.
        #expect(windows == (surface == .tray ? 1 : 0), "\(surface)")
        await model.stop()
    }
}

/// A tray review or notice that cannot open, clicked while a session is on screen, takes the window
/// to the Dashboard, where the root error shows, rather than leaving the reason invisible.
@MainActor @Test func aFailedOutsideOpenShowsItsReasonOnTheDashboard() async throws {
    for notice in [false, true] {
        let suite = "outside-failure-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let runtime = RefreshRuntime(), transport = runtime.transport
        await transport.addSession()
        let model = refreshApp(runtime, preferences: preferences, desktop: ProjectPageActions())
        var windows = 0
        model.showMainWindow = { windows += 1 }
        await model.start()
        try await refreshEventually { model.sessions.contains { $0.id == "s" } && model.connection == "Connected" }
        model.select(.session("s"))
        let elsewhere = OpenPageRequest(url: "https://github.com/someone/else/pull/3", kind: "github", title: "PR #3")
        await #expect(throws: BackendError.self) {
            if notice { _ = try await model.openNotificationPage(elsewhere) } else { try await model.openTrayReview(elsewhere) }
        }
        #expect(model.selection == .overview, "notice: \(notice)")
        #expect(model.root.error == "No project with a workspace matches this page.", "notice: \(notice)")
        // The tray raises the window itself; a notice's coordinator does it for the notice.
        #expect(windows == (notice ? 0 : 1), "notice: \(notice)")
        await model.stop()
    }
}

/// Activity lives in the Settings window: a log row that opened brings the main window up.
@MainActor @Test func anActivityRowThatOpensBringsTheMainWindowUp() async throws {
    let suite = "logs-open-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime(), transport = runtime.transport
    await transport.addSession()
    let model = refreshApp(runtime, preferences: preferences, desktop: ProjectPageActions())
    var windows = 0
    model.showMainWindow = { windows += 1 }
    await model.start()
    try await refreshEventually { model.sessions.contains { $0.id == "s" } && model.connection == "Connected" }
    let logs = try #require(model.logs)
    var request = OpenPageRequest(url: "https://github.com/example/repo/pull/7", kind: "github", title: "PR #7",
                                  repo: "example/repo", branch: "feature")
    request.projectID = "p"
    logs.navigation.open(request); await logs.navigation.waitForOpen()
    #expect(model.selection == .session("s") && windows == 1)
    // One that fails leaves the window where it is; the row shows why.
    logs.navigation.open(OpenPageRequest(url: "https://github.com/someone/else/pull/3", kind: "github", title: "PR #3"))
    await logs.navigation.waitForOpen()
    #expect(windows == 1 && logs.navigation.error != nil)
    await model.stop()
}

/// A subagent's thread is not a row of the sidebar or of Projects, but the app can go to it from
/// its parent's page, where it opens read-only: it follows its parent's agent.
@MainActor @Test func aSubagentThreadOpensReadOnlyAndStaysOutOfTheLists() async throws {
    let suite = "refresh-subagent-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = RefreshRuntime()
    let model = refreshApp(runtime, preferences: preferences)
    await model.start()
    try await refreshEventually { model.chats.error != nil }
    let selection = ChatThreadShell.ModelSelection(provider: "claudeAgent", model: "haiku")
    model.chats.receive(ChatThreadShell(id: "parent", projectId: ChatProject.standalone, title: "Parent", modelSelection: selection,
                                        workingDirectory: "/work", createdAt: "2026-10-05T10:00:00.000Z"))
    model.chats.receive(ChatThreadShell(id: "subagent:parent:toolu_1", projectId: ChatProject.standalone, title: "List files",
                                        modelSelection: selection, workingDirectory: "/work", createdAt: "2026-10-05T10:00:01.000Z",
                                        parentThreadId: "parent"))
    try await refreshEventually { model.root.entries.contains { $0.chatID == "parent" || $0.children.contains { $0.chatID == "parent" } } }
    let chatIDs = model.root.entries.flatMap { [$0] + $0.children }.compactMap(\.chatID)
    #expect(chatIDs == ["parent"])
    #expect(model.rootState().chats.contains { $0.id == "subagent:parent:toolu_1" })
    #expect(model.makeChatModel(threadID: "parent")?.page.context.readOnly == false)
    let child = try #require(model.makeChatModel(threadID: "subagent:parent:toolu_1"))
    #expect(child.page.context.readOnly && child.page.context.cwd == "/work")
    await model.stop()
}
