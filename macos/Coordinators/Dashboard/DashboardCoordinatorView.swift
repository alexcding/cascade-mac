import SwiftUI

/// Hosts the dashboard and owns its toolbar: the tabs where a page title would sit, with the
/// dashboard's own `.searchable` field filling the trailing side. My Tickets pushes over the home
/// screen as the Tickets tab.
struct DashboardCoordinatorView: View {
    @Bindable var coordinator: DashboardCoordinator

    var body: some View {
        let pushed = coordinator.path.last
        (pushed ?? coordinator.root).view()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The tabs replaced the back button; its Command-[ stays, from a button nobody sees.
            .background {
                if pushed != nil {
                    Button("Back to Dashboard") { coordinator.model.closeTickets() }
                        .keyboardShortcut("[", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                        .accessibilityIdentifier("dashboard-back")
                }
            }
            .toolbar {
                // The tabs stand in for the page title. Tickets is My Tickets, pushed over the home
                // screen, so choosing any other tab from there pops back to it.
                ToolbarItem(placement: .navigation) {
                    DashboardTabBar(selection: pushed == nil ? coordinator.model.tab : .tickets,
                                    tickets: coordinator.model.ticketsAvailable, select: coordinator.model.selectTab)
                }
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            }
    }
}
