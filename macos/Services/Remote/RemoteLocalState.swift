import CryptoKit
import Foundation
import IOKit

/// What the mirror keeps on this Mac, beside the data it belongs to: whether it is on, the phones
/// approved here, and the commands it has begun. In the data directory, not `UserDefaults`, so a
/// run with its own data folder is its own mirror and shares nothing with the installed app.
struct RemoteLocalState: Codable, Equatable {
    /// A phone its owner allowed to act on this Mac, with the key it was approved under. A device
    /// record that later shows a different key is a different device.
    struct Device: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var publicKey: Data
        var approvedAt: Date
    }

    var enabled = false
    var approved: [String: Device] = [:]
    /// Phones turned away here, by device ID, with the name each gave.
    var denied: [String: String] = [:]
    /// The iCloud account changed under a running mirror. It stays stopped, across launches too,
    /// until it is turned off and on: the account signed in now was never asked.
    var accountChanged = false
    /// When each command was begun, by ID. One found here and still pending was cut off by a quit
    /// or a crash, and is never typed again.
    var attempts: [String: TimeInterval] = [:]
    /// Turned off while this Mac's records could not be taken out of iCloud: they still are there.
    var needsClear = false
    /// Used only on a Mac that reports no hardware ID.
    var fallbackHostID: String?

    init() {}

    /// Every field is read if it is there: a file written by an older version, without a field
    /// added since, keeps what it has rather than reading as nothing at all.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        approved = try values.decodeIfPresent([String: Device].self, forKey: .approved) ?? [:]
        denied = try values.decodeIfPresent([String: String].self, forKey: .denied) ?? [:]
        accountChanged = try values.decodeIfPresent(Bool.self, forKey: .accountChanged) ?? false
        attempts = try values.decodeIfPresent([String: TimeInterval].self, forKey: .attempts) ?? [:]
        needsClear = try values.decodeIfPresent(Bool.self, forKey: .needsClear) ?? false
        fallbackHostID = try values.decodeIfPresent(String.self, forKey: .fallbackHostID)
    }

    static func load(from url: URL) -> RemoteLocalState {
        guard let data = try? Data(contentsOf: url) else { return RemoteLocalState() }
        return (try? JSONDecoder().decode(RemoteLocalState.self, from: data)) ?? RemoteLocalState()
    }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }

    /// This Mac with this data directory, as its records name it. Derived, not stored: a data
    /// folder or a preferences file carried to another Mac must not carry the identity with it,
    /// and two runs on one Mac with their own folders must not share one.
    static func hostID(dataDirectory: URL, hardware: String? = hardwareID()) -> String? {
        guard let hardware else { return nil }
        let material = Data((hardware + "\n" + dataDirectory.standardizedFileURL.path).utf8)
        return SHA256.hash(data: material).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func hardwareID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
