import Foundation
import ServiceManagement

enum LoginItemStatus: Sendable { case notRegistered, enabled, requiresApproval, notFound, unknown }
struct LoginItemState: Sendable {
    let status: LoginItemStatus
    let registrationUnavailableReason: String?
    var registered: Bool { status == .enabled || status == .requiresApproval }
}

protocol LoginItemService: Sendable {
    func state() async -> LoginItemState
    func setEnabled(_ enabled: Bool) async throws
    func openSystemSettings() async
}

enum LoginItemRegistrationPolicy {
    static func unavailableReason(debug: Bool, packaged: Bool) -> String? {
        if debug { return "Launch at login is unavailable in development builds. Use the packaged release app." }
        if !packaged { return "Launch at login requires the packaged app with its bundled backend." }
        return nil
    }
    static var currentReason: String? {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let configuration = try? BackendConfiguration.current()
        let packaged = configuration?.packaged == true && PackagedBundle.isPackaged(Bundle.main.bundleURL)
        return unavailableReason(debug: debug, packaged: packaged)
    }
}

// macOS owns this setting. Never mirror it to the backend or UserDefaults, and
// never register merely because a view was opened or a stored preference is true.
actor NativeLoginItemService: LoginItemService {
    private let unavailableReason = LoginItemRegistrationPolicy.currentReason
    func state() -> LoginItemState {
        let status: LoginItemStatus
        switch SMAppService.mainApp.status {
        case .notRegistered: status = .notRegistered
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        @unknown default: status = .unknown
        }
        return LoginItemState(status: status, registrationUnavailableReason: unavailableReason)
    }
    func setEnabled(_ enabled: Bool) throws {
        let current = state()
        if enabled {
            if current.registered { return }
            if let reason = unavailableReason { throw BackendError.operation(reason) }
            try SMAppService.mainApp.register()
        } else if current.registered {
            // The synchronous API executes on this actor, off the UI thread.
            // Unregistering mainApp leaves this running process alive.
            try SMAppService.mainApp.unregister()
        }
    }
    func openSystemSettings() async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
