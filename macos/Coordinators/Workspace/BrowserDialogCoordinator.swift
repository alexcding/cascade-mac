import AppKit
import Observation

@MainActor protocol BrowserDialogPresenting {
    /// Starts presentation and returns a cancellation action. Completion may be
    /// synchronous and must also be called if a native sheet is cancelled.
    func present(_ request: BrowserDialogViewModel.Request, in window: NSWindow?,
                 completion: @escaping (BrowserDialogViewModel.Response) -> Void) -> () -> Void
}

@MainActor struct NativeBrowserDialogPresenter: BrowserDialogPresenting {
    func present(_ request: BrowserDialogViewModel.Request, in window: NSWindow?,
                 completion: @escaping (BrowserDialogViewModel.Response) -> Void) -> () -> Void {
        guard let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else {
            completion(.cancel); return {}
        }
        if case .files(let multiple, let directories) = request.kind {
            let panel = NSOpenPanel()
            panel.title = "Choose files for \(request.origin)"
            panel.canChooseFiles = true
            panel.canChooseDirectories = directories
            panel.allowsMultipleSelection = multiple
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? .files(panel.urls) : .cancel)
            }
            return { [weak window, weak panel] in
                guard let panel, panel.sheetParent === window else { return }
                window?.endSheet(panel, returnCode: .cancel)
                panel.orderOut(nil)
            }
        }
        let alert = NSAlert()
        alert.window.setAccessibilityIdentifier("browser-dialog")
        alert.messageText = request.origin + " says"
        let field: NSTextField?
        switch request.kind {
        case .alert(let message), .confirm(let message):
            alert.informativeText = message; field = nil
        case .prompt(let message, let defaultText):
            alert.informativeText = message
            let input = NSTextField(string: defaultText)
            input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            input.setAccessibilityIdentifier("browser-dialog-input")
            input.setAccessibilityLabel("Response")
            alert.accessoryView = input; field = input
        case .files: return {}
        }
        alert.addButton(withTitle: "OK")
        if case .alert = request.kind {} else { alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}" }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(.cancel); return }
            switch request.kind {
            case .alert: completion(.acknowledge)
            case .confirm: completion(.confirm(true))
            case .prompt: completion(.text(field?.stringValue ?? ""))
            case .files: completion(.cancel)
            }
        }
        if let field { alert.window.makeFirstResponder(field) }
        return { [weak window, weak sheet = alert.window] in
            guard let sheet, sheet.sheetParent === window else { return }
            window?.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
    }
}

/// One coordinator reserves browser presentation across all retained pages.
/// The page's model owns request/completion lifetime; the adapter only renders it.
@MainActor @Observable final class BrowserDialogCoordinator {
    var enabled = true { didSet { if oldValue != enabled && !enabled { cancel() } } }
    private(set) var requestID: UUID?
    var isPresenting: Bool { requestID != nil }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored var presentationEnded: () -> Void = {}
    @ObservationIgnored private weak var owner: BrowserDialogViewModel?
    @ObservationIgnored private var cancelPresentation: (() -> Void)?
    @ObservationIgnored private let presenter: any BrowserDialogPresenting

    init(presenter: any BrowserDialogPresenting = NativeBrowserDialogPresenter()) { self.presenter = presenter }

    func bind(_ model: BrowserDialogViewModel, isOwned: @escaping () -> Bool,
              window: @escaping () -> NSWindow?) {
        model.cancel()
        model.onAction = { [weak self, weak model] action in
            guard let model else { return }
            guard let self else { model.cancel(); return }
            switch action {
            case .cancel(let id):
                if owner === model && requestID == id { dismiss() }
            case .present(let id):
                guard enabled, model.active, isOwned(), !isPresenting, canPresent(), let request = model.request,
                      request.id == id else { model.respond(.cancel, to: id); return }
                owner = model; requestID = id
                let cancel = presenter.present(request, in: window()) { [weak self, weak model] response in
                    guard let self, let model, owner === model, requestID == id else { return }
                    // Clear ownership before completing WebKit: its callback may
                    // synchronously navigate, close a page or request another dialog.
                    owner = nil; requestID = nil; cancelPresentation = nil
                    model.respond(model.active && isOwned() ? response : .cancel, to: id)
                    presentationEnded()
                }
                if owner === model && requestID == id { cancelPresentation = cancel }
                else { cancel() }
            }
        }
    }

    func cancel() {
        let model = owner
        dismiss()
        model?.cancel()
    }

    private func dismiss() {
        guard isPresenting else { return }
        let cancel = cancelPresentation
        owner = nil; requestID = nil; cancelPresentation = nil
        cancel?()
        presentationEnded()
    }
}
