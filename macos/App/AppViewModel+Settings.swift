import AppKit
import Foundation
import WebKit

extension AppViewModel: SettingsCoordinating {
    func activateSettings() {
        // Reached from AppViewModel.init() via installSettings, which runs before NSApplication
        // finishes wiring NSApp — an implicitly-unwrapped nil there traps on launch.
        settings?.applicationActiveChanged(NSApp?.isActive ?? false)
        shell.loadSettings(); shell.notifications.refreshAuthorization()
    }
    /// Settings is its own window; the welcome is a sheet on the main one, so that comes forward
    /// first — but only when the sheet can follow it, or the button would just take focus away.
    func presentWelcome() {
        guard canPresentWelcome else { return }
        showMainWindow?()
        presentWelcome(firstRunOnly: false)
    }
    func presentSettings() {
        openSettingsWindow?()
        NSApp?.activate(ignoringOtherApps: true)
    }
    func applySettingsSave(_ patch: [String: String]) async {
        if patch["jira_base_url"] != nil || patch["jira_api_token"] != nil {
            for model in projectModels.values { await model.tickets?.invalidateSite() }
        }
    }
    func clearBrowsingData(_ scope: BrowsingDataScope) async {
        switch scope {
        case .history:
            viewer.clearBrowsingHistory()
        case .websiteData:
            // Every embedded page shares WebKit's default store, so one sweep covers them all.
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            viewer.reloadLivePages()
        }
    }
}
