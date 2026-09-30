import Foundation

/// Types a message from the phone into a session's agent.
///
/// The phone cannot see a question the agent puts up in the terminal, so a message must never
/// land in one: it is typed only while the agent's hooks show it at its prompt, with nothing
/// asked and no approval open, and it waits for that before every write.
enum RemoteDelivery {
    /// How long a message waits for the agent to be ready before it is given up.
    static let wait = RemoteSchema.deliveryWait

    @MainActor
    static func deliver(_ text: String, to terminal: TerminalSession, wait: TimeInterval = RemoteDelivery.wait,
                        approvalOpen: @escaping @MainActor () -> Bool) async throws {
        guard terminal.isLive else {
            throw RemoteCommandError(String(localized: "The session isn’t running on your Mac."))
        }
        guard terminal.agentTurns.streamAvailable else {
            throw RemoteCommandError(String(localized: "Cascade can’t tell when this agent is ready. Install its hooks in Settings → Integrations."))
        }
        let deadline = Date().addingTimeInterval(wait)
        try await AgentMessageTyper.type(text, files: [], into: terminal) { [weak terminal] in
            while true {
                guard let terminal, terminal.isLive else {
                    throw RemoteCommandError(String(localized: "The session isn’t running on your Mac."))
                }
                if terminal.agentTurns.idle && !terminal.agentTurns.mayBeAsking && !approvalOpen() { return }
                guard Date() < deadline else {
                    throw RemoteCommandError(String(localized: "The agent stayed busy, so the message wasn’t sent."))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
