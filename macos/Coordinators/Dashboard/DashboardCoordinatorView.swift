import SwiftUI

/// Hosts Projects, one page whose tabs sit at its top (`Destination.windowToolbar` titles it).
struct DashboardCoordinatorView: View {
    @Bindable var coordinator: DashboardCoordinator

    var body: some View {
        (coordinator.path.last ?? coordinator.root).view()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
