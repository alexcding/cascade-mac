import SwiftUI

extension AppCoordinator {
    /// The main window's toolbar: the shown deck workspace's, or else the root destination's. Read
    /// under observation by `MainToolbarController`, so whatever it reads redraws the toolbar.
    var windowToolbar: WindowToolbar {
        var toolbar = shownDeckWorkspace.map { SessionWorkspaceToolbar(context: $0.context, model: $0.model).toolbar }
            ?? root.windowToolbar
        // Today's activity is the app's, in the sidebar's section before its toggle over every
        // screen: its model and the way to Activity are the root's, which no screen knows of.
        if let rootModel {
            toolbar.sidebar = [.init("today-activity") { TodayActivityButton(viewModel: rootModel) }]
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
