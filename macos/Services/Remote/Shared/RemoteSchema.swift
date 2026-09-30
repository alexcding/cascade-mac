import CloudKit
import Foundation

// What the Mac mirrors to the user's CloudKit private database and what the phone writes back.
// Cascade Remote, the iPhone app in the cascade-ios repository, compiles a copy of this folder.
// It is the wire format between the two apps: change both copies together. Foundation and
// CloudKit only: no AppKit, UIKit or app types.
//
// One writer per record, so nothing ever needs merging: each Mac writes its own sessions, turns
// and permissions; the phone creates commands addressed to one Mac, and only that Mac marks them
// handled. Every record names the Mac it belongs to (`host`), so two Macs on one Apple Account
// never touch each other's.

enum RemoteSchema {
    static let container = "iCloud.com.alexcding.cascade"
    static let zone = CKRecordZone.ID(zoneName: "Remote", ownerName: CKCurrentUserDefaultName)
    /// Every record carries its whole value, end-to-end encrypted, under this one key.
    static let payloadKey = "payload"
    /// And the Mac it belongs to, in the clear: a random ID, readable without decrypting.
    static let hostKey = "host"
    /// CloudKit refuses a record over 1 MB; a payload is cut well under that.
    static let maxPayload = 900_000
    /// A message older than this when the Mac reads it is dropped, never typed: a phone that was
    /// offline for an hour must not type into whatever the agent is doing by then.
    static let commandLifetime: TimeInterval = 120
    /// How long the Mac waits for a busy agent before giving a message up.
    static let deliveryWait: TimeInterval = 60
    /// A command still `pending` after this was never picked up: past its lifetime, and past the
    /// longest a Mac that did pick it up would take to answer. The phone says so itself.
    static let commandGiveUp: TimeInterval = commandLifetime + deliveryWait + 30
    /// Handled commands are removed after this, so the zone holds only live state.
    static let commandRetention: TimeInterval = 600
    /// The turns mirrored per session, newest last. The phone is a window on the live
    /// conversation, not an archive of it.
    static let turnsPerSession = 60
}

enum RemoteRecordType: String, Codable, Sendable, CaseIterable {
    case session = "Session", turn = "Turn", permission = "Permission", command = "Command"
}

/// A value that lives in one CloudKit record.
protocol RemotePayload: Codable, Equatable, Sendable {
    static var recordType: RemoteRecordType { get }
    var recordName: String { get }
    /// The Mac the record belongs to: its `RemoteMirror.hostID`.
    var host: String { get }
}

/// One agent session with a live terminal on the Mac.
struct RemoteSession: RemotePayload {
    static let recordType = RemoteRecordType.session
    enum State: String, Codable, Sendable { case working, idle, asking }

    var id: String
    var title: String
    var project: String?
    var cli: String
    var state: State
    var host: String
    /// The Mac's name, so a phone paired with two Macs can tell their sessions apart.
    var hostName: String
    var updatedAt: Date

    var recordName: String { Self.recordName(id) }
    static func recordName(_ id: String) -> String { "session:\(id)" }
}

/// One turn of a session's conversation, cut down for a phone.
struct RemoteTurn: RemotePayload {
    static let recordType = RemoteRecordType.turn
    enum Role: String, Codable, Sendable { case user, assistant }

    struct Block: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case text, thinking, tool }
        var type: Kind
        var text: String?
        /// A tool block: its name, the adapter's one-line summary, and what it ran or touched.
        var name: String?
        var summary: String?
        var command: String?
        var path: String?
        var output: String?
        var isError: Bool?
        /// `run`, `read`, `edit`, … as the CLI's adapter reports it.
        var kind: String?
        /// Something in this block was cut to fit.
        var truncated: Bool?
    }

    var id: String
    var session: String
    var host: String
    var role: Role
    var timestamp: Date?
    /// Where the turn sits in the conversation. Turns are sorted by it.
    var order: Double
    var blocks: [Block]

    var recordName: String { Self.recordName(session: session, id: id) }
    static func recordName(session: String, id: String) -> String { "turn:\(session):\(id)" }
    static func session(ofRecordName name: String) -> String? {
        let parts = name.split(separator: ":", maxSplits: 2)
        return parts.count == 3 && parts[0] == "turn" ? String(parts[1]) : nil
    }
}

/// A tool approval an agent is waiting on.
struct RemotePermission: RemotePayload {
    static let recordType = RemoteRecordType.permission

    var id: String
    var session: String
    var host: String
    var tool: String
    var kind: String?
    var detail: String
    var reason: String
    /// Too long to show whole. The phone must not offer Allow for what it cannot show.
    var truncated: Bool
    var createdAt: Date

    var recordName: String { Self.recordName(id) }
    static func recordName(_ id: String) -> String { "permission:\(id)" }
}

/// Something the phone asks the Mac to do.
struct RemoteCommand: RemotePayload {
    static let recordType = RemoteRecordType.command
    enum Action: String, Codable, Sendable { case message, allow, deny }
    enum Status: String, Codable, Sendable { case pending, delivered, failed }

    var id: String
    var session: String
    /// The Mac the session runs on; no other Mac acts on it.
    var host: String
    var action: Action
    /// The message, for `message`.
    var text: String?
    /// The request answered, for `allow` and `deny`.
    var permission: String?
    var device: String
    var createdAt: Date
    var status: Status = .pending
    /// Why it failed, in words the phone shows.
    var message: String?

    var recordName: String { Self.recordName(id) }
    static func recordName(_ id: String) -> String { "command:\(id)" }
}

/// A record as the local mirror keeps it: its value, and CloudKit's system fields once the server
/// has seen it, so the next save is an update rather than a conflict.
struct RemoteEntry: Codable, Equatable, Sendable {
    var type: RemoteRecordType
    /// The Mac the record belongs to, kept beside the payload so it is known without decoding it.
    var host: String
    var payload: Data
    var systemFields: Data?

    func decode<T: RemotePayload>(_: T.Type) -> T? {
        guard type == T.recordType else { return nil }
        return try? RemoteCodec.decoder.decode(T.self, from: payload)
    }
}

enum RemoteCodec {
    /// Sorted keys, so an unchanged value encodes to the same bytes and is not sent again.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func entry<T: RemotePayload>(_ value: T) throws -> RemoteEntry {
        RemoteEntry(type: T.recordType, host: value.host, payload: try encoder.encode(value))
    }
}
