import Foundation

@MainActor protocol DocumentFeatureFactory {
    func fileOpen() -> FileOpenViewModel
    func fileOpenCoordinator() -> FileOpenCoordinator
    func diffCoordinator() -> DiffCoordinator
    func editorClose(documents: [EditorDocumentViewModel]) -> EditorCloseViewModel
    func editor(record: FileDocumentRecord) -> EditorDocumentViewModel
    func editorService(api: APIClient) -> any FileDocumentService
    func fileSearch() -> FileSearchViewModel
    func fileSearchService(api: APIClient) -> any FileSearchService
    func editorSurface(baseURL: URL) -> any EditorSurface
    func changes(worktree: String, service: any GitChangesService, didChange: @escaping () -> Void) -> GitChangesActions
    func diff(worktree: String, baseURL: URL, service: any DiffService, actionsService: any GitChangesService,
              openFile: @escaping (DocumentLocation) -> Void) -> DiffViewModel
    func history(worktree: String, baseURL: URL, base: String, service: any GitHistoryService,
                 copy: @escaping (String) -> Void) -> GitHistoryViewModel
    func patch(worktree: String, baseURL: URL, diff: String) -> DiffViewModel
}

@MainActor struct NativeDocumentFeatureFactory: DocumentFeatureFactory {}

// Shared assembly keeps nested creation on the injected factory as well: history
// patches and git actions must not silently fall back to a new native factory.
extension DocumentFeatureFactory {
    func fileOpen() -> FileOpenViewModel { FileOpenViewModel() }
    func fileOpenCoordinator() -> FileOpenCoordinator { FileOpenCoordinator() }
    func diffCoordinator() -> DiffCoordinator { DiffCoordinator() }
    func editorClose(documents: [EditorDocumentViewModel]) -> EditorCloseViewModel { EditorCloseViewModel(documents: documents) }
    func editor(record: FileDocumentRecord) -> EditorDocumentViewModel { EditorDocumentViewModel(record: record) }
    func editorService(api: APIClient) -> any FileDocumentService { APIFileDocumentService(api: api) }
    func fileSearch() -> FileSearchViewModel { FileSearchViewModel() }
    func fileSearchService(api: APIClient) -> any FileSearchService { APIFileSearchService(api: api) }
    func editorSurface(baseURL: URL) -> any EditorSurface { CodeEditEditorSurface() }
    func changes(worktree: String, service: any GitChangesService, didChange: @escaping () -> Void) -> GitChangesActions {
        GitChangesActions(worktree: worktree, service: service, didChange: didChange)
    }
    func diff(worktree: String, baseURL: URL, service: any DiffService, actionsService: any GitChangesService,
              openFile: @escaping (DocumentLocation) -> Void) -> DiffViewModel {
        DiffViewModel(worktree: worktree, baseURL: baseURL, service: service, actionsService: actionsService,
                      factory: self, openFile: openFile)
    }
    func history(worktree: String, baseURL: URL, base: String, service: any GitHistoryService,
                 copy: @escaping (String) -> Void) -> GitHistoryViewModel {
        GitHistoryViewModel(worktree: worktree, baseURL: baseURL, base: base, service: service, factory: self, copy: copy)
    }
    func patch(worktree: String, baseURL: URL, diff: String) -> DiffViewModel {
        DiffViewModel(worktree: worktree, baseURL: baseURL,
                      service: HistoricalPatchService(diff: diff), allowsFileOpening: false, factory: self)
    }
}
