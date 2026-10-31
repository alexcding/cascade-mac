import CoreGraphics
import Foundation

// The Simulator pane's side of the backend's device layer (`crates/cascade-backend/src/device/`):
// the shapes its routes answer and its events carry, as Synara's device contract names them, and
// the routes themselves. An owner is the working folder a session's agents work in, its worktree.

struct DeviceGeometry: Codable, Equatable, Sendable {
    let pointWidth: Double
    let pointHeight: Double
    let scale: Double
}

enum DeviceRuntimeState: String, Codable, Equatable, Sendable {
    case shutdown, booting, booted, shuttingDown = "shutting-down"

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A state this app does not know yet is taken for one in transition: never picked or streamed.
        self = Self(rawValue: raw) ?? .booting
    }

    var label: String {
        switch self {
        case .shutdown: String(localized: "Shut down")
        case .booting: String(localized: "Booting")
        case .booted: String(localized: "Booted")
        case .shuttingDown: String(localized: "Shutting down")
        }
    }
}

struct DeviceDescriptor: Codable, Equatable, Sendable, Identifiable {
    let udid: String
    let name: String
    /// e.g. `iOS 18.2`.
    let runtime: String
    let state: DeviceRuntimeState
    /// `cascade` for a device Cascade booted (and shuts down again), `user` for any other.
    var bootSource: String = "user"
    /// `phone` or `tablet`.
    var family: String?
    var geometry: DeviceGeometry?
    var id: String { udid }

    init(udid: String, name: String, runtime: String, state: DeviceRuntimeState, bootSource: String = "user",
         family: String? = nil, geometry: DeviceGeometry? = nil) {
        self.udid = udid; self.name = name; self.runtime = runtime; self.state = state
        self.bootSource = bootSource; self.family = family; self.geometry = geometry
    }

    var pointSize: CGSize? {
        guard let geometry, geometry.pointWidth > 0, geometry.pointHeight > 0 else { return nil }
        return CGSize(width: geometry.pointWidth, height: geometry.pointHeight)
    }
}

struct DeviceSetupStep: Codable, Equatable, Sendable, Identifiable {
    /// `install-xcode`, `accept-xcode-license`, `select-xcode-command-line-tools`,
    /// `install-ios-runtime`, `build-device-helper`.
    let id: String
    let label: String
    let done: Bool
    var detail: String?
}

struct DeviceCapabilityStatus: Codable, Equatable, Sendable {
    /// `framebuffer`, `hid`, `accessibility`, `encoder`.
    let id: String
    let ok: Bool
    var missingSymbol: String?
    var detail: String?

    var label: String {
        switch id {
        case "framebuffer": String(localized: "Screen capture")
        case "hid": String(localized: "Touch and keyboard input")
        case "accessibility": String(localized: "Accessibility inspection")
        case "encoder": String(localized: "Video encoding")
        default: id
        }
    }
}

struct DeviceToolchain: Codable, Equatable, Sendable {
    var xcodeVersion: String?
    var xcodeBuild: String?
}

/// Whether the pane can run here, and if not what stands in the way.
enum DeviceAvailability: Decodable, Equatable, Sendable {
    case available
    case unsupportedPlatform(String)
    case setupRequired([DeviceSetupStep])
    /// Set up and running, but some capability failed its preflight (an Xcode moved a symbol).
    case degraded([DeviceCapabilityStatus], DeviceToolchain?)
    /// The helper is compiled against the user's Xcode on first use, and that failed.
    case helperUnavailable(String)

