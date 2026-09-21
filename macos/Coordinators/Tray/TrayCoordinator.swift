import Foundation
import Observation

@MainActor protocol TrayFeatureFactory {
    func tray(service: any TrayServing, shell: ShellStore) -> TrayViewModel
}

@MainActor struct NativeTrayFeatureFactory: TrayFeatureFactory {
    func tray(service: any TrayServing, shell: ShellStore) -> TrayViewModel {
        TrayViewModel(service: service, shell: shell)
    }
}

@MainActor protocol TrayCoordinating: TrayServing {
    /// Opens a review in a Craft tab (or the session that already owns its address).
    func openTrayReview(_ request: OpenPageRequest) async throws
    /// Shows the screen that carries the plan usage the tray summarises.
    func openTrayUsage()
}

@MainActor struct TrayPresentation {
    let openWindow: () -> Void
    let dismiss: () -> Void
    /// Quit through the app's own contract — the same path as the Craft menu's Quit.
    var quit: () -> Void = {}
}

@MainActor @Observable public final class TrayCoordinator {
    public let model: TrayViewModel
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored private var presentation: TrayPresentation?
    @ObservationIgnored private weak var runtime: (any TrayCoordinating)?
    @ObservationIgnored private var opening: (id: String, task: Task<Void, Never>)?

    init(model: TrayViewModel, runtime: any TrayCoordinating, presentation: TrayPresentation) {
        self.model = model; self.runtime = runtime; self.presentation = presentation
        model.onAction = { [weak self] in self?.handle($0) }
    }
    public func setActive(_ value: Bool) {
        guard !retired, isOwned() else { return }
        model.setActive(value)
    }
    func handle(_ action: TrayViewModel.Action) {
        guard !retired, isOwned(), model.available, model.active, let runtime, presentation != nil else { return }
        switch action {
        case .refresh: model.performRefresh()
        case .openUsage:
            runtime.openTrayUsage()
            model.setActive(false); presentation?.dismiss(); presentation?.openWindow()
        case .quit:
            model.setActive(false); presentation?.dismiss(); presentation?.quit()
        case .openReview(let id):
            // A repeat click on the review already opening is ignored; a click on another one wins,
            // so the panel never sits on a slow open while the user has moved on.
            guard opening?.id != id, let review = model.review(for: id), let url = review.webURL else { return }
            opening?.task.cancel()
            let request = OpenPageRequest(url: url.absoluteString, kind: "github", title: "PR #\(review.number) \(review.title)",
                                          repo: review.repo, category: review.category)
            let task = Task { [weak self, weak runtime] in
                var opened = false
                do { try await runtime?.openTrayReview(request); opened = runtime != nil } catch {}
                guard let self, !retired, !Task.isCancelled, opening?.id == id else { return }
                opening = nil
                model.reviewDidOpen(review, success: opened)
                guard opened else { return }
                model.setActive(false); presentation?.dismiss(); presentation?.openWindow()
            }
            opening = (id, task)
        }
    }
    func retire() {
        retired = true; isOwned = { false }; opening?.task.cancel(); opening = nil
        presentation = nil; runtime = nil; model.retire()
    }
}

extension AppCoordinator {
    func makeTray(factory: any TrayFeatureFactory, runtime: any TrayCoordinating, shell: ShellStore,
                  presentation: TrayPresentation) -> TrayCoordinator {
        trayCoordinator?.retire()
        let model = factory.tray(service: runtime, shell: shell)
        let child = TrayCoordinator(model: model, runtime: runtime, presentation: presentation)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return trayCoordinator?.model === model
        }
        trayCoordinator = child
        return child
    }
}
