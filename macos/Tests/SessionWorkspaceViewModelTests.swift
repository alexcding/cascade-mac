import Foundation
import Observation
import Testing

@MainActor @Observable private final class WorkspaceFixture: WorkspaceServing {
    var state = SessionWorkspaceState()
    var actions: [SessionWorkspaceViewModel.Action] = []
    var contextIDs: [String] = []
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { state }
    func record(_ action: SessionWorkspaceViewModel.Action, in context: WorkspaceContext) {
        actions.append(action); contextIDs.append(context.id)
    }
}

@MainActor private final class CountingWorkspaceFactory: WorkspaceFeatureFactory {
    let native = NativeWorkspaceFeatureFactory()
    var creations = 0
    func workspace(context: WorkspaceContext, service: any WorkspaceServing) -> SessionWorkspaceViewModel {
        creations += 1; return native.workspace(context: context, service: service)
    }
    func removal(service: any SessionRemoving, record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession],
                 didRemove: @escaping ([WorkspaceSession]) async -> Void, finished: @escaping () -> Void) -> SessionRemovalViewModel {
        native.removal(service: service, record: record, projects: projects, sessions: sessions, didRemove: didRemove, finished: finished)
    }
    func build(api: APIClient, project: Project, session: WorkspaceSession,
               terminalFactory: @escaping () throws -> any BuildTerminal) -> BuildWorkspaceViewModel {
        native.build(api: api, project: project, session: session, terminalFactory: terminalFactory)
    }
    func buildDestination(runtime: BuildWorkspaceViewModel, purpose: BuildDestinationViewModel.Purpose) -> BuildDestinationViewModel {
        native.buildDestination(runtime: runtime, purpose: purpose)
    }
}

@MainActor @Test func workspaceModelComputesPaneVisibilityAndGatesOperationsAgainstCurrentState() throws {
    let context = WorkspaceContext(id: "task:one", sourceURL: "", title: "")
    let service = WorkspaceFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
    model.onAction = { [weak service, weak context] action in
        if let context { service?.record(action, in: context) }
    }
    #expect(!model.showsTerminal && model.showsPage && !model.canRemove)
    service.state.session = WorkspaceSession(id: "one", projectId: "p", workspace: "/tmp", worktree: "/tmp/one", title: "One",
                                             branch: "one", url: "", createdAt: nil, pinned: false)
    service.state.project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    // A session with no page of its own opens on its terminal alone; the pane is one toggle away.
    #expect(model.showsTerminal && !model.showsPage && model.canToggleContext && !model.canRun)
    model.toggleContext(); #expect(context.pane == .term && model.showsPage)
    model.toggleContext(); #expect(context.pane == .off && !model.showsPage)
    _ = try #require(context.open("https://example.test/context"))
    // Opening a page brings the pane back with it.
    #expect(context.pane == .term && model.showsPage && model.canToggleContext)
    model.toggleContext(); #expect(context.pane == .off && !model.showsPage)
    model.toggleContext(); #expect(context.pane == .term && model.showsPage)
    context.setPane(.diff)
    #expect(model.showsTerminal && model.showsChanges && model.showsPage)
    service.state.connected = true; service.state.canPresent = true
    service.state.editorLabel = "Open Xcode"
    #expect(model.canRun && model.canRemove && model.canRestart && model.canOpenExternal)
    model.openEditor(); model.run(); model.remove(); model.restart()
    #expect(service.actions == [.operation(.openEditor), .run, .remove, .restart])
    service.state.changingSession = true
    model.openEditor(); model.run(); model.remove(); model.restart()
    #expect(service.actions.count == 4 && !model.canRun && !model.canRemove)
    service.state.changingSession = false; service.state.canPresent = false
    model.run(); model.remove(); model.restart()
    #expect(service.actions.count == 4)
    service.state.connected = false
    #expect(!model.canShowChanges)
}

