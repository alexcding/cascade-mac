import SwiftUI

extension AppCoordinator {
    /// The main window's toolbar: the shown deck workspace's, or else the root destination's. Read
    /// under observation by `MainToolbarController`, so whatever it reads redraws the toolbar.
    var windowToolbar: WindowToolbar {
        var toolbar = shownDeckWorkspace.map { SessionWorkspaceToolbar(context: $0.context, model: $0.model).toolbar }
            ?? root.windowToolbar
        // Only while there is a Today menu for it to open.
        if let model = rootModel, model.todayActivity != nil, !sidebarCollapsed {
            // Before the sidebar's toggle on every screen, while the sidebar is open.
            toolbar.sidebar = [WindowToolbarItem("activity", priority: .high) {
                ActivityToolbarItem(viewModel: model) { [weak self, weak model] entry in self?.openActivityLink(entry, root: model) }
            }]
        }
        return toolbar
    }

    /// A Today row's link: a web address only, opened beside the session on show, else as a notice's
    /// click opens it — its page's session or its project's Start.
    private func openActivityLink(_ entry: LogEntry, root: RootViewModel?) {
        guard let url = entry.link.flatMap(safeWebURL) else { return }
        if shownDeckWorkspace?.model.openLink(url) == true { return }
        let host = url.host?.lowercased() ?? ""
        let github = host == "github.com" || host.hasSuffix(".github.com")
        root?.openActivityLink(OpenPageRequest(url: url.absoluteString, kind: github ? "github" : "web", title: entry.title))
    }

    /// The deck workspace whose context pane the window shows as its inspector column, if any.
    var inspectorWorkspace: SessionWorkspaceCoordinator? {
        shownDeckWorkspace.flatMap { $0.model.showsInspector ? $0 : nil }
    }
}
