import Foundation
import Observation

@MainActor protocol LogsFeatureFactory {
    func logs(pageActions: any PageActionServing, copy: @escaping (String) -> Void) -> LogsViewModel
}
@MainActor struct NativeLogsFeatureFactory: LogsFeatureFactory {
    func logs(pageActions: any PageActionServing, copy: @escaping (String) -> Void) -> LogsViewModel {
        LogsViewModel(pageActions: pageActions, copy: copy)
    }
}

@MainActor @Observable final class LogsCoordinator: Coordinatable {
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: LogsViewModel
    private(set) var confirmation: LogsViewModel.ClearRequest?
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored var presentationEnded: () -> Void = {}
    var isPresenting: Bool { confirmation != nil || model.clearing }
    init(model: LogsViewModel) {
        self.model = model
        root = .logs(model)
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination { .none }
    func handle(_ action: Action) {
        if case .logs(let action) = action { handle(action) } else { self.action?(action) }
    }
    func handle(_ action: LogsViewModel.Action) {
        guard !retired, isOwned(), !isPresenting, canPresent() else { return }
        switch action {
        case .requestClear:
            guard let request = model.makeClearRequest() else { return }
            model.cancelActions(); confirmation = request
        default: model.perform(action)
        }
    }
    func confirm(id: UUID) async {
        guard !retired, isOwned(), let request = confirmation, request.id == id, model.canClear(request) else { return }
        defer { presentationEnded() }
        if await model.clear(request), confirmation?.id == id { confirmation = nil }
    }
    func cancel(id: UUID) {
        guard confirmation?.id == id, !model.clearing else { return }
        endPresentation()
    }
    func endPresentation() {
        model.cancelActions()
        guard let request = confirmation else { return }
        model.cancelClear(request); confirmation = nil; presentationEnded()
    }
    func retire() {
        retired = true; confirmation = nil; isOwned = { false }; canPresent = { false }; presentationEnded = {}
        model.retire()
    }
}

extension AppCoordinator {
    @discardableResult func installLogs(_ model: LogsViewModel) -> LogsCoordinator {
        if let existing = logsCoordinator, existing.model === model { return existing }
        logsCoordinator?.retire()
        let child = LogsCoordinator(model: model)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return logsCoordinator?.model === model
        }
        child.canPresent = { [weak self] in
            self?.activityVisible == true && self?.canPresent == true && self?.canOpenExternalRoute() == true
        }
        child.presentationEnded = { [weak self] in self?.schedulePendingDeepLink() }
        logsCoordinator = child; schedulePendingDeepLink()
        return child
    }
    func makeLogs(factory: any LogsFeatureFactory, pageActions: any PageActionServing, copy: @escaping (String) -> Void) -> LogsViewModel {
        installLogs(factory.logs(pageActions: pageActions, copy: copy)).model
    }
}
