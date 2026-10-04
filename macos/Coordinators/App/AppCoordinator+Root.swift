import Foundation

@MainActor protocol RootCoordinating: RootServing {
    func activateRootDestination()
    func performRootCommand(_ command: ShellCommand)
    func reconnect() async
    func togglePin(_ id: String)
    func openTerminal()
    func moveProject(_ id: String, before: String?)
    func moveSession(_ id: String, before: String?)
    func movePinned(_ id: String, before: String?)
    func makeSessionRemoval(_ id: String) -> SessionRemovalViewModel?
    func openGitClient(_ id: String)
    func renameSession(_ id: String, to name: String)
    func forkSession(_ id: String)
    func reattachSession(_ id: String)
    func focusSession(_ id: String)
    func newTask(in projectID: String)
    func openProjectSettings(_ projectID: String)
}

extension RootCoordinating {
    func moveProject(_ id: String, before: String?) {}
    func moveSession(_ id: String, before: String?) {}
    func movePinned(_ id: String, before: String?) {}
    func makeSessionRemoval(_ id: String) -> SessionRemovalViewModel? { nil }
    func openGitClient(_ id: String) {}
    func renameSession(_ id: String, to name: String) {}
    func forkSession(_ id: String) {}
    func reattachSession(_ id: String) {}
    func focusSession(_ id: String) {}
    func newTask(in projectID: String) {}
    func openProjectSettings(_ projectID: String) {}
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
        case .moveProject(let id, let before): rootRuntime?.moveProject(id, before: before)
        case .moveSession(let id, let before): rootRuntime?.moveSession(id, before: before)
        case .movePinned(let id, let before): rootRuntime?.movePinned(id, before: before)
        case .reconnect: Task { [weak rootRuntime] in await rootRuntime?.reconnect() }
        case .openTerminal: rootRuntime?.openTerminal()
        case .removeSession(let id): presentRemoval { rootRuntime?.makeSessionRemoval(id) }
        case .openGitClient(let id): rootRuntime?.openGitClient(id)
        case .renameSession(let id, let name): rootRuntime?.renameSession(id, to: name)
        case .forkSession(let id): rootRuntime?.forkSession(id)
        case .reattachSession(let id): rootRuntime?.reattachSession(id)
        case .focusSession(let id): rootRuntime?.focusSession(id)
        case .newTask(let id): rootRuntime?.newTask(in: id)
        case .projectSettings(let id): rootRuntime?.openProjectSettings(id)
        }
    }
}
