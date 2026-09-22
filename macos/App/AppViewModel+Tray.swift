import Foundation

extension AppViewModel: TrayCoordinating {
    func trayState() -> TrayState {
        .init(pendingReviews: shell.pendingReviews,
              acknowledging: shell.acknowledging, canNavigate: coordinator.canPresent && coordinator.canOpenExternalRoute())
    }
    func refreshTray() {
        shell.notifications.refreshAuthorization()
        refresh(); shell.loadSettings()
    }
    func acknowledgeTrayReview(_ review: TrayPR) { shell.acknowledge(review) }
    /// A tray click lands on the PR's session — or offers to start one, as Open in Session does.
    /// A PR no workspace project tracks has nowhere to start a session, so it opens in a tab.
    func openTrayReview(_ request: OpenPageRequest) async throws {
        var inSession = request; inSession.inSession = true
        guard SessionPage.parse(request.url) != nil, Self.pageSessionProject(for: inSession, in: projects) != nil else {
            try await openPage(request); return
        }
        // The tray has no error surface worth a dead end: when a session cannot start right now
        // (a sheet is up, another start is in flight), the PR still opens in a tab.
        do { try await openPageSession(inSession) } catch { try await openPage(request) }
    }
    // The usage picker lives on the Dashboard toolbar.
    func openTrayUsage() { select(.overview) }
}
