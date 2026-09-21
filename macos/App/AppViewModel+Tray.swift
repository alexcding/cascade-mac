import Foundation

extension AppViewModel: TrayCoordinating {
    func trayState() -> TrayState {
        .init(reviews: shell.prs,
              acknowledging: shell.acknowledging, canNavigate: coordinator.canPresent && coordinator.canOpenExternalRoute())
    }
    func refreshTray() {
        shell.notifications.refreshAuthorization()
        refresh(); shell.loadSettings()
    }
    func acknowledgeTrayReview(_ review: TrayPR) { shell.acknowledge(review) }
    func openTrayReview(_ request: OpenPageRequest) async throws { try await openPage(request) }
    // The usage picker lives on the Dashboard toolbar.
    func openTrayUsage() { select(.overview) }
}
