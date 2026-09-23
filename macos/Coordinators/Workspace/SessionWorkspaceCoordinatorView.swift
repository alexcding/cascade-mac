import SwiftUI

/// Hosts the selected session workspace in the detail column and owns its toolbar. A session's or
/// the terminal's workspace itself lives in the detail column's `SessionWorkspaceDeck`, which keeps
/// every open one alive underneath; this view then only carries the toolbar.
struct SessionWorkspaceCoordinatorView: View {
    @Bindable var coordinator: SessionWorkspaceCoordinator

    var body: some View {
        content
            .toolbar { SessionWorkspaceToolbar(model: coordinator.model) }
            // A page-only tab in browser mode draws its own bar where the toolbar was.
            .toolbarBackground(coordinator.model.fillsTitleBar ? .hidden : .automatic, for: .windowToolbar)
    }

    @ViewBuilder private var content: some View {
        if coordinator.context.holdsOnePage {
            coordinator.root.view()
        } else {
            // Clicks and accessibility go through to the deck's page beneath.
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
