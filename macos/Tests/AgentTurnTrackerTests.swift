import Foundation
import Testing

private func hook(_ type: String, terminal: String = "pty", cli: String = "claude", session: String? = "conversation") -> ServerEvent {
    ServerEvent(type: type, projectId: nil, id: nil, runId: terminal, cli: cli, sessionId: session)
}

@MainActor private func connectedTurns() -> AgentTurnTracker {
    let tracker = AgentTurnTracker()
    tracker.bind(terminalID: "pty"); tracker.setStreamAvailable(true)
    return tracker
}

@MainActor @Test func agentTurnsCaptureFastStartStopAndIgnoreUnrelatedHooks() async throws {
    let tracker = connectedTurns()
    #expect(!tracker.receive(hook("agent-turn-start", terminal: "other")))
    #expect(!tracker.busy)
    tracker.receive(hook("agent-turn-start"))
    #expect(tracker.busy)
    tracker.receive(hook("agent-turn-done"))
    tracker.receive(hook("agent-turn-done")) // Duplicate Stop is harmless.
    #expect(!tracker.busy)
}

@MainActor @Test func agentTurnsLearnCodexConversationAndRejectSessionReplacement() async throws {
    let tracker = connectedTurns()
    tracker.receive(hook("agent-turn-start", cli: "codex", session: "minted-by-codex"))
    #expect(tracker.busy && tracker.sessionID == "minted-by-codex")
    #expect(!tracker.receive(hook("agent-turn-done", cli: "codex", session: "different")))
    #expect(tracker.busy) // Unrelated Stop must not clear the original turn.
    tracker.receive(hook("agent-turn-done", cli: "codex", session: "minted-by-codex"))
    #expect(!tracker.busy)
}

@MainActor @Test func agentTurnsConnectionLossClearsBetweenTurns() async throws {
    let tracker = connectedTurns()
    tracker.receive(hook("agent-turn-start")); tracker.receive(hook("agent-turn-done"))
    #expect(tracker.betweenTurns)
    tracker.setStreamAvailable(false)
    #expect(!tracker.betweenTurns && !tracker.streamAvailable)
    #expect(!tracker.receive(hook("agent-turn-start")))
    tracker.setStreamAvailable(true)
    tracker.receive(hook("agent-turn-start")); tracker.receive(hook("agent-turn-done"))
    #expect(tracker.betweenTurns)
}

@MainActor @Test func agentTurnsRejectOverlappingTurnsAndWrongIdleStop() async throws {
    let tracker = connectedTurns()
    tracker.receive(hook("agent-turn-start"))
    #expect(!tracker.receive(hook("agent-turn-done", cli: "codex")))
    #expect(tracker.busy)
    tracker.receive(hook("agent-turn-done"))
    #expect(!tracker.receive(hook("agent-turn-done", session: "old-conversation")))
    #expect(tracker.sessionID == "conversation")
}

@MainActor @Test func agentTurnsFollowAnAnnouncedConversationAndKeepACompactingTurnBusy() throws {
    let tracker = connectedTurns()
    #expect(tracker.receive(hook("agent-turn-start")))
    tracker.adopt(sessionID: "compacted", midTurn: true)
    #expect(tracker.busy && tracker.sessionID == "compacted")
    #expect(tracker.receive(hook("agent-turn-done", session: "compacted")) && !tracker.busy)
    #expect(tracker.receive(hook("agent-turn-start", session: "compacted"))) // Its Stop is lost.
    tracker.adopt(sessionID: "cleared", midTurn: false)
    #expect(!tracker.busy && tracker.sessionID == "cleared")
}

