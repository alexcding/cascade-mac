import Foundation
import Observation

@MainActor @Observable final class FileOpenViewModel {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let contextID: String
        /// Where the panel starts; nil leaves it wherever macOS last had it.
        var directory: String? = nil
    }
    enum Action { case present(Request), cancel(UUID), open(Request, URL) }
    private(set) var request: Request?
    @ObservationIgnored var onAction: ((Action) -> Void)?

    func begin(contextID: String, directory: String? = nil) {
        guard request == nil, let onAction else { return }
        let request = Request(contextID: contextID, directory: directory)
        self.request = request
        onAction(.present(request))
    }

    func respond(to id: UUID, url: URL?) {
        guard let request, request.id == id else { return }
        self.request = nil
        if let url, url.isFileURL { onAction?(.open(request, url)) }
    }

    func cancel() {
        guard let request else { return }
        self.request = nil
        onAction?(.cancel(request.id))
    }
}
