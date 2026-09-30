import AppKit
import GhosttyTerminal
import Foundation
import Testing

// `RemoteDelivery` against a real terminal: an isolated daemon, and a private executable named
// `claude` that echoes what it is typed. No real coding agent is launched.

private final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PtyEvent] = []
    func append(_ event: PtyEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: storage.compactMap(\.bytes).reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
    }

    func receives(_ expected: String) async throws -> Bool {
        for _ in 0..<100 {
            if text.contains(expected) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return text.contains(expected)
    }
}

/// Runs `body` with a terminal whose foreground process is the echoing agent, its hooks stream
/// available and the tracker idle, and the bytes the agent received.
/// With `launchAgent` false the terminal stays at its shell, while the tracker is made idle by the same hook events.
@MainActor private func withEchoAgent(launchAgent: Bool = true, _ body: (TerminalSession, DeliveryLog) async throws -> Void) async throws {
    _ = NSApplication.shared
    let root = TestPaths.checkout
    let directory = URL(fileURLWithPath: "/tmp/th-remote-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let shell = directory.appendingPathComponent("fixture-shell")
    try "#!/bin/sh\nexec /bin/bash --noprofile --norc -i\n".write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
    let agent = directory.appendingPathComponent("claude")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = [root.appendingPathComponent("macos/scripts/agent-echo-fixture.c").path, "-o", agent.path]
    compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
    try compiler.run(); compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    let config = PtydConfiguration(executable: root.appendingPathComponent("crates/cascade-ptyd/target/debug/cascade-ptyd"),
        directory: directory, socketPath: directory.appendingPathComponent("daemon.sock").path)
    let host = PtydHost(configuration: config), log = DeliveryLog()
    let control = PtydClient(onEvent: log.append)
    let hello = try await host.connect(client: control)
    defer { control.close(); _ = kill(hello.pid, SIGTERM) }
    let term: PtyInfo = try await control.request(.init(op: "create", opts: .init(cwd: directory.path, shell: shell.path,
        pairKey: "agent", stateResponseOwner: PtyHello.stateResponseOwnerVersion)))
    defer { _ = kill(Int32(term.pid), SIGTERM) }
    let session = TerminalSession(pairKey: "agent", cwd: directory.path, configuration: config)
    let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    view.delegate = session.surface; view.controller = session.surface.controller; view.configuration = session.surface.configuration
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded(); view.setSurfaceVisible(false)
    defer { session.disconnect(); window.contentView = nil; window.close() }
    await session.start(); try await session.waitUntilReady()
    session.agentTurns.setStreamAvailable(true)
    var stopAgent: (() -> Void)?
    if launchAgent {
        try await session.submit("/bin/stty raw -echo; " + SessionAgent.quote(agent.path))
        var foreground = try await session.foregroundProcess()
        for _ in 0..<100 {
            if foreground.process == "claude" { break }
            try await Task.sleep(for: .milliseconds(20)); foreground = try await session.foregroundProcess()
        }
        try #require(foreground.process == "claude")
        if let pgid = foreground.pgid { stopAgent = { _ = kill(pgid, SIGTERM) } }
    }
    for type in ["agent-turn-start", "agent-turn-done"] {
        session.agentTurns.receive(ServerEvent(type: type, projectId: nil, id: nil, runId: term.id, cli: "claude", sessionId: "fixture"))
    }
    try #require(session.agentTurns.idle)
    try await body(session, log)
    stopAgent?()
    await session.stopConnecting(); try await host.stopExisting()
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryTypesTheMessageAndEnterWhenTheAgentIsIdle() async throws {
    try await withEchoAgent { session, log in
        try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 5, turnStart: 0.2) { false }
        #expect(try await log.receives("hello from the phone\r"))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryTypesNothingWhileAnApprovalIsOpen() async throws {
    try await withEchoAgent { session, log in
        await #expect(throws: RemoteCommandError.self) {
            try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 0.5, turnStart: 0.2) { true }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.text.contains("hello from the phone"))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryRefusesAnAgentWithoutHooks() async throws {
    try await withEchoAgent { session, log in
        session.agentTurns.setStreamAvailable(false)
        await #expect(throws: RemoteCommandError.self) {
            try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 5, turnStart: 0.2) { false }
        }
        #expect(!log.text.contains("hello from the phone"))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryRefusesATerminalAtItsShell() async throws {
    try await withEchoAgent(launchAgent: false) { session, log in
        await #expect(throws: RemoteCommandError.self) {
            try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 5, turnStart: 0.2) { false }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.text.contains("hello from the phone"))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryHoldsTheNextMessageUntilTheAgentIsHeardToStart() async throws {
    try await withEchoAgent { session, log in
        // Nothing reports a turn beginning: the whole wait passes before the next message may go.
        let first = Date()
        let unheard = try await RemoteDelivery.deliver("first", to: session, wait: 5, turnStart: 1) { false }
        // Sent at once; it is the wait for its turn that takes the time.
        #expect(try await log.receives("first\r"))
        await unheard()
        #expect(-first.timeIntervalSinceNow >= 0.9)

        // The agent's hook reports its turn beginning: the wait ends there.
        let terminal = try #require(session.termID)
        let begins = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(200))
            session.agentTurns.receive(hook("agent-turn-start", terminal: terminal))
        }
        let second = Date()
        let heard = try await RemoteDelivery.deliver("second", to: session, wait: 5, turnStart: 10) { false }
        await heard()
        _ = try await begins.value
        #expect(-second.timeIntervalSinceNow < 5)
        #expect(session.agentTurns.busy)

        // And the agent is busy now, so a third message is not typed into its turn.
        await #expect(throws: RemoteCommandError.self) {
            try await RemoteDelivery.deliver("third", to: session, wait: 0.5, turnStart: 0.2) { false }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.text.contains("third"))
    }
}

