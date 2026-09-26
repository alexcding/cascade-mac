import SwiftUI

/// The screen's column of the main window (`MainSplitViewController`): the coordinator's `root`
/// destination, or the deck of workspaces, and the app-wide presentations. Which destination that
/// is — a workspace, a screen, a placeholder — is the coordinator's decision; each child coordinator
/// view owns its own insets. The sidebar and the context pane are the window's other columns, and
/// the toolbar is described by the destinations (`AppCoordinator.windowToolbar`).
struct AppCoordinatorView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        ZStack {
            let shown = coordinator.shownDeckWorkspace
            // A session's workspace, or the terminal's, is built once and kept in the deck, the
            // way a Ghostty tab keeps its window: a switch shows one and hides the last, and
            // nothing is taken down or rebuilt. Anything else — a screen, a sidebar tab — is
            // built from `root` while it is selected, and only then.
            SessionWorkspaceDeck(workspaces: coordinator.deckWorkspaces, shown: shown)
            if shown == nil { coordinator.root.view() }
        }
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            if let error = coordinator.connectionError {
                HStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                    Button("Reconnect", action: coordinator.reconnect)
                }
                .padding(.horizontal, 28).padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: Binding(get: { coordinator.sheet }, set: { value in
            if value == nil, let sheet = coordinator.sheet { coordinator.dismissSheet(id: sheet.id) }
        })) { sheet in
            AppCoordinatorSheetView(sheet: sheet, cancel: { coordinator.dismissSheet(id: sheet.id) })
        }
        .confirmationDialog("Restart this session?", isPresented: Binding(get: { coordinator.restartConfirmation != nil }, set: { value in
            if !value, let request = coordinator.restartConfirmation { coordinator.dismissRestart(id: request.id) }
        }), titleVisibility: .visible) {
            if let request = coordinator.restartConfirmation {
                Button("Restart Session", role: .destructive) { coordinator.confirmRestart(id: request.id) }
            }
        } message: {
            Text("This stops the session’s shell and any command it is running. The worktree is kept. The agent resumes its saved conversation when an ID is available.")
        }
        // Removal asks with the system's own confirmation, once its plan is known.
        .confirmationDialog(coordinator.removal?.model.promptTitle ?? "", isPresented: Binding(get: {
            coordinator.removal?.phase == .confirming
        }, set: { value in
            if !value, let request = coordinator.removal { coordinator.cancelRemoval(id: request.id) }
        }), titleVisibility: .visible) {
            if let request = coordinator.removal {
                Button(request.model.confirmLabel, role: .destructive) { coordinator.confirmRemoval(id: request.id) }
            }
        } message: {
            if let request = coordinator.removal { Text(request.model.promptMessage) }
        }
        .alert("The session could not be removed", isPresented: Binding(get: { coordinator.removalFailure != nil }, set: { value in
            if !value, let failure = coordinator.removalFailure { coordinator.dismissRemovalFailure(id: failure.id) }
        }), presenting: coordinator.removalFailure) { _ in
        } message: { failure in
            Text(failure.message)
        }
    }
}
