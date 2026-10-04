import Foundation
import Observation

@MainActor protocol NewSessionFeatureFactory {
    func newSession() -> NewSessionViewModel
}

@MainActor struct NativeNewSessionFeatureFactory: NewSessionFeatureFactory {
    func newSession() -> NewSessionViewModel { NewSessionViewModel() }
}

/// What New Task needs from the app: a project's Start composer, and New Project.
@MainActor protocol NewSessionCoordinating: AnyObject {
    func newSessionComposer(for projectID: String) -> ProjectComposerModel?
    func newSessionNewProject()
}

/// New Task's coordinator. The page shows a project's own Start composer, which the project's
/// model owns, so this holds only the page's model and gates what it asks for.
@MainActor @Observable final class NewSessionCoordinator {
    let model: NewSessionViewModel
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored private weak var runtime: (any NewSessionCoordinating)?

    init(model: NewSessionViewModel, runtime: (any NewSessionCoordinating)?) {
        self.model = model
        self.runtime = runtime
        model.onAction = { [weak self] in self?.handle($0) }
        model.composerFor = { [weak self] id in
            guard let self, !retired, isOwned() else { return nil }
            return self.runtime?.newSessionComposer(for: id)
        }
    }

    func handle(_ action: NewSessionViewModel.Action) {
        guard !retired, isOwned(), canPresent() else { return }
        switch action {
        case .newProject: runtime?.newSessionNewProject()
        }
    }

    func retire() { retired = true; isOwned = { false }; canPresent = { false }; model.retire() }
}

extension AppCoordinator {
    @discardableResult func installNewSession(_ model: NewSessionViewModel, runtime: (any NewSessionCoordinating)?) -> NewSessionCoordinator {
        if let existing = newSessionCoordinator, existing.model === model { return existing }
        newSessionCoordinator?.retire()
        let child = NewSessionCoordinator(model: model, runtime: runtime)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return newSessionCoordinator?.model === model
        }
        child.canPresent = { [weak self] in self?.selection == .newSession && self?.canPresent == true }
        newSessionCoordinator = child
        return child
    }

    func makeNewSession(factory: any NewSessionFeatureFactory, runtime: (any NewSessionCoordinating)?) -> NewSessionViewModel {
        installNewSession(factory.newSession(), runtime: runtime).model
    }
}