private func hook(_ type: String, terminal: String) -> ServerEvent {
    ServerEvent(type: type, projectId: nil, id: nil, runId: terminal, cli: "claude", sessionId: "fixture")
}

@MainActor @Test func remoteTrackerSeesTheProcessChangeUntilAHookIsHeard() {
    let tracker = AgentTurnTracker()
    tracker.bind(terminalID: "t1")
    tracker.setStreamAvailable(true)
    tracker.watch(foreground: 1, atShell: false)
    #expect(!tracker.processChanged)
    tracker.watch(foreground: 2, atShell: false)
    #expect(tracker.processChanged)
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    #expect(!tracker.processChanged)
}

@MainActor @Test func remoteTrackerTakesAHookToSpeakOnlyForAProcessWithTheAgentsName() {
    let tracker = AgentTurnTracker()
    tracker.bind(terminalID: "t1")
    tracker.setStreamAvailable(true)
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    tracker.watch(foreground: 10, name: "claude", atShell: false)
    #expect(!tracker.processChanged)

    // Its turn ends, and before the next look the agent is gone and another program is in front.
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    tracker.watch(foreground: 11, name: "vim", atShell: false)
    #expect(tracker.processChanged)

    // The agent started again, under a new process, and is heard from.
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    tracker.watch(foreground: 12, name: "claude", atShell: false)
    #expect(!tracker.processChanged)
}

@MainActor @Test func remoteTrackerForgetsTheAgentsNameWhenAnAgentAnnouncesItsStart() {
    let tracker = AgentTurnTracker()
    tracker.bind(terminalID: "t1")
    tracker.setStreamAvailable(true)
    // The process is named for its binary, which carries the version.
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    tracker.watch(foreground: 10, name: "2.1.285", atShell: false)
    #expect(!tracker.processChanged)

    // The agent updated itself, was quit and run again: a new name, announced by its start.
    tracker.watch(foreground: nil, name: "zsh", atShell: true)
    #expect(tracker.processChanged)
    tracker.adopt(sessionID: "next", midTurn: false)
    tracker.watch(foreground: 20, name: "2.1.286", atShell: false)
    #expect(!tracker.processChanged)
    // And it stays the agent through the turns that follow.
    tracker.receive(hook("agent-turn-start", terminal: "t1"))
    tracker.watch(foreground: 20, name: "2.1.286", atShell: false)
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    tracker.watch(foreground: 20, name: "2.1.286", atShell: false)
    #expect(!tracker.processChanged)
}

@MainActor @Test func remoteTrackerLearnsNoNameBeforeAHookIsHeard() {
    let tracker = AgentTurnTracker()
    tracker.bind(terminalID: "t1")
    tracker.setStreamAvailable(true)
    // Something else is in front before the agent has ever been heard from.
    tracker.watch(foreground: 5, name: "vim", atShell: false)
    // The agent starts and ends a turn: it is the agent by its hook, whatever was there before.
    tracker.receive(hook("agent-turn-done", terminal: "t1"))
    tracker.watch(foreground: 6, name: "claude", atShell: false)
    #expect(!tracker.processChanged)
}

@MainActor @Test func remoteTrackerSeesTheAgentExitToItsShell() {
    let tracker = AgentTurnTracker()
    tracker.bind(terminalID: "t1")
    tracker.watch(foreground: 5, atShell: true)
    #expect(tracker.processChanged)
}
