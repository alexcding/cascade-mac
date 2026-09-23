import Foundation
import Observation
import GhosttyTerminal

@MainActor @Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let pairKey: String
    let cwd: String
    let paired: Bool
    @ObservationIgnored private(set) var presentation: TerminalPaneViewModel!
    private(set) var surface = TerminalViewState()
    private(set) var surfaceGeneration = UUID() { didSet { presentation?.surfaceChanged() } }
    private(set) var status = "Connecting"
    private(set) var error: String? { didSet { if oldValue != error { noticeDismissed = false } } }
    private(set) var shellPID: UInt32?
    private(set) var termID: String?
    let agentTurns = AgentTurnTracker()
    var agentBusy: Bool { agentTurns.busy }
    private(set) var ready = false
    private(set) var style = TerminalStyle()
    /// Everything in the current style that did not apply, joined for display. Never fatal.
    private(set) var styleError: String? { didSet { if oldValue != styleError { noticeDismissed = false } } }
    /// Hides the notice banner without touching `error`/`styleError` themselves — those still
    /// drive `isConnecting` and reconnect logic. A new error or style issue (a value change,
    /// not just an in-place re-set) un-dismisses it.
    private(set) var noticeDismissed = false
    @ObservationIgnored private var pipe: TerminalPipe!
    /// The NSView Ghostty draws into. The view owns the surface — grid, scrollback,
    /// parser — so the session keeps it alive across SwiftUI mounting it and taking it
    /// down again as the sidebar selection moves; a fresh view per mount would start an
    /// empty terminal. One per `surfaceGeneration`, mirroring how `BrowserPage` keeps its
    /// `WKWebView`.
    @ObservationIgnored private var platformView: WorkspaceTerminalView?
    @ObservationIgnored private var client: PtydClient?
    @ObservationIgnored private var host: PtydHost?
    @ObservationIgnored private var hello: PtyHello?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var commandWrites = 0
    @ObservationIgnored private let configuration: PtydConfiguration?
    @ObservationIgnored private let configurationProvider: @Sendable () throws -> PtydConfiguration
    @ObservationIgnored private let shellPath: String?
    var outputDiagnostics: TerminalPipe.Diagnostics { pipe.diagnostics }
    @ObservationIgnored var openLink: (String, String, Bool) -> Void = { _, _, _ in }
    @ObservationIgnored var onCreated: ((TerminalSession) async throws -> Void)?
    @ObservationIgnored var launchedAgent: WorkflowCLI?
    @ObservationIgnored var launchedAgentForeground: WorkflowForeground?

    init(pairKey: String = "native-terminal-spike", cwd: String = FileManager.default.homeDirectoryForCurrentUser.path, paired: Bool = false,
         configuration: PtydConfiguration? = nil, shellPath: String? = nil,
         configurationProvider: @escaping @Sendable () throws -> PtydConfiguration = { try .current() }) {
        self.pairKey = pairKey
        self.cwd = cwd
        self.paired = paired
        self.configuration = configuration
        self.configurationProvider = configurationProvider
        self.shellPath = shellPath
        makeSurface()
        presentation = TerminalPaneViewModel(session: self)
    }

    private func makeSurface() {
        let wasVisible = surface.isSurfaceVisible
        surfaceGeneration = UUID()
        let generation = surfaceGeneration
        platformView = nil
        var resolved = style.resolve()
        var issues = resolved.issues
        surface = TerminalViewState(theme: resolved.theme, terminalConfiguration: resolved.configuration)
        // A line Ghostty rejects discards the whole config, font and theme included, and the
        // package quietly falls back to its stock config. Keybinds are the only free-form
        // input, so drop them and rebuild rather than lose the styling.
        if let issue = surface.controller.lastConfigurationIssue {
            if !style.keybinds.isEmpty {
                resolved = style.withoutKeybinds.resolve()
                surface = TerminalViewState(theme: resolved.theme, terminalConfiguration: resolved.configuration)
                issues.append("Ghostty rejected the terminal keybinds, so they are off until fixed in Settings: \(issue)")
            } else {
                issues.append(issue)
            }
        }
        styleError = issues.isEmpty ? nil : issues.joined(separator: " ")
        surface.isSurfaceVisible = wasVisible
        pipe = TerminalPipe(onError: { [weak self] text in
            Task { @MainActor in
                guard let self, self.surfaceGeneration == generation else { return }
                self.setError(text, prefer: true)
            }
        }, onExit: { [weak self] code in
            Task { @MainActor in
                guard let self, self.surfaceGeneration == generation else { return }
                self.status = "Exited (\(code))"; self.ready = false
                self.agentTurns.invalidate("The terminal exited during the workflow step.")
            }
        })
        surface.configuration = .init(backend: .inMemory(pipe.memory))
        surface.makePlatformView = { [weak self] in
            if let view = self?.platformView { return view }
            let view = WorkspaceTerminalView(frame: .zero)
            view.openLink = { [weak self] raw, directory, external in
                guard let self, self.surfaceGeneration == generation else { return }
                self.openLink(raw, directory ?? self.cwd, external)
            }
            view.visibilityChanged = { [weak self] in
                guard let self, self.surfaceGeneration == generation else { return }
                self.presentation?.surfaceChanged()
            }
            self?.platformView = view
            return view
        }
        surface.onClose = { [weak self] _ in
            guard let self, self.surfaceGeneration == generation else { return }
            self.status = "Exited"; self.ready = false
            self.agentTurns.invalidate("The terminal closed during the workflow step.")
        }
    }

    func setStyle(_ value: TerminalStyle) {
        guard style != value else { return }
        let previous = style
        let resolved = value.resolve()
        var issues = resolved.issues
        // Changing surface.configuration would rebuild the emulator. Reconfigure
        // its controller in place, preserving parser/surface and daemon ownership.
        //
        // The difference is checked here first because setTerminalConfiguration also returns
        // false for a configuration equal to the one already applied. Calling it unguarded
        // reports "could not apply" for every style change that leaves the font alone — a
        // theme switch, say — which is the opposite of what happened.
        if resolved.configuration != surface.terminalConfiguration,
           !surface.setTerminalConfiguration(resolved.configuration) {
            let issue = surface.controller.lastConfigurationIssue ?? "Could not apply the terminal font."
            // Same recovery as makeSurface: keep the font and theme, shed the keybinds.
            if !value.keybinds.isEmpty, surface.setTerminalConfiguration(value.withoutKeybinds.resolve().configuration) {
                issues.append("Ghostty rejected the terminal keybinds, so they are off until fixed in Settings: \(issue)")
            } else {
                issues.append(issue)
            }
        }
        if resolved.theme != surface.theme, !surface.setTheme(resolved.theme) {
            issues.append(surface.controller.lastConfigurationIssue ?? "Could not apply the terminal theme.")
        }
        style = value
        styleError = issues.isEmpty ? nil : issues.joined(separator: " ")
        // A prior native zoom action marks the size as manually adjusted; reset
        // to the newly configured size so future preference updates keep working.
        // Only a font change needs it: resetting after a theme or smoothing change
        // would throw away a zoom the surface was legitimately holding.
        if previous.font != value.font { _ = surface.performBindingAction("reset_font_size") }
    }

    func start() async {
        guard !started, !stopped else { return }
        started = true
        let task = Task {
            do { try await connect(reconnecting: false) }
            catch { setError(error.localizedDescription); pipe.close(); client?.close() }
        }
        startTask = task
        await task.value
    }

    private func connect(reconnecting: Bool) async throws {
        let generation = surfaceGeneration
        // The engine must exist before replay; the package's pre-surface buffer
        // drops old bytes past 1 MiB and is not a substitute for our flow control.
        for _ in 0..<50 {
            if surface.surface != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard surface.surface != nil else { throw PtyError.connection("Ghostty could not create a native surface.") }
        guard pipe.memory.enableGeometryCallbacks() else {
            throw PtyError.connection("Ghostty could not report complete terminal geometry.")
        }
        let config = try configuration ?? configurationProvider()
        let host = PtydHost(configuration: config)
        self.host = host
        let pipe = self.pipe!
        let client = PtydClient(onEvent: { pipe.receive($0) }, onDisconnect: { [weak self] failure in
            let inputWasIdle = pipe.freezeForReconnect()
            Task { @MainActor in
                guard let self, self.surfaceGeneration == generation else { return }
                self.connectionLost(failure, inputWasIdle: inputWasIdle)
            }
        })
        self.client = client
        // Reconnect only to the existing daemon. Never spawn a replacement
        // daemon or shell to hide the loss of the original process.
        if reconnecting { hello = try await client.connect(path: config.socketPath) }
        else { hello = try await host.connect(client: client) }
        try hello?.validateByteTransport()
        try hello?.validateInputAcknowledgements()
        try hello?.validateSnapshots()
        try hello?.validateStateResponseOwner()
        let negotiated: PtyHello = try await client.request(.init(op: "hello", dataEncoding: "base64",
                                                                  snapshotRevision: PtySnapshot.revision))
        try negotiated.validateSnapshots()
        try negotiated.validateStateResponseOwner()
        try Task.checkCancellation()
        let terminals: [PtyInfo] = try await client.request(.init(op: "list"))
        let info: PtyInfo
        let created: Bool
        if reconnecting {
            guard let existing = terminals.first(where: { $0.id == termID && $0.pid == shellPID }) else {
                throw PtyError.connection("The original terminal is no longer running. Automatic reconnect did not create a replacement shell.")
            }
            info = existing
            created = false
        } else if let existing = terminals.first(where: { $0.pairKey == pairKey && $0.paired == paired }) {
            info = existing
            created = false
        } else {
            try negotiated.validateIdentityResponseOwner()
            try negotiated.validateShellIntegration()
            try negotiated.validateGeometryResponseOwner()
            try negotiated.validateAppearanceResponseOwner()
            let profile = try PtyTerminalProfile.current()
            let geometry = try await pipe.measuredGeometry()
            let appearance = try pipe.prepareAppearance()
            try Task.checkCancellation()
            info = try await client.request(.init(op: "create", opts: .init(
                cwd: cwd, shell: shellPath, paired: paired, pairKey: pairKey,
                stateResponseOwner: PtyHello.identityResponseOwnerVersion, terminalProfile: profile,
                geometryResponseOwner: PtyHello.geometryResponseOwnerVersion, geometry: geometry,
                appearanceResponseOwner: PtyHello.appearanceResponseOwnerVersion, appearance: appearance)))
            created = true
        }
        guard !created || info.geometryResponseOwner == PtyHello.geometryResponseOwnerVersion else {
            throw PtyError.connection("The PTY helper did not preserve the requested terminal geometry owner. The created shell has been preserved.")
        }
        guard !created || info.appearanceResponseOwner == PtyHello.appearanceResponseOwnerVersion else {
            throw PtyError.connection("The PTY helper did not preserve native color ownership. The created shell has been preserved.")
        }
        try info.validateStateResponseOwner()
        if info.stateResponseOwner == PtyHello.identityResponseOwnerVersion {
            try negotiated.validateIdentityResponseOwner()
        }
        if info.geometryResponseOwner != nil { try negotiated.validateGeometryResponseOwner() }
        shellPID = info.pid
        termID = info.id
        agentTurns.bind(terminalID: info.id)
        if info.appearanceResponseOwner != nil {
            try negotiated.validateAppearanceResponseOwner()
            _ = try pipe.prepareAppearance()
        }
        pipe.bind(client: client, id: info.id, geometryOwned: info.geometryResponseOwner != nil,
                  appearanceOwned: info.appearanceResponseOwner != nil)
        if info.appearanceResponseOwner != nil { try await pipe.synchronizeAppearance() }
        try await pipe.synchronizeGrid()
        status = "Restoring terminal"
        let snapshot = try await PtySnapshotDownloader(client: client).fetch(term: info.id)
        try await pipe.attach(snapshot, daemonOwnsStateResponses: true,
                              daemonOwnsIdentityResponses: info.stateResponseOwner == PtyHello.identityResponseOwnerVersion,
                              daemonOwnsGeometryResponses: info.geometryResponseOwner != nil,
                              daemonOwnsAppearanceResponses: info.appearanceResponseOwner != nil) { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.surfaceGeneration == generation, self.error == nil else { return }
                self.status = "Connected"
                self.ready = true
                self.presentation.becameReady()
                if created, let onCreated = self.onCreated {
                    self.launchTask = Task {
                        defer { self.launchTask = nil }
                        do {
                            // Let the shell finish its startup files before entering a command.
                            try await Task.sleep(for: .seconds(1))
                            try await onCreated(self)
                        } catch { if !Task.isCancelled, self.error == nil { self.error = error.localizedDescription } }
                    }
                }
            }
        }
        try await waitUntilReady()
    }

    private func connectionLost(_ failure: PtyError, inputWasIdle: Bool) {
        guard !stopped else { return }
        agentTurns.invalidate("The terminal connection was lost. Check the terminal before restarting the workflow.")
        let wasReady = ready
        ready = false
        // The current attempt observes its closed pipeline and handles retry.
        guard reconnectTask == nil else { return }
        guard wasReady, failure.permitsReconnect, inputWasIdle,
              commandWrites == 0, launchTask == nil else {
            setError(inputWasIdle ? failure.localizedDescription :
                "Terminal disconnected while input or attachment was unsettled. Earlier input may have been sent. Check the shell before reattaching.")
            return
        }
        status = "Reconnecting"
        reconnectTask = Task {
            defer { reconnectTask = nil }
            for delay in [250, 500, 1000, 2000, 4000] {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                    try Task.checkCancellation()
                    guard !stopped else { return }
                    error = nil
                    makeSurface()
                    try await connect(reconnecting: true)
                    return
                } catch {
                    pipe.close()
                    guard !Task.isCancelled, !stopped else { return }
                    if (error as? PtyError)?.permitsReconnect != true {
                        setError(error.localizedDescription)
                        return
                    }
                    if delay == 4000 { setError(error.localizedDescription) }
                    else { status = "Reconnecting" }
                }
            }
        }
    }

    /// True while the pane should cover the surface with progress: before the first
    /// attach and across a reconnect, but never once the shell has exited — that
    /// surface still holds the scrollback the user wants to read. Keyed on `status`,
    /// not `error`: `setError` always lands on "Disconnected", so dismissing the banner
    /// cannot make a dead connection look like a retry.
    var isConnecting: Bool { !ready && !status.hasPrefix("Exited") && status != "Disconnected" }

    /// Clears the banner only. The connection keeps whatever state it was in — `error` and
    /// `styleError` are left set — so `isConnecting` still reflects a genuine failure instead
    /// of flipping true once the banner is dismissed. A later failure or a reconnect
    /// (a change to either value) shows the banner again.
    func dismissNotice() {
        noticeDismissed = true
    }

    private func setError(_ text: String, prefer: Bool = false) {
        // Closing a failed pipeline also reports a socket disconnect; preserve
        // the actionable root cause (for example truncated restoration).
        if error == nil || prefer { error = text }
        status = "Disconnected"
        ready = false
        agentTurns.invalidate(text)
    }

    func disconnect() {
        // This object owns one connection/surface generation. A delayed ready
        // callback must not reactivate it after its owner removes the pane.
        stopped = true
        agentTurns.invalidate("The terminal was disconnected during the workflow step.")
        reconnectTask?.cancel()
        started = false
        pipe.close()
        ready = false
        // `isConnecting` reads `status`: a stopped terminal must not look like one
        // still attaching, or the pane's opaque progress overlay would hide its output.
        status = "Disconnected"
    }

    func stopConnecting() async {
        stopped = true
        started = false
        launchTask?.cancel()
        startTask?.cancel()
        reconnectTask?.cancel()
        // A create already sent may still be completing in the daemon. Await its
        // reply before closing the transport so Quit can account for that shell.
        await startTask?.value
        await reconnectTask?.value
        await launchTask?.value
        disconnect()
    }

    func submit(_ line: String) async throws {
        guard ready, let client, let termID else { throw PtyError.closed }
        guard !line.contains("\n"), !line.contains("\r"), !line.contains("\0") else {
            throw PtyError.connection("Terminal commands must contain a single line.")
        }
        commandWrites += 1
        defer { commandWrites -= 1 }
        guard try await atShell() else { throw PtyError.connection("The terminal is busy. Return to its shell before launching a command.") }
        try Task.checkCancellation()
        do {
            let _: Bool? = try await client.request(.init(op: "write", term: termID, data: line))
            try await Task.sleep(for: .milliseconds(60))
            let _: Bool? = try await client.request(.init(op: "write", term: termID, data: "\r"))
        } catch {
            setError("Command delivery was interrupted. Earlier input may have been sent. Check the shell before reattaching.", prefer: true)
            throw error
        }
    }

    /// Types at the agent's own prompt: slash commands, and key presses in a menu one of them
    /// opened. The mirror image of `submit`: it refuses at the shell, where a slash command
    /// would run as a path.
    func submitToAgent(_ inputs: [AgentInput]) async throws {
        guard ready, let client, let termID else { throw PtyError.closed }
        let texts = inputs.map { input in switch input { case .line(let text), .key(let text): text } }
        guard texts.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }) else {
            throw PtyError.connection("Agent commands must contain a single line.")
        }
        guard commandWrites == 0 else { throw BackendError.operation("Another terminal command is being delivered.") }
        commandWrites += 1
        defer { commandWrites -= 1 }
        guard try await !atShell() else { throw PtyError.connection("No agent is running in this terminal.") }
        try Task.checkCancellation()
        for (index, input) in inputs.enumerated() {
            // The agent redraws after each command or choice; typing into the redraw drops keys.
            if index > 0 { try await Task.sleep(for: .milliseconds(700)) }
            switch input {
            case .line(let text):
                let _: Bool? = try await client.request(.init(op: "write", term: termID, data: text))
                try await Task.sleep(for: .milliseconds(60))
                let _: Bool? = try await client.request(.init(op: "write", term: termID, data: "\r"))
            case .key(let key):
                let _: Bool? = try await client.request(.init(op: "write", term: termID, data: key))
            }
        }
    }

    func atShell() async throws -> Bool {
        struct Foreground: Decodable, Sendable { let atShell: Bool }
        guard ready, let client, let termID else { throw PtyError.closed }
        let result: Foreground = try await client.request(.init(op: "foreground", term: termID))
        return result.atShell
    }

    struct WorkflowForeground: Decodable, Equatable, Sendable {
        let atShell: Bool
        let process: String
        var processPath: String?
        var pgid: Int32?
    }
    func workflowForeground() async throws -> WorkflowForeground {
        guard ready, let client, let termID else { throw PtyError.closed }
        return try await client.request(.init(op: "foreground", term: termID))
    }
    func waitForAutomaticLaunch() async throws {
        try await waitUntilReady()
        let launch = launchTask
        await withTaskCancellationHandler {
            if Task.isCancelled { launch?.cancel() }
            await launch?.value
        } onCancel: { launch?.cancel() }
        if launch != nil { try await Task.sleep(for: .seconds(2)) }
        try Task.checkCancellation()
        if let error { throw BackendError.operation(error) }
    }
    func writeWorkflowInput(_ data: String) async throws {
        guard ready, let client, let termID else { throw PtyError.closed }
        guard commandWrites == 0 else { throw BackendError.operation("Another terminal command is being delivered.") }
        commandWrites += 1
        defer { commandWrites -= 1 }
        do {
            let _: Bool? = try await client.request(.init(op: "write", term: termID, data: data))
        } catch {
            setError("Workflow input delivery was interrupted. Earlier input may have been sent. Check the terminal before restarting.", prefer: true)
            throw error
        }
    }

    func interrupt() async throws {
        guard ready, let client, let termID else { throw PtyError.closed }
        commandWrites += 1
        defer { commandWrites -= 1 }
        do {
            let _: Bool? = try await client.request(.init(op: "write", term: termID, data: "\u{03}"))
        } catch {
            setError("Interrupt delivery was interrupted. Earlier input may have been sent. Check the shell before reattaching.", prefer: true)
            throw error
        }
    }

    func waitUntilReady() async throws {
        for _ in 0..<100 {
            if ready { return }
            if let error { throw PtyError.connection(error) }
            if pipe.isClosed { throw PtyError.closed }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PtyError.connection("The terminal did not become ready. Open its pane and retry.")
    }

    func quit() async {
        await stopConnecting()
        if let host {
            do { try await host.stopExisting() }
            catch { setError(error.localizedDescription) }
        }
    }

    func viewportText() async -> String? {
        let memory = pipe.memory!
        return await Task.detached {
            memory.waitForPendingOutput()
            return memory.readViewportText()
        }.value
    }
}
