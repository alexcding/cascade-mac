import Foundation
import Testing
import WebKit

@MainActor final class BrowserExtensionHostFixture: BrowserExtensionHost {
    var supported = true
    var failure: String?
    var loaded = false
    var loads = 0, unloads = 0, attaches = 0
    func attach(to configuration: WKWebViewConfiguration) { attaches += 1 }
    func load(app: URL) async throws {
        loads += 1
        try await Task.sleep(for: .milliseconds(30))
        if let failure { throw BackendError.operation(failure) }
        loaded = true
    }
    var refusesUnload = false
    func unload() -> Bool {
        unloads += 1
        if refusesUnload { return false }
        loaded = false; return true
    }
}

@MainActor private func waitForAdBlock(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for the ad blocker")
}

@MainActor private func adBlockDefaults() -> UserDefaults {
    let name = "adblock-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let installedApp = URL(fileURLWithPath: "/Applications/uBlock Origin Lite.app")

@MainActor @Test func adBlockerReportsMissingAppAndNeverLoads() async throws {
    let host = BrowserExtensionHostFixture()
    let blocker = BrowserAdBlocker(host: host, locate: { nil }, defaults: adBlockDefaults())
    blocker.setEnabled(true)
    #expect(blocker.state == .notInstalled)
    #expect(host.loads == 0)
}

@MainActor @Test func adBlockerLoadsWhenEnabledAndPersistsTheSwitch() async throws {
    let host = BrowserExtensionHostFixture(), defaults = adBlockDefaults()
    let blocker = BrowserAdBlocker(host: host, locate: { installedApp }, defaults: defaults)
    blocker.refresh()
    #expect(blocker.state == .available)
    blocker.setEnabled(true)
    #expect(blocker.state == .loading)
    try await waitForAdBlock { blocker.state == .active }
    #expect(host.loaded && host.loads == 1)
    #expect(defaults.bool(forKey: BrowserAdBlocker.enabledKey))
    // A second look while active does not load again.
    blocker.refresh()
    #expect(host.loads == 1)
    // A new instance over the same defaults starts switched on and loads on first attach.
    let relaunchedHost = BrowserExtensionHostFixture()
    let relaunched = BrowserAdBlocker(host: relaunchedHost, locate: { installedApp }, defaults: defaults)
    relaunched.attach(to: WKWebViewConfiguration())
    #expect(relaunchedHost.attaches == 1)
    try await waitForAdBlock { relaunched.state == .active }
}

@MainActor @Test func adBlockerDisabledMidLoadEndsUnloaded() async throws {
    let host = BrowserExtensionHostFixture()
    let blocker = BrowserAdBlocker(host: host, locate: { installedApp }, defaults: adBlockDefaults())
    blocker.setEnabled(true)
    blocker.setEnabled(false)
    #expect(blocker.state == .available)
    try await waitForAdBlock { host.loads == 1 && host.unloads >= 2 }
    #expect(!host.loaded)
    #expect(blocker.state == .available)
}

@MainActor @Test func adBlockerReportsFailureAndRetriesOnRefresh() async throws {
    let host = BrowserExtensionHostFixture()
    host.failure = "bad manifest"
    let blocker = BrowserAdBlocker(host: host, locate: { installedApp }, defaults: adBlockDefaults())
    blocker.setEnabled(true)
    try await waitForAdBlock { if case .failed = blocker.state { true } else { false } }
    host.failure = nil
    blocker.refresh()
    try await waitForAdBlock { blocker.state == .active }
    #expect(host.loads == 2)
}

@MainActor @Test func adBlockerUnsupportedOSNeverLoads() async throws {
    let host = BrowserExtensionHostFixture()
    host.supported = false
    let blocker = BrowserAdBlocker(host: host, locate: { installedApp }, defaults: adBlockDefaults())
    blocker.setEnabled(true)
    #expect(blocker.state == .unsupported)
    #expect(host.loads == 0)
}

@MainActor @Test func browserSettingsModelOpensTheAppStoreAndRefusesAfterRetire() async throws {
    let host = BrowserExtensionHostFixture()
    let blocker = BrowserAdBlocker(host: host, locate: { nil }, defaults: adBlockDefaults())
    var opened: [URL] = []
    let model = BrowserSettingsViewModel(blocker: blocker, openBrowser: { opened.append($0); return true })
    model.refresh()
    #expect(model.state == .notInstalled && !model.installed)
    model.install()
    #expect(opened == [BrowserAdBlocker.appStoreURL])
    model.retire()
    model.install(); model.setEnabled(true)
    #expect(opened.count == 1)
    #expect(!blocker.enabled)
}

@MainActor @Test func browsingDataClearsOnlyFromTheBrowserSection() async throws {
    let runtime = SettingsRuntimeFixture(), model = settingsFixtureModel()
    let coordinator = SettingsCoordinator(model: model, runtime: runtime)
    model.setActive(true)
    model.section = .browser
    model.clearBrowsingData(.history)
    try await waitForAdBlock { runtime.cleared == [.history] && model.clearingBrowsingData == nil }
    #expect(model.browsingDataNotice == BrowsingDataScope.history.clearedNotice)
    // Anywhere else the clear is cancelled before it reaches the runtime.
    model.section = .general
    model.clearBrowsingData(.websiteData)
    #expect(model.clearingBrowsingData == nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(runtime.cleared == [.history])
    // A factory given no blocker stays inert: the Browser section never reaches WebKit.
    #expect(model.adBlock.state == .unsupported)
    withExtendedLifetime(coordinator) {}
}

@MainActor @Test func adBlockerNeverClaimsOffOverAnExtensionThatStayedLoaded() async throws {
    let host = BrowserExtensionHostFixture()
    let blocker = BrowserAdBlocker(host: host, locate: { installedApp }, defaults: adBlockDefaults())
    blocker.setEnabled(true)
    try await waitForAdBlock { blocker.state == .active }
    host.refusesUnload = true
    blocker.setEnabled(false)
    #expect(host.loaded)
    if case .failed = blocker.state {} else { Issue.record("Expected a failure, got \(blocker.state)") }
    // Once WebKit lets go, the next look reports plain off.
    host.refusesUnload = false
    blocker.refresh()
    #expect(blocker.state == .available && !host.loaded)
}
