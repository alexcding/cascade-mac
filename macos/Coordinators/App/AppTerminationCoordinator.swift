import Foundation
import Observation

/// Serializes asynchronous document/terminal cleanup at AppKit's termination
/// boundary. Window close, Command-Q, Dock/app-menu Quit, and updater restart
/// all enter the same transaction.
@MainActor @Observable public final class AppTerminationCoordinator {
    public enum Reason: Sendable { case quit, update }
    public enum Decision: Equatable { case later, now }
    public private(set) var pending: Reason?
    public private(set) var approved = false
    private let prepare: (Reason) async throws -> Void
    private let finished: (Reason, Bool) -> Void
    private let failed: (Error) -> Void

    public init(prepare: @escaping (Reason) async throws -> Void,
                finished: @escaping (Reason, Bool) -> Void,
                failed: @escaping (Error) -> Void) {
        self.prepare = prepare; self.finished = finished; self.failed = failed
    }

    public func systemTermination(updateRequested: Bool) -> Decision {
        if approved { return .now }
        guard pending == nil else { return .later }
        begin(updateRequested ? .update : .quit)
        return .later
    }

    private func begin(_ reason: Reason) {
        pending = reason
        Task {
            do {
                try await prepare(reason)
                approved = true
                pending = nil
                finished(reason, true)
            } catch {
                pending = nil
                finished(reason, false)
                failed(error)
            }
        }
    }
}
