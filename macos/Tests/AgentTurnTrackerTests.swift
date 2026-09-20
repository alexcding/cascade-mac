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
    let ticket = try tracker.arm(cli: .claude, sessionID: "conversation")
    #expect(!tracker.receive(hook("agent-turn-start", terminal: "other")))
    #expect(!tracker.receive(hook("agent-turn-start", cli: "codex")))
    #expect(!tracker.receive(hook("agent-turn-start", session: nil)))
    #expect(!tracker.busy)
    tracker.receive(hook("agent-turn-done")) // Old/startup Stop cannot complete an armed step.
    tracker.receive(hook("agent-turn-start"))
    #expect(tracker.busy)
    let revision = tracker.revision
    tracker.receive(hook("agent-turn-done")) // Completes before a waiter is registered.
    tracker.receive(hook("agent-turn-done")) // Duplicate Stop is harmless.
    #expect(try await tracker.wait(for: ticket) == revision)
    #expect(!tracker.busy)
    let next = try tracker.arm(cli: .claude, sessionID: "conversation")
    tracker.cancel(next)
}

@MainActor @Test func agentTurnsLearnCodexConversationAndRejectSessionReplacement() async throws {
    let tracker = connectedTurns()
    let ticket = try tracker.arm(cli: .codex, sessionID: nil)
    tracker.receive(hook("agent-turn-start", cli: "codex", session: "minted-by-codex"))
    #expect(tracker.busy && tracker.sessionID == "minted-by-codex")
    #expect(!tracker.receive(hook("agent-turn-done", cli: "codex", session: "different")))
    do { _ = try await tracker.wait(for: ticket); Issue.record("Changed conversations must fail the step") }
    catch { #expect(error.localizedDescription.contains("conversation changed")) }
    #expect(tracker.busy) // Unrelated Stop must not clear the original turn.
    tracker.receive(hook("agent-turn-done", cli: "codex", session: "minted-by-codex"))
    #expect(!tracker.busy)
}

@MainActor @Test func agentTurnsCancellationReleasesWaiterAndCannotCancelNextStep() async throws {
    let tracker = connectedTurns()
    let first = try tracker.arm(cli: .claude, sessionID: "conversation")
    let waiting = Task { try await tracker.wait(for: first) }
    await Task.yield()
    waiting.cancel()
    do { _ = try await waiting.value; Issue.record("Cancelled waiter must terminate") }
    catch { #expect(error is CancellationError) }
    // Drain the cancellation callback even when it ran before waiter registration.
    tracker.cancel(first)
    let next = try tracker.arm(cli: .claude, sessionID: "conversation")
    tracker.cancel(first)
    tracker.receive(hook("agent-turn-start")); tracker.receive(hook("agent-turn-done"))
    _ = try await tracker.wait(for: next)
}

@MainActor @Test func agentTurnsConnectionLossRejectsPendingAndBufferedCompletion() async throws {
    let tracker = connectedTurns()
    let first = try tracker.arm(cli: .claude, sessionID: "conversation")
    let waiting = Task { try await tracker.wait(for: first) }
    await Task.yield()
    tracker.setStreamAvailable(false)
    do { _ = try await waiting.value; Issue.record("Lost SSE cannot complete a workflow") }
    catch { #expect(error.localizedDescription.contains("event connection was lost")) }
    #expect(throws: (any Error).self) { try tracker.arm(cli: .claude, sessionID: nil) }
    #expect(!tracker.receive(hook("agent-turn-start")))
    tracker.setStreamAvailable(true)
    let second = try tracker.arm(cli: .claude, sessionID: "conversation")
    tracker.receive(hook("agent-turn-start")); tracker.receive(hook("agent-turn-done"))
    tracker.invalidate("PTY disconnected")
    do { _ = try await tracker.wait(for: second); Issue.record("Buffered completion must not survive a PTY disconnect") }
    catch { #expect(error.localizedDescription == "PTY disconnected") }
}

@MainActor @Test func agentTurnsRejectOverlappingTurnsAndWrongIdleStop() async throws {
    let tracker = connectedTurns()
    tracker.receive(hook("agent-turn-start"))
    #expect(throws: (any Error).self) { try tracker.arm(cli: .claude, sessionID: nil) }
    #expect(!tracker.receive(hook("agent-turn-done", cli: "codex")))
    #expect(tracker.busy)
    tracker.receive(hook("agent-turn-done"))
    #expect(!tracker.receive(hook("agent-turn-done", session: "old-conversation")))
    #expect(tracker.sessionID == "conversation")
    let ticket = try tracker.arm(cli: .claude, sessionID: "conversation")
    tracker.receive(hook("agent-turn-start")); tracker.receive(hook("agent-turn-start"))
    tracker.receive(hook("agent-turn-done"))
    do { _ = try await tracker.wait(for: ticket); Issue.record("Overlapping turns must fail") }
    catch { #expect(error.localizedDescription.contains("Another agent turn")) }
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
    let ticket = try tracker.arm(cli: .claude, sessionID: "cleared")
    tracker.adopt(sessionID: "ignored", midTurn: false) // A step owns the conversation.
    #expect(tracker.hasPendingStep && tracker.sessionID == "cleared")
    tracker.cancel(ticket)
}