    private enum Keys: String, CodingKey { case kind, platform, steps, capabilities, toolchain, message }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "unsupported-platform": self = .unsupportedPlatform(try values.decodeIfPresent(String.self, forKey: .platform) ?? "")
        case "setup-required": self = .setupRequired(try values.decodeIfPresent([DeviceSetupStep].self, forKey: .steps) ?? [])
        case "degraded":
            self = .degraded(try values.decodeIfPresent([DeviceCapabilityStatus].self, forKey: .capabilities) ?? [],
                             try values.decodeIfPresent(DeviceToolchain.self, forKey: .toolchain))
        case "helper-unavailable": self = .helperUnavailable(try values.decodeIfPresent(String.self, forKey: .message) ?? "")
        default: self = .available
        }
    }

    /// Synara `resolveDeviceAvailabilityView`: what the pane shows instead of the picker, if anything.
    /// The helper is the one setup step nobody does by hand — choosing a device builds it — so when
    /// it is all that is left the picker shows.
    var blocker: Blocker? {
        switch self {
        case .available, .degraded: return nil
        case .unsupportedPlatform(let platform):
            return Blocker(title: String(localized: "iOS Simulator needs macOS"),
                           detail: String(localized: "This backend runs on \(platform). Simulators run only on a Mac with Xcode."),
                           steps: [], retryable: false)
        case .setupRequired(let steps):
            let remaining = steps.filter { !$0.done }
            if !remaining.isEmpty, remaining.allSatisfy({ $0.id == "build-device-helper" }) { return nil }
            return Blocker(title: String(localized: "Set up the iOS Simulator"),
                           detail: String(localized: "Each step is checked again until it is done."), steps: steps, retryable: true)
        case .helperUnavailable(let message):
            return Blocker(title: String(localized: "The simulator helper could not start"), detail: message, steps: [], retryable: true)
        }
    }

    struct Blocker: Equatable {
        let title: String
        let detail: String
        let steps: [DeviceSetupStep]
        /// Worth asking again: the user can fix it outside the app.
        let retryable: Bool
    }

    /// One line naming what a degraded helper cannot do, and what still works.
    var degradedNotice: String? {
        guard case .degraded(let capabilities, let toolchain) = self else { return nil }
        let broken = capabilities.filter { !$0.ok }.map(\.label)
        guard !broken.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: broken)
        if let version = toolchain?.xcodeVersion { return String(localized: "\(names) unavailable with Xcode \(version).") }
        return String(localized: "\(names) unavailable.")
    }
}

enum DeviceAttachPhase: String, Codable, Equatable, Sendable {
    case booting, waitingForDisplay = "waiting-for-display", connecting

    var label: String {
        switch self {
        case .booting: String(localized: "Starting up…")
        case .waitingForDisplay: String(localized: "Waiting for the screen…")
        case .connecting: String(localized: "Connecting…")
        }
    }
}

/// What an owner's pane shows (`device::manager::OwnerDeviceState`).
struct OwnerDeviceState: Decodable, Equatable, Sendable {
    let owner: String
    /// Monotonic per owner: an older state is never shown over a newer one.
    let version: UInt64
    let attachedDeviceUdid: String?
    let attachPhase: DeviceAttachPhase?
    let devices: [DeviceDescriptor]
    /// An agent's tool is driving the device right now.
    let agentActive: Bool
    let availability: DeviceAvailability
    let lastError: String?

    init(owner: String, version: UInt64, attachedDeviceUdid: String? = nil, attachPhase: DeviceAttachPhase? = nil,
         devices: [DeviceDescriptor] = [], agentActive: Bool = false, availability: DeviceAvailability = .available,
         lastError: String? = nil) {
        self.owner = owner; self.version = version; self.attachedDeviceUdid = attachedDeviceUdid
        self.attachPhase = attachPhase; self.devices = devices; self.agentActive = agentActive
        self.availability = availability; self.lastError = lastError
    }

    var attachedDevice: DeviceDescriptor? {
        attachedDeviceUdid.flatMap { udid in devices.first { $0.udid == udid } }
    }
}

enum DeviceBootResult: Decodable, Equatable, Sendable {
    case booted(DeviceDescriptor)
    /// Cascade already runs as many simulators as it boots: the ones it could shut down to make room.
    case bootLimitReached(limit: Int, cascadeBooted: [DeviceDescriptor])

    private enum Keys: String, CodingKey { case kind, device, limit, cascadeBooted }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        if try values.decode(String.self, forKey: .kind) == "boot-limit-reached" {
            self = .bootLimitReached(limit: try values.decode(Int.self, forKey: .limit),
                                     cascadeBooted: try values.decodeIfPresent([DeviceDescriptor].self, forKey: .cascadeBooted) ?? [])
        } else {
            self = .booted(try values.decode(DeviceDescriptor.self, forKey: .device))
        }
    }
}

/// The owner a folder names, as the backend keys it (`device::service::normalize_owner`): trimmed,
/// without a trailing slash, and with its symlinks resolved when it exists, since a terminal's
/// agent reports `pwd -P` while the session knows its worktree by the path it was stored under.
/// `realpath(3)`, as Rust's `canonicalize` is: `URL.resolvingSymlinksInPath` strips `/private`.
func deviceOwner(_ folder: String) -> String {
    let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    var stripped = Substring(trimmed)
    while stripped.hasSuffix("/") { stripped = stripped.dropLast() }
    let plain = stripped.isEmpty && trimmed.hasPrefix("/") ? "/" : String(stripped)
    guard plain.hasPrefix("/"), let resolved = realpath(plain, nil) else { return plain }
    defer { free(resolved) }
    return String(cString: resolved)
}

