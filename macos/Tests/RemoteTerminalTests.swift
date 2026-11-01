import AppKit
import Foundation
import Testing

// A paired Mac's session terminal, opened here (`TerminalSession.remote`): it attaches to the
// terminal the other Mac's app made and types into it, and never creates one or changes its size.
// The relay between the Macs is the backend's (tested there); here the socket is the daemon's own.

@MainActor @Test(.timeLimit(.minutes(1))) func aRemoteTerminalAttachesToTheSessionsTerminalAtItsSizeAndTypesIntoIt() async throws {
    _ = NSApplication.shared
    let fixture = try DaemonFixture()
    defer { fixture.remove() }
    let control = PtydClient(onEvent: { _ in })
    let daemon = try await PtydHost(configuration: fixture.config).connect(client: control).pid
    defer { control.close(); _ = kill(daemon, SIGTERM) }
    let _: PtyHello = try await control.request(.init(op: "hello", dataEncoding: "base64", snapshotRevision: PtySnapshot.revision))

    // The other Mac's own terminal for the session, as its app makes it.
    let local = TerminalSession(pairKey: "session-r", cwd: fixture.directory.path, paired: true,
                                configuration: fixture.config, shellPath: fixture.shell)
    let localWindow = mountOffscreen(local)
    defer { local.disconnect(); localWindow.contentView = nil; localWindow.close() }
    await local.start()
    try await local.waitUntilReady()
    let before = try await grid(of: try #require(local.termID))

    // Opened here, in a wider view than the other Mac's.
    let socket = fixture.config.socketPath
    let remote = TerminalSession(pairKey: "session-r", cwd: "/elsewhere", paired: true)
    remote.remote = RemoteTerminalSource(name: "Mac mini", socket: { socket })
    let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700))
    view.delegate = remote.surface; view.controller = remote.surface.controller
    view.configuration = remote.surface.configuration
    let remoteWindow = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    remoteWindow.isReleasedWhenClosed = false; remoteWindow.contentView = view
    view.layoutSubtreeIfNeeded(); view.setSurfaceVisible(false)
    defer { remote.disconnect(); remoteWindow.contentView = nil; remoteWindow.close() }
    await remote.start()
    try await remote.waitUntilReady()

    #expect(remote.termID == local.termID && remote.shellPID == local.shellPID, "the same terminal, not a new one")
    let terminals: [PtyInfo] = try await control.request(.init(op: "list"))
    #expect(terminals.filter { $0.pairKey == "session-r" }.count == 1)
    // The wider view did not resize the terminal: it keeps the other Mac's size.
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await grid(of: try #require(remote.termID)) == before)

    // Typed here, run there.
    try await remote.writeAgentInput("echo REMOTE_$((40+2))\r")
    for _ in 0..<200 {
        if await local.viewportText()?.contains("REMOTE_42") == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await local.viewportText()?.contains("REMOTE_42") == true)
    #expect(await remote.viewportText()?.contains("REMOTE_42") == true)

    func grid(of term: String) async throws -> [UInt16] {
        let snapshot = try await PtySnapshotDownloader(client: control).fetch(term: term)
        let geometry = try #require(snapshot.header.geometry)
        return [geometry.cols, geometry.rows]
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func aRemoteTerminalNeverStartsAShellWhenTheSessionHasNone() async throws {
    _ = NSApplication.shared
    let fixture = try DaemonFixture()
    defer { fixture.remove() }
    let control = PtydClient(onEvent: { _ in })
    let daemon = try await PtydHost(configuration: fixture.config).connect(client: control).pid
    defer { control.close(); _ = kill(daemon, SIGTERM) }

    let socket = fixture.config.socketPath
    let remote = TerminalSession(pairKey: "not-running", cwd: "/elsewhere", paired: true)
    remote.remote = RemoteTerminalSource(name: "Mac mini", socket: { socket })
    let window = mountOffscreen(remote)
    defer { remote.disconnect(); window.contentView = nil; window.close() }
    await remote.start()

    #expect(remote.error?.contains("not running on Mac mini") == true, "\(remote.error ?? "no error")")
    // Over, so the app attaches afresh on the next look or Reconnect rather than keep this one.
    let session = WorkspaceSession(id: "not-running", projectId: "p", workspace: "/w", worktree: "/elsewhere",
                                   title: "Gone", branch: "b", url: "", createdAt: nil, pinned: false)
    #expect(RemoteTerminalModel(peer: "ab", session: session, macName: "Mac mini", terminal: remote).isOver)
    let terminals: [PtyInfo] = try await control.request(.init(op: "list"))
    #expect(terminals.isEmpty, "nothing was created")
}

// A session a paired Mac starts here (`AppViewModel.startUnseen`): started with no screen showing
// it, then shown here, the same shell.
@MainActor @Test(.timeLimit(.minutes(1))) func aSessionStartedForAPairedMacRunsUnseenUntilAScreenHereShowsIt() async throws {
    _ = NSApplication.shared
    let fixture = try DaemonFixture()
    defer { fixture.remove() }
    let control = PtydClient(onEvent: { _ in })
    let daemon = try await PtydHost(configuration: fixture.config).connect(client: control).pid
    defer { control.close(); _ = kill(daemon, SIGTERM) }

    let terminal = TerminalSession(pairKey: "session-u", cwd: fixture.directory.path, paired: true,
                                   configuration: fixture.config, shellPath: fixture.shell)
    defer { terminal.disconnect() }
    let unseen = UnseenTerminals()
    unseen.mount(terminal, key: "task:session-u", size: NSSize(width: 900, height: 500))
    await terminal.start()
    try await terminal.waitUntilReady()
    #expect(terminal.isLive && unseen.contains("task:session-u"))
    let shell = terminal.shellPID

    // A screen here shows it: the hidden window lets the view go, and the screen takes it.
    unseen.release("task:session-u")
    #expect(!unseen.contains("task:session-u"))
    let window = mountOffscreen(terminal)
    defer { window.contentView = nil; window.close() }
    try await terminal.writeAgentInput("echo UNSEEN_$((40+2))\r")
    for _ in 0..<200 {
        if await terminal.viewportText()?.contains("UNSEEN_42") == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await terminal.viewportText()?.contains("UNSEEN_42") == true)
    #expect(terminal.shellPID == shell, "the same shell")

    // A terminal replaced or gone under its key is let go.
    unseen.mount(terminal, key: "task:session-u", size: NSSize(width: 900, height: 500))
    unseen.keep([:])
    #expect(!unseen.contains("task:session-u"))
}
