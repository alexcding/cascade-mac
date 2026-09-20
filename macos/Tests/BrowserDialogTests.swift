import AppKit
import Testing

@MainActor private final class BrowserDialogPresenterFixture: BrowserDialogPresenting {
    var requests: [BrowserDialogViewModel.Request] = []
    var completions: [(BrowserDialogViewModel.Response) -> Void] = []
    var cancelled: [UUID] = []
    var synchronous: BrowserDialogViewModel.Response?
    func present(_ request: BrowserDialogViewModel.Request, in window: NSWindow?,
                 completion: @escaping (BrowserDialogViewModel.Response) -> Void) -> () -> Void {
        requests.append(request); completions.append(completion)
        if let synchronous { completion(synchronous) }
        return { self.cancelled.append(request.id); completion(.cancel) }
    }
}

@MainActor @Test func browserDialogCompletesOncePreservesEmptyPromptAndSerializesPages() throws {
    let presenter = BrowserDialogPresenterFixture(), coordinator = BrowserDialogCoordinator(presenter: presenter)
    let first = BrowserDialogViewModel(), second = BrowserDialogViewModel()
    for model in [first, second] {
        model.active = true
        coordinator.bind(model, isOwned: { true }, window: { nil })
    }
    var responses: [BrowserDialogViewModel.Response] = []
    first.begin(.prompt("Name", defaultText: "Original"), origin: "example.test") { responses.append($0) }
    let request = try #require(first.request)
    #expect(coordinator.isPresenting && presenter.requests == [request])
    first.respond(.text("wrong"), to: UUID())
    second.begin(.confirm("Overlap"), origin: "second.test") { responses.append($0) }
    #expect(responses == [.cancel] && first.request?.id == request.id)
    #expect(second.request == nil && presenter.requests.count == 1)
    presenter.completions[0](.text(""))
    presenter.completions[0](.text("duplicate"))
    #expect(responses == [.cancel, .text("")])
    #expect(!coordinator.isPresenting && first.request == nil)
    second.begin(.files(multiple: true, directories: true), origin: "upload.test") { responses.append($0) }
    #expect(presenter.requests.last?.kind == .files(multiple: true, directories: true))
    presenter.completions[1](.files([URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")]))
    #expect(responses.count == 3 && !coordinator.isPresenting)
}

@MainActor @Test func browserDialogDeactivationCancelsNativeSheetAndIgnoresLateCompletion() throws {
    let presenter = BrowserDialogPresenterFixture(), coordinator = BrowserDialogCoordinator(presenter: presenter)
    let model = BrowserDialogViewModel()
    model.active = true
    coordinator.bind(model, isOwned: { true }, window: { nil })
    var responses: [BrowserDialogViewModel.Response] = []
    model.begin(.confirm("Leave?"), origin: "example.test") { responses.append($0) }
    let oldID = try #require(model.request?.id)
    model.active = false
    #expect(responses == [.cancel] && presenter.cancelled == [oldID])
    #expect(!coordinator.isPresenting && model.request == nil)
    model.begin(.alert("Hidden"), origin: "example.test") { responses.append($0) }
    #expect(responses == [.cancel, .cancel] && presenter.requests.count == 1)
    model.active = true
    model.begin(.confirm("New?"), origin: "example.test") { responses.append($0) }
    presenter.completions[0](.confirm(true))
    #expect(model.request != nil && coordinator.isPresenting && responses.count == 2)
    presenter.completions[1](.confirm(true))
    #expect(responses == [.cancel, .cancel, .confirm(true)])
}

@MainActor @Test func browserDialogRechecksOwnershipAndCancelsOnRebindingOrShutdown() {
    let presenter = BrowserDialogPresenterFixture(), coordinator = BrowserDialogCoordinator(presenter: presenter)
    let model = BrowserDialogViewModel()
    var owned = true
    model.active = true
    coordinator.bind(model, isOwned: { owned }, window: { nil })
    var responses: [BrowserDialogViewModel.Response] = []
    model.begin(.files(multiple: false, directories: false), origin: "upload.test") { responses.append($0) }
    owned = false
    presenter.completions[0](.files([URL(fileURLWithPath: "/tmp/late")]))
    #expect(responses == [.cancel])
    model.begin(.alert("Removed"), origin: "upload.test") { responses.append($0) }
    #expect(presenter.requests.count == 1 && responses.count == 2)
    owned = true
    model.begin(.alert("Pending"), origin: "upload.test") { responses.append($0) }
    let replacement = BrowserDialogCoordinator(presenter: presenter)
    replacement.bind(model, isOwned: { true }, window: { nil })
    #expect(!coordinator.isPresenting && presenter.cancelled.count == 1 && responses.count == 3)
    model.begin(.alert("Replacement"), origin: "upload.test") { responses.append($0) }
    replacement.enabled = false
    #expect(responses.count == 4 && !replacement.isPresenting)
    model.begin(.alert("Stopped"), origin: "upload.test") { responses.append($0) }
    #expect(responses.count == 5 && presenter.requests.count == 3)
    presenter.completions[1](.acknowledge); presenter.completions[2](.acknowledge)
    #expect(responses == Array(repeating: .cancel, count: 5))
}

@MainActor @Test func browserDialogSynchronousPresenterAndMissingCoordinatorDrainRequests() {
    let presenter = BrowserDialogPresenterFixture()
    presenter.synchronous = .cancel
    var coordinator: BrowserDialogCoordinator? = BrowserDialogCoordinator(presenter: presenter)
    let model = BrowserDialogViewModel()
    model.active = true
    coordinator?.bind(model, isOwned: { true }, window: { nil })
    var responses: [BrowserDialogViewModel.Response] = []
    model.begin(.alert("No window"), origin: "example.test") { responses.append($0) }
    #expect(responses == [.cancel] && coordinator?.isPresenting == false)
    coordinator = nil
    model.begin(.alert("No owner"), origin: "example.test") { responses.append($0) }
    #expect(responses == [.cancel, .cancel] && model.request == nil)
}

@MainActor @Test func browserDialogReservationPreservesRootDraftAndReleasesForNextSheet() {
    let presenter = BrowserDialogPresenterFixture(), dialogs = BrowserDialogCoordinator(presenter: presenter)
    let root = AppCoordinator(factory: NativeCreationFlowFactory(), browserDialogCoordinator: dialogs)
    let model = BrowserDialogViewModel()
    model.active = true; dialogs.bind(model, isOwned: { true }, window: { nil })
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    let draftID = root.sheet?.id
    var responses: [BrowserDialogViewModel.Response] = []
    model.begin(.confirm("Background request"), origin: "example.test") { responses.append($0) }
    #expect(responses == [.cancel] && presenter.requests.isEmpty && root.sheet?.id == draftID)
    if let draftID { root.dismissSheet(id: draftID) }
    model.begin(.confirm("Current request"), origin: "example.test") { responses.append($0) }
    #expect(!root.canPresent)
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    #expect(root.sheet == nil)
    presenter.completions[0](.confirm(true))
    #expect(root.canPresent && responses == [.cancel, .confirm(true)])
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    #expect(root.sheet != nil)
}

@MainActor @Test func browserDialogFactorySharesPresentationAndCancelsEvictedAndRemovedPages() throws {
    let presenter = BrowserDialogPresenterFixture(), coordinator = BrowserDialogCoordinator(presenter: presenter)
    let factory = BrowserPageFactory(dialogs: coordinator)
    let context = WorkspaceContext(id: "dialog", sourceURL: "https://example.test", title: "Fixture", pageFactory: factory)
    let page = try #require(context.activePage)
    page.dialogs.active = true
    var responses: [BrowserDialogViewModel.Response] = []
    page.dialogs.begin(.prompt("Value", defaultText: ""), origin: "example.test") { responses.append($0) }
    page.evict()
    #expect(responses == [.cancel] && !coordinator.isPresenting && presenter.cancelled.count == 1)
    page.dialogs.begin(.alert("Again"), origin: "example.test") { responses.append($0) }
    context.close(page)
    #expect(responses == [.cancel, .cancel] && !coordinator.isPresenting)
    page.dialogs.begin(.alert("Retained closed page"), origin: "example.test") { responses.append($0) }
    #expect(responses.count == 3 && presenter.requests.count == 2)
    context.apply(.init(pages: [.init(url: "https://example.test/restored", title: "Restored")]))
    let restored = try #require(context.pages.first)
    restored.dialogs.active = true
    restored.dialogs.begin(.alert("Restored"), origin: "example.test") { responses.append($0) }
    #expect(presenter.requests.count == 3)
    coordinator.cancel()
    #expect(responses.count == 4 && restored.dialogs.request == nil)
}

@MainActor private final class BrowserWorkspaceFixture: WorkspaceServing {
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { SessionWorkspaceState() }
}


@MainActor @Test func browserDialogActivityFollowsWorkspaceModelsWithoutViewObservers() throws {
    let presenter = BrowserDialogPresenterFixture(), dialogs = BrowserDialogCoordinator(presenter: presenter)
    let context = WorkspaceContext(id: "workspace", sourceURL: "https://example.test/one", title: "One",
                                   pageFactory: BrowserPageFactory(dialogs: dialogs))
    let runtime = BrowserWorkspaceFixture()
    context.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: runtime)
    let workspace = try #require(context.workspaceViewModel), first = try #require(context.activePage)
    workspace.setActive(true)
    #expect(first.dialogs.active && first.controls.active)
    var responses: [BrowserDialogViewModel.Response] = []
    first.dialogs.begin(.confirm("Pending"), origin: "example.test") { responses.append($0) }
    let second = try #require(context.open("https://example.test/two"))
    #expect(!first.dialogs.active && !first.controls.active && second.dialogs.active && second.controls.active && responses == [.cancel])
    second.dialogs.begin(.confirm("Second"), origin: "example.test") { responses.append($0) }
    context.restoring = true
    #expect(!second.dialogs.active && !second.controls.active && responses == [.cancel, .cancel])
    context.restoring = false
    #expect(second.dialogs.active && second.controls.active)
    second.dialogs.begin(.confirm("Third"), origin: "example.test") { responses.append($0) }
    workspace.setActive(false)
    #expect(!second.dialogs.active && !second.controls.active && responses.count == 3 && !dialogs.isPresenting)
}
