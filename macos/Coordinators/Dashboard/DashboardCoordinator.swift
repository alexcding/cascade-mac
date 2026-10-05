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
    /// The toolbar's New Project, handed to the app, and whether the app can make one now.
    @ObservationIgnored var requestNewProject: () -> Void = {}
    /// A project's page, from its name on Projects, handed to the app.
    @ObservationIgnored var requestProject: (String) -> Void = { _ in }
    @ObservationIgnored var requestSession: (String) -> Void = { _ in }
    @ObservationIgnored var requestNewSession: (String) -> Void = { _ in }
    @ObservationIgnored var canCreateProject: () -> Bool = { false }

    init(model: DashboardViewModel, shell: ShellStore = ShellStore()) {
        self.model = model
        self.shell = shell
        root = .dashboard(model, shell)
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination { .none }
    func handle(_ action: Action) {
        if case .dashboard(let action) = action { handle(action) } else { self.action?(action) }
    }
    func handle(_ action: DashboardViewModel.Action) {
        guard !retired, isOwned(), canPresent() else { return }
        switch action {
        // Only after the gate above, so a hidden or blocked dashboard stays silent rather than warn.
        case .open(let request):
            if model.prs.connected { model.navigation.open(request) } else { model.navigation.reject("Connect to open pull requests in Cascade.") }
        case .openProject(let id): requestProject(id)
        case .openSession(let id): requestSession(id)
        case .newSession(let projectID): requestNewSession(projectID)
        case .board(.open(let request)):
            guard model.tab == .board else { return }
            model.board?.navigation.open(request)
        }
    }
    /// New Project, from the page's toolbar, while the page is the one on screen.
    func newProject() {
        guard !retired, isOwned(), canPresent(), canCreateProject() else { return }
        requestNewProject()
    }
    func retire() {
        retired = true; isOwned = { false }; canPresent = { false }; requestNewProject = {}; canCreateProject = { false }
        requestProject = { _ in }; requestSession = { _ in }; requestNewSession = { _ in }
        model.retire()
    }
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
        child.requestNewProject = { [weak self] in self?.rootRuntime?.performRootCommand(.newProject) }
        child.canCreateProject = { [weak self] in self?.rootRuntime?.canPerform(.newProject) ?? false }
        child.requestProject = { [weak self] id in self?.rootRuntime?.openProjectSettings(id) }
        child.requestSession = { [weak self] id in self?.rootRuntime?.openSession(id) }
        child.requestNewSession = { [weak self] id in self?.rootRuntime?.newTask(in: id) }
        dashboardCoordinator = child
        model.onScreen = selection == .overview
        model.appearance = appearance
        refreshRoot()
        return child
    }

    func makeDashboard(factory: any DashboardFeatureFactory, pageActions: any PageActionServing, shell: ShellStore = ShellStore()) -> DashboardViewModel {
        installDashboard(factory.dashboard(pageActions: pageActions), shell: shell).model
    }
}
