import Foundation
import Observation
import Testing

@MainActor @Observable private final class RootRuntimeFixture: RootCoordinating, WorkspaceCoordinating {
    var state = RootState()
    var commands: [ShellCommand] = []
    var pins: [String] = []
    var closedTabs: [String] = []
    var selections: [SidebarDestination] = []
    var opens: [URL] = []
    var terminals = 0
    var reconnects = 0
    var removalRequests: [String] = []
    weak var coordinator: AppCoordinator?
    func rootState() -> RootState { state }
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { SessionWorkspaceState() }
    /// Stands in for `AppViewModel.showSelectedContext`: activates the viewer context for the selection.
    var onActivate: (SidebarDestination) -> Void = { _ in }
    func activateRootDestination() {
        if let coordinator { state.selection = coordinator.selection; selections.append(coordinator.selection) }
        if let coordinator { onActivate(coordinator.selection) }
    }
    func ownsWorkspace(_ context: WorkspaceContext) -> Bool { true }
    func performWorkspaceOperation(_ operation: WorkspaceOperation, in context: WorkspaceContext) {}
    func makeWorkspaceBuild(in context: WorkspaceContext) -> BuildWorkspaceViewModel? { nil }
    func makeWorkspaceRemoval(in context: WorkspaceContext) -> SessionRemovalViewModel? { nil }
    func restartWorkspaceSession(_ id: String, in context: WorkspaceContext) {}
    func performRootCommand(_ command: ShellCommand) { commands.append(command) }
    func reconnect() async { reconnects += 1 }
    func togglePin(_ id: String) { pins.append(id) }
    func closeTab(_ url: String) { closedTabs.append(url) }
    func openTerminal() { terminals += 1 }
    func openRootBrowser(_ url: URL) { opens.append(url) }
    func makeSessionRemoval(_ id: String) -> SessionRemovalViewModel? {
        removalRequests.append(id)
        guard let session = state.sessions.first(where: { $0.id == id }) else { return nil }
        return SessionRemovalViewModel(service: InertRemovalService(), record: session, projects: state.projects,
                                       sessions: state.sessions, didRemove: { _ in }, finished: {})
    }
}

private struct InertRemovalService: SessionRemoving {
    func prepare(record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession]) async throws -> SessionRemovalPlan {
        .init(record: record, sessions: [record], removesWorktree: false, holders: [])
    }
    func remove(_ plan: SessionRemovalPlan) async throws {}
}

@MainActor private final class RecordingRootFactory: RootFeatureFactory {
    var creations = 0
    func root(service: any RootServing, shell: ShellStore, viewer: ViewerStore) -> RootViewModel {
        creations += 1
        return RootViewModel(service: service, shell: shell, viewer: viewer)
    }
}

@MainActor @Test func rootActionsReachCoordinatorAndObsoleteRootCannotNavigate() async throws {
    let preferences = try #require(UserDefaults(suiteName: "CraftRootTests-\(UUID().uuidString)"))
    let shell = ShellStore(preferences: preferences), viewer = ViewerStore(), factory = RecordingRootFactory()
    let store = TransientSidebarSelectionStore(.terminal)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), selectionStore: store)
    let runtime = RootRuntimeFixture(); runtime.coordinator = coordinator
    let model = coordinator.makeRoot(factory: factory, runtime: runtime, shell: shell, viewer: viewer)
    #expect(coordinator.selection == .terminal && factory.creations == 1)
    model.newProject(); model.newSession(); model.refresh()
    #expect(runtime.commands.isEmpty)
    runtime.state.canCreateProject = true; runtime.state.canCreateSession = true; runtime.state.canRefresh = true
    model.newProject(); model.newSession(); model.refresh()
    #expect(runtime.commands == [.newProject, .newSession, .refresh])
    model.select(.session("session"))
    #expect(coordinator.selection == .session("session") && store.load() == .session("session"))
    #expect(runtime.selections == [.session("session")])
    model.togglePin("session"); model.closeTab("https://example.test/tab"); model.openTerminal(); model.reconnect()
    let url = try #require(URL(string: "https://example.test/page"))
    model.openBrowser(url)
    await Task.yield()
    #expect(runtime.pins == ["session"] && runtime.closedTabs == ["https://example.test/tab"] && runtime.terminals == 1 && runtime.reconnects == 1 && runtime.opens == [url])
    let replacement = coordinator.makeRoot(factory: factory, runtime: runtime, shell: shell, viewer: viewer)
    model.select(.overview)
    #expect(coordinator.selection == .session("session") && factory.creations == 2)
    replacement.select(.terminal)
    #expect(coordinator.selection == .terminal && store.load() == .terminal)
}

