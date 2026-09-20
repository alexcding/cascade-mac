import Foundation
import Observation

// Hook state belongs to one PTY, independently of whether its surface is visible.
// Arm before writing a workflow command: a fast Stop may arrive before wait().
@MainActor @Observable final class AgentTurnTracker {
    struct Ticket: Equatable, Sendable { fileprivate let id = UUID() }
    private(set) var busy = false
    private(set) var revision: UInt64 = 0
    private(set) var streamAvailable = false
    private(set) var cli: WorkflowCLI?
    private(set) var sessionID: String?
    @ObservationIgnored private var terminalID: String?
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        let ticket: Ticket
        let cli: WorkflowCLI
        var sessionID: String?
        var started = false
        var result: Result<UInt64, Error>?
        var continuation: CheckedContinuation<UInt64, Error>?
    }

    func bind(terminalID: String) {
        guard self.terminalID != terminalID else { return }
        invalidate("The terminal identity changed during the workflow step.")
        self.terminalID = terminalID; cli = nil; sessionID = nil; busy = false
    }

    func setStreamAvailable(_ value: Bool) {
        guard streamAvailable != value else { return }
        streamAvailable = value
        if !value { invalidate("The agent event connection was lost. Check the terminal before restarting the workflow.") }
    }

    /// A workflow step owns the conversation until it settles; nothing else may re-point the
    /// session while it does, or the step's own check for a changed conversation is defeated.
    var hasPendingStep: Bool { pending != nil }

    /// The agent said its conversation changed. A turn of the old one can no longer finish, so
    /// its busy state goes with it, unless this is a compaction, which lands mid-turn and carries on.
    func adopt(sessionID id: String, midTurn: Bool) {
        guard pending == nil, sessionID != id else { return }
        sessionID = id; revision &+= 1
        if !midTurn { busy = false }
    }

    func arm(cli: WorkflowCLI, sessionID: String?) throws -> Ticket {
        guard streamAvailable, terminalID != nil else {
            throw BackendError.operation("Connect the terminal and agent event stream before running a workflow.")
        }
        guard pending == nil, !busy else { throw BackendError.operation("The agent already has an active turn or workflow step.") }
        let ticket = Ticket()
        pending = Pending(ticket: ticket, cli: cli, sessionID: sessionID.flatMap { $0.isEmpty ? nil : $0 })
        return ticket
    }

    // Returns true only for a recognized hook addressed to this PTY. The caller
    // still checks its durable session's CLI before persisting conversation IDs.
    @discardableResult func receive(_ event: ServerEvent) -> Bool {
        guard streamAvailable, let terminalID, event.runId == terminalID,
              let raw = event.cli, let incomingCLI = WorkflowCLI(rawValue: raw),
              ["agent-turn-start", "agent-turn-done"].contains(event.type) else { return false }
        if let pending, pending.cli != incomingCLI { return false }
        let incomingID = event.sessionId.flatMap { $0.isEmpty ? nil : $0 }
        if pending?.sessionID != nil && incomingID == nil { return false }
        if let expected = pending?.sessionID, let incomingID, expected != incomingID {
            invalidate("The agent conversation changed during the workflow step. Check the terminal before continuing.")
            return false
        }
        // A Stop for an older/different CLI conversation must not clear a newer
        // turn's busy state when no workflow currently owns it.
        if event.type == "agent-turn-done",
           ((cli != nil && cli != incomingCLI) || (sessionID != nil && incomingID != nil && sessionID != incomingID)) { return false }
        cli = incomingCLI
        if let incomingID { sessionID = incomingID }
        if event.type == "agent-turn-start" {
            revision &+= 1; busy = true
            if pending?.started == true {
                invalidate("Another agent turn started before the workflow step finished.")
            } else if pending != nil {
                pending?.started = true
                if let incomingID { pending?.sessionID = incomingID }
            }
        } else {
            busy = false
            // A startup/old Stop hook is not evidence that our submitted step ran.
            if pending?.started == true { finish(.success(revision)) }
        }
        return true
    }

    func wait(for ticket: Ticket) async throws -> UInt64 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard var current = pending, current.ticket == ticket else {
                    continuation.resume(throwing: BackendError.operation("This workflow step is no longer active.")); return
                }
                if let result = current.result {
                    pending = nil; continuation.resume(with: result)
                } else if current.continuation != nil {
                    continuation.resume(throwing: BackendError.operation("This workflow step already has a completion waiter."))
                } else {
                    current.continuation = continuation; pending = current
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(ticket) }
        }
    }

    func cancel(_ ticket: Ticket) {
        guard pending?.ticket == ticket else { return }
        let continuation = pending?.continuation
        pending = nil; continuation?.resume(throwing: CancellationError())
        // Cancellation stops waiting. Only a hook or confirmed interrupt clears busy.
    }

    func interrupted() {
        invalidate("The workflow was interrupted.")
        busy = false
    }

    func invalidate(_ message: String) {
        revision &+= 1
        guard let current = pending else { return }
        if case .failure = current.result { return }
        let failure = BackendError.operation(message)
        if let continuation = current.continuation {
            pending = nil; continuation.resume(throwing: failure)
        } else { pending?.result = .failure(failure) }
    }

    private func finish(_ result: Result<UInt64, Error>) {
        guard let current = pending, current.result == nil else { return }
        if let continuation = current.continuation {
            pending = nil; continuation.resume(with: result)
        } else { pending?.result = result }
    }
}
