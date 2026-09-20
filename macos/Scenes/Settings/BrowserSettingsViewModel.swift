import Foundation
import Observation

/// Settings → Browser's ad-blocking card: whether uBlock Origin Lite is installed, the App Store
/// link when it is not, and the switch that loads it into the embedded browser.
@MainActor @Observable final class BrowserSettingsViewModel {
    @ObservationIgnored private let blocker: BrowserAdBlocker
    @ObservationIgnored private let openBrowser: (URL) -> Bool
    private(set) var retired = false

    init(blocker: BrowserAdBlocker, openBrowser: @escaping (URL) -> Bool) {
        self.blocker = blocker; self.openBrowser = openBrowser
    }
    var state: BrowserAdBlockState { blocker.state }
    var enabled: Bool { blocker.enabled }
    var installed: Bool {
        switch state {
        case .available, .loading, .active, .failed: true
        case .unknown, .unsupported, .notInstalled: false
        }
    }
    var statusText: String {
        switch state {
        case .unknown: "Checking for uBlock Origin Lite…"
        case .unsupported: "Ad blocking needs macOS 15.4 or later."
        case .notInstalled: "Not installed. Install it from the App Store, then come back here."
        case .available: "Installed. Off."
        case .loading: "Loading…"
        case .active: "Blocking ads in new and open browser tabs."
        case .failed(let message): "Could not load: \(message)"
        }
    }
    func refresh() { if !retired { blocker.refresh() } }
    func setEnabled(_ value: Bool) { if !retired { blocker.setEnabled(value) } }
    func install() { if !retired { _ = openBrowser(BrowserAdBlocker.appStoreURL) } }
    func retire() { retired = true }
}
