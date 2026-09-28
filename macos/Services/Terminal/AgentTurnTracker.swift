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
    /// Approvals and questions the agent's hook has put to the app and nobody has answered yet, by
    /// request id. Claude draws its own prompt in the terminal as the hook starts, not after it.
    private var asking: Set<String> = []
    /// One may be up in the terminal with no word of its answer until the turn ends: handed to the
    /// terminal's own prompt, or asked while nothing was listening.
    private var askingInTerminal = false
    @ObservationIgnored private var terminalID: String?

    func bind(terminalID: String) {
        guard self.terminalID != terminalID else { return }
        invalidate()
        self.terminalID = terminalID; cli = nil; sessionID = nil; busy = false; betweenTurns = false
        closePrompts()
    }

    func setStreamAvailable(_ value: Bool) {
        guard streamAvailable != value else { return }
        streamAvailable = value
        if !value {
            betweenTurns = false
            promptsUnheard()
            invalidate()
        }
    }

    /// Requests may have come and gone unheard, while the stream was down or the app was not
    /// running: one may still be up until a turn is heard to begin or end.
    func promptsUnheard() {
        askingInTerminal = true
    }

    /// Known to be at its prompt, with the stream that would report its next turn still up.
    var idle: Bool { streamAvailable && betweenTurns }

    /// The agent may be showing a prompt in the terminal, an approval or a question, which keys
    /// typed there would answer: one its hook asked about, one handed to the terminal this turn,
    /// or any at all while the stream that would report one is down.
    var mayBeAsking: Bool { !streamAvailable || !asking.isEmpty || askingInTerminal }

    /// The agent started, or its conversation changed (Claude's SessionStart): it is at its prompt,
    /// and a turn of the old conversation can no longer finish, so its busy state goes with it.
    /// A compaction is the exception: it lands mid-turn and the turn carries on.
    func adopt(sessionID id: String, midTurn: Bool) {
        if !midTurn { busy = false; betweenTurns = true; closePrompts() }
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
        // A turn begins only from the prompt, and one that ends leaves nothing asked.
        closePrompts()
        return true
    }

    /// An approval request for this PTY, and how it ended: `answered` (the agent takes the answer
    /// and closes its prompt), `cancelled` (the agent moved on), or `terminal` (its prompt waits
    /// there for a person).
    @discardableResult func receivePermission(_ event: ServerEvent) -> Bool {
        guard let terminalID, event.runId == terminalID, let id = event.id else { return false }
        switch event.type {
        case "agent-permission": asking.insert(id)
        case "agent-permission-done":
            asking.remove(id)
            if event.outcome == "terminal" { askingInTerminal = true }
        default: return false
        }
        return true
    }

    private func closePrompts() {
        if !asking.isEmpty { asking = [] }
        if askingInTerminal { askingInTerminal = false }
    }

    func invalidate() {
        revision &+= 1
    }
}
