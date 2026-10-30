import AppKit
import SwiftUI

// The chrome around the outline: a footer, below a divider, that is the Settings button. The activity capsule is in
// the toolbar before the sidebar's toggle, as a bell (`ActivityToolbarItem`). New Project is File → New Project
// and New Task's project picker. The outline itself starts at the top of the column.
struct SidebarView: View {
    let viewModel: RootViewModel

    var body: some View {
        VStack(spacing: 0) {
            CocoaSidebar(entries: viewModel.entries, selection: viewModel.sidebarSelection,
                         pinnedIDs: viewModel.pinnedIDs, forkableIDs: viewModel.forkableIDs, sessionShortcuts: viewModel.sessionShortcuts,
                         onSelect: viewModel.select, onTogglePin: viewModel.togglePin,
                         onNewTask: viewModel.newTask(in:),
                         onMoveProject: viewModel.moveProject, onMoveSession: viewModel.moveSession, onMovePinned: viewModel.movePinned,
                         onRemoveSession: viewModel.removeSession,
                         onRenameSession: viewModel.renameSession, onForkSession: viewModel.forkSession,
                         onReattachSession: viewModel.reattachSession,
                         onFocusSession: viewModel.focusSession,
                         gitClientLabel: viewModel.gitClientLabel, onOpenGitClient: viewModel.openGitClient,
                         onRenameChat: viewModel.renameChat(_:to:),
                         onDeleteChat: viewModel.deleteChat(_:))

            Divider()
            SettingsFooterButton(action: viewModel.openSettings)
        }
    }
}

/// The footer, below its divider: the whole area is Settings, its gear and its name, lit under the
/// pointer in the outline's hover colour.
private struct SettingsFooterButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: SidebarPalette.text2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                // The whole area below the divider takes the click and lights, edge to edge and down
                // to the window's foot.
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(hovered ? Color(nsColor: SidebarPalette.hover) : .clear, ignoresSafeAreaEdges: .bottom)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Settings")
    }
}