protocol DeviceServing: Sendable {
    func state(owner: String) async throws -> OwnerDeviceState
    func boot(udid: String) async throws -> DeviceBootResult
    func shutdown(udid: String) async throws
    /// Answers once the attachment is recorded; the stream comes up behind it, told as events.
    func attach(owner: String, udid: String) async throws -> OwnerDeviceState
    func detach(owner: String) async throws -> OwnerDeviceState
    /// Device points.
    func tap(udid: String, at point: CGPoint) async throws
    func swipe(udid: String, from: CGPoint, to: CGPoint, durationMs: Int) async throws
    func type(udid: String, text: String) async throws
    func key(udid: String, usage: UInt16, modifiers: [DeviceKeyboard.Modifier], down: Bool) async throws
    func press(udid: String, button: DeviceKeyboard.Button) async throws
    /// The Unix socket the device's video is read from.
    func frameSocket(owner: String, udid: String) async throws -> String
}

struct APIDeviceService: DeviceServing {
    let api: APIClient
    private struct Nothing: Decodable, Sendable {}
    private struct Socket: Decodable, Sendable { let socketPath: String }
    private struct Owner: Encodable, Sendable { let owner: String }
    private struct Udid: Encodable, Sendable { let udid: String }
    private struct Attach: Encodable, Sendable { let owner: String; let udid: String }
    private struct Tap: Encodable, Sendable { let udid: String; let x: Double; let y: Double }
    private struct Swipe: Encodable, Sendable {
        let udid: String; let fromX: Double; let fromY: Double; let toX: Double; let toY: Double; let durationMs: Int
    }
    private struct TypeText: Encodable, Sendable { let udid: String; let text: String }
    private struct Key: Encodable, Sendable {
        let udid: String; let keyCode: UInt16; let modifiers: [DeviceKeyboard.Modifier]; let direction: String
    }
    private struct Button: Encodable, Sendable { let udid: String; let button: DeviceKeyboard.Button }

    func state(owner: String) async throws -> OwnerDeviceState {
        try await api.request(Routes.DEVICE_STATE, method: "POST", body: Owner(owner: owner), timeout: 60)
    }
    func boot(udid: String) async throws -> DeviceBootResult {
        // A cold boot takes the better part of a minute.
        try await api.request(Routes.DEVICE_BOOT, method: "POST", body: Udid(udid: udid), timeout: 240)
    }
    func shutdown(udid: String) async throws {
        let _: Nothing = try await api.request(Routes.DEVICE_SHUTDOWN, method: "POST", body: Udid(udid: udid), timeout: 120)
    }
    func attach(owner: String, udid: String) async throws -> OwnerDeviceState {
        try await api.request(Routes.DEVICE_ATTACH, method: "POST", body: Attach(owner: owner, udid: udid), timeout: 60)
    }
    func detach(owner: String) async throws -> OwnerDeviceState {
        try await api.request(Routes.DEVICE_DETACH, method: "POST", body: Owner(owner: owner), timeout: 60)
    }
    func tap(udid: String, at point: CGPoint) async throws {
        let _: Nothing = try await api.request(Routes.DEVICE_TAP, method: "POST", body: Tap(udid: udid, x: point.x, y: point.y), timeout: 20)
    }
    func swipe(udid: String, from: CGPoint, to: CGPoint, durationMs: Int) async throws {
        let body = Swipe(udid: udid, fromX: from.x, fromY: from.y, toX: to.x, toY: to.y, durationMs: durationMs)
        let _: Nothing = try await api.request(Routes.DEVICE_SWIPE, method: "POST", body: body, timeout: 30)
    }
    func type(udid: String, text: String) async throws {
        let _: Nothing = try await api.request(Routes.DEVICE_TYPE, method: "POST", body: TypeText(udid: udid, text: text), timeout: 30)
    }
    func key(udid: String, usage: UInt16, modifiers: [DeviceKeyboard.Modifier], down: Bool) async throws {
        let body = Key(udid: udid, keyCode: usage, modifiers: modifiers, direction: down ? "down" : "up")
        let _: Nothing = try await api.request(Routes.DEVICE_KEY, method: "POST", body: body, timeout: 20)
    }
    func press(udid: String, button: DeviceKeyboard.Button) async throws {
        let _: Nothing = try await api.request(Routes.DEVICE_BUTTON, method: "POST", body: Button(udid: udid, button: button), timeout: 20)
    }
    func frameSocket(owner: String, udid: String) async throws -> String {
        let socket: Socket = try await api.request(Routes.DEVICE_FRAMES, method: "POST", body: Attach(owner: owner, udid: udid), timeout: 20)
        return socket.socketPath
    }
}
