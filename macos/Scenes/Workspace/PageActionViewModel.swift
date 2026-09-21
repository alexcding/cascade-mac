import Foundation
import Observation

/// Per-surface navigation lifetime. Cancelling a page open does not undo an already
/// persisted tab or affect independent ticket mutations.
@MainActor @Observable final class PageActionViewModel {
    private(set) var opening: String?
    private(set) var error: String?
    @ObservationIgnored private let service: any PageActionServing
    @ObservationIgnored private let failureDescription: String
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var feedbackGeneration = UUID()
    @ObservationIgnored private var openingInSession = false
    @ObservationIgnored private var task: Task<Void, Never>? { didSet { oldValue?.cancel() } }

    init(service: any PageActionServing, failureDescription: String = "Could not open ticket") {
        self.service = service; self.failureDescription = failureDescription
    }

    func open(_ request: OpenPageRequest) {
        // The same row asked the other way — tab, then session — is a new request, not a repeat.
        guard opening != request.url || openingInSession != request.inSession else { return }
        let generation = UUID(), feedback = UUID()
        self.generation = generation; feedbackGeneration = feedback
        opening = request.url; openingInSession = request.inSession; error = nil
        let service = service
        let failureDescription = failureDescription
        task = Task { [weak self] in
            defer { if self?.generation == generation { self?.opening = nil; self?.task = nil } }
            do {
                try Task.checkCancellation()
                try await service.openPage(request)
            } catch {
                if !Task.isCancelled && self?.generation == generation && self?.feedbackGeneration == feedback {
                    self?.error = request.failure(failureDescription, error)
                }
            }
        }
    }
    func cancel() { generation = UUID(); task = nil; opening = nil }
    func reject(_ message: String) { cancel(); feedbackGeneration = UUID(); error = message }
    func waitForOpen() async { await task?.value }
}
