import SwiftUI

extension AppCoordinator {
    /// The main window's toolbar: the shown deck workspace's, or else the root destination's. Read
    /// under observation by `MainToolbarController`, so whatever it reads redraws the toolbar.
    var windowToolbar: WindowToolbar {
        if let shown = shownDeckWorkspace {
            return SessionWorkspaceToolbar(context: shown.context, model: shown.model).toolbar
        }
        var toolbar = root.windowToolbar
        // Today's activity is the Dashboard's, beside its search. It is added here rather than in
        // the Dashboard's own description because the bell is the app's: its model and the way to
        // Activity are the root's, which the Dashboard knows nothing of.
        if case .dashboardCoordinator = root, let rootModel {
            toolbar.trailing.insert(.init("today-activity") { TodayActivityButton(viewModel: rootModel) }, at: 0)
        }
        return toolbar
    }

    /// The deck workspace whose context pane the window shows in its pane column, if any.
    var inspectorWorkspace: SessionWorkspaceCoordinator? {
        shownDeckWorkspace.flatMap { $0.model.showsInspector ? $0 : nil }
    }
}

/// The activity bell: today's events in a popover under it, and from there the way to all of them.
private struct TodayActivityButton: View {
    let viewModel: RootViewModel
    @State private var showingActivity = false

    var body: some View {
        Button { showingActivity.toggle() } label: {
            Label(String(localized: "Today's activity"), systemImage: "bell")
        }
        .help(String(localized: "Today's activity"))
        .popover(isPresented: $showingActivity, arrowEdge: .bottom) {
            if let today = viewModel.todayActivity {
                TodayActivityPopover(model: today, showAllEvents: {
                    showingActivity = false
                    viewModel.openActivity()
                }, dismiss: { showingActivity = false })
            }
        }
        .onChange(of: showingActivity) { _, open in viewModel.todayActivity?.setVisible(open) }
    }
}
