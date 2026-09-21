import AppKit

/// A daemon shell driven with no view at all: created, typed into and polled over the socket.
///
/// A `TerminalSession` cannot do this. It measures geometry and colors from its Ghostty
/// surface before it asks for a shell, and Ghostty only builds a surface for a view that is
/// in a window, so a terminal nobody is looking at could never start. The daemon itself asks
/// for none of that: `create` defaults its grid, records output into its own VT whether or
/// not anyone is attached, and answers `foreground` from the PTY. A `TerminalSession` with the
/// same pair key adopts the shell later, from the daemon's snapshot, when someone opens it.
@MainActor final class DetachedShell {
    /// The grid a new shell starts at. Nothing measures it, so whoever will show the shell says
    /// what it expects to fit: a viewer that attaches at a very different width re-wraps the
    /// output that is already there.
    var grid: (cols: UInt16, rows: UInt16) = (120, 32)

    /// What `size` holds in `font`, by AppKit's metrics. Ghostty pads its cells a little
    /// differently, so this lands within a column or two, which is what avoids the re-wrap.
    static func grid(fitting size: CGSize, font: CodeFont) -> (cols: UInt16, rows: UInt16) {
        let points = CGFloat(font.size)
        let face = (font.family.isEmpty ? nil : NSFont(name: font.family, size: points))
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)
        let cell = CGSize(width: max(1, face.maximumAdvancement.width), height: max(1, ceil(face.ascender - face.descender + face.leading)))
        return (UInt16(max(20, min(500, size.width / cell.width))), UInt16(max(5, min(500, size.height / cell.height))))
    }
    private let pairKey: String
    private let cwd: String
    private let shellPath: String?
    private let configurationProvider: @Sendable () throws -> PtydConfiguration
    private var client: PtydClient?
    private var termID: String?
    private var generation = UUID()

    init(pairKey: String, cwd: String, shellPath: String? = nil, configurationProvider: @escaping @Sendable () throws -> PtydConfiguration) {
        self.pairKey = pairKey; self.cwd = cwd; self.shellPath = shellPath; self.configurationProvider = configurationProvider
    }

    /// Connects on demand, so a daemon connection lost since the last build is simply made again.
    /// So is the shell: someone may have typed `exit` in the log popover, and the daemon reports
    /// a terminal it no longer has as sitting at its shell, which would read as a finished build.
    func waitUntilReady() async throws {
        if let client, let termID {
            let terminals: [PtyInfo]? = try? await client.request(.init(op: "list"))
            if terminals?.contains(where: { $0.id == termID }) == true { return }
            close()
        }
        let generation = UUID(); self.generation = generation
        let client = PtydClient(onEvent: { _ in }, onDisconnect: { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.client = nil; self.termID = nil
            }
        })
        do {
            let hello = try await PtydHost(configuration: configurationProvider()).connect(client: client)
            let terminals: [PtyInfo] = try await client.request(.init(op: "list"))
            if let existing = terminals.first(where: { $0.pairKey == pairKey && $0.paired }) {
                termID = existing.id
            } else {
                try hello.validateIdentityResponseOwner()
                try hello.validateShellIntegration()
                // Geometry and colors are the view's to give, so neither is claimed here: the
                // daemon only takes ownership of them together with measured values.
                let info: PtyInfo = try await client.request(.init(op: "create", opts: .init(
                    cwd: cwd, shell: shellPath, paired: true, pairKey: pairKey,
                    stateResponseOwner: PtyHello.identityResponseOwnerVersion, terminalProfile: try .current())))
                let _: Bool? = try await client.request(.init(op: "resize", term: info.id, cols: grid.cols, rows: grid.rows))
                termID = info.id
            }
            guard self.generation == generation else { throw PtyError.closed }
            self.client = client
        } catch {
            client.close(); termID = nil
            throw error
        }
    }

    /// The shell belongs to the daemon and outlives this; only the connection is given up.
    func close() {
        generation = UUID()
        client?.close(); client = nil; termID = nil
    }

    func atShell() async throws -> Bool {
        struct Foreground: Decodable, Sendable { let atShell: Bool }
        guard let client, let termID else { throw PtyError.closed }
        let result: Foreground = try await client.request(.init(op: "foreground", term: termID))
        return result.atShell
    }

    func foregroundProcess() async throws -> (atShell: Bool, process: String, subshell: Bool?) {
        // `subshell` is missing from a daemon that outlived the app version it was started by.
        struct Foreground: Decodable, Sendable { let atShell: Bool; let process: String; var subshell: Bool? }
        guard let client, let termID else { throw PtyError.closed }
        let result: Foreground = try await client.request(.init(op: "foreground", term: termID))
        return (result.atShell, result.process, result.subshell)
    }

    func submit(_ line: String) async throws {
        guard let client, let termID else { throw PtyError.closed }
        guard !line.contains("\n"), !line.contains("\r"), !line.contains("\0") else {
            throw PtyError.connection("Terminal commands must contain a single line.")
        }
        guard try await atShell() else { throw PtyError.connection("The terminal is busy. Return to its shell before launching a command.") }
        try Task.checkCancellation()
        let _: Bool? = try await client.request(.init(op: "write", term: termID, data: line))
        try await Task.sleep(for: .milliseconds(60))
        let _: Bool? = try await client.request(.init(op: "write", term: termID, data: "\r"))
    }

    func interrupt() async throws {
        guard let client, let termID else { throw PtyError.closed }
        let _: Bool? = try await client.request(.init(op: "write", term: termID, data: "\u{03}"))
    }
}
