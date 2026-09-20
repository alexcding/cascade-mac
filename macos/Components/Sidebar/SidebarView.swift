import AppKit
import SwiftUI

// The chrome around the outline: a footer of round glass buttons — New Project on the left, the
// activity bell and Settings (gear only) on the right. The outline itself starts at the top of the column.
struct SidebarView: View {
    let viewModel: RootViewModel
    @State private var showingActivity = false

    var body: some View {
        VStack(spacing: 0) {
            CocoaSidebar(entries: viewModel.entries, selection: viewModel.selection,
                         pinnedIDs: viewModel.pinnedIDs,
                         onSelect: viewModel.select, onTogglePin: viewModel.togglePin,
                         onNewSession: viewModel.newSession(in:), onCloseTab: viewModel.closeTab, onNewTab: viewModel.newTab, onMoveTab: viewModel.moveTab,
                         onMoveProject: viewModel.moveProject, onMoveSession: viewModel.moveSession, onMovePinned: viewModel.movePinned,
                         onTogglePinTab: viewModel.togglePinTab, onRemoveSession: viewModel.removeSession,
                         gitClientLabel: viewModel.gitClientLabel, onOpenGitClient: viewModel.openGitClient)

            HStack(spacing: 6) {
                SidebarAppButton(icon: "plus", label: "New Project", help: "New Project") { viewModel.newProject() }
                    .disabled(!viewModel.canCreateProject)
                Spacer()
                SidebarAppButton(icon: "bell", label: "Today's activity", help: "Today's activity") { showingActivity.toggle() }
                    .popover(isPresented: $showingActivity, arrowEdge: .top) {
                        if let today = viewModel.todayActivity {
                            TodayActivityPopover(model: today, showAllEvents: {
                                showingActivity = false
                                viewModel.openActivity()
                            }, dismiss: { showingActivity = false })
                        }
                    }
                    .onChange(of: showingActivity) { _, open in viewModel.todayActivity?.setVisible(open) }
                SidebarAppButton(icon: "gearshape", label: "Settings", help: "Settings") { viewModel.openSettings() }
            }
            .glassIconButtons()
            .foregroundStyle(Color(nsColor: SidebarPalette.text2))
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 250, max: 420)
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
