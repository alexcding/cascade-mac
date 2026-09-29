import AppKit
import SwiftUI

// The chrome around the outline: a footer of round glass buttons — the activity bell on the left,
// Settings (gear only) on the right. New Project is the "Projects" heading's hover "+"
// (`SidebarEntry.Role.projectsHeader`). The outline itself starts at the top of the column.
struct SidebarView: View {
    let viewModel: RootViewModel
    @State private var showingActivity = false

    var body: some View {
        VStack(spacing: 0) {
            CocoaSidebar(entries: viewModel.entries, selection: viewModel.selection,
                         pinnedIDs: viewModel.pinnedIDs, forkableIDs: viewModel.forkableIDs, sessionShortcuts: viewModel.sessionShortcuts,
                         onSelect: viewModel.select, onTogglePin: viewModel.togglePin,
                         onCloseTab: viewModel.closeTab, onNewTab: viewModel.newTab, onNewProject: viewModel.newProject, onMoveTab: viewModel.moveTab,
                         onMoveProject: viewModel.moveProject, onMoveSession: viewModel.moveSession, onMovePinned: viewModel.movePinned,
                         onTogglePinTab: viewModel.togglePinTab, onRemoveSession: viewModel.removeSession,
                         onRenameSession: viewModel.renameSession, onForkSession: viewModel.forkSession,
                         onFocusSession: viewModel.focusSession,
                         gitClientLabel: viewModel.gitClientLabel, onOpenGitClient: viewModel.openGitClient)

            HStack(spacing: 6) {
                SidebarAppButton(icon: "bell", label: String(localized: "Today's activity"), help: String(localized: "Today's activity")) { showingActivity.toggle() }
                    .popover(isPresented: $showingActivity, arrowEdge: .top) {
                        if let today = viewModel.todayActivity {
                            TodayActivityPopover(model: today, showAllEvents: {
                                showingActivity = false
                                viewModel.openActivity()
                            }, dismiss: { showingActivity = false })
                        }
                    }
                    .onChange(of: showingActivity) { _, open in viewModel.todayActivity?.setVisible(open) }
                Spacer()
                SidebarAppButton(icon: "gearshape", label: String(localized: "Settings"), help: String(localized: "Settings")) { viewModel.openSettings() }
            }
            .glassIconButtons()
            .foregroundStyle(Color(nsColor: SidebarPalette.text2))
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }
}

/// A footer button: a system symbol at its default size, whose title is its accessibility name. The footer's
/// `glassIconButtons()` gives it the round Liquid Glass look.
private struct SidebarAppButton: View {
    let icon: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .help(help)
    }
}
