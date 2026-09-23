import Foundation
import Observation

@MainActor protocol AutomationFeatureFactory {
    func automation() -> AutomationViewModel
}

@MainActor struct NativeAutomationFeatureFactory: AutomationFeatureFactory {
    func automation() -> AutomationViewModel { AutomationViewModel() }
}

@MainActor @Observable final class AutomationCoordinator: Coordinatable {
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: AutomationViewModel
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }

    init(model: AutomationViewModel) {
        self.model = model
        root = .automation(model)
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination { .none }
    func handle(_ action: Action) { self.action?(action) }
    /// Saves and deletes are the model's own business; nothing above it needs to know yet.
    func handle(_ action: AutomationViewModel.Action) {
        guard !retired, isOwned() else { return }
    }
    func retire() { retired = true; isOwned = { false }; canPresent = { false }; model.retire() }
}

extension AppCoordinator {
    @discardableResult func installAutomation(_ model: AutomationViewModel) -> AutomationCoordinator {
        if let existing = automationCoordinator, existing.model === model { return existing }
        automationCoordinator?.retire()
        let child = AutomationCoordinator(model: model)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return automationCoordinator?.model === model
        }
        child.canPresent = { [weak self] in
            self?.selection == .automation && self?.canPresent == true && self?.canOpenExternalRoute() == true
        }
        automationCoordinator = child
        refreshRoot()
        return child
    }

    func makeAutomation(factory: any AutomationFeatureFactory) -> AutomationViewModel {
        installAutomation(factory.automation()).model
    }
}
