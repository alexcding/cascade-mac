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

    /// The deck workspace whose context pane the window shows as its inspector column, if any.
    var inspectorWorkspace: SessionWorkspaceCoordinator? {
        shownDeckWorkspace.flatMap { $0.model.showsInspector ? $0 : nil }
    }
}
