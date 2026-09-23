import Foundation

extension AppViewModel: NotificationCoordinating {
    func acknowledgeNotificationReview(repo: String, number: Int) {
        shell.acknowledgeReview(repo: repo, number: number)
    }
    /// Before the backend connects there is nowhere to put a tab, so the link opens in the browser
    /// rather than not at all.
    func openNotificationPage(_ request: OpenPageRequest) async throws -> Bool {
        do { try await openPage(request); return true } catch {
            guard let url = safeWebURL(request.url), openInBrowser(url) else { throw error }
            return false
        }
    }

    public func configureNativeNotifications(isMainWindowFocused: @escaping () -> Bool,
                                            showWindow: @escaping () -> Void) {
        shell.notifications.isMainWindowFocused = isMainWindowFocused
        coordinator.notificationCoordinator?.showWindow = showWindow
        self.showMainWindow = showWindow
        shell.notifications.configure(MacNotificationDelivery(store: shell.notifications))
    }
}
