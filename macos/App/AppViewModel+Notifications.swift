import Foundation

extension AppViewModel: NotificationCoordinating {
    func acknowledgeNotificationReview(repo: String, number: Int) {
        shell.acknowledgeReview(repo: repo, number: number)
    }
    /// A notice whose page has a session selects it, in Cascade; any other link opens in the system
    /// browser. True only for the session, so the caller brings the window up only then.
    func openNotificationPage(_ request: OpenPageRequest) async throws -> Bool {
        if let session = existingSession(for: request) { select(.session(session.id)); return true }
        do { try await openPage(request) } catch {
            guard let url = safeWebURL(request.url), openInBrowser(url) else { throw error }
        }
        return false
    }

    public func configureNativeNotifications(isMainWindowFocused: @escaping () -> Bool,
                                            showWindow: @escaping () -> Void) {
        shell.notifications.isMainWindowFocused = isMainWindowFocused
        coordinator.notificationCoordinator?.showWindow = showWindow
        self.showMainWindow = showWindow
        shell.notifications.configure(MacNotificationDelivery(store: shell.notifications))
    }
}
