import SwiftUI

struct ChatCoordinatorView: View {
    @Bindable var coordinator: ChatCoordinator

    var body: some View {
        coordinator.root.view()
    }
}
