import Foundation

@MainActor final class NativeWorkflowTerminal: WorkflowTerminal {
    private let terminal: TerminalSession
    private let cli: WorkflowCLI
    private let sessionID: String?
    private let foreground: TerminalSession.WorkflowForeground
    private let surfaceGeneration: UUID
    private var activeTicket: AgentTurnTracker.Ticket?

    init(terminal: TerminalSession, cli: WorkflowCLI, sessionID: String?) async throws {
        self.terminal = terminal; self.cli = cli; self.sessionID = sessionID
        surfaceGeneration = terminal.surfaceGeneration
        let foreground = try await terminal.workflowForeground()
        guard !foreground.atShell, let pgid = foreground.pgid, pgid > 0 else {
            throw BackendError.operation("The agent is not running, or the PTY helper needs updating. Open the terminal and check its startup before retrying.")
        }
        guard Self.matches(foreground, cli: cli,
                           launched: terminal.launchedAgent == cli && terminal.launchedAgentForeground == foreground) else {
            throw BackendError.operation("The foreground program is \(foreground.process.isEmpty ? "unknown" : foreground.process), not the selected \(cli.title) agent. Return to the shell before running this workflow.")
        }
        guard !terminal.agentBusy else { throw BackendError.operation("The agent is busy. Finish or stop its current turn first.") }
        self.foreground = foreground
    }

    static func matches(_ value: TerminalSession.WorkflowForeground, cli: WorkflowCLI, launched: Bool) -> Bool {
        if value.process == cli.rawValue { return true }
        if cli == .claude, let path = value.processPath,
           path.contains("/claude/versions/"), value.process.first?.isNumber == true { return true }
        // npm Claude runs inside Node. Its exact foreground identity must match
        // our launch; an old hook or a different Node process is insufficient.
        return cli == .claude && value.process == "node" && launched
    }

    private func validateOwner() async throws {
        guard terminal.ready, terminal.surfaceGeneration == surfaceGeneration,
              terminal.agentTurns.streamAvailable else { throw BackendError.operation("The terminal or agent event connection changed during the workflow.") }
        let current = try await terminal.workflowForeground()
        guard current == foreground else { throw BackendError.operation("The foreground program changed. Workflow input was stopped.") }
        try Task.checkCancellation()
    }
    func validate(after revision: UInt64) async throws {
        try await validateOwner()
        guard !terminal.agentBusy, terminal.agentTurns.revision == revision else {
            throw BackendError.operation("Another agent turn started. Workflow input was stopped.")
        }
    }
    static func paste(_ command: String) throws -> String {
        guard !command.isEmpty, command.utf8.count <= 64 * 1024,
              !command.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127 }) else {
            throw BackendError.operation("Workflow commands must contain text without terminal control characters and fit within 64 KiB after expansion.")
        }
        // Both interactive agents use bracketed paste for multi-line commands.
        // Enter is acknowledged separately after the pasted text has arrived.
        return "\u{1b}[200~" + command + "\u{1b}[201~"
    }
    func execute(_ command: String) async throws -> UInt64 {
        let pasted = try Self.paste(command)
        try await validateOwner()
        let ticket = try terminal.agentTurns.arm(cli: cli, sessionID: sessionID)
        activeTicket = ticket
        do {
            try await terminal.writeWorkflowInput(pasted)
            try await Task.sleep(for: .milliseconds(60))
            try await validateOwner()
            try await terminal.writeWorkflowInput("\r")
            let revision = try await terminal.agentTurns.wait(for: ticket)
            activeTicket = nil
            return revision
        } catch is CancellationError {
            // Keep the interruption target until stopStep handles it.
            terminal.agentTurns.cancel(ticket)
            throw CancellationError()
        } catch {
            terminal.agentTurns.cancel(ticket); activeTicket = nil
            throw error
        }
    }
    func lastMessage() async -> String? {
        guard let text = await terminal.viewportText() else { return nil }
        return String(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n").suffix(16_384))
    }
    func stopStep() async throws {
        guard let ticket = activeTicket else { return }
        activeTicket = nil; terminal.agentTurns.cancel(ticket)
        guard terminal.ready, terminal.surfaceGeneration == surfaceGeneration,
              try await terminal.workflowForeground() == foreground else { return }
        // This task is separate from the cancelled run; never deliver Escape to
        // a replacement foreground process or a reconnected surface.
        try await terminal.writeWorkflowInput("\u{1b}")
        terminal.agentTurns.interrupted()
    }
}
