import Foundation
import Observation

// Hook state belongs to one PTY, independently of whether its surface is visible.
@MainActor @Observable final class AgentTurnTracker {
    private(set) var busy = false
    /// The agent was heard between turns since this terminal was bound, by its Stop or its start
    /// at the prompt, and has not begun a turn since. Silence proves nothing: without its hooks,
    /// or after an event the stream may have missed, this stays false. Never true while `busy`.
    private(set) var betweenTurns = false
    private(set) var revision: UInt64 = 0
    private(set) var streamAvailable = false
    private(set) var cli: AgentCLI?
    private(set) var sessionID: String?
    @ObservationIgnored private var terminalID: String?

    func bind(terminalID: String) {
        guard self.terminalID != terminalID else { return }
        invalidate()
        self.terminalID = terminalID; cli = nil; sessionID = nil; busy = false; betweenTurns = false
    }

    func setStreamAvailable(_ value: Bool) {
        guard streamAvailable != value else { return }
        streamAvailable = value
        if !value {
            betweenTurns = false
            invalidate()
        }
    }

    /// Known to be at its prompt, with the stream that would report its next turn still up.
    var idle: Bool { streamAvailable && betweenTurns }

    /// The agent started, or its conversation changed (Claude's SessionStart): it is at its prompt,
    /// and a turn of the old conversation can no longer finish, so its busy state goes with it.
    /// A compaction is the exception: it lands mid-turn and the turn carries on.
    func adopt(sessionID id: String, midTurn: Bool) {
        if !midTurn { busy = false; betweenTurns = true }
        guard sessionID != id else { return }
        sessionID = id; revision &+= 1
    }

    // Returns true only for a recognized hook addressed to this PTY. The caller
    // still checks its durable session's CLI before persisting conversation IDs.
    @discardableResult func receive(_ event: ServerEvent) -> Bool {
        guard streamAvailable, let terminalID, event.runId == terminalID,
              let raw = event.cli, let incomingCLI = AgentCLI(rawValue: raw),
              ["agent-turn-start", "agent-turn-done"].contains(event.type) else { return false }
        let incomingID = event.sessionId.flatMap { $0.isEmpty ? nil : $0 }
        // A Stop for an older/different CLI conversation must not clear a newer
        // turn's busy state.
        if event.type == "agent-turn-done",
           ((cli != nil && cli != incomingCLI) || (sessionID != nil && incomingID != nil && sessionID != incomingID)) { return false }
        cli = incomingCLI
        if let incomingID { sessionID = incomingID }
        if event.type == "agent-turn-start" {
            revision &+= 1; busy = true; betweenTurns = false
        } else {
            busy = false; betweenTurns = true
        }
        return true
    }

    func invalidate() {
        revision &+= 1
    }
}
