import Foundation

extension AppCoordinator {
    /// The main window's toolbar: the shown deck workspace's, or else the root destination's. Read
    /// under observation by `MainToolbarController`, so whatever it reads redraws the toolbar.
    var windowToolbar: WindowToolbar {
        if let shown = shownDeckWorkspace {
            return SessionWorkspaceToolbar(context: shown.context, model: shown.model).toolbar
        }
        return root.windowToolbar
    }

    /// The screen on show whose pane the window's inspector column holds: the deck workspace's
    /// context pane, or the project's settings. The column is open while its `showsInspector` is.
    var inspectorOwner: (any InspectorPresenting)? {
        if let shown = shownDeckWorkspace { return shown.model }
        return shownProject?.model
    }

    /// The project on screen, when the root shows one.
    var shownProject: ProjectCoordinator? {
        guard case .projectCoordinator(let child) = root else { return nil }
        return child
    }
}
