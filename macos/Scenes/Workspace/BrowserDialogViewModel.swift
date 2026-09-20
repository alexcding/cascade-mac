import Foundation
import Observation

@MainActor @Observable final class BrowserDialogViewModel {
    enum Kind: Equatable {
        case alert(String), confirm(String), prompt(String, defaultText: String)
        case files(multiple: Bool, directories: Bool)
    }
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let origin: String
        let kind: Kind
    }
    enum Response: Equatable {
        case cancel, acknowledge, confirm(Bool), text(String), files([URL])
    }
    enum Action { case present(UUID), cancel(UUID) }
    var active = false {
        didSet { if oldValue != active && !active { cancel() } }
    }
    private(set) var request: Request?
    @ObservationIgnored var onAction: ((Action) -> Void)?
    @ObservationIgnored private var completion: ((Response) -> Void)?

    func begin(_ kind: Kind, origin: String, completion: @escaping (Response) -> Void) {
        guard active, request == nil, let onAction else { completion(.cancel); return }
        let request = Request(origin: origin, kind: kind)
        self.request = request
        self.completion = completion
        onAction(.present(request.id))
    }

    func respond(_ response: Response, to id: UUID) {
        guard request?.id == id else { return }
        let completion = completion
        request = nil; self.completion = nil
        completion?(response)
    }

    func cancel() {
        guard let id = request?.id else { return }
        let completion = completion
        request = nil; self.completion = nil
        onAction?(.cancel(id))
        completion?(.cancel)
    }
}
