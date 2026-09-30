import Foundation

/// Types a message from the phone into a session's agent.
///
/// The phone cannot see the terminal, so a message must never land anywhere but the agent's own
/// prompt: not in a question the agent put up, not in a shell the agent exited to, not in the
/// startup dialog of an agent started since. It is typed only while the agent's hooks show it at
/// its prompt with nothing asked, no approval is open, and what is in front of the terminal is
/// still the process those hooks spoke for. All of that is checked again before every write.
enum RemoteDelivery {
    /// How long a message waits for the agent to be ready before it is given up.
    static let wait = RemoteSchema.deliveryWait
    /// How long after Enter the agent is given to be heard starting its turn. Until then its
    /// hooks still say idle, and the next message would be typed into the turn beginning.
    static let turnStart: TimeInterval = 10

    /// Waits for the agent to be heard starting on what was just sent. The next message waits on it.
    typealias TurnStart = @MainActor () async -> Void

    /// Returns once Enter is written: the message is sent. What it returns is awaited before the
    /// next message is typed.
    @MainActor @discardableResult
    static func deliver(_ text: String, to terminal: TerminalSession, wait: TimeInterval = RemoteDelivery.wait,
                        turnStart: TimeInterval = RemoteDelivery.turnStart,
                        approvalOpen: @escaping @MainActor () -> Bool) async throws -> TurnStart {
        guard terminal.isLive else {
            throw RemoteCommandError(String(localized: "The session isn’t running on your Mac."))
        }
        guard terminal.agentTurns.streamAvailable else {
            throw RemoteCommandError(String(localized: "Cascade can’t tell when this agent is ready. Install its hooks in Settings → Integrations."))
        }
        let deadline = Date().addingTimeInterval(wait)
        let before = terminal.agentTurns.revision
        try await AgentMessageTyper.type(text, files: [], into: terminal) { [weak terminal] in
            while true {
                guard let terminal, terminal.isLive else {
                    throw RemoteCommandError(String(localized: "The session isn’t running on your Mac."))
                }
                let front = try await terminal.foregroundProcess()
                terminal.agentTurns.watch(foreground: front.pgid, name: front.process, atShell: front.atShell)
                guard !front.atShell else {
                    throw RemoteCommandError(String(localized: "No agent is running in this session."))
                }
                let turns = terminal.agentTurns
                if turns.idle && !turns.mayBeAsking && !turns.processChanged && !approvalOpen() { return }
                guard Date() < deadline else {
                    throw RemoteCommandError(String(localized: "The agent wasn’t ready, so the message wasn’t sent."))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let sent = Date()
        return { [weak terminal] in
            while let terminal, terminal.isLive, !terminal.agentTurns.busy, terminal.agentTurns.revision == before,
                  -sent.timeIntervalSinceNow < turnStart {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
