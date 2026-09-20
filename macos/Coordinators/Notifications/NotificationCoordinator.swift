import Foundation
import Observation

@MainActor protocol NotificationFeatureFactory { func notifications() -> NotificationStore }
@MainActor struct NativeNotificationFeatureFactory: NotificationFeatureFactory {
    func notifications() -> NotificationStore { NotificationStore() }
}

@MainActor protocol NotificationCoordinating: AnyObject {
    func acknowledgeNotificationReview(repo: String, number: Int)
}

@MainActor @Observable final class NotificationCoordinator {
    let model: NotificationStore
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canUsePreferences: () -> Bool = { false }
    @ObservationIgnored var openActivity: () -> Void = {}
    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored private weak var runtime: (any NotificationCoordinating)?
    @ObservationIgnored private let desktop: any DesktopActions

    init(model: NotificationStore, runtime: any NotificationCoordinating, desktop: any DesktopActions) {
        self.model = model; self.runtime = runtime; self.desktop = desktop
        model.onAction = { [weak self] in self?.handle($0) }
    }

    func handle(_ action: NotificationStore.Action) {
        guard !retired, !model.retired, isOwned(), let runtime else { return }
        switch action {
        case .enable:
            guard canUsePreferences() else { return }
            model.requestAuthorization()
        case .previewSound(let sound):
            guard canUsePreferences() else { return }
            model.playPreview(sound)
        case .openCurrent(let id):
            guard let notice = model.notice(id: id) else { return }
            open(notice, runtime: runtime)
        case .openDelivered(let notice): open(notice, runtime: runtime)
        }
    }

    private func open(_ notice: NativeNotice, runtime: any NotificationCoordinating) {
        if let address = notice.url {
            guard let url = safeWebURL(address) else { model.didOpen(notice, success: false); return }
            let success = desktop.openBrowser(url)
            model.didOpen(notice, success: success)
            if success, notice.kind == .review, let repo = notice.repo, !repo.isEmpty,
               let number = notice.number, number > 0 {
                runtime.acknowledgeNotificationReview(repo: repo, number: number)
            }
        } else {
            showWindow(); openActivity(); model.didOpen(notice, success: true)
        }
    }

    func retire() {
        retired = true; isOwned = { false }; canUsePreferences = { false }
        openActivity = {}; showWindow = {}; runtime = nil; model.retire()
    }
}

extension AppCoordinator {
    @discardableResult func installNotifications(_ model: NotificationStore, runtime: any NotificationCoordinating,
                                                 desktop: any DesktopActions) -> NotificationCoordinator {
        if let existing = notificationCoordinator, existing.model === model { return existing }
        notificationCoordinator?.retire()
        let child = NotificationCoordinator(model: model, runtime: runtime, desktop: desktop)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return notificationCoordinator?.model === model
        }
        child.canUsePreferences = { [weak self] in
            guard let self, canPresent, canOpenExternalRoute() else { return false }
            return trayCoordinator?.model.active == true ||
                (settingsCoordinator?.model.active == true && settingsCoordinator?.model.section == .general)
        }
        child.openActivity = { [weak self] in self?.presentActivity() }
        notificationCoordinator = child
        return child
    }
}
