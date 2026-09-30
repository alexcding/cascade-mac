import CloudKit
import CryptoKit
import Foundation

// What the Mac mirrors to the user's CloudKit private database and what the phone writes back.
// Cascade Remote, the iPhone app in the cascade-ios repository, compiles a copy of this folder.
// It is the wire format between the two apps: change both copies together. Foundation, CloudKit
// and CryptoKit only: no AppKit, UIKit or app types.
//
// One writer per record, so nothing ever needs merging: each Mac writes its own host record,
// sessions, turns and permissions; each phone writes its own device record and creates commands
// addressed to one Mac, and only that Mac marks them handled. Every Mac record names the Mac it
// belongs to (`host`), so two Macs on one Apple Account never touch each other's.
//
// Reading is open to every device on the Apple Account: that is what iCloud is. Acting is not. A
// command is signed by the phone's own key, and a Mac carries it out only for a phone its owner
// approved on that Mac.

enum RemoteSchema {
    static let container = "iCloud.com.alexcding.cascade"
    static let zone = CKRecordZone.ID(zoneName: "Remote", ownerName: CKCurrentUserDefaultName)
    /// Every record carries its whole value, end-to-end encrypted, under this one key.
    static let payloadKey = "payload"
    /// And the Mac it belongs to, in the clear: an opaque ID, readable without decrypting.
    /// `phoneHost` for a phone's own device record.
    static let hostKey = "host"
    static let phoneHost = "phone"
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
    /// How often an open phone says it is there.
    static let heartbeat: TimeInterval = 300
    /// A Mac mirrors conversations only while an approved phone has said so this recently: with no
    /// phone looking, transcripts stay on the Mac.
    static let phoneActive: TimeInterval = 3 * heartbeat
    /// The most of a file change's old or new side an approval carries. Past it the request is
    /// marked too long, and the phone may only deny it.
    static let maxChange = 6_000
}

enum RemoteRecordType: String, Codable, Sendable, CaseIterable {
    case session = "Session", turn = "Turn", permission = "Permission", command = "Command"
    case host = "Host", device = "Device"
}

/// A value that lives in one CloudKit record.
protocol RemotePayload: Codable, Equatable, Sendable {
    static var recordType: RemoteRecordType { get }
    var recordName: String { get }
    /// The Mac the record belongs to: its `RemoteMirror.hostID`. `RemoteSchema.phoneHost` for a
    /// phone's own record.
    var host: String { get }
}

/// A Mac that mirrors, and the phones its owner has approved to act on it.
struct RemoteHost: RemotePayload {
    static let recordType = RemoteRecordType.host

    var host: String
    var name: String
    /// Device IDs. A phone reads this to know whether its commands will be carried out.
    var approved: [String]
    /// Device IDs turned away here, so a phone can say so rather than keep asking.
    var denied: [String]

    var recordName: String { Self.recordName(host) }
    static func recordName(_ host: String) -> String { "host:\(host)" }
}

extension RemoteHost {
    /// `denied` is read if it is there: a Mac on a build before it still says whom it approved.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decode(String.self, forKey: .host)
        name = try values.decode(String.self, forKey: .name)
        approved = try values.decode([String].self, forKey: .approved)
        denied = try values.decodeIfPresent([String].self, forKey: .denied) ?? []
    }
}

/// A phone running Cascade Remote, as it introduces itself.
struct RemoteDevice: RemotePayload {
    static let recordType = RemoteRecordType.device

    /// Derived from `publicKey` (`RemoteSigning.deviceID`), so a record cannot claim another's.
    var id: String
    var name: String
    /// P-256, X9.63. The private half never leaves the phone.
    var publicKey: Data
    /// When the app was last open. Mirroring follows it (`RemoteSchema.phoneActive`).
    var lastSeen: Date

    var host: String { RemoteSchema.phoneHost }
    var recordName: String { Self.recordName(id) }
    static func recordName(_ id: String) -> String { "device:\(id)" }
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
    /// A file change's two sides, when the tool is one and they fit.
    var old: String?
    var new: String?
    /// Not shown whole: the detail, or a file change's sides, were too long. The phone must not
    /// offer Allow for what it cannot show, and the Mac refuses one.
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
    /// For `allow` and `deny`: `RemoteSigning.digest` of the request as the phone showed it.
    var shown: String?
    /// The phone that sent it: its `RemoteDevice.id`.
    var device: String
    /// Whole milliseconds, so it reads back exactly as it was signed.
    var createdAt: Date
    /// The phone's signature over `RemoteSigning.bytes(of:)`.
    var signature: Data?
    var status: Status = .pending
    /// Why it failed, in words the phone shows.
    var message: String?

    var recordName: String { Self.recordName(id) }
    static func recordName(_ id: String) -> String { "command:\(id)" }
}

/// How a phone proves a command is its own, and what it was looking at when it sent it.
enum RemoteSigning {
    /// A device is named by its key, so a record under another phone's ID fails to verify.
    static func deviceID(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The start of a device's ID, shown on the phone and beside it on the Mac: a name is
    /// whatever a record claims, and this is what tells the owner's phone from another. Twelve
    /// characters, 48 bits: an ID is a hash of a key its maker chooses, and fewer could be
    /// matched by making keys until one fits.
    static func code(for deviceID: String) -> String {
        let head = Array(deviceID.prefix(12).uppercased())
        return stride(from: 0, to: head.count, by: 4).map { String(head[$0..<min($0 + 4, head.count)]) }.joined(separator: "-")
    }

    /// `Date()`, to the whole millisecond a signed command keeps.
    static func now() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Fields run together with their lengths, so no text can pass for the end of one field and
    /// the start of the next. A missing value is not an empty one.
    private static func packed(_ fields: [String?]) -> Data {
        Data(fields.map { field in field.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: "\n").utf8)
    }

    /// A request exactly as a phone is shown it. An Allow carries this, so the Mac allows only
    /// what it offered: a record rewritten in iCloud on its way to the phone does not match.
    static func digest(of permission: RemotePermission) -> String {
        let shown = packed([permission.id, permission.session, permission.host, permission.tool, permission.kind,
                            permission.detail, permission.reason, permission.old, permission.new,
                            permission.truncated ? "truncated" : "whole"])
        return SHA256.hash(data: shown).map { String(format: "%02x", $0) }.joined()
    }

    /// What is signed: everything the Mac acts on. The status and message are the Mac's to write.
    static func bytes(of command: RemoteCommand) -> Data {
        let milliseconds = Int64((command.createdAt.timeIntervalSince1970 * 1000).rounded())
        return packed([command.id, command.session, command.host, command.action.rawValue, command.text,
                       command.permission, command.shown, command.device, String(milliseconds)])
    }

    /// `signer` is the phone's key, wherever it is kept.
    static func sign(_ command: RemoteCommand, using signer: (Data) throws -> P256.Signing.ECDSASignature) rethrows -> Data {
        try signer(bytes(of: command)).derRepresentation
    }

    static func sign(_ command: RemoteCommand, with key: P256.Signing.PrivateKey) throws -> Data {
        try sign(command) { try key.signature(for: $0) }
    }

    static func verify(_ command: RemoteCommand, publicKey: Data) -> Bool {
        guard let signature = command.signature,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: bytes(of: command))
    }
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
