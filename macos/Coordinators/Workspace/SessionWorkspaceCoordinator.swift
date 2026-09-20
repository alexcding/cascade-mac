import Foundation
import Observation

/// One per opened workspace context: the terminal session or page it shows, and the
/// actions its view model emits. Tab selection is handled here; everything that needs
/// the runtime or a sheet is forwarded to the parent as `.workspace`.
@MainActor @Observable final class SessionWorkspaceCoordinator: Coordinatable {
    var root: Destination = .none
    var path: [Destination] = []

    @ObservationIgnored var action: ((Action) -> Void)?

    let model: SessionWorkspaceViewModel
    let context: WorkspaceContext

    init(model: SessionWorkspaceViewModel, context: WorkspaceContext) {
        self.model = model
        self.context = context
        root = .sessionWorkspace(model, context)
        model.onAction = { [weak self] in self?.handle($0) }
    }

    func makeDestination(for route: Route) -> Destination { .none }

    func handle(_ action: Action) { self.action?(action) }

    func handle(_ action: SessionWorkspaceViewModel.Action) {
        self.action?(.workspace(action, context))
    }
}