@MainActor @Test func agentTurnsCallAnAgentIdleOnlyOnceItsHooksSayItIsAtItsPrompt() throws {
    let tracker = connectedTurns()
    #expect(!tracker.idle) // Silence proves nothing: its hooks may not be installed.
    tracker.adopt(sessionID: "conversation", midTurn: false) // SessionStart: up at its prompt.
    #expect(tracker.idle)
    tracker.receive(hook("agent-turn-start"))
    #expect(!tracker.idle)
    tracker.adopt(sessionID: "conversation", midTurn: true) // A compaction carries the turn on.
    #expect(tracker.busy && !tracker.idle)
    tracker.receive(hook("agent-turn-done"))
    #expect(tracker.idle)
    tracker.setStreamAvailable(false); tracker.setStreamAvailable(true)
    #expect(!tracker.idle) // A turn may have started unheard.
    tracker.receive(hook("agent-turn-done"))
    #expect(tracker.idle)
    tracker.bind(terminalID: "other")
    #expect(!tracker.idle) // Another shell, not heard from yet.
}

private func permission(_ type: String, _ id: String, outcome: String? = nil, terminal: String = "pty") -> ServerEvent {
    ServerEvent(type: type, projectId: nil, id: id, runId: terminal, outcome: outcome)
}

@MainActor @Test func agentTurnsKnowWhenTheAgentMayBeAskingInTheTerminal() throws {
    let tracker = connectedTurns()
    tracker.receive(hook("agent-turn-start"))
    #expect(!tracker.mayBeAsking)
    #expect(!tracker.receivePermission(permission("agent-permission", "other", terminal: "elsewhere")))
    #expect(tracker.receivePermission(permission("agent-permission", "a")))
    #expect(tracker.mayBeAsking) // Its prompt is drawn as the hook starts.
    tracker.receivePermission(permission("agent-permission-done", "a", outcome: "answered"))
    #expect(!tracker.mayBeAsking)
    tracker.receivePermission(permission("agent-permission", "b"))
    tracker.receivePermission(permission("agent-permission-done", "b", outcome: "terminal"))
    #expect(tracker.mayBeAsking) // Answered there, if at all, unheard.
    tracker.receive(hook("agent-turn-done"))
    #expect(!tracker.mayBeAsking)
    tracker.setStreamAvailable(false)
    #expect(tracker.mayBeAsking) // A request may go by unheard.
    tracker.setStreamAvailable(true)
    #expect(tracker.mayBeAsking) // And may still be up.
    tracker.receive(hook("agent-turn-start"))
    #expect(!tracker.mayBeAsking)
    tracker.promptsUnheard() // A replayed hook, after the app was not running.
    #expect(tracker.mayBeAsking)
    tracker.adopt(sessionID: "conversation", midTurn: false)
    #expect(!tracker.mayBeAsking)
}

/// A finished turn is news until the session is looked at or the next turn begins; a question the
/// agent asked is waiting on a person until it is answered.
@MainActor @Test func agentTurnsReportAFinishedTurnAndAQuestionWaitingOnAPerson() {
    let tracker = connectedTurns()
    tracker.receive(hook("agent-turn-start"))
    #expect(!tracker.finishedUnseen && !tracker.needsInput)
    tracker.receivePermission(permission("agent-permission", "a"))
    #expect(tracker.needsInput)
    tracker.receivePermission(permission("agent-permission-done", "a", outcome: "answered"))
    #expect(!tracker.needsInput)
    tracker.receivePermission(permission("agent-permission", "b"))
    tracker.receivePermission(permission("agent-permission-done", "b", outcome: "terminal"))
    #expect(tracker.needsInput, "handed to the terminal's own prompt while nobody looks, it waits there")
    tracker.acknowledge()
    #expect(!tracker.needsInput && tracker.mayBeAsking, "once looked at, the terminal's prompt is the person's to see")
    tracker.receivePermission(permission("agent-permission", "c"))
    tracker.receivePermission(permission("agent-permission-done", "c", outcome: "terminal"))
    #expect(tracker.needsInput)
    tracker.receive(hook("agent-turn-done"))
    #expect(tracker.finishedUnseen && !tracker.needsInput)
    tracker.acknowledge()
    #expect(!tracker.finishedUnseen)
    tracker.receive(hook("agent-turn-start")); tracker.receive(hook("agent-turn-done"))
    tracker.receive(hook("agent-turn-start"))
    #expect(!tracker.finishedUnseen, "a new turn is not done")
    tracker.promptsUnheard()
    #expect(!tracker.needsInput, "a prompt that may have come unheard is not known to wait")
}