@MainActor @Test func rootIsTheActiveWorkspaceCoordinatorAndDeselectedContextsAreRetained() throws {
    let preferences = try #require(UserDefaults(suiteName: "CraftRootTests-\(UUID().uuidString)"))
    let shell = ShellStore(preferences: preferences), viewer = ViewerStore(), factory = RecordingRootFactory()
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }),
                                     selectionStore: TransientSidebarSelectionStore(.session("first")))
    let runtime = RootRuntimeFixture(); runtime.coordinator = coordinator
    viewer.prepareContext = { [runtime] context in
        context.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: runtime)
        if let model = context.workspaceViewModel { coordinator.bindWorkspace(model, context: context, runtime: runtime) }
    }
    runtime.onActivate = { destination in
        if case .session(let id) = destination { _ = viewer.select(id: "task:\(id)", url: "", title: id) } else { viewer.deactivate() }
    }
    func placeholder(_ id: String) -> Bool { if case .session(id, _) = coordinator.root { true } else { false } }
    func workspace(_ context: WorkspaceContext) -> Bool {
        coordinator.root == coordinator.workspaceCoordinator(for: context).map(Destination.sessionWorkspaceCoordinator)
    }
    let model = coordinator.makeRoot(factory: factory, runtime: runtime, shell: shell, viewer: viewer)
    // Selected before its context exists: the placeholder, until the viewer activates it.
    #expect(placeholder("first"))
    let first = viewer.select(id: "task:first", url: "", title: "First")
    let document = try #require(first.openFile("/tmp/Retained.swift"))
    #expect(workspace(first))
    model.select(.session("second"))
    let second = try #require(viewer.contexts["task:second"])
    #expect(workspace(second) && viewer.contexts.count == 2)
    // Away from every workspace: the selection's own destination, and nothing is dropped.
    model.select(.overview)
    #expect(coordinator.root == .unavailable(title: "Overview", message: "Connect to load the dashboard."))
    #expect(viewer.contexts["task:first"] === first && first.activeDocument === document && viewer.contexts["task:second"] === second)
    // Back: the same coordinator, not a new one.
    let retained = coordinator.workspaceCoordinator(for: first)
    model.select(.session("first"))
    #expect(workspace(first) && coordinator.workspaceCoordinator(for: first) === retained)
    viewer.deactivate()
    runtime.state.projects = [Project(id: "p", name: "Native Project", repo: "", color: nil, workspace: "/tmp")]
    runtime.state.selection = .project("p")
    #expect(model.title == "Native Project")
    runtime.state.sessions = [WorkspaceSession(id: "s", projectId: "p", workspace: "/tmp", worktree: "/tmp/worktree", title: "Title",
        branch: "feature", url: "", createdAt: nil, pinned: true)]
    runtime.state.selection = .session("s")
    runtime.state.pinnedIDs = ["s"]
    #expect(model.title == "worktree" && model.pinnedIDs == ["s"])
    #expect(model.session("s")?.id == "s")
    runtime.state.sessions = []
    #expect(model.session("s") == nil)
    runtime.state.selection = .tab("file:///tmp/private")
    #expect(model.browserAddress("file:///tmp/private") == nil)
    #expect(model.browserAddress("https://example.com")?.host == "example.com")
}

@MainActor @Test func sidebarSelectionPreservesExistingJSONFormatAndIgnoresCorruption() throws {
    let suite = "CraftSelectionTests-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let selection = SidebarDestination.tab("https://example.test/a?q=one%20two")
    preferences.set(try JSONEncoder().encode(selection), forKey: "sidebar.selection")
    let storage = UserDefaultsSidebarSelectionStore(preferences: preferences)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), selectionStore: storage)
    #expect(coordinator.selection == selection)
    coordinator.navigate(to: .project("p"))
    #expect(storage.load() == .project("p"))
    preferences.set(Data("corrupt".utf8), forKey: "sidebar.selection")
    let restored = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }), selectionStore: storage)
    #expect(restored.selection == .overview)
}

@MainActor @Test func closingTheTabInViewSelectsItsSidebarNeighbour() {
    let tabs = ["a", "b", "c"]
    #expect(AppViewModel.destination(closing: "a", among: tabs) == .tab("b"))
    #expect(AppViewModel.destination(closing: "b", among: tabs) == .tab("c"))
    #expect(AppViewModel.destination(closing: "c", among: tabs) == .tab("b"))
    #expect(AppViewModel.destination(closing: "a", among: ["a"]) == .overview)
    // A tab the sidebar does not list (its URL belongs to a session) is never the neighbour.
    #expect(AppViewModel.destination(closing: "a", among: ["a", "c"]) == .tab("c"))
    #expect(AppViewModel.destination(closing: "missing", among: tabs) == .overview)
}


/// A session row's right-click Remove Session asks with the same system confirmation the
/// workspace toolbar does, without the session having to be open. An unknown id asks nothing.
@MainActor @Test(.timeLimit(.minutes(1))) func sidebarRemoveSessionAsksForConfirmation() async throws {
    let preferences = try #require(UserDefaults(suiteName: "CraftRootTests-\(UUID().uuidString)"))
    let shell = ShellStore(preferences: preferences), viewer = ViewerStore()
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }),
                                     selectionStore: TransientSidebarSelectionStore(.overview))
    let runtime = RootRuntimeFixture(); runtime.coordinator = coordinator
    runtime.state.sessions = [WorkspaceSession(id: "s", projectId: "p", workspace: "/tmp", worktree: "/tmp/worktree",
        title: "Title", branch: "feature", url: "", createdAt: nil, pinned: false)]
    let model = coordinator.makeRoot(factory: RecordingRootFactory(), runtime: runtime, shell: shell, viewer: viewer)
    model.removeSession("missing")
    #expect(runtime.removalRequests == ["missing"] && coordinator.removal == nil)
    model.removeSession("s")
    let request = try #require(coordinator.removal)
    #expect(runtime.removalRequests == ["missing", "s"])
    // Nothing is asked until the worktree has been checked, and nothing else may present meanwhile.
    #expect(request.phase == .preparing && !coordinator.canPresent)
    for _ in 0..<500 where coordinator.removal?.phase == .preparing { await Task.yield() }
    #expect(coordinator.removal?.phase == .confirming && coordinator.removal?.id == request.id)
    #expect(coordinator.removal?.model.promptTitle == "Forget this session?")
    // Modal: a second request while the dialog is up is refused.
    model.removeSession("s")
    #expect(coordinator.removal?.id == request.id && runtime.removalRequests == ["missing", "s"])
    coordinator.cancelRemoval(id: request.id)
    #expect(coordinator.removal == nil && coordinator.removalFailure == nil && coordinator.canPresent)
}
