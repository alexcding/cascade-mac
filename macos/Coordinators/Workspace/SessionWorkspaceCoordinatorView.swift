import SwiftUI

/// Hosts the selected session workspace in the detail column and owns its toolbar.
struct SessionWorkspaceCoordinatorView: View {
    @Bindable var coordinator: SessionWorkspaceCoordinator

    var body: some View {
        coordinator.root.view()
            .toolbar { SessionWorkspaceToolbar(model: coordinator.model) }
            // A page-only tab in browser mode draws its own bar where the toolbar was.
            .toolbarBackground(coordinator.model.fillsTitleBar ? .hidden : .automatic, for: .windowToolbar)
    }
}
