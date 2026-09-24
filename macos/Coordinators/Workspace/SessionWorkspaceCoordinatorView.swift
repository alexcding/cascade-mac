import SwiftUI

/// Hosts a sidebar tab's workspace in the detail column and owns its toolbar. A session's
/// workspace, or the terminal's, lives in `SessionWorkspaceDeck` instead, which keeps every
/// open one built between visits (`AppCoordinator.deckWorkspaces`).
struct SessionWorkspaceCoordinatorView: View {
    @Bindable var coordinator: SessionWorkspaceCoordinator

    var body: some View {
        coordinator.root.view()
            .toolbar { SessionWorkspaceToolbar(model: coordinator.model) }
            // A page-only tab in browser mode draws its own bar where the toolbar was.
            .toolbarBackground(coordinator.model.fillsTitleBar ? .hidden : .automatic, for: .windowToolbar)
    }
}
