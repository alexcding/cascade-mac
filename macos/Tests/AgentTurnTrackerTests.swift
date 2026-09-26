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
