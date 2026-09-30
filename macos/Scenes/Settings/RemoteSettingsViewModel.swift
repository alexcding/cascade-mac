import Foundation
import Observation

/// Settings → iPhone: turns the iCloud mirror on and says how it is doing. The mirror is the app's
/// and outlives this model; nil when the app runs without one (tests, previews).
@MainActor @Observable
final class RemoteSettingsViewModel {
    @ObservationIgnored private let mirror: RemoteMirror?

    init(mirror: RemoteMirror?) { self.mirror = mirror }

    var available: Bool { mirror?.available ?? false }
    var enabled: Bool { mirror?.enabled ?? false }
    func setEnabled(_ value: Bool) { mirror?.setEnabled(value) }

    var statusText: String {
        switch mirror?.status ?? .off {
        case .off: String(localized: "Off")
        case .unavailable(let reason): reason
        case .starting: String(localized: "Connecting to iCloud…")
        case .syncing(let date?): String(localized: "Syncing. Last synced \(date.formatted(date: .omitted, time: .standard)).")
        case .syncing(nil): String(localized: "Syncing.")
        case .failed(let message): message
        }
    }

    var failed: Bool {
        if case .failed = mirror?.status { return true }
        return false
    }
}
