import AppKit
import Foundation
import Testing

// The session pool end to end at the 1 GB minimum: real shells in an isolated daemon, stub agents,
// and a memory reading that has each agent hold 600 MB, so only one fits.

private actor PoolBackend: BackendTransport {
    let worktree: String
    let ids: [String]
    /// Sessions with no conversation id yet, which a Claude launch reserves one for.
    let unreserved: Set<String>
    /// Conversations that are not on disk, by id. The first look at one still finds it, as a look
    /// made just before its transcript went would.
    let missing: Set<String>
    private var looked: Set<String> = []
    private(set) var paths: [String] = []
    /// Each PATCH's path and body.
    private(set) var patches: [(path: String, body: String)] = []
    init(worktree: String, ids: [String], unreserved: Set<String> = [], missing: Set<String> = []) {
        self.worktree = worktree; self.ids = ids; self.unreserved = unreserved; self.missing = missing
    }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        paths.append(url.path)
        if request.httpMethod == "PATCH" { patches.append((url.path, String(decoding: request.httpBody ?? Data(), as: UTF8.self))) }
        let body: String
        switch url.path {
        case Routes.PROJECTS: body = #"[{"id":"p","name":"Project","repo":"example/repo","workspace":"\#(worktree)"}]"#
        case Routes.TASKS:
            body = "[" + ids.map { id in
                #"{"id":"\#(id)","projectId":"p","workspace":"\#(worktree)","worktree":"\#(worktree)","title":"\#(id)","branch":"\#(id)","url":"","pinned":false,"cli":"claude","sessionId":"\#(unreserved.contains(id) ? "" : "conversation-\(id)")"}"#
            }.joined(separator: ",") + "]"
        case Routes.TABS: body = #"{"tabs":[]}"#
        case Routes.AGENT_CONVERSATION:
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            body = #"{"exists":\#(!missing.contains(id) || looked.insert(id).inserted)}"#
        case Routes.SETTINGS: body = #"{"sessionMemoryLimit":"1"}"#
        case Routes.DASHBOARD, Routes.PRS_TRAY: body = "[]"
        default: body = "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class PoolRuntime: BackendRuntimeServing {
    var onEvent: (BackendRuntimeEvent) -> Void = { _ in }
    let transport: PoolBackend
    init(worktree: String, ids: [String], unreserved: Set<String> = [], missing: Set<String> = []) {
        transport = PoolBackend(worktree: worktree, ids: ids, unreserved: unreserved, missing: missing)
    }
    func start() throws -> APIClient { try APIClient(baseURL: URL(string: "http://127.0.0.1:43188")!, transport: transport) }
    func startEvents() { onEvent(.connected) }
    func stopEvents() {}
    func stop() {}
    /// What an agent's hooks send: its SessionStart, and each turn's start and Stop.
    func hook(_ type: String, terminal: String, conversation: String, source: String?) {
        onEvent(.message(ServerEvent(type: type, projectId: nil, id: nil, runId: terminal, cli: "claude",
                                     sessionId: conversation, source: source)))
    }
    func emit(_ type: String) { onEvent(.message(ServerEvent(type: type, projectId: nil, id: nil))) }
}

/// The daemon's control, but a session's stop fails as one that timed out does: its shell keeps running.
private struct RefusedStops: TerminalRuntimeControlling {
    let native: any TerminalRuntimeControlling
    func stopPaired(keys: Set<String>) async throws { throw PtyError.connection("Session processes did not stop.") }
    func stopExisting() async throws { try await native.stopExisting() }
    func pairedShells() async throws -> [String: Int32] { try await native.pairedShells() }
}

/// Every terminal in the fixture's daemon and shell; each agent reads as 600 MB.
@MainActor private struct PoolPlatform: AppPlatformFactory {
    let fixture: DaemonFixture
    var refusesStops = false
    /// A shell the daemon will not start an agent in, so creating a session's terminal fails.
    var refusedShell = false
    var homeDirectory: String { fixture.directory.path }
    private var native: NativeAppPlatformFactory {
        let config = fixture.config
        return NativeAppPlatformFactory(homeDirectory: homeDirectory, configuration: { config })
    }
    func viewer(dialogs: BrowserDialogCoordinator, documents: any DocumentFeatureFactory, close: EditorCloseCoordinator) -> ViewerStore {
        native.viewer(dialogs: dialogs, documents: documents, close: close)
    }
    func workspaceLauncher() -> WorkspaceLaunchViewModel { native.workspaceLauncher() }
    func terminal(_ request: AppTerminalRequest) -> TerminalSession {
        TerminalSession(pairKey: request.key, cwd: request.directory, paired: request.paired, configuration: fixture.config,
                        shellPath: refusedShell ? "/bin/sh" : fixture.shell)
    }
    func detachedShell(_ request: AppTerminalRequest) -> DetachedShell {
        let config = fixture.config
        return DetachedShell(pairKey: request.key, cwd: request.directory, shellPath: fixture.shell, configurationProvider: { config })
    }
    func terminalControl() -> any TerminalRuntimeControlling { refusesStops ? RefusedStops(native: native.terminalControl()) : native.terminalControl() }
    func processSampler() -> any ProcessSampling { FixedMemory(each: 600 << 20) }
    func workflowTerminal(_ terminal: TerminalSession, cli: WorkflowCLI, sessionID: String?) async throws -> any WorkflowTerminal {
        try await native.workflowTerminal(terminal, cli: cli, sessionID: sessionID)
    }
    func resources(api: APIClient?) -> any ResourceUsageService { native.resources(api: api) }
    func pageActions(open: @escaping (OpenPageRequest) async throws -> Void,
                     session: @escaping (OpenPageRequest) -> PageSessionMark?) -> any PageActionServing {
        native.pageActions(open: open, session: session)
    }
}

@MainActor private func sessionEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw BackendError.operation("The session pool did not settle") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Craft at the 1 GB minimum over its own daemon, with a Claude session per id, each resuming
/// `conversation-<id>` in a stub agent; those in `backgroundJobs` leave a job running.
@MainActor private final class PoolHarness {
    let fixture: DaemonFixture
    let runtime: PoolRuntime
    let model: AppViewModel
    private let ids: [String]
    private let backgroundJobs: [String]
    private let suite = "session-pool-\(UUID().uuidString)"
    private let control = PtydClient(onEvent: { _ in })
    private var daemon: Int32?
    private var opened: [(TerminalSession, NSWindow)] = []

    init(sessions ids: [String], backgroundJobs: [String] = [], refusingStops: Bool = false,
         unreserved: Set<String> = [], refusedShell: Bool = false, missing: [String] = [], missingOnDisk: Set<String> = []) throws {
        _ = NSApplication.shared
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.set("1", forKey: "native.sessionMemoryLimit")
        fixture = try DaemonFixture()
        try backgroundJobs.map { "conversation-\($0)\n" }.joined().write(to: fixture.backgroundJobs, atomically: true, encoding: .utf8)
        try missing.map { "conversation-\($0)\n" }.joined().write(to: fixture.missingConversations, atomically: true, encoding: .utf8)
        self.ids = ids
        self.backgroundJobs = backgroundJobs
        runtime = PoolRuntime(worktree: fixture.directory.path, ids: ids, unreserved: unreserved, missing: missingOnDisk)
        model = AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }), backendRuntime: runtime,
            shellFactory: NativeShellFeatureFactory(preferences: preferences), platformFactory: PoolPlatform(fixture: fixture, refusesStops: refusingStops, refusedShell: refusedShell),
            welcomeStore: TransientWelcomeStore(shown: true),
            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
    }

    /// Starts the daemon, then Craft, and waits for the sidebar to list the sessions.
    func start() async throws {
        daemon = try await PtydHost(configuration: fixture.config).connect(client: control).pid
        await model.start()
        try await sessionEventually { Set(self.model.sessions.map(\.id)) == Set(self.ids) }
    }

    /// Opens each session in turn, the next once the one before has its agent up: each switch's pass
    /// finds the agents it hid up, and silent. Returns once the agents in `backgroundJobs` have their
    /// jobs running, in groups of their own.
    func openAll() async throws {
        for id in ids {
            try await open(id)
            try await sessionEventually { self.terminal(id)?.launchedAgentForeground != nil }
        }
        try await sessionEventually { self.launches().count == self.ids.count }
        let sampler = NativeProcessResourceSampler()
        for id in backgroundJobs {
            let agent = try #require(terminal(id)?.launchedAgentForeground?.pgid)
            try await sessionEventually { await sampler.processGroups(of: agent).map { $0.count > 1 } == true }
        }
    }

    func terminal(_ id: String) -> TerminalSession? { model.terminals["task:\(id)"] }

    /// What session `id`'s agent hooks send.
    func hook(_ type: String, _ id: String, source: String? = nil) throws {
        runtime.hook(type, terminal: try #require(terminal(id)?.termID), conversation: "conversation-\(id)", source: source)
    }

    /// Keys a user types into session `id`'s terminal.
    func type(_ keys: String, into id: String) async throws {
        let _: Bool? = try await control.request(.init(op: "write", term: try #require(terminal(id)?.termID), data: keys))
    }

    /// Ends what session `id`'s agent left running in groups of its own.
    func endBackgroundJobs(of id: String) async throws {
        let agent = try #require(terminal(id)?.launchedAgentForeground?.pgid)
        let sampler = NativeProcessResourceSampler()
        for job in try await sampler.sample(roots: [ResourceRoot(pid: agent, group: .terminals)]).processes
        where job.processGroup != agent { kill(job.pid, SIGTERM) }
        try await sessionEventually { await sampler.processGroups(of: agent) == [agent] }
    }

    /// Selects session `id` and mounts its pane offscreen, which starts its shell if it has none.
    func open(_ id: String) async throws {
        model.select(.session(id))
        let terminal = try #require(terminal(id))
        opened.append((terminal, mountOffscreen(terminal)))
        await terminal.start()
    }

    /// The sessions whose shells the daemon runs.
    func shells() async throws -> [String] { try await PtydHost(configuration: fixture.config).pairedShells().keys.sorted() }

    /// One line per stub agent launch: its name and arguments.
    func launches() -> [String] {
        ((try? String(contentsOf: fixture.launches, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// What the sidebar says of session `id`.
    func live(_ id: String) -> Bool? {
        for entry in model.root.entries.flatMap(\.descendants) where entry.sessionID == id {
            if case .session(let status, _) = entry.role { return status.live }
        }
        return nil
    }

    /// Stops Craft, then the daemon and every shell in it.
    func finish() async throws {
        for (terminal, _) in opened { terminal.disconnect() }
        await model.stop()
        try await PtydHost(configuration: fixture.config).stopExisting()
    }

    /// Removes what the test made, however far it got.
    func tearDown() {
        for (_, window) in opened { window.close() }
        control.close()
        if let daemon { kill(daemon, SIGTERM) }
        fixture.remove()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

/// The shell starts the agent itself once its startup files have run, so it is never typed ahead of
/// the prompt, where it would echo twice, and it starts once.
@MainActor @Test(.timeLimit(.minutes(1))) func theShellStartsTheAgentItselfOnce() async throws {
    let pool = try PoolHarness(sessions: ["a"])
    defer { pool.tearDown() }
    try await pool.start()
    try await pool.open("a")
    try await sessionEventually { pool.launches() == ["claude --resume conversation-a"] }
    try await sessionEventually { pool.terminal("a")?.launchedAgentForeground != nil }
    try await Task.sleep(for: .milliseconds(1500))
    #expect(pool.launches().count == 1)
    try await pool.finish()
}

/// Two agents, room for one. Launch starts neither: each starts once it is opened. Neither may go
/// before its hooks say it is at its prompt. The one left mid-turn keeps running and is stopped once
/// its turn ends; stopped, it stays stopped through a refresh; opened again, it resumes its
/// conversation and the other, idle and hidden now, is stopped in its place.
@MainActor @Test(.timeLimit(.minutes(1))) func atTheMinimumLimitOnlyAnIdleHiddenAgentIsStoppedAndReopeningResumesIt() async throws {
    let pool = try PoolHarness(sessions: ["a", "b"])
    defer { pool.tearDown() }
    try await pool.start()
    try await Task.sleep(for: .milliseconds(500))
    #expect(try await pool.shells().isEmpty)
    try await pool.openAll()
    #expect(try await pool.shells() == ["a", "b"])
    // Opening b hid a, up but silent: nothing says either is idle, so neither went.
    #expect(pool.terminal("a")?.agentIdle == false && pool.terminal("b")?.agentIdle == false)
    // Claude's SessionStart on resuming says each is at its prompt.
    try pool.hook("agent-session", "a", source: "resume")
    try pool.hook("agent-session", "b", source: "resume")
    #expect(pool.terminal("a")?.agentIdle == true && pool.terminal("b")?.agentIdle == true)

    // b is mid-turn when the switch to a leaves it hidden: over the limit, it keeps running.
    try pool.hook("agent-turn-start", "b")
    #expect(pool.terminal("b")?.agentBusy == true)
    pool.model.select(.session("a"))
    try await Task.sleep(for: .milliseconds(500))
    #expect(try await pool.shells() == ["a", "b"])

    // Its turn ends: now it is idle and hidden, and it goes.
    try pool.hook("agent-turn-done", "b")
    try await sessionEventually { try await pool.shells() == ["a"] }
    try await sessionEventually { pool.terminal("b") == nil && pool.live("b") == false }

    // A refresh does not bring it back.
    let served = await pool.runtime.transport.paths.filter { $0 == Routes.TASKS }.count
    pool.runtime.emit("tasks")
    try await sessionEventually { await pool.runtime.transport.paths.filter { $0 == Routes.TASKS }.count > served }
    try await Task.sleep(for: .milliseconds(300))
    #expect(pool.terminal("b") == nil)

    // Opened again, its agent starts for the pane and resumes its conversation, and a, idle and
    // hidden now, is stopped to make room.
    try await pool.open("b")
    try await sessionEventually { try await pool.shells() == ["b"] }
    try await sessionEventually { pool.launches().count == 3 }
    #expect(pool.launches().last == "claude --resume conversation-b")
    try await sessionEventually { pool.live("a") == false && pool.live("b") == true }
    try await pool.finish()
}

/// Four agents, room for one, with a on screen, and none of the others may go: b's hooks were
/// never heard, so nothing says it is idle; c's agent was quit, so what its terminal runs now is
/// the user's; d left a job running in the background. Once d's job ends, its next Stop lets it go.
@MainActor @Test(.timeLimit(.minutes(1))) func onlyAnIdleAgentWithNothingLeftRunningIsStopped() async throws {
    let pool = try PoolHarness(sessions: ["a", "b", "c", "d"], backgroundJobs: ["d"])
    defer { pool.tearDown() }
    try await pool.start()
    try await pool.openAll()
    try pool.hook("agent-session", "c", source: "resume")
    try pool.hook("agent-session", "d", source: "resume")
    // Ctrl-C ends c's agent, and its shell takes the terminal back.
    try await pool.type("\u{03}", into: "c")
    try await sessionEventually { try await pool.terminal("c")?.atShell() == true }

    pool.model.select(.session("a"))
    try await Task.sleep(for: .milliseconds(500))
    #expect(try await pool.shells() == ["a", "b", "c", "d"])

    try await pool.endBackgroundJobs(of: "d")
    try pool.hook("agent-turn-done", "d")
    try await sessionEventually { try await pool.shells() == ["a", "b", "c"] }
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await pool.shells() == ["a", "b", "c"])
    #expect(pool.live("b") == true && pool.live("c") == true && pool.live("d") == false)
    try await pool.finish()
}

/// Two agents, room for one, and a daemon that will not stop a session. The pool's pick is left
/// detached as a stopped one is, its agent still running: no error for a stop the user never asked
/// for, and a refresh does not attach it again, which would start its agent anew had the stop gone
/// through. Opened, it attaches to the agent still running rather than launching another.
@MainActor @Test(.timeLimit(.minutes(1))) func aStopThatFailsLeavesTheSessionDetachedUntilItIsOpened() async throws {
    let pool = try PoolHarness(sessions: ["a", "b"], refusingStops: true)
    defer { pool.tearDown() }
    try await pool.start()
    try await pool.openAll()
    try pool.hook("agent-session", "a", source: "resume")
    try pool.hook("agent-session", "b", source: "resume")
    pool.model.select(.session("a"))
    try await sessionEventually { pool.terminal("b") == nil }
    #expect(try await pool.shells() == ["a", "b"] && pool.model.error == nil)

    let served = await pool.runtime.transport.paths.filter { $0 == Routes.TASKS }.count
    pool.runtime.emit("tasks")
    try await sessionEventually { await pool.runtime.transport.paths.filter { $0 == Routes.TASKS }.count > served }
    try await Task.sleep(for: .milliseconds(300))
    #expect(pool.terminal("b") == nil)

    try await pool.open("b")
    try await sessionEventually { pool.terminal("b")?.ready == true }
    #expect(pool.launches().count == 2 && pool.model.error == nil)
    try await pool.finish()
}

/// ⌘1–9 and ⌘0 go to the sidebar's sessions in its order, past the end do nothing, and ⌘[ ] step.
@MainActor @Test(.timeLimit(.minutes(1))) func numberShortcutsSelectSessionsInSidebarOrder() async throws {
    let pool = try PoolHarness(sessions: ["a", "b", "c"])
    defer { pool.tearDown() }
    try await pool.start()
    let order = pool.model.root.entries.flatMap(\.descendants).compactMap(\.sessionID)
    #expect(order.count == 3)
    // What the sidebar shows beside them while ⌘ is held.
    #expect(pool.model.root.sessionShortcuts == [order[0]: "⌘1", order[1]: "⌘2", order[2]: "⌘3"])
    pool.model.perform(.session2)
    #expect(pool.model.selection == .session(order[1]))
    pool.model.perform(.session3)
    #expect(pool.model.selection == .session(order[2]))
    #expect(!pool.model.canPerform(.session4) && !pool.model.canPerform(.session10))
    pool.model.perform(.session10)
    #expect(pool.model.selection == .session(order[2]))
    pool.model.perform(.session1)
    #expect(pool.model.selection == .session(order[0]))
    // ⌘[ ] step through them and wrap; from anything but a session they start at either end.
    pool.model.perform(.previousSession)
    #expect(pool.model.selection == .session(order[2]))
    pool.model.perform(.nextSession)
    #expect(pool.model.selection == .session(order[0]))
    pool.model.perform(.nextSession)
    #expect(pool.model.selection == .session(order[1]))
    pool.model.select(.overview)
    pool.model.perform(.previousSession)
    #expect(pool.model.selection == .session(order[2]))
    try await pool.finish()
}

/// A new Claude session's conversation id goes on its record once its shell exists and starts the
/// agent under it; a shell that is never created leaves the record as it was.
@MainActor @Test(.timeLimit(.minutes(1))) func aNewConversationIdIsSavedOnlyOnceItsShellExists() async throws {
    let pool = try PoolHarness(sessions: ["a"], unreserved: ["a"])
    defer { pool.tearDown() }
    try await pool.start()
    try await pool.open("a")
    try await sessionEventually { pool.launches().count == 1 }
    let words = pool.launches()[0].split(separator: " ").map(String.init)
    #expect(words.prefix(2) == ["claude", "--session-id"])
    let id = try #require(words.dropFirst(2).first)
    try await sessionEventually { await pool.runtime.transport.patches.contains { $0.path == Routes.task("a") && $0.body.contains(id) } }
    #expect(pool.model.sessions.first { $0.id == "a" }?.sessionId == id)
    try await pool.finish()

    let refused = try PoolHarness(sessions: ["b"], unreserved: ["b"], refusedShell: true)
    defer { refused.tearDown() }
    try await refused.start()
    try await refused.open("b")
    try await sessionEventually { refused.terminal("b")?.error != nil }
    try await Task.sleep(for: .milliseconds(300))
    #expect(await refused.runtime.transport.patches.isEmpty)
    #expect(refused.model.sessions.first { $0.id == "b" }?.sessionId?.isEmpty != false)
    #expect(refused.launches().isEmpty)
    try await refused.finish()
}

/// A conversation Claude cannot find ends its resume at the shell, and is gone from disk. The session
/// starts a new one under a new id, keeps that id, and follows the new agent, with nothing reported.
/// One quit at once, its conversation still on disk, is left at the shell.
@MainActor @Test(.timeLimit(.minutes(1))) func aResumeClaudeCannotFindStartsANewConversation() async throws {
    let pool = try PoolHarness(sessions: ["a"], missing: ["a"], missingOnDisk: ["conversation-a"])
    defer { pool.tearDown() }
    try await pool.start()
    try await pool.open("a")
    try await sessionEventually { pool.launches().count == 2 }
    #expect(pool.launches()[0] == "claude --resume conversation-a")
    let words = pool.launches()[1].split(separator: " ").map(String.init)
    #expect(words.prefix(2) == ["claude", "--session-id"])
    let id = try #require(words.dropFirst(2).first)
    #expect(id != "conversation-a")
    try await sessionEventually { await pool.runtime.transport.patches.contains { $0.path == Routes.task("a") && $0.body.contains(id) } }
    try await sessionEventually { try await pool.terminal("a")?.atShell() == false }
    try await Task.sleep(for: .seconds(3.5))
    #expect(pool.launches().count == 2, "a new conversation that starts is not started again")
    #expect(pool.model.error == nil)
    #expect(pool.model.sessions.first { $0.id == "a" }?.sessionId == id)
    try await pool.finish()
}
