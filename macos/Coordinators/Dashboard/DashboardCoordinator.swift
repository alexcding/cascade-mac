import Foundation
import Observation

@MainActor protocol DashboardFeatureFactory {
    func dashboard(pageActions: any PageActionServing) -> DashboardViewModel
}

@MainActor struct NativeDashboardFeatureFactory: DashboardFeatureFactory {
    func dashboard(pageActions: any PageActionServing) -> DashboardViewModel { DashboardViewModel(pageActions: pageActions) }
}

@MainActor @Observable final class DashboardCoordinator: Coordinatable {
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: DashboardViewModel
    let shell: ShellStore
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }

    init(model: DashboardViewModel, shell: ShellStore = ShellStore()) {
        self.model = model
        self.shell = shell
        root = .dashboard(model, shell)
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination {
        if case .dashboardTickets = route { return .dashboardTickets(model) }
        return .none
    }
    func handle(_ action: Action) {
        if case .dashboard(let action) = action { handle(action) } else { self.action?(action) }
    }
    func handle(_ action: DashboardViewModel.Action) {
        guard !retired, isOwned(), canPresent() else { return }
        switch action {
        // Only after the gate above, so a hidden or blocked dashboard stays silent rather than warn.
        case .open(let request):
            if model.prs.connected { model.navigation.open(request) } else { model.navigation.reject("Connect to open pull requests in Craft.") }
        case .showTickets: if path.isEmpty { navigate(to: .dashboardTickets) }
        case .closeTickets: leaveTickets()
        }
    }
    /// Back to the home screen, ending any search: going back is navigation, and a search left
    /// running would keep its results over the page the user asked for.
    func leaveTickets() {
        guard !path.isEmpty else { return }
        popToRoot()
        model.clearFilter()
    }
    func retire() { retired = true; isOwned = { false }; canPresent = { false }; model.retire() }
}

extension AppCoordinator {
    @discardableResult func installDashboard(_ model: DashboardViewModel, shell: ShellStore = ShellStore()) -> DashboardCoordinator {
        if let existing = dashboardCoordinator, existing.model === model { return existing }
        dashboardCoordinator?.retire()
        let child = DashboardCoordinator(model: model, shell: shell)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return dashboardCoordinator?.model === model
        }
        child.canPresent = { [weak self] in
            self?.selection == .overview && self?.canPresent == true && self?.canOpenExternalRoute() == true
        }
        dashboardCoordinator = child
        refreshRoot()
        return child
    }

    func makeDashboard(factory: any DashboardFeatureFactory, pageActions: any PageActionServing, shell: ShellStore = ShellStore()) -> DashboardViewModel {
        installDashboard(factory.dashboard(pageActions: pageActions), shell: shell).model
    }
}
