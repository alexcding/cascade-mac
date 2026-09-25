import SwiftUI

/// Hosts the dashboard and owns its toolbar: the tabs where a page title would sit, with the
/// dashboard's one search field filling the trailing side. My Tickets pushes over the home screen
/// as the Tickets tab. The search is global: while it holds text its results stand in for
/// whichever page is up, and clearing it shows that page again.
struct DashboardCoordinatorView: View {
    @Bindable var coordinator: DashboardCoordinator

    var body: some View {
        let pushed = coordinator.path.last
        let model = coordinator.model
        // The page stays underneath while searching, hidden rather than torn down, so clearing the
        // search returns to it where it was left, scroll position and in-flight opens included.
        ZStack(alignment: .topLeading) {
            (pushed ?? coordinator.root).view()
                .opacity(model.searching ? 0 : 1)
                .allowsHitTesting(!model.searching)
                .accessibilityHidden(model.searching)
            if model.searching { DashboardSearchView(model: model) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            // The tabs stand in for the page title. Tickets is My Tickets, pushed over the home
            // screen, so choosing any other tab from there pops back to it.
            ToolbarItem(placement: .navigation) {
                DashboardTabBar(selection: pushed == nil ? model.tab : .tickets,
                                tickets: model.tickets.available, select: model.selectTab)
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        }
        .searchable(text: Bindable(model).query, placement: .toolbar, prompt: "Search pull requests and tickets")
    }
}
