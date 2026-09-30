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
@MainActor private func withEchoAgent(_ body: (TerminalSession, DeliveryLog) async throws -> Void) async throws {
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
    try await session.submit("/bin/stty raw -echo; " + SessionAgent.quote(agent.path))
    var foreground = try await session.foregroundProcess()
    for _ in 0..<100 {
        if foreground.process == "claude" { break }
        try await Task.sleep(for: .milliseconds(20)); foreground = try await session.foregroundProcess()
    }
    try #require(foreground.process == "claude")
    for type in ["agent-turn-start", "agent-turn-done"] {
        session.agentTurns.receive(ServerEvent(type: type, projectId: nil, id: nil, runId: term.id, cli: "claude", sessionId: "fixture"))
    }
    try #require(session.agentTurns.idle)
    try await body(session, log)
    if let pgid = foreground.pgid { _ = kill(pgid, SIGTERM) }
    await session.stopConnecting(); try await host.stopExisting()
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryTypesTheMessageAndEnterWhenTheAgentIsIdle() async throws {
    try await withEchoAgent { session, log in
        try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 5) { false }
        #expect(try await log.receives("hello from the phone\r"))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryTypesNothingWhileAnApprovalIsOpen() async throws {
    try await withEchoAgent { session, log in
        await #expect(throws: RemoteCommandError.self) {
            try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 0.5) { true }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.text.contains("hello from the phone"))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func remoteDeliveryRefusesAnAgentWithoutHooks() async throws {
    try await withEchoAgent { session, log in
        session.agentTurns.setStreamAvailable(false)
        await #expect(throws: RemoteCommandError.self) {
            try await RemoteDelivery.deliver("hello from the phone", to: session, wait: 5) { false }
        }
        #expect(!log.text.contains("hello from the phone"))
    }
}
