import SwiftUI

/// Hosts the Automation screen. It has no pushed pages, so this is its root and nothing more.
struct AutomationCoordinatorView: View {
    @Bindable var coordinator: AutomationCoordinator

    var body: some View {
        if case .automation(let model) = coordinator.root {
            AutomationView(model: model)
        }
    }
}
