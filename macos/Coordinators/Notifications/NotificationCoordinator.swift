import Foundation
import Observation

@MainActor protocol NotificationFeatureFactory { func notifications() -> NotificationStore }
@MainActor struct NativeNotificationFeatureFactory: NotificationFeatureFactory {
    func notifications() -> NotificationStore { NotificationStore() }
}

@MainActor protocol NotificationCoordinating: AnyObject {
    func acknowledgeNotificationReview(repo: String, number: Int)
    /// Opens a notice's link in a Craft tab (or the session that already owns its address), or in
    /// the browser when Craft cannot open pages yet. True when it opened inside Craft.
    func openNotificationPage(_ request: OpenPageRequest) async throws -> Bool
}

@MainActor @Observable final class NotificationCoordinator {
    let model: NotificationStore
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canUsePreferences: () -> Bool = { false }
    @ObservationIgnored var openActivity: () -> Void = {}
    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored private weak var runtime: (any NotificationCoordinating)?
    @ObservationIgnored private var opening: Task<Void, Never>?

    init(model: NotificationStore, runtime: any NotificationCoordinating) {
        self.model = model; self.runtime = runtime
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

    /// A linked notice opens inside Craft, as a row's click does; a later click replaces one
    /// still opening. A notice with no link shows Activity. A failed open brings the window up so
    /// its error is seen; one that fell back to the browser leaves the browser in front.
    private func open(_ notice: NativeNotice, runtime: any NotificationCoordinating) {
        guard let address = notice.url else {
            showWindow(); openActivity(); model.didOpen(notice, success: true); return
        }
        guard let url = safeWebURL(address) else { model.didOpen(notice, success: false); return }
        let host = url.host?.lowercased() ?? ""
        let github = host == "github.com" || host.hasSuffix(".github.com")
        let request = OpenPageRequest(url: url.absoluteString, kind: github ? "github" : "web",
                                      title: notice.title, repo: notice.repo ?? "")
        opening?.cancel()
        opening = Task { [weak self, weak runtime] in
            var success = false, inApp = false
            do {
                if let runtime { inApp = try await runtime.openNotificationPage(request); success = true }
            } catch {}
            guard let self, !retired, !Task.isCancelled, let runtime else { return }
            opening = nil
            model.didOpen(notice, success: success)
            if !success || inApp { showWindow() }
            guard success else { return }
            if notice.kind == .review, let repo = notice.repo, !repo.isEmpty, let number = notice.number, number > 0 {
                runtime.acknowledgeNotificationReview(repo: repo, number: number)
            }
        }
    }

    /// Settles once the click in flight, if any, has opened or failed.
    func waitForOpen() async { await opening?.value }

    func retire() {
        retired = true; isOwned = { false }; canUsePreferences = { false }
        opening?.cancel(); opening = nil
        openActivity = {}; showWindow = {}; runtime = nil; model.retire()
    }
}

extension AppCoordinator {
    @discardableResult func installNotifications(_ model: NotificationStore,
                                                 runtime: any NotificationCoordinating) -> NotificationCoordinator {
        if let existing = notificationCoordinator, existing.model === model { return existing }
        notificationCoordinator?.retire()
        let child = NotificationCoordinator(model: model, runtime: runtime)
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
