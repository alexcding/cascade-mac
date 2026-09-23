import Foundation

extension AppViewModel: WorkspaceCoordinating {
    func updateWorkspaceReviewState() {
        for context in viewer.contexts.values { context.workspaceViewModel?.reviewStateChanged() }
    }

    func updateWorkspaceDocumentState() {
        for context in viewer.contexts.values { context.workspaceViewModel?.documentStateChanged() }
    }
    func updateWorkspaceTerminalState() {
        for context in viewer.contexts.values { context.workspaceViewModel?.terminalStateChanged() }
    }

    /// Starts the session worktree's IDE preparation, for the session being opened and no other.
    /// Lazy on purpose: warming every session a workflow creates would run several package
    /// resolves at once over one SwiftPM cache, and most of them for a checkout nobody is about
    /// to build. Creating a session selects it, so the one being worked on is always warmed.
    /// The backend coalesces, so selecting it again costs nothing.
    func warmIDE(for session: WorkspaceSession) {
        guard let project = projects.first(where: { $0.id == session.projectId }) else { return }
        ideWarmup.warm(worktree: session.worktree, ide: project.ide ?? "", target: project.ideTarget ?? "")
    }

    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState {
        guard viewer.contexts[context.id] === context else { return SessionWorkspaceState() }
        let session = sessions.first { "task:\($0.id)" == context.id }
        let project = session.flatMap { session in projects.first { $0.id == session.projectId } }
        let base = session.flatMap { session in dashboard?.prs.projects.flatMap(\.prs).first { $0.url == session.url }?.baseRefName }
        let title: String
        if context.id == "scratch" { title = "Terminal" }
        else if let session { title = session.label }
        else { title = visibleTabs.first { "tab:\($0.id)" == context.id }?.displayTitle ?? "Tab" }
        return SessionWorkspaceState(session: session, project: project, terminal: terminals[context.id],
            buildTerminal: terminals["build:\(context.sourceURL)"], build: buildModels[context.id],
            history: historyModels[context.id], diff: diffModels[context.id], workflow: workflowModel(in: context),
            appearance: shell.appearance, documentFont: shell.font(.diff), editorStyle: shell.editorStyle, terminalStyle: shell.terminalStyle, connected: connection == "Connected",
            changingSession: session.map { changingSessions.contains($0.id) } ?? false,
            removingSession: session.map { isRemoving($0.id) } ?? false,
            openingExternal: workspaceLaunch.opening.contains(context.id), canPresent: coordinator.canPresent,
            canCreateSession: canPerform(.newSession), title: title,
            offersPageSession: offersPageSession(in: context), offersNewTab: !context.holdsOnePage, editorID: project?.ide,
            editorLabel: workspaceLaunch.editorLabel(project),
            launchError: workspaceLaunch.errors[context.id],
            reviewBase: base,
            warmup: ideWarmup.state(for: session?.worktree ?? ""))
    }

    /// Create Session belongs in the toolbar only where the page decides the session: a GitHub PR
    /// or Jira ticket tab in view whose repository or Jira key maps to a local project. A plain
    /// page, or one no project claims, gets nothing.
    private func offersPageSession(in context: WorkspaceContext) -> Bool {
        guard case .tab(let id) = selection, context.id == "tab:\(id)", let url = tabURL(id) else { return false }
        return Self.pageProject(url, in: projects) != nil
    }

    func ownsWorkspace(_ context: WorkspaceContext) -> Bool {
        viewer.contexts[context.id] === context && viewer.active === context
    }

    func makeWorkspaceBuild(in context: WorkspaceContext) -> BuildWorkspaceViewModel? {
        guard ownsWorkspace(context), let session = workspaceState(in: context).session else { return nil }
        return buildModel(for: session, context: context)
    }

    func makeWorkspaceRemoval(in context: WorkspaceContext) -> SessionRemovalViewModel? {
        guard ownsWorkspace(context), let session = workspaceState(in: context).session else { return nil }
        return removalModel(for: session)
    }

    func restartWorkspaceSession(_ id: String, in context: WorkspaceContext) {
        guard viewer.contexts[context.id] === context,
              let current = sessions.first(where: { $0.id == id }), !changingSessions.contains(id) else { return }
        restartSession(current)
    }

    func performWorkspaceOperation(_ action: WorkspaceOperation, in context: WorkspaceContext) {
        guard ownsWorkspace(context) else { return }
        let state = workspaceState(in: context)
        switch action {
        case .openEditor:
            if let session = state.session {
                Task { await workspaceLaunch.openEditor(session: session, project: state.project) }
            }
        case .createSession(let agent): newSession(agent: agent)
        case .openFile: viewer.openFile(in: context, directory: state.session?.worktree)
        case .changes: if let session = state.session { showChanges(for: session, context: context) }
        case .openTerminal: openTerminal()
        case .toggleEditorPreview: shell.setEditorMinimap(!shell.editorStyle.showMinimap)
        case .hookSettings: openWorkflowHookSettings()
        case .prepareChanges: if let session = state.session { prepareChanges(for: session, context: context) }
        }
    }
}
