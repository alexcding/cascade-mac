import AppKit
import Foundation

// For tests that run real terminals: an isolated daemon whose shell can start only stub agents,
// and a pane's surface mounted offscreen.

/// An isolated daemon, and a zsh that reads no startup files. Its `claude` and `codex` are stubs
/// that note each launch and wait in the foreground, as an agent does, so a test that launches an
/// agent can never start a real one. One resuming a conversation listed in `backgroundJobs` first
/// leaves a job running in a process group of its own, as an agent does with a build.
struct DaemonFixture {
    let directory = URL(fileURLWithPath: "/tmp/th-term-\(UUID().uuidString.prefix(12))")
    var config: PtydConfiguration {
        PtydConfiguration(executable: TestPaths.checkout.appendingPathComponent("crates/craft-ptyd/target/debug/craft-ptyd"),
                          directory: directory, socketPath: directory.appendingPathComponent("pty.sock").path)
    }
    /// Named zsh: it is the only shell the daemon starts an agent in.
    var shell: String { directory.appendingPathComponent("zsh").path }
    /// One line per stub agent launch: its name and arguments.
    var launches: URL { directory.appendingPathComponent("launches") }
    /// One conversation id per line.
    var backgroundJobs: URL { directory.appendingPathComponent("background-jobs") }
    /// Conversations a resume cannot find, one id per line: the stub says so and exits, as Claude does.
    var missingConversations: URL { directory.appendingPathComponent("missing-conversations") }

    init() throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "#!/bin/sh\nPATH='\(bin.path)':/usr/bin:/bin; export PATH\nexec /bin/zsh -f \"$@\"\n"
            .write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell)
        for agent in ["claude", "codex"] {
            let stub = bin.appendingPathComponent(agent).path
            try """
                #!/bin/sh
                printf '%s %s\\n' \(agent) "$*" >> '\(launches.path)'
                if [ "$1" = --resume ] && grep -qx -- "$2" '\(missingConversations.path)' 2>/dev/null; then
                    echo "No conversation found with session ID: $2"; exit 1
                fi
                grep -qx -- "$2" '\(backgroundJobs.path)' 2>/dev/null || exec /bin/sleep 600
                # Waiting in the shell, not replaced by sleep, the stub reaps the job once it ends, as
                # an agent does. The job ends by itself once the fixture is removed.
                /usr/bin/perl -e 'setpgrp; sleep 1 while -d $ARGV[0]' '\(directory.path)' &
                /bin/sleep 600

                """.write(toFile: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A pane's surface in an offscreen window: measured, never drawn.
@MainActor func mountOffscreen(_ session: TerminalSession) -> NSWindow {
    let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 420))
    view.delegate = session.surface; view.controller = session.surface.controller
    view.configuration = session.surface.configuration
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    view.layoutSubtreeIfNeeded(); view.setSurfaceVisible(false)
    return window
}
