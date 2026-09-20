import Foundation
import Testing

@MainActor final class EditorClosePresenterFixture: EditorClosePresenting {
    var requests: [EditorCloseViewModel.Request] = []
    var chooseAction: (EditorCloseViewModel.Request) async -> EditorCloseViewModel.Choice = { _ in .cancel }
    func choose(_ request: EditorCloseViewModel.Request) async -> EditorCloseViewModel.Choice {
        requests.append(request)
        return await chooseAction(request)
    }
}

@MainActor private final class CloseFactoryFixture: DocumentFeatureFactory {
    var models: [EditorCloseViewModel] = []
    func editorClose(documents: [EditorDocumentViewModel]) -> EditorCloseViewModel {
        let model = EditorCloseViewModel(documents: documents); models.append(model); return model
    }
}

@MainActor func closeFixtureDocument(_ path: String) async -> (EditorDocumentViewModel, BufferFixture, FileFixture) {
    let surface = BufferFixture(), service = FileFixture()
    let model = EditorDocumentViewModel(record: .init(path: path), service: service, makeSurface: { surface })
    model.show(appearance: .system); await model.waitForLoad(); surface.edit("unsaved " + path, notify: false)
    return (model, surface, service)
}

@MainActor @Test(.timeLimit(.minutes(1))) func editorCloseBatchFreezesAllRetriesSaveAndRejectsOldChoice() async throws {
    let (first, firstSurface, service) = await closeFixtureDocument("/tmp/first.swift")
    let (second, secondSurface, _) = await closeFixtureDocument("/tmp/second.swift")
    let factory = CloseFactoryFixture(), presenter = EditorClosePresenterFixture()
    let coordinator = EditorCloseCoordinator(factory: factory, presenter: presenter)
    await service.fail(true)
    var committed = false
    presenter.chooseAction = { request in
        #expect(firstSurface.frozen && secondSurface.frozen && first.closing && second.closing)
        #expect(!committed && coordinator.isPresenting)
        switch presenter.requests.count {
        case 1: return .save
        case 2:
            #expect(request.error == "File changed on disk" && first.dirty)
            let model = try! #require(coordinator.model)
            model.respond(to: presenter.requests[0].id, choice: .discard)
            #expect(model.request?.id == request.id)
            await service.fail(false)
            return .save
        default: return .discard
        }
    }
    let approved = await coordinator.close([first, first, second], commit: {
        #expect(!first.dirty && second.dirty && firstSurface.frozen && secondSurface.frozen)
        committed = true; first.dispose(); second.dispose()
    })
    #expect(approved)
    #expect(committed && firstSurface.disposed && secondSurface.disposed && !coordinator.isPresenting)
    #expect(factory.models.count == 1 && factory.models[0].phase == .approved)
    #expect(presenter.requests.map(\.title) == ["first.swift", "first.swift", "second.swift"])
    #expect(await service.writes.count == 2)
}

@MainActor @Test(.timeLimit(.minutes(1))) func editorCloseCancelRollsBackEveryBufferAndLeavesPriorLocksAlone() async throws {
    let (first, firstSurface, _) = await closeFixtureDocument("/tmp/first.swift")
    let (second, secondSurface, _) = await closeFixtureDocument("/tmp/second.swift")
    let presenter = EditorClosePresenterFixture(), coordinator = EditorCloseCoordinator(presenter: presenter)
    presenter.chooseAction = { request in request.title == "first.swift" ? .discard : .cancel }
    #expect(await coordinator.close([first, second], commit: { Issue.record("Cancelled batch closed documents") }) == false)
    #expect(!first.closing && !second.closing && !firstSurface.frozen && !secondSurface.frozen)
    #expect(!firstSurface.disposed && !secondSurface.disposed)
    firstSurface.edit("retry after cancel")
    #expect(firstSurface.content == "retry after cancel")
    _ = try await second.beginClose()
    #expect(await coordinator.close([first, second], commit: { Issue.record("Partially frozen batch closed") }) == false)
    #expect(!first.closing && !firstSurface.frozen && second.closing && secondSurface.frozen)
    #expect(presenter.requests.count == 2)
    await second.cancelClose(); first.dispose(); second.dispose()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func editorCloseRejectsConcurrentRequestsAndRollsBackCancelledOrUnownedApproval(cancelTask: Bool) async throws {
    let (document, surface, _) = await closeFixtureDocument("/tmp/held.swift")
    let presenter = EditorClosePresenterFixture(), gate = ProjectPageGate()
    let coordinator = EditorCloseCoordinator(presenter: presenter)
    var owned = true, committed = false
    presenter.chooseAction = { _ in try? await gate.wait(); return .discard }
    let task = Task { await coordinator.close([document], isOwned: { owned }, commit: { committed = true }) }
    await gate.waitForStart()
    #expect(await coordinator.close([document], commit: { Issue.record("Overlapping close committed") }) == false)
    #expect(presenter.requests.count == 1 && surface.frozen)
    if cancelTask { task.cancel() } else { owned = false }
    await gate.finish()
    #expect(await task.value == false)
    #expect(!committed && !document.closing && !surface.frozen && !surface.disposed && !coordinator.isPresenting)
    document.dispose()
}

@MainActor @Test(.timeLimit(.minutes(1))) func viewerUsesOneCloseOwnerAndIncludesFilesOpenedWhilePrompting() async throws {
    let presenter = EditorClosePresenterFixture(), gate = ProjectPageGate(), factory = CloseFactoryFixture()
    let coordinator = EditorCloseCoordinator(factory: factory, presenter: presenter)
    let viewer = ViewerStore(documentFactory: factory, closeCoordinator: coordinator)
    let context = viewer.select(id: "files", url: "", title: "Files")
    let first = try #require(context.openFile("/tmp/first.swift")), firstSurface = BufferFixture()
    first.connect(service: FileFixture(), makeSurface: { firstSurface })
    first.show(appearance: .system); await first.waitForLoad(); firstSurface.edit("unsaved first")
    presenter.chooseAction = { _ in try? await gate.wait(); return .discard }
    context.close(.file(first))
    await gate.waitForStart()
    #expect(await viewer.closeDocuments() == false) // Quit cannot overlap tab close.
    await gate.finish()
    while coordinator.isPresenting { await Task.yield() }
    #expect(context.documents.isEmpty && firstSurface.disposed)
    let second = try #require(context.openFile("/tmp/second.swift")), secondSurface = BufferFixture()
    second.connect(service: FileFixture(), makeSurface: { secondSurface })
    second.show(appearance: .system); await second.waitForLoad(); secondSurface.edit("unsaved second")
    var newFile: EditorDocumentViewModel?
    presenter.chooseAction = { _ in
        newFile = context.openFile("/tmp/picker-completed.swift")
        return .discard
    }
    #expect(await viewer.closeDocuments())
    #expect(context.documents.isEmpty && secondSurface.disposed && newFile?.closing == true)
    #expect(factory.models.count == 3) // Individual close, batch, then picker result.
    await viewer.stop()
}
