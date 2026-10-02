import Foundation

extension AppViewModel: NotificationCoordinating {
    func acknowledgeNotificationReview(repo: String, number: Int) {
        shell.acknowledgeReview(repo: repo, number: number)
    }
    /// A notice opens as a row's click does (`openPage`): its page's session or its project's
    /// Start, in Cascade, so the caller brings the window up. A page no project claims is reported
    /// where the app reports errors, and the caller brings the window up for that too. A
    /// superseded click opens nothing.
    func openNotificationPage(_ request: OpenPageRequest) async throws -> Bool {
        // The notice's coordinator brings the window up for a failure itself.
        do { try await openPage(request) } catch { reportOutsideOpenFailure(error, showWindow: false); throw error }
        return true
    }

    public func configureNativeNotifications(isMainWindowFocused: @escaping () -> Bool,
                                            showWindow: @escaping () -> Void) {
        shell.notifications.isMainWindowFocused = isMainWindowFocused
        coordinator.notificationCoordinator?.showWindow = showWindow
        self.showMainWindow = showWindow
        shell.notifications.configure(MacNotificationDelivery(store: shell.notifications))
    }
}
