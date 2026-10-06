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

/// The toolbar's toggle shows and hides the pane as it was; Diff's tab opens through the app,
/// which loads the changes first.
@MainActor @Test func thePaneTogglesAndDiffOpensThroughTheApp() throws {
    let context = WorkspaceContext(id: "task:picker", sourceURL: "", title: "")
    let service = WorkspaceFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
    model.onAction = { [weak service, weak context] action in
        if let context { service?.record(action, in: context) }
    }
    service.state.session = WorkspaceSession(id: "picker", projectId: "p", workspace: "/tmp", worktree: "/tmp/picker", title: "Picker",
                                             branch: "picker", url: "", createdAt: nil, pinned: false)
    model.setActive(true)
    let page = try #require(context.open("https://example.test/picker"))
    model.setContextPresented(false)
    #expect(!model.showsPage, "the toggle hides the pane")
    model.setContextPresented(true)
    #expect(model.showsPage && context.activePage === page, "and brings it back on the same page")
    service.state.connected = true
    context.openTool(.changes)
    context.select(.page(page))
    model.selectTab(.tool(.changes))
    #expect(service.actions.last == .operation(.changes), "Diff's tab goes through the app")
    #expect(model.startPageTools().map(\.id) == ["files", "terminal", "chat"], "Diff is open: it is not offered again")
    context.close(.tool(.changes))
    #expect(model.startPageTools().map(\.id) == ["files", "terminal", "diff", "chat"])
    context.openTool(.files)
    context.openTool(.terminal)
    #expect(model.startPageTools().map(\.id) == ["files", "terminal", "diff", "chat"],
            "Files and Terminal are offered again: they may have many tabs")
    #expect(model.shellTitle(.terminal) == "picker" && model.shellTitle(WorkspaceToolTab(.terminal, number: 2)) == "picker 2",
            "a Terminal tab goes by its worktree's folder, numbered past the first")
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

@MainActor @Test func workspaceModelRefreshesOnlyVisibleReviewsAndRetainsIdentity() throws {
    let service = WorkspaceFixture(), factory = CountingWorkspaceFactory(), viewer = ViewerStore()
    viewer.prepareContext = { [service] context in
        context.configureWorkspace(factory: factory, service: service)
        context.workspaceViewModel?.onAction = { [weak service, weak context] action in
            if let context { service?.record(action, in: context) }
        }
    }
    let context = viewer.select(id: "task:prepared", url: "", title: "Prepared")
    let model = try #require(context.workspaceViewModel)
    let document = try #require(context.openFile("/tmp/Workspace.swift"))
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

// A page's X lets the page and its web view go. A lone page with content can be closed (the panel then
// shows its empty state, a blank page) but a lone blank one cannot, since it is that empty state.
@MainActor @Test func aPageOffersCloseUnlessItIsTheLoneBlankPageOfAPanel() throws {
    let service = WorkspaceFixture()
    let session = WorkspaceContext(id: "task:close", sourceURL: "", title: "Session")
    let model = SessionWorkspaceViewModel(context: session, service: service)
    let page = try #require(session.open("https://example.test/close"))
    #expect(model.offersClose(page))
    let blank = session.openBlankPage()
    #expect(model.offersClose(page) && model.offersClose(blank))
    session.close(page)
    #expect(session.pages.count == 1 && !model.offersClose(blank))
}

// The context pane's last tab, blank or not, closes, and the pane stays open on its empty state.
@MainActor @Test func theContextPanesLastTabClosesAndThePaneStays() throws {
    let service = WorkspaceFixture()
    let scratch = WorkspaceContext(id: "scratch", sourceURL: "", title: "Terminal")
    scratch.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: service)
    let model = try #require(scratch.workspaceViewModel)
    model.onAction = { [weak scratch] action in
        if case .closeTab(let id) = action, let scratch, let tab = scratch.tab(id) { scratch.close(tab) }
    }
    model.setContextPresented(true)
    let blank = scratch.openBlankPage()
    #expect(model.showsInspector && scratch.stripTabs.count == 1 && model.offersClose(blank))
    model.closeTab(.page(blank))
    #expect(scratch.stripTabs.isEmpty && model.showsInspector)
}

// The blank page the pane opens for itself is its empty state, not a tab in its strip, until New Tab
// takes it; cycling the tabs never lands on it.
@MainActor @Test func thePanesOwnBlankPageIsNoTabInItsStrip() throws {
    let scratch = WorkspaceContext(id: "scratch", sourceURL: "", title: "Terminal")
    scratch.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: WorkspaceFixture())
    scratch.workspaceViewModel?.setContextPresented(true)
    let filler = scratch.openBlankPage()
    scratch.fillerPageID = filler.id
    #expect(scratch.tabs.count == 1 && scratch.stripTabs.isEmpty)
    let files = WorkspaceToolTab(.files, number: 1)
    scratch.openTool(.files)
    #expect(scratch.stripTabs.map(\.id) == [files.id])
    scratch.cycle(1)
    #expect(scratch.activeID == files.id)
    #expect(scratch.openBlankPage() === filler && scratch.fillerPageID == nil && scratch.stripTabs.count == 2)
}

// A panel's row shows its own blank page as a tab, so cycling there reaches it; only the context
// pane's strip leaves it out.
@MainActor @Test func cyclingReachesThePanelsOwnBlankPage() throws {
    let context = WorkspaceContext(id: "task:panel", sourceURL: "", title: "Panel")
    let filler = context.openBlankPage()
    context.fillerPageID = filler.id
    let page = try #require(context.open("https://example.test/cycle"))
    #expect(context.activeID == page.id)
    context.cycle(1)
    #expect(context.activeID == filler.id)
}

// A pick from a blank tab swaps in place only when it opens a new tab there; selecting a tab already
// open closes the blank as any tab closes, which the strip animates.
@MainActor @Test func aBlankTabSwapsInPlaceOnlyForANewTab() throws {
    let context = WorkspaceContext(id: "task:swap", sourceURL: "", title: "Swap")
    context.openTool(.live)
    _ = context.openBlankPage()
    var edits = context.tabEdits
    context.openTool(.simulator, replacingBlank: true)
    #expect(context.tabEdits == edits && context.activeTool == .simulator && context.pages.isEmpty)
    _ = context.openBlankPage()
    edits = context.tabEdits
    context.openTool(.live, replacingBlank: true)
    #expect(context.tabEdits > edits && context.activeTool == .live && context.pages.isEmpty)

    let path = NSTemporaryDirectory() + "blank-swap-\(UUID().uuidString).txt"
    try "text".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = context.openBlankPage()
    edits = context.tabEdits
    let file = try #require(context.openFile(path))
    #expect(context.tabEdits == edits && context.activeID == file.id && context.pages.isEmpty)
    _ = context.openBlankPage()
    edits = context.tabEdits
    #expect(context.openFile(path) === file)
    #expect(context.tabEdits > edits && context.activeID == file.id && context.pages.isEmpty)
}

