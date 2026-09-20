import Foundation
import Testing

@MainActor private final class DocumentFactoryFixture: DocumentFeatureFactory {
    var editors: [FileDocumentRecord] = []
    var surfaces: [BufferFixture] = []
    var origins: [URL] = []
    var patches: [String] = []
    var actionWorktrees: [String] = []
    func editor(record: FileDocumentRecord) -> EditorDocumentViewModel {
        editors.append(record)
        return NativeDocumentFeatureFactory().editor(record: record)
    }
    func editorSurface(baseURL: URL) -> any EditorSurface {
        origins.append(baseURL)
        let surface = BufferFixture(); surfaces.append(surface); return surface
    }
    func patch(worktree: String, baseURL: URL, diff: String) -> DiffViewModel {
        patches.append(diff)
        return NativeDocumentFeatureFactory().patch(worktree: worktree, baseURL: baseURL, diff: diff)
    }
    func changes(worktree: String, service: any GitChangesService, didChange: @escaping () -> Void) -> GitChangesActions {
        actionWorktrees.append(worktree)
        return NativeDocumentFeatureFactory().changes(worktree: worktree, service: service, didChange: didChange)
    }
}

private final class DocumentHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if request.url?.path == Routes.SETTINGS && request.httpMethod == "GET" {
            let snapshot = #"{"pages":[],"activeID":"restored","history":[],"pane":"term","documents":[{"id":"restored","path":"/fixture/restored.swift"}],"tabOrder":["restored"]}"#
            body = try! JSONEncoder().encode(["native.context.documents": snapshot])
        } else if request.url?.path == Routes.FILE {
            body = try! JSONEncoder().encode(FileDocumentSnapshot(content: "original", readOnly: false, revision: String(repeating: "a", count: 64)))
        } else { body = Data(#"{"ok":true}"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class DocumentWorkspaceRuntime: WorkspaceServing {
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { .init(connected: true) }
}

@MainActor @Test(.timeLimit(.minutes(1))) func documentFactorySurvivesBackendRestorationReopenAndContextPromotion() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DocumentHTTPFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let base = URL(string: "http://127.0.0.1:9")!, api = try APIClient(baseURL: base, session: session)
    let factory = DocumentFactoryFixture(), runtime = DocumentWorkspaceRuntime()
    let viewer = ViewerStore(documentFactory: factory)
    viewer.prepareContext = { $0.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: runtime) }
    let context = viewer.select(id: "documents", url: "", title: "Documents")
    viewer.connect(api)
    while context.restoring { await Task.yield() }
    let restored = try #require(context.activeDocument)
    await restored.waitForLoad()
    #expect(restored.id == "restored" && restored.loaded)
    #expect(factory.editors.map(\.id) == ["restored"] && factory.origins == [base])
    let existing = context.openFile("/fixture/sub/../restored.swift")
    #expect(existing === restored && factory.editors.count == 1)
    let surface = try #require(factory.surfaces.first)
    surface.edit("unsaved restored buffer")
    try viewer.promoteContext(from: "documents", to: "task:documents")
    #expect(viewer.active === context && context.activeDocument === restored)
    #expect(factory.editors.count == 1 && restored.dirty && restored.surface === surface)
    let second = try #require(context.openFile("/fixture/new.swift"))
    await second.waitForLoad()
    #expect(factory.editors.count == 2 && factory.surfaces.count == 2 && second.loaded)
    context.remove(second)
    let reopened = try #require(context.openFile("/fixture/new.swift"))
    await reopened.waitForLoad()
    #expect(reopened !== second && factory.editors.count == 3 && factory.surfaces.count == 3)
    #expect(factory.origins == [base, base, base])
    #expect(restored.surface === surface && surface.content == "unsaved restored buffer" && !surface.disposed)
    viewer.deactivate(); await viewer.stop()
    context.documents.forEach { $0.dispose() }
}

@MainActor @Test func documentFactoryIsRetainedBySnapshotReplacementAndLegacyImport() throws {
    let factory = DocumentFactoryFixture()
    let record = FileDocumentRecord(id: "one", path: "/fixture/one.swift")
    let snapshot = ContextSnapshot(pages: [], activeID: record.id, history: [], pane: "term", documents: [record], tabOrder: [record.id])
    let context = WorkspaceContext(id: "snapshot", sourceURL: "", title: "", snapshot: snapshot, documentFactory: factory)
    #expect(context.activeDocument?.record == record && factory.editors == [record])
    context.apply(snapshot)
    #expect(context.activeDocument?.record == record && factory.editors == [record, record])
    #expect(context.activeDocument?.surface == nil)
    let second = try #require(context.openFile("/fixture/two.swift"))
    #expect(factory.editors.last?.id == second.id && factory.editors.count == 3)
    let legacy = SavedTab(kind: "web", title: "Legacy", url: "session:legacy", links: [
        .init(kind: "file", url: "file:///fixture/legacy.swift", active: true),
        .init(kind: "file", path: "relative.swift")
    ])
    let imported = WorkspaceContext(id: "legacy", sourceURL: legacy.url, title: legacy.title,
        snapshot: .importing(legacy), documentFactory: factory)
    #expect(imported.activeDocument?.record.path == "/fixture/legacy.swift")
    #expect(imported.documents.count == 1 && factory.editors.count == 4)
}

@MainActor @Test(.timeLimit(.minutes(1))) func documentFactoryKeepsNestedHistoryPatchesReadOnlyAndWorkingActionsConnected() async throws {
    let factory = DocumentFactoryFixture(), base = URL(string: "http://127.0.0.1:9")!
    let history = factory.history(worktree: "/fixture", baseURL: base, base: "main", service: HistoryFixture(), copy: { _ in })
    history.presentation.active = true
    await history.waitForList(); await history.waitForDetail()
    let patch = try #require(history.patch)
    await patch.waitForRefresh()
    #expect(factory.patches == ["immutable patch"] && factory.actionWorktrees.isEmpty)
    #expect(patch.actions == nil && patch.snapshot?.fileLinks == false && patch.presentation.active)
    let service = GitActionFixture()
    let working = factory.diff(worktree: "/fixture", baseURL: base, service: service, actionsService: service, openFile: { _ in })
    working.presentation.active = true; await working.waitForRefresh()
    let actions = try #require(working.actions)
    await actions.load(); actions.message = "Factory commit"
    await actions.perform(.commit); await working.waitForRefresh()
    #expect(factory.actionWorktrees == ["/fixture"] && working.snapshot?.diff == "")
    #expect(await service.commits.count == 1)
    history.presentation.active = false; working.disconnect()
}
