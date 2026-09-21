import Foundation

extension AppViewModel: RootCoordinating, ProjectCoordinating {
    func rootState() -> RootState {
        RootState(selection: selection, entries: sidebarEntries, pinnedIDs: sidebarPinnedIDs, projects: projects, sessions: sessions, tabs: visibleTabs,
                  projectModels: projectModels, dashboard: dashboard, logs: logs, todayActivity: todayActivity, settings: settings, error: coordinator.routingError ?? error,
                  canCreateProject: canPerform(.newProject),
                  canCreateSession: canPerform(.newSession), canRefresh: canPerform(.refresh),
                  gitClientLabel: workspaceLaunch.gitClientLabel(shell.gitClient))
    }
    func performRootCommand(_ command: ShellCommand) { perform(command) }
    func newSession(in projectID: String) { presentNewSession(in: projectID, pageURL: nil) }

    /// Sidebar right-click Remove Session. Same sheet the workspace toolbar opens, so a session
    /// can be removed without first opening it.
    func makeSessionRemoval(_ id: String) -> SessionRemovalViewModel? {
        guard let session = sessions.first(where: { $0.id == id }), !changingSessions.contains(id) else { return nil }
        return removalModel(for: session)
    }

    /// Sidebar right-click "Open in <git client>": opens the session's worktree without opening it.
    func openGitClient(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }), !changingSessions.contains(id) else { return }
        Task {
            await workspaceLaunch.openGitClient(session: session, id: shell.gitClient, custom: shell.gitClientCommand)
            // The launch banner belongs to the session's own screen. From the sidebar that
            // screen may not be showing, so the failure is reported where the user is instead.
            guard viewer.active?.id != "task:\(id)", let message = workspaceLaunch.takeError(sessionID: id) else { return }
            let failure = "Could not open \(session.label): \(message)"
            if let context = viewer.active { context.error = failure } else { reportRootError(failure) }
        }
    }

    /// The AppKit delegate forwards delivery here; parsing and navigation stay in the coordinator.
    @discardableResult public func handleOpenURL(_ url: URL) -> Bool { coordinator.handle(url: url) }
    public func resumePendingDeepLink() { coordinator.schedulePendingDeepLink() }
}
