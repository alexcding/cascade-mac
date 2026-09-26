import SwiftUI

/// Hosts a sidebar tab's workspace in the screen's column; its toolbar is described by
/// `SessionWorkspaceToolbar`. A session's workspace, or the terminal's, lives in
/// `SessionWorkspaceDeck` instead, which keeps every open one built between visits
/// (`AppCoordinator.deckWorkspaces`).
struct SessionWorkspaceCoordinatorView: View {
    @Bindable var coordinator: SessionWorkspaceCoordinator

    var body: some View {
        coordinator.root.view()
    }
}
