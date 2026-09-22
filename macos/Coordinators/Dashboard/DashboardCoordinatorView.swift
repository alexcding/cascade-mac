import SwiftUI

/// Hosts the dashboard and owns its toolbar: the page title, with the dashboard's own
/// `.searchable` field filling the trailing side. My Tickets pushes over the home screen and
/// takes the title, with a back button to return.
struct DashboardCoordinatorView: View {
    @Bindable var coordinator: DashboardCoordinator

    var body: some View {
        let pushed = coordinator.path.last
        (pushed ?? coordinator.root).view()
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                if pushed != nil {
                    ToolbarItem(placement: .navigation) {
                        Button { coordinator.model.closeTickets() } label: { Image(systemName: "chevron.left") }
                            .help("Back to Dashboard").accessibilityLabel("Back to Dashboard")
                            .accessibilityIdentifier("dashboard-back")
                            .keyboardShortcut("[", modifiers: .command)
                    }
                }
                PageTitleToolbarItem(title: pushed == nil ? "Dashboard" : "My Tickets")
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            }
    }
}