@MainActor @Test func workspaceModelRefreshesOnlyVisibleReviewsAndRetainsIdentityThroughPromotion() throws {
    let service = WorkspaceFixture(), factory = CountingWorkspaceFactory(), viewer = ViewerStore()
    viewer.prepareContext = { [service] context in
        context.configureWorkspace(factory: factory, service: service)
        context.workspaceViewModel?.onAction = { [weak service, weak context] action in
            if let context { service?.record(action, in: context) }
        }
    }
    let context = viewer.select(id: "page", url: "", title: "Page")
    let model = try #require(context.workspaceViewModel)
    let document = try #require(context.openFile("/tmp/Workspace.swift"))
    _ = viewer.select(id: "page", url: "", title: "Page")
    #expect(context.workspaceViewModel === model && factory.creations == 1)
    try viewer.promoteContext(from: "page", to: "task:prepared")
    _ = viewer.select(id: "task:prepared", url: "", title: "Prepared")
    #expect(viewer.active === context && context.workspaceViewModel === model && factory.creations == 1)
    #expect(context.activeDocument === document)
    service.state.session = WorkspaceSession(id: "prepared", projectId: "p", workspace: "/tmp", worktree: "/tmp/prepared",
                                             title: "Prepared", branch: "prepared", url: "", createdAt: nil, pinned: false)
    context.setPane(.diff)
    #expect(model.active && service.actions == [.operation(.prepareChanges)] && service.contextIDs == ["task:prepared"])
    context.setReviewSection(.history)
    #expect(service.actions.count == 2)
    context.setReviewSection(.history); model.setActive(true)
    #expect(service.actions.count == 2)
    let inputs = model.reviewInputs
    service.state.reviewBase = "main"
    #expect(model.reviewInputs != inputs)
    model.reviewStateChanged(); #expect(service.actions.count == 3)
    model.reviewStateChanged(); #expect(service.actions.count == 3)
    viewer.deactivate(); model.prepareChanges(); #expect(!model.active && service.actions.count == 3)
    context.setPane(.term)
    _ = viewer.select(id: "task:prepared", url: "", title: "Prepared")
    #expect(model.active && service.actions.count == 3)
}

@MainActor @Test func workspaceModelDoesNotRetainItsContextOrRuntime() {
    var context: WorkspaceContext? = WorkspaceContext(id: "scratch", sourceURL: "", title: "")
    var service: WorkspaceFixture? = WorkspaceFixture()
    let model = SessionWorkspaceViewModel(context: context!, service: service!)
    #expect(model.workspaceTitle == "Terminal" && model.showsTerminal)
    context = nil; service = nil
    #expect(!model.showsTerminal && !model.canRestart)
    model.openTerminal(); model.setActive(true)
}

@MainActor @Test func workspaceKeepsEveryTerminalStyleCurrentAcrossReplacementAndFontChanges() throws {
    let runtime = WorkspaceFixture(), viewer = ViewerStore()
    let terminal = TerminalSession(), build = TerminalSession(), replacement = TerminalSession()
    defer { terminal.disconnect(); build.disconnect(); replacement.disconnect() }
    runtime.state.session = WorkspaceSession(id: "terminals", projectId: "p", workspace: "/tmp", worktree: "/tmp/terminals",
        title: "Terminals", branch: "terminals", url: "", createdAt: nil, pinned: false)
    runtime.state.terminal = terminal; runtime.state.buildTerminal = build
    viewer.prepareContext = { $0.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: runtime) }
    let context = viewer.select(id: "task:terminals", url: "", title: "Terminals")
    let model = try #require(context.workspaceViewModel)
    // Which pane is on screen is the view's `if`; the model only carries the style, and to
    // every terminal it holds, shown or not, so a pane draws correctly the moment it appears.
    runtime.state.terminalStyle = TerminalStyle(font: CodeFont(size: 19)); model.terminalStateChanged()
    #expect(terminal.presentation.style.font.size == 19 && build.presentation.style.font.size == 19)
    viewer.deactivate()
    runtime.state.terminalStyle = TerminalStyle(font: CodeFont(size: 20)); model.terminalStateChanged()
    #expect(terminal.presentation.style.font.size == 20 && build.presentation.style.font.size == 20)
    _ = viewer.select(id: "task:terminals", url: "", title: "Terminals")
    runtime.state.terminal = replacement; model.terminalStateChanged()
    #expect(replacement.presentation.style.font.size == 20)
    #expect(terminal.termID == nil && build.termID == nil && replacement.termID == nil)
    viewer.deactivate()
}

