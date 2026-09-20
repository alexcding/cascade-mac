import AppKit
import UserNotifications

// Construct only in the bundled application. Command-line Swift package tests
// inject a delivery recorder and never access the real Notification Center.
@MainActor final class MacNotificationDelivery: NSObject, NotificationDelivery, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private weak var store: NotificationStore?
    private var soundProcess: Process?

    init(store: NotificationStore) {
        self.store = store
        super.init()
        center.delegate = self
    }

    func access() async -> NotificationAccess {
        let settings = await center.notificationSettings()
        let permission: NotificationPermission
        switch settings.authorizationStatus {
        case .notDetermined: permission = .notDetermined
        case .denied: permission = .denied
        case .authorized, .provisional, .ephemeral: permission = .authorized
        @unknown default: permission = .unavailable
        }
        return NotificationAccess(permission: permission, soundAllowed: settings.soundSetting == .enabled)
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ notice: NativeNotice) async throws {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        // Review batches play one selected sound, never one sound per PR.
        content.categoryIdentifier = notice.kind.rawValue
        var info: [String: String] = ["kind": notice.kind.rawValue]
        info["url"] = notice.url
        info["repo"] = notice.repo
        info["number"] = notice.number.map(String.init)
        content.userInfo = info
        try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    func playReviewSound(_ path: String) throws {
        let file = path.isEmpty || path == "system" ? "/System/Library/Sounds/Glass.aiff" : path
        guard file.hasPrefix("/"), FileManager.default.isReadableFile(atPath: file) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if soundProcess?.isRunning == true { return } // Avoid overlapping chimes.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [file]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run() // Async child; no wait on the UI actor.
        soundProcess = process
    }

    nonisolated private static func notice(_ notification: UNNotification) -> NativeNotice {
        let content = notification.request.content
        let info = content.userInfo
        return NativeNotice(id: notification.request.identifier,
                            kind: NativeNotice.Kind(rawValue: info["kind"] as? String ?? "") ?? .activity,
                            title: content.title, body: content.body,
                            url: (info["url"] as? String).flatMap(safeWebURL)?.absoluteString,
                            repo: info["repo"] as? String,
                            number: (info["number"] as? String).flatMap(Int.init))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let notice = Self.notice(notification)
        return await MainActor.run {
            guard let store, store.accepts(self) else { return [] }
            return store.shouldPresentBanner(for: notice) ? [.banner, .list] : []
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let notice = Self.notice(response.notification)
        await MainActor.run {
            guard let store, store.accepts(self) else { return }
            store.openDelivered(notice)
        }
    }
}
