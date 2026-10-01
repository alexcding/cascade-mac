import AppKit
import SwiftUI

// The outline, from the top of the column to its bottom: the rows of the mode the rail picked
// (`SidebarRail`), Home's or Browser's, never both. New Project is the "Projects" heading's hover
// "+" (`SidebarEntry.Role.projectsHeader`). Settings is the rail's; the activity bell leads the
// toolbar's sidebar section (`AppCoordinator.windowToolbar`).
struct SidebarView: View {
    let viewModel: RootViewModel
    var mode = SidebarMode.home

    var body: some View {
        CocoaSidebar(entries: viewModel.entries.filter { $0.mode == mode }, list: mode.rawValue, selection: viewModel.selection,
                     pinnedIDs: viewModel.pinnedIDs, forkableIDs: viewModel.forkableIDs, sessionShortcuts: viewModel.sessionShortcuts,
                     onSelect: viewModel.select, onTogglePin: viewModel.togglePin,
                     onCloseTab: viewModel.closeTab, onNewTab: viewModel.newTab, onNewProject: viewModel.newProject, onMoveTab: viewModel.moveTab,
                     onMoveProject: viewModel.moveProject, onMoveSession: viewModel.moveSession, onMovePinned: viewModel.movePinned,
                     onTogglePinTab: viewModel.togglePinTab, onRemoveSession: viewModel.removeSession,
                     onRenameSession: viewModel.renameSession, onForkSession: viewModel.forkSession,
                     onFocusSession: viewModel.focusSession,
                     gitClientLabel: viewModel.gitClientLabel, onOpenGitClient: viewModel.openGitClient)
    }
}
