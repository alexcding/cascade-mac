import AppKit
import Observation

@MainActor protocol FileOpenPresenting {
    func present(in window: NSWindow?, directory: URL?, completion: @escaping (URL?) -> Void) -> () -> Void
}

@MainActor struct NativeFileOpenPresenter: FileOpenPresenting {
    func present(in window: NSWindow?, directory: URL?, completion: @escaping (URL?) -> Void) -> () -> Void {
        guard let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else {
            completion(nil); return {}
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
        return { [weak window, weak panel] in
            guard let panel, panel.sheetParent === window else { return }
            window?.endSheet(panel, returnCode: .cancel)
            panel.orderOut(nil)
        }
    }
}

@MainActor @Observable final class FileOpenCoordinator {
    var enabled = true { didSet { if oldValue != enabled && !enabled { cancel() } } }
    private(set) var requestID: UUID?
    var isPresenting: Bool { requestID != nil }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored var presentationEnded: () -> Void = {}
    @ObservationIgnored private weak var model: FileOpenViewModel?
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var cancelPresentation: (() -> Void)?
    @ObservationIgnored private let presenter: any FileOpenPresenting

    init(presenter: any FileOpenPresenting = NativeFileOpenPresenter()) { self.presenter = presenter }

    func bind(_ model: FileOpenViewModel, activeContext: @escaping () -> WorkspaceContext?,
              window: @escaping () -> NSWindow? = { NSApp?.keyWindow }) {
        cancel()
        model.cancel()
        self.model = model
        let binding = UUID(); bindingID = binding
        model.onAction = { [weak self, weak model] action in
            guard let model else { return }
            guard let self, self.model === model, bindingID == binding else { model.cancel(); return }
            switch action {
            case .present(let request):
                guard enabled, !isPresenting, canPresent(), let context = activeContext(),
                      context.id == request.contextID else { model.respond(to: request.id, url: nil); return }
                requestID = request.id
                let cancel = presenter.present(in: window(), directory: request.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }) { [weak self, weak model, weak context] url in
                    guard let self, let model, self.model === model, bindingID == binding,
                          requestID == request.id else { return }
                    requestID = nil; cancelPresentation = nil
                    let owned = context != nil && activeContext() === context && context?.id == request.contextID
                    model.respond(to: request.id, url: enabled && owned ? url : nil)
                    presentationEnded()
                }
                if requestID == request.id { cancelPresentation = cancel } else { cancel() }
            case .cancel(let id):
                if requestID == id { dismiss() }
            case .open(let request, let url):
                guard enabled, let context = activeContext(), context.id == request.contextID else { return }
                context.openFile(url.path)
            }
        }
    }

    func cancel() {
        model?.cancel()
        dismiss()
    }

    private func dismiss() {
        guard isPresenting else { return }
        let cancel = cancelPresentation
        requestID = nil; cancelPresentation = nil
        cancel?()
        presentationEnded()
    }
}
