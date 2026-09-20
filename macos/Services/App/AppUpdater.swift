import Foundation
import Observation
import Sparkle

enum UpdateConfiguration {
    static func unavailableReason(debug: Bool, packaged: Bool, info: [String: Any]) -> String? {
        if debug { return "Updates are unavailable in development builds." }
        if !packaged { return "Updates require the packaged application." }
        guard let feed = info["SUFeedURL"] as? String,
              let url = URLComponents(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return "A release update feed has not been configured." }
        guard let key = info["SUPublicEDKey"] as? String,
              let data = Data(base64Encoded: key), data.count == 32 else {
            return "A release update signing key has not been configured."
        }
        return nil
    }
}

/// The application retains this adapter because Sparkle holds its delegate weakly.
/// Unconfigured and development apps never construct or start an updater.
@MainActor @Observable public final class AppUpdater: NSObject, SPUUpdaterDelegate {
    public private(set) var unavailableReason: String?
    public private(set) var restartRequested = false
    public private(set) var canCheckForUpdates = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?

    public override init() {
        super.init()
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let bundle = Bundle.main
        let packaged = bundle.bundleURL.pathExtension == "app"
            && FileManager.default.isExecutableFile(atPath: bundle.bundleURL.appendingPathComponent("Contents/Helpers/craft-backend").path)
            && FileManager.default.isExecutableFile(atPath: bundle.bundleURL.appendingPathComponent("Contents/Helpers/craft-ptyd").path)
        unavailableReason = UpdateConfiguration.unavailableReason(debug: debug, packaged: packaged, info: bundle.infoDictionary ?? [:])
        guard unavailableReason == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    canCheckForUpdates = self.controller?.updater.canCheckForUpdates == true
                }
            }
        } catch { unavailableReason = error.localizedDescription }
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    public func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle 2.9.6 sets this before its installer requests termination. The
        // callback is emitted only once, even when the user cancels a save sheet
        // and later retries installation. Keep it armed until the cycle ends.
        restartRequested = true
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        restartRequested = false
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        restartRequested = false
    }
}
