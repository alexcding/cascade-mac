import Foundation

extension AppViewModel: TrayCoordinating {
    func trayState() -> TrayState {
        .init(pendingReviews: shell.pendingReviews,
              acknowledging: shell.acknowledging, canNavigate: coordinator.canPresent && coordinator.canOpenExternalRoute())
    }
    func refreshTray() {
        shell.notifications.refreshAuthorization()
        refresh()
    }
    func acknowledgeTrayReview(_ review: TrayPR) { shell.acknowledge(review) }
    /// A tray click selects the session that already owns the PR, leaving the page it shows alone;
    /// a PR with none opens in a tab. It never starts a session.
    func openTrayReview(_ request: OpenPageRequest) async throws {
        if let session = existingSession(for: request) { select(.session(session.id)); return }
        try await openPage(request)
    }
    // The usage picker lives on the Dashboard toolbar.
    func openTrayUsage() { select(.overview) }
}
