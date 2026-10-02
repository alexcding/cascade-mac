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
    /// A tray click opens as a row's does (`openPage`): the PR's session, else its project's Start
    /// with the link filled in. It never starts a session. A PR no project claims brings the window
    /// up with the reason.
    func openTrayReview(_ request: OpenPageRequest) async throws {
        do { try await openPage(request) } catch { reportOutsideOpenFailure(error); throw error }
    }
    // The usage picker lives on the Dashboard toolbar.
    func openTrayUsage() { select(.overview) }
}
