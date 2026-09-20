import Foundation
import Observation

@MainActor @Observable final class EditorCloseViewModel {
    enum Choice { case save, discard, cancel }
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let error: String?
    }
    enum Action { case choose(Request) }
    enum Phase { case idle, freezing, choosing, saving, releasing, approved, cancelled }
    private(set) var phase = Phase.idle
    private(set) var request: Request?
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored private let documents: [EditorDocumentViewModel]
    @ObservationIgnored private var locked: [EditorDocumentViewModel] = []
    @ObservationIgnored private var response: CheckedContinuation<Choice, Never>?

    init(documents: [EditorDocumentViewModel]) {
        var seen: Set<ObjectIdentifier> = []
        self.documents = documents.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func prepare() async -> Bool {
        guard phase == .idle else { return false }
        phase = .freezing
        do {
            var unsaved: [EditorDocumentViewModel] = []
            for document in documents {
                try Task.checkCancellation()
                if try await document.beginClose() { unsaved.append(document) }
                locked.append(document)
            }
            for document in unsaved {
                var approved = false
                while !approved {
                    try Task.checkCancellation()
                    let choice = await choose(document)
                    try Task.checkCancellation()
                    switch choice {
                    case .save:
                        phase = .saving
                        approved = await document.save() && !document.dirty
                    case .discard: approved = true
                    case .cancel: throw CancellationError()
                    }
                }
            }
            try Task.checkCancellation()
            phase = .approved
            return true
        } catch {
            await rollback()
            return false
        }
    }

    private func choose(_ document: EditorDocumentViewModel) async -> Choice {
        let request = Request(title: document.title, error: document.error)
        self.request = request; phase = .choosing
        return await withCheckedContinuation { response in
            self.response = response
            onAction(.choose(request))
        }
    }

    func respond(to id: UUID, choice: Choice) {
        guard phase == .choosing, request?.id == id, let response else { return }
        self.response = nil; request = nil
        response.resume(returning: choice)
    }

    func rollback() async {
        phase = .releasing
        // Cleanup must finish even when the caller cancelled its close task.
        // A cancellation-aware editor bridge still needs to unfreeze the buffer.
        let documents = locked
        await Task { @MainActor in
            for document in documents { await document.cancelClose() }
        }.value
        locked = []; phase = .cancelled
    }
}