@MainActor @Test(.timeLimit(.minutes(1))) func workspaceOwnsDocumentActivationAndStyleWithoutRenderingViews() async throws {
    let runtime = WorkspaceFixture(), viewer = ViewerStore()
    let diffService = DiffFixture(), historyService = HistoryFixture(), fileService = FileFixture()
    let base = URL(string: "http://127.0.0.1:9")!
    runtime.state.session = WorkspaceSession(id: "documents", projectId: "p", workspace: "/tmp", worktree: "/tmp/documents",
        title: "Documents", branch: "documents", url: "", createdAt: nil, pinned: false)
    runtime.state.connected = true
    let diff = DiffViewModel(worktree: "/tmp/documents", baseURL: base, service: diffService)
    let history = GitHistoryViewModel(worktree: "/tmp/documents", baseURL: base, service: historyService, pageSize: 2)
    runtime.state.diff = diff; runtime.state.history = history
    viewer.prepareContext = { context in context.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: runtime) }
    let context = viewer.select(id: "task:documents", url: "", title: "Documents")
    let workspace = try #require(context.workspaceViewModel)
    let file = try #require(context.openFile("/tmp/documents/File.swift")), surface = BufferFixture()
    file.connect(service: fileService, makeSurface: { surface })
    await file.waitForLoad()
    #expect(file.loaded && file.presentation.active && !diff.presentation.active && !history.presentation.active)
    surface.edit("keep this unsaved buffer")
    context.setPane(.diff)
    await diff.waitForRefresh()
    #expect(!file.presentation.active && file.dirty && file.surface === surface && !surface.disposed)
    #expect(diff.presentation.active && diff.snapshot != nil && !history.presentation.active)
    context.setPane(.diff); workspace.reviewStateChanged()
    #expect(await diffService.calls == 1)
    context.setReviewSection(.history)
    await history.waitForList(); await history.waitForDetail()
    #expect(!diff.presentation.active && history.presentation.active)
    #expect(history.patch?.presentation.active == true && history.patch?.actions == nil)
    history.loadMore(); await history.waitForList()
    let selection = history.selectedSHA, patch = try #require(history.patch)
    let count = await historyService.calls.count
    runtime.state.appearance = .dark; runtime.state.documentFont = CodeFont(size: 19)
    workspace.documentStateChanged(); workspace.documentStateChanged()
    #expect(history.patch === patch && patch.presentation.appearance == .dark && patch.presentation.font.size == 19)
    #expect(await historyService.calls.count == count && history.selectedSHA == selection)
    #expect(surface.appearances.last == .dark && surface.fonts.last?.size == 19)
    viewer.deactivate()
    #expect(!history.presentation.active && history.patch == nil && !patch.presentation.active)
    #expect(file.loaded && file.surface === surface)
    _ = viewer.select(id: "task:documents", url: "", title: "Documents")
    await history.waitForList(); await history.waitForDetail()
    #expect(history.commits.count == 3 && history.selectedSHA == selection && history.presentation.active)
    context.select(.file(file)); await file.waitForLoad()
    #expect(!history.presentation.active && file.presentation.active && file.surface === surface)
    #expect(surface.content == "keep this unsaved buffer")
    #expect(await fileService.reads == 1)
    context.restoring = true
    #expect(!file.presentation.active)
    context.restoring = false
    #expect(file.presentation.active && file.surface === surface)
    viewer.deactivate(); diff.disconnect(); history.hide(); file.dispose()
}

