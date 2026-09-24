import Foundation

@MainActor protocol WorkspaceCoordinating: WorkspaceServing {
    func ownsWorkspace(_ context: WorkspaceContext) -> Bool
    func performWorkspaceOperation(_ operation: WorkspaceOperation, in context: WorkspaceContext)
    func makeWorkspaceBuild(in context: WorkspaceContext) -> BuildWorkspaceViewModel?
    func makeWorkspaceRemoval(in context: WorkspaceContext) -> SessionRemovalViewModel?
    func restartWorkspaceSession(_ id: String, in context: WorkspaceContext)
}

extension AppCoordinator {
    @discardableResult
    func bindWorkspace(_ model: SessionWorkspaceViewModel, context: WorkspaceContext,
                       runtime: any WorkspaceCoordinating) -> SessionWorkspaceCoordinator {
        defer { refreshRoot() }
        pruneWorkspaces()
        if let existing = workspaceCoordinator(for: context), existing.model === model { return existing }
        workspaceCoordinators.removeAll { $0.context === context }
        let child = SessionWorkspaceCoordinator(model: model, context: context)
        workspaceRuntime = runtime
        child.action = { [weak self] in self?.handle($0) }
        workspaceCoordinators.append(child)
        return child
    }

    func workspaceCoordinator(for context: WorkspaceContext) -> SessionWorkspaceCoordinator? {
        workspaceCoordinators.first { $0.context === context }
    }

    /// The workspaces the detail column keeps alive (`SessionWorkspaceDeck`): every live one but a
    /// sidebar tab's, whose page-only panel draws into the title-bar zone and stays a destination.
    var deckWorkspaces: [SessionWorkspaceCoordinator] { workspaceCoordinators.filter { !$0.context.holdsOnePage } }

    /// The one of them on screen, when the selection shows it.
    var shownDeckWorkspace: SessionWorkspaceCoordinator? {
        guard case .sessionWorkspaceCoordinator(let child) = root, !child.context.holdsOnePage else { return nil }
        return child
    }

    /// Drops coordinators whose contexts the viewer no longer holds.
    func pruneWorkspaces() {
        guard let viewer = rootModel?.viewer else { return }
        let live = viewer.contexts.values
        func stale(_ child: SessionWorkspaceCoordinator) -> Bool { !live.contains { $0 === child.context } }
        // `removeAll` writes even when it removes nothing, and this runs several times per sidebar
        // switch; the Product menu reads this list, so only a real removal may touch it.
        guard workspaceCoordinators.contains(where: stale) else { return }
        workspaceCoordinators.removeAll(where: stale)
    }

    func handleWorkspace(_ action: SessionWorkspaceViewModel.Action, in context: WorkspaceContext) {
        guard let runtime = workspaceRuntime, runtime.ownsWorkspace(context),
              workspaceCoordinator(for: context) != nil else { return }
        switch action {
        case .selectTab(let id):
            guard canPresent else { return }
            // The blank file tab is not a saved tab; selecting it is opening it again.
            if id == WorkspaceContext.blankFileID { context.newFileTab() }
            else if let tab = context.tab(id) { context.select(tab) }
        case .newTab:
            guard canPresent else { return }
            context.openBlankPage()
        case .newFileTab:
            guard canPresent else { return }
            context.newFileTab()
        case .closeTab(let id):
            guard canPresent else { return }
            if id == WorkspaceContext.blankFileID { context.closeBlankFileTab() }
            else if let tab = context.tab(id) { context.close(tab) }
        case .moveTab(let id, let target):
            guard canPresent else { return }
            context.moveTab(id, before: target)
        case .reopen(let id):
            guard canPresent, let visit = context.visits.first(where: { $0.id == id }) else { return }
            switch visit {
            case .page(let page): context.open(page.url, title: page.title)
            case .file(let file): context.openFile(file.path)
            }
        case .operation(let operation): runtime.performWorkspaceOperation(operation, in: context)
        case .run: runBuild { runtime.makeWorkspaceBuild(in: context) }
        case .configureRun: presentBuild(purpose: .configure) { runtime.makeWorkspaceBuild(in: context) }
        case .remove: presentRemoval { runtime.makeWorkspaceRemoval(in: context) }
        case .restart:
            guard let session = runtime.workspaceState(in: context).session else { return }
            presentRestart { [weak context, weak runtime] in
                guard let context else { return }
                runtime?.restartWorkspaceSession(session.id, in: context)
            }
        }
    }
}
