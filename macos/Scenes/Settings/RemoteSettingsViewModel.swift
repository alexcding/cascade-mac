import Foundation
import Observation

/// Settings → iPhone: turns the iCloud mirror on, says how it is doing, and decides which phones
/// may act on this Mac. The mirror is the app's and outlives this model; nil when the app runs
/// without one (tests, previews).
@MainActor @Observable
final class RemoteSettingsViewModel {
    struct Phone: Identifiable, Equatable {
        let id: String
        let name: String
        /// What the phone itself shows as its code: a name is only what a record claims.
        var code: String { RemoteSigning.code(for: id) }
    }

    @ObservationIgnored private let mirror: RemoteMirror?
    @ObservationIgnored private var retired = false

    init(mirror: RemoteMirror?) { self.mirror = mirror }

    var available: Bool { mirror?.available ?? false }
    var enabled: Bool { mirror?.enabled ?? false }

    /// Phones that asked to control sessions on this Mac and have not been answered.
    var waiting: [Phone] { (mirror?.pendingDevices ?? []).map { Phone(id: $0.id, name: $0.name) } }
    /// Phones allowed to send messages and answer approvals.
    var approved: [Phone] { (mirror?.approvedDevices ?? []).map { Phone(id: $0.id, name: $0.name) } }
    /// Phones turned away, which may be asked again.
    var denied: [Phone] { (mirror?.deniedDevices ?? []).map { Phone(id: $0.id, name: $0.name) } }

    /// Another phone, waiting or allowed, shows the same code. Codes are long enough that this
    /// does not happen by chance: one of the two was made to look like the other, and neither
    /// can be told apart here.
    func clashes(_ phone: Phone) -> Bool {
        (waiting + approved).contains { $0.id != phone.id && $0.code == phone.code }
    }

    func setEnabled(_ value: Bool) {
        guard !retired else { return }
        mirror?.setEnabled(value)
    }

    func approve(_ phone: Phone) {
        guard !retired, !clashes(phone) else { return }
        mirror?.approve(phone.id)
    }

    func deny(_ phone: Phone) {
        guard !retired else { return }
        mirror?.deny(phone.id)
    }

    func remove(_ phone: Phone) {
        guard !retired else { return }
        mirror?.remove(phone.id)
    }

    func askAgain(_ phone: Phone) {
        guard !retired else { return }
        mirror?.askAgain(phone.id)
    }

    /// The mirror goes on as the app's; this model stops driving it.
    func retire() { retired = true }

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
