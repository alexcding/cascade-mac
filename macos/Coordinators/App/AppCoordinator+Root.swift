import Foundation

@MainActor protocol RootCoordinating: RootServing {
    func activateRootDestination()
    func performRootCommand(_ command: ShellCommand)
    func reconnect() async
    func togglePin(_ id: String)
    func openTerminal()
    func openRootBrowser(_ url: URL)
    func newSession(in projectID: String)
    func closeTab(_ url: String)
    func newTab()
    func moveTab(_ id: String, before: String?)
    func moveProject(_ id: String, before: String?)
    func moveSession(_ id: String, before: String?)
    func movePinned(_ id: String, before: String?)
    func togglePinTab(_ id: String)
    func makeSessionRemoval(_ id: String) -> SessionRemovalViewModel?
    func openGitClient(_ id: String)
}

extension RootCoordinating {
    func newSession(in projectID: String) {}
    func newTab() {}
    func moveTab(_ id: String, before: String?) {}
    func moveProject(_ id: String, before: String?) {}
    func moveSession(_ id: String, before: String?) {}
    func movePinned(_ id: String, before: String?) {}
    func togglePinTab(_ id: String) {}
    func makeSessionRemoval(_ id: String) -> SessionRemovalViewModel? { nil }
    func openGitClient(_ id: String) {}
}

extension AppCoordinator {
    func makeRoot(factory: any RootFeatureFactory, runtime: any RootCoordinating,
                  shell: ShellStore, viewer: ViewerStore) -> RootViewModel {
        rootRuntime = runtime
        let bindingID = UUID()
        rootBindingID = bindingID
        let model = factory.root(service: runtime, shell: shell, viewer: viewer)
        model.onAction = { [weak self] action in
            guard let self, rootBindingID == bindingID else { return }
            handle(.root(action))
        }
        // `root` follows the viewer: a workspace selection resolves to its coordinator only
        // once its context is active, and back to the placeholder when that context goes.
        viewer.activeContextChanged = { [weak self] in self?.refreshRoot() }
        viewer.contextRemoved = { [weak self] _ in self?.refreshRoot() }
        rootModel = model
        refreshRoot()
        return model
    }

    func handle(_ action: RootViewModel.Action) {
        switch action {
        case .select(let destination): discardQueuedDeepLink(); navigate(to: destination)
        case .command(let command): rootRuntime?.performRootCommand(command)
        case .togglePin(let id): rootRuntime?.togglePin(id)
        case .newSession(let projectID): rootRuntime?.newSession(in: projectID)
        case .closeTab(let url): rootRuntime?.closeTab(url)
        case .newTab: rootRuntime?.newTab()
        case .moveTab(let id, let before): rootRuntime?.moveTab(id, before: before)
        case .moveProject(let id, let before): rootRuntime?.moveProject(id, before: before)
        case .moveSession(let id, let before): rootRuntime?.moveSession(id, before: before)
        case .movePinned(let id, let before): rootRuntime?.movePinned(id, before: before)
        case .togglePinTab(let id): rootRuntime?.togglePinTab(id)
        case .reconnect: Task { [weak rootRuntime] in await rootRuntime?.reconnect() }
        case .openTerminal: rootRuntime?.openTerminal()
        case .openBrowser(let url): rootRuntime?.openRootBrowser(url)
        case .removeSession(let id): presentRemoval { rootRuntime?.makeSessionRemoval(id) }
        case .openGitClient(let id): rootRuntime?.openGitClient(id)
        }
    }
}