@MainActor @Test(.timeLimit(.minutes(1))) func workspaceReplacementAndReconnectDeactivateObsoleteDocumentModels() async throws {
    let runtime = WorkspaceFixture(), viewer = ViewerStore(), base = URL(string: "http://127.0.0.1:9")!
    let service = DiffFixture()
    let old = DiffViewModel(worktree: "/tmp/old", baseURL: base, service: service)
    runtime.state.session = WorkspaceSession(id: "p", projectId: "p", workspace: "/tmp", worktree: "/tmp/p",
        title: "P", branch: "p", url: "", createdAt: nil, pinned: false)
    runtime.state.connected = true; runtime.state.diff = old
    viewer.prepareContext = { $0.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: runtime) }
    let context = viewer.select(id: "task:p", url: "", title: "P")
    let model = try #require(context.workspaceViewModel)
    context.setPane(.diff)
    let fresh = DiffViewModel(worktree: "/tmp/fresh", baseURL: base, service: service)
    runtime.state.diff = fresh; model.documentStateChanged()
    await fresh.waitForRefresh()
    #expect(!old.presentation.active && old.snapshot == nil)
    #expect(fresh.presentation.active && fresh.snapshot?.diff == "diff for /tmp/fresh")
    // Offline, the diff stops refreshing but keeps showing the last changes it loaded.
    runtime.state.connected = false; model.reviewStateChanged()
    #expect(!fresh.presentation.active && fresh.snapshot?.diff == "diff for /tmp/fresh")
    runtime.state.connected = true; model.reviewStateChanged(); await fresh.waitForRefresh()
    #expect(fresh.presentation.active && fresh.snapshot != nil)
    viewer.deactivate(); old.disconnect(); fresh.disconnect()
}

@MainActor @Test func onlyAPanelThatHoldsManyPagesOffersNewTab() {
    // A sidebar tab is one page: its row in the sidebar is the tab, so the panel shows no ＋ and
    // ⌘T does nothing. A session's second panel and the scratch terminal keep both.
    #expect(WorkspaceContext(id: "tab:one", sourceURL: "", title: "Tab").holdsOnePage)
    #expect(!WorkspaceContext(id: "task:one", sourceURL: "", title: "Session").holdsOnePage)
    #expect(!WorkspaceContext(id: "scratch", sourceURL: "", title: "Terminal").holdsOnePage)

    let context = WorkspaceContext(id: "tab:one", sourceURL: "", title: "Tab")
    let service = WorkspaceFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
    model.onAction = { [weak service, weak context] action in
        if let context { service?.record(action, in: context) }
    }
    service.state.canPresent = true
    model.setActive(true)
    service.state.offersNewTab = false
    // The panel still fills itself with its blank page; only the affordance is gone.
    #expect(!model.offersNewTab && model.canOpenTab)
    model.newTab()
    #expect(service.actions == [.newTab])
    service.state.offersNewTab = true
    #expect(model.offersNewTab && model.canOpenTab)
}

// A page's X lets the page and its web view go. A lone page with content can be closed (the panel then
// shows its empty state, a blank page) but a lone blank one cannot, since it is that empty state. A
// sidebar tab's panel follows the same rule.
@MainActor @Test func aPageOffersCloseUnlessItIsTheLoneBlankPageOfAPanel() throws {
    let service = WorkspaceFixture()
    let session = WorkspaceContext(id: "task:close", sourceURL: "", title: "Session")
    let model = SessionWorkspaceViewModel(context: session, service: service)
    let page = try #require(session.open("https://example.test/close"))
    #expect(model.offersClose(page))
    let blank = session.openBlankPage()
    #expect(model.offersClose(page) && model.offersClose(blank))
    session.close(page)
    #expect(session.pageTabs.count == 1 && !model.offersClose(blank))
    let tab = WorkspaceContext(id: "tab:close", sourceURL: "", title: "Tab")
    let tabModel = SessionWorkspaceViewModel(context: tab, service: service)
    let tabPage = try #require(tab.open("https://example.test/tab"))
    #expect(tabModel.offersClose(tabPage))
    tab.close(tabPage)
    #expect(!tabModel.offersClose(tab.openBlankPage()))
}
