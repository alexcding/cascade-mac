import AppKit
import Observation

@MainActor enum WorkspaceTab: Identifiable {
    case page(BrowserPage), file(EditorDocumentViewModel)
    nonisolated var id: String { switch self { case .page(let page): page.id; case .file(let file): file.id } }
    @MainActor var title: String { switch self { case .page(let page): page.title.isEmpty ? page.url : page.title; case .file(let file): file.title } }
    @MainActor var dirty: Bool { if case .file(let file) = self { file.dirty } else { false } }
}

enum WorkspaceVisit: Identifiable {
    case page(WebPageRecord), file(FileDocumentRecord)
    var id: String { switch self { case .page(let page): page.id; case .file(let file): file.id } }
    var title: String { switch self { case .page(let page): page.title.isEmpty ? page.url : page.title; case .file(let file): file.path } }
}

@MainActor protocol EditorClosePresenting {
    func choose(_ request: EditorCloseViewModel.Request) async -> EditorCloseViewModel.Choice
}

@MainActor struct NativeEditorClosePresenter: EditorClosePresenting {
    func choose(_ request: EditorCloseViewModel.Request) async -> EditorCloseViewModel.Choice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(request.title)” before closing?"
        alert.informativeText = request.error.map { "\($0)\n\nYour changes have not been discarded." } ?? "Your changes will be lost if you discard them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow { response = await alert.beginSheetModal(for: window) }
        else { response = alert.runModal() }
        switch response { case .alertFirstButtonReturn: return .save; case .alertSecondButtonReturn: return .discard; default: return .cancel }
    }
}

/// One owner serializes tab, worktree and Quit confirmations. The model freezes
/// and saves buffers; this coordinator presents choices and commits navigation.
@MainActor @Observable final class EditorCloseCoordinator {
    private(set) var model: EditorCloseViewModel?
    var isPresenting: Bool { model != nil }
    @ObservationIgnored var presentationEnded: () -> Void = {}
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored private let factory: any DocumentFeatureFactory
    @ObservationIgnored private let presenter: any EditorClosePresenting

    init(factory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         presenter: any EditorClosePresenting = NativeEditorClosePresenter()) {
        self.factory = factory; self.presenter = presenter
    }

    func requestClose(_ documents: [EditorDocumentViewModel], isOwned: @escaping () -> Bool,
                      commit: @escaping () -> Void) {
        guard let model = begin(documents, isOwned: isOwned) else { return }
        Task { await finish(model, isOwned: isOwned, commit: commit) }
    }

    @discardableResult func close(_ documents: [EditorDocumentViewModel], isOwned: () -> Bool = { true },
                                  commit: () -> Void) async -> Bool {
        guard let model = begin(documents, isOwned: isOwned) else { return false }
        return await finish(model, isOwned: isOwned, commit: commit)
    }

    private func begin(_ documents: [EditorDocumentViewModel], isOwned: () -> Bool) -> EditorCloseViewModel? {
        guard !isPresenting, canPresent(), !Task.isCancelled, isOwned() else { return nil }
        let model = factory.editorClose(documents: documents)
        self.model = model
        model.onAction = { [weak self, weak model] action in
            guard let self, let model, self.model === model else { return }
            switch action {
            case .choose(let request):
                Task { [presenter, weak self, weak model] in
                    let choice = await presenter.choose(request)
                    guard let self, let model, self.model === model else { return }
                    model.respond(to: request.id, choice: choice)
                }
            }
        }
        return model
    }

    private func finish(_ model: EditorCloseViewModel, isOwned: () -> Bool, commit: () -> Void) async -> Bool {
        defer { model.onAction = { _ in }; self.model = nil; presentationEnded() }
        guard await model.prepare() else { return false }
        guard !Task.isCancelled, isOwned() else { await model.rollback(); return false }
        // No suspension between approval and removing all approved documents.
        commit()
        return true
    }
}
