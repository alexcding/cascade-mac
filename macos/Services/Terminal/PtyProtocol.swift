import Foundation

enum PtyError: LocalizedError, Sendable {
    case connection(String), socket(Int32), protocolMismatch(UInt32), timeout, closed, overflow
    var permitsReconnect: Bool {
        switch self {
        case .closed, .timeout: true
        case .socket(let code): [ENOENT, ECONNREFUSED, ECONNRESET, ENOTCONN, EPIPE].contains(code)
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .connection(let text): text
        case .socket(let code): String(cString: strerror(code))
        case .protocolMismatch(let version): "Terminal daemon protocol \(version) is incompatible; expected 2."
        case .timeout: "The terminal daemon did not respond."
        case .closed: "The terminal daemon connection closed."
        case .overflow: "The terminal connection exceeded its bounded buffer."
        }
    }
}

struct PtyInfo: Codable, Sendable, Identifiable {
    let id: String
    let cwd: String
    let title: String
    let paired: Bool
    let pairKey: String
    let hasContext: Bool
    let pid: UInt32
    let created: UInt64
    var stateResponseOwner: String? = nil
    var terminalProfile: PtyTerminalProfile? = nil
    var geometryResponseOwner: String? = nil
    var appearanceResponseOwner: String? = nil

    func validateStateResponseOwner() throws {
        if let appearanceResponseOwner, appearanceResponseOwner != PtyHello.appearanceResponseOwnerVersion || geometryResponseOwner == nil {
            throw PtyError.connection("This shell has an incompatible appearance owner. The existing shell has been preserved.")
        }
        if let geometryResponseOwner {
            guard geometryResponseOwner == PtyHello.geometryResponseOwnerVersion,
                  stateResponseOwner == PtyHello.identityResponseOwnerVersion else {
                throw PtyError.connection("This shell has an incompatible terminal geometry owner. The existing shell has been preserved.")
            }
        }
        if stateResponseOwner == PtyHello.stateResponseOwnerVersion && terminalProfile == nil { return }
        guard stateResponseOwner == PtyHello.identityResponseOwnerVersion, let terminalProfile else {
            throw PtyError.connection("This shell uses an older terminal response owner. Save its work and close it explicitly before creating a new terminal. The existing shell has been preserved.")
        }
        try terminalProfile.validate()
    }
}

struct PtyHello: Decodable, Sendable {
    static let stateResponseOwnerVersion = "daemon-state-v1"
    static let identityResponseOwnerVersion = "daemon-identity-v1"
    static let appearanceResponseOwnerVersion = "daemon-appearance-v1"
    static let geometryResponseOwnerVersion = "daemon-geometry-graphics-v2"
    let `protocol`: UInt32
    let pid: Int32
    let dataEncoding: String?
    let acknowledgedInput: Bool?
    var snapshotRevision: String? = nil
    var stateResponseOwner: String? = nil
    var identityResponseOwner: String? = nil
    var shellIntegration: Bool? = nil
    var geometryResponseOwner: String? = nil

    var appearanceResponseOwner: String? = nil
    func validateAppearanceResponseOwner() throws {
        guard appearanceResponseOwner == Self.appearanceResponseOwnerVersion else {
            throw PtyError.connection("This PTY helper cannot preserve configured terminal colors. Existing shells have been preserved; rebuild the helper after saving your work and quitting explicitly.")
        }
    }

    func validateGeometryResponseOwner() throws {
        guard geometryResponseOwner == Self.geometryResponseOwnerVersion else {
            throw PtyError.connection("This PTY helper cannot preserve terminal pixel geometry. Save your work, quit Craft explicitly, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }

    func validateShellIntegration() throws {
        guard shellIntegration == true else {
            throw PtyError.connection("This PTY helper cannot preserve native shell integration. Save your work, quit Craft explicitly, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }

    func validateIdentityResponseOwner() throws {
        guard identityResponseOwner == Self.identityResponseOwnerVersion else {
            throw PtyError.connection("This PTY helper cannot preserve the native terminal identity. Save your work, quit Craft explicitly, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }

    func validateStateResponseOwner() throws {
        guard stateResponseOwner == Self.stateResponseOwnerVersion else {
            throw PtyError.connection("This PTY helper cannot own terminal state replies. Save your work, quit Craft explicitly, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }

    func validateSnapshots() throws {
        guard snapshotRevision == PtySnapshot.revision else {
            throw PtyError.connection("This PTY helper cannot provide compatible terminal snapshots. Save your work, quit Craft explicitly, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }

    func validateInputAcknowledgements() throws {
        guard acknowledgedInput == true else {
            throw PtyError.connection("This PTY helper cannot acknowledge input failures. Save your work, quit Craft explicitly, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }

    func validateByteTransport() throws {
        guard dataEncoding == "base64" else {
            throw PtyError.connection("This PTY helper cannot preserve terminal bytes. Quit Craft explicitly after saving your work, rebuild the helper, and reopen. Existing shells have been preserved.")
        }
    }
}

struct PtyAttachment: Decodable, Sendable {
    let bytes: Data
    let seq: UInt64
    let live: Bool
    let truncated: Bool?

    func validateReplay() throws {
        guard live else { throw PtyError.connection("The terminal exited before attachment.") }
        guard let truncated else {
            throw PtyError.connection("This PTY helper cannot report incomplete history. Rebuild the helper before reattaching.")
        }
        guard !truncated else {
            throw PtyError.connection("Terminal history was truncated; the screen cannot be restored reliably. The shell is still running. Full-state restoration is required.")
        }
    }
}

struct PtyEvent: Decodable, Sendable {
    let ev: String
    let id: String
    let bytes: Data?
    let seq: UInt64?
    let exitCode: Int?
    let signal: Int?
    var message: String? = nil
    var stateSeq: UInt64? = nil
    var cols: UInt16? = nil
    var rows: UInt16? = nil
    var geometry: PtyGeometry? = nil
    var appearance: PtyAppearance? = nil
}

struct PtyRequest: Encodable, Sendable {
    struct Options: Encodable, Sendable {
        var cwd: String
        var shell: String?
        var paired = false
        var pairKey: String
        var stateResponseOwner: String? = nil
        var terminalProfile: PtyTerminalProfile? = nil
        var geometryResponseOwner: String? = nil
        var geometry: PtyGeometry? = nil
        var appearanceResponseOwner: String? = nil
        var appearance: PtyAppearance? = nil
    }
    var id: UInt64?
    var op: String
    var term: String?
    var data: String?
    var bytes: Data?
    var dataEncoding: String?
    var cols: UInt16?
    var rows: UInt16?
    var pause: Bool?
    var opts: Options?
    var snapshotRevision: String?
    var token: UInt64?
    var offset: Int?
    var geometry: PtyGeometry?
    var appearance: PtyAppearance?
}

// Stream framing is independent of socket reads. Decode only complete UTF-8 JSON
// lines; raw reads can split both escape sequences and multibyte characters.
struct PtyFramer {
    private var pending = Data()
    var limit = 2 * 1024 * 1024

    mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if byte == 10 {
                if !pending.isEmpty { frames.append(pending) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < limit else { throw PtyError.overflow }
                pending.append(byte)
            }
        }
        return frames
    }
}
