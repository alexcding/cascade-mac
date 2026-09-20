import AppKit
import Observation
import WebKit

/// Where uBlock Origin Lite stands for the embedded browser.
enum BrowserAdBlockState: Equatable, Sendable {
    /// Not looked yet: nothing has asked for the state.
    case unknown
    /// `WKWebExtension` needs macOS 15.4.
    case unsupported
    case notInstalled
    /// Installed and switched off.
    case available
    case loading
    case active
    case failed(String)
}

/// The WebKit half: one extension controller shared by every browser page, and the one
/// extension context loaded into it. Tests substitute this so no real extension is loaded.
@MainActor protocol BrowserExtensionHost: AnyObject {
    var supported: Bool { get }
    /// Every page attaches, whether or not the extension is loaded: loading and unloading the
    /// context is then live for web views that already exist.
    func attach(to configuration: WKWebViewConfiguration)
    func load(app: URL) async throws
    /// False when WebKit refused and the extension is still loaded.
    @discardableResult func unload() -> Bool
}

/// Loads the web extension out of the installed app's `.appex`. The app is not sandboxed, so
/// the bundle is read in place and App Store updates are picked up on the next load.
@MainActor final class WebKitBrowserExtensionHost: BrowserExtensionHost {
    enum Failure: LocalizedError {
        case extensionMissing
        var errorDescription: String? { "uBlock Origin Lite is installed but its Safari extension could not be found." }
    }
    // Stored untyped: the WebKit types are macOS 15.4+, the deployment target is not.
    private var controller: AnyObject?
    private var context: AnyObject?

    var supported: Bool { if #available(macOS 15.4, *) { true } else { false } }

    func attach(to configuration: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        configuration.webExtensionController = sharedController()
    }
    func load(app: URL) async throws {
        guard #available(macOS 15.4, *), context == nil else { return }
        let plugIns = app.appendingPathComponent("Contents/PlugIns")
        let bundles = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
        // The app may ship more than one extension; only the Safari web extension loads here.
        let candidates = bundles.filter { $0.pathExtension == "appex" }.sorted { $0.path < $1.path }.compactMap(Bundle.init(url:))
        guard let bundle = candidates.first(where: Self.isWebExtension) ?? candidates.first else {
            throw Failure.extensionMissing
        }
        let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
        // A second load may have landed while this one awaited.
        guard context == nil else { return }
        let loaded = WKWebExtensionContext(for: webExtension)
        // Nothing runs until what the manifest asks for is granted; there is no prompt UI here.
        for permission in webExtension.requestedPermissions { loaded.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in webExtension.allRequestedMatchPatterns { loaded.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try sharedController().load(loaded)
        context = loaded
    }
    @discardableResult func unload() -> Bool {
        guard #available(macOS 15.4, *), let loaded = context as? WKWebExtensionContext else { return true }
        // A context WebKit refused to unload is still loaded: keep it, so the next load reuses it
        // rather than failing on a second context for the same extension.
        do { try sharedController().unload(loaded); context = nil; return true } catch { return false }
    }
    private static func isWebExtension(_ bundle: Bundle) -> Bool {
        let point = (bundle.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
        return point == "com.apple.Safari.web-extension"
    }
    @available(macOS 15.4, *) private func sharedController() -> WKWebExtensionController {
        if let controller = controller as? WKWebExtensionController { return controller }
        let created = WKWebExtensionController()
        controller = created
        return created
    }
}

@MainActor private final class InertBrowserExtensionHost: BrowserExtensionHost {
    let supported = false
    func attach(to configuration: WKWebViewConfiguration) {}
    func load(app: URL) async throws {}
    func unload() -> Bool { true }
}

/// Ad blocking for the embedded browser, by way of the user's own uBlock Origin Lite install.
/// Settings → Browser shows `state` and flips `enabled`; `BrowserPage` calls `attach`.
@MainActor @Observable final class BrowserAdBlocker {
    static let shared = BrowserAdBlocker()
    nonisolated static let bundleIdentifier = "net.raymondhill.uBlock-Origin-Lite"
    static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/id6745342698")!
    static let enabledKey = "browser.adBlockEnabled"

    private(set) var state = BrowserAdBlockState.unknown
    private(set) var enabled: Bool
    @ObservationIgnored private let host: any BrowserExtensionHost
    @ObservationIgnored private let locate: () -> URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = UUID()

    init(host: (any BrowserExtensionHost)? = nil,
         locate: @escaping () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserAdBlocker.bundleIdentifier) },
         defaults: UserDefaults = .standard) {
        self.host = host ?? WebKitBrowserExtensionHost(); self.locate = locate; self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Reports unsupported and never looks for the app or touches WebKit: what a settings model
    /// gets when nobody hands it the shared blocker, which is every test.
    static func inert() -> BrowserAdBlocker { BrowserAdBlocker(host: InertBrowserExtensionHost(), locate: { nil },
                         defaults: UserDefaults(suiteName: "craft.adblock.inert") ?? .standard)
    }

    func attach(to configuration: WKWebViewConfiguration) {
        host.attach(to: configuration)
        if state == .unknown { refresh() }
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        refresh()
    }
    /// Looks again: the app may have been installed or removed since. A failed load is retried.
    func refresh() {
        guard host.supported else { state = .unsupported; return }
        guard let app = locate() else { state = stop() ? .notInstalled : Self.stillLoaded; return }
        guard enabled else { state = stop() ? .available : Self.stillLoaded; return }
        guard state != .active && state != .loading else { return }
        let token = UUID()
        generation = token; state = .loading
        Task { [weak self, host] in
            do {
                try await host.load(app: app)
                guard let self else { return }
                // Disowned while loading: keep it only if a newer load wants the same context.
                // A newer load that failed first must not leave "Could not load" over a loaded context.
                guard generation == token else {
                    if !enabled || state == .notInstalled { host.unload() } else if case .failed = state { state = .active }
                    return
                }
                state = .active
            } catch {
                guard let self, generation == token else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
    /// A load still in flight is disowned, then unloaded when it lands switched off.
    private func stop() -> Bool {
        generation = UUID()
        return host.unload()
    }
    /// Never claim "off" over an extension that is still filtering.
    private static let stillLoaded = BrowserAdBlockState.failed("uBlock Origin Lite could not be switched off. Quit and reopen Craft.")
}
