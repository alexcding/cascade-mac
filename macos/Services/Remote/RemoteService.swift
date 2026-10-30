import Foundation

/// This Mac's listener for other Macs, as `GET /api/remote` reports it.
struct RemoteStatus: Decodable, Equatable, Sendable {
    var enabled: Bool
    var port: Int?
    /// The certificate's SHA-256: what a paired Mac pins, and the `id` this Mac advertises.
    var fingerprint: String?
}

/// A Mac paired with this one, which may read its sessions (host side).
struct RemoteClient: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var label: String
    var createdAt: String
    var lastSeenAt: String?
}

/// A Mac this one paired with, whose sessions it shows (client side).
struct RemotePeer: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var addresses: [String]
    var reach: Reach = .offline

    enum Reach: String, Decodable, Sendable {
        case connecting, online, offline, revoked, changed
    }

    private enum CodingKeys: String, CodingKey { case id, name, addresses, reach }

    init(id: String, name: String, addresses: [String] = [], reach: Reach = .offline) {
        self.id = id; self.name = name; self.addresses = addresses; self.reach = reach
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
        // A state this build does not know reads as offline.
        reach = (try? container.decodeIfPresent(Reach.self, forKey: .reach)) ?? .offline
    }
}

/// The pairing window this Mac has open for another to pair in.
struct RemotePairingWindow: Decodable, Equatable, Sendable {
    var open: Bool
    var attemptsLeft: Int
    var seconds: Int
}

struct RemotePairingCode: Decodable, Equatable, Sendable {
    let code: String
    let seconds: Int
}

/// The remote routes of this Mac's own backend. A fake implements it in tests.
protocol RemoteServing: Sendable {
    func status() async throws -> RemoteStatus
    func setEnabled(_ enabled: Bool) async throws -> RemoteStatus
    func clients() async throws -> [RemoteClient]
    func revoke(client id: String) async throws
    func openPairing(name: String?) async throws -> RemotePairingCode
    func pairingWindow() async throws -> RemotePairingWindow
    func closePairing() async throws
    func peers() async throws -> [RemotePeer]
    /// Pairs with the Mac at `address` showing `code`; it lists this Mac as `label`.
    func pair(address: String, code: String, label: String?) async throws -> RemotePeer
    func forget(peer id: String) async throws
    /// Tries a paired Mac again, at `address` first when Bonjour sees it there.
    func connect(peer id: String, address: String?) async throws
    func sessions(peer id: String) async throws -> [WorkspaceSession]
    /// The paired Mac's chat engine, through this Mac's backend; the other Mac answers only reads.
    func chat(peer id: String) -> any ChatServing
}

struct APIRemoteService: RemoteServing {
    let api: APIClient

    private struct OK: Decodable, Sendable {}
    private struct Empty: Encodable, Sendable {}

    func status() async throws -> RemoteStatus { try await api.get(Routes.REMOTE) }
    func setEnabled(_ enabled: Bool) async throws -> RemoteStatus {
        try await api.request(enabled ? Routes.REMOTE_ENABLE : Routes.REMOTE_DISABLE, method: "POST", body: Empty())
    }
    func clients() async throws -> [RemoteClient] { try await api.get(Routes.REMOTE_CLIENTS) }
    func revoke(client id: String) async throws {
        let _: OK = try await api.request(Routes.remoteClient(id), method: "DELETE", body: Empty())
    }
    func openPairing(name: String?) async throws -> RemotePairingCode {
        try await api.request(Routes.REMOTE_PAIRING, method: "POST", body: name.map { ["name": $0] } ?? [:])
    }
    func pairingWindow() async throws -> RemotePairingWindow { try await api.get(Routes.REMOTE_PAIRING) }
    func closePairing() async throws {
        let _: OK = try await api.request(Routes.REMOTE_PAIRING, method: "DELETE", body: Empty())
    }
    func peers() async throws -> [RemotePeer] { try await api.get(Routes.REMOTE_PEERS) }
    func pair(address: String, code: String, label: String?) async throws -> RemotePeer {
        var body = ["address": address, "code": code]
        if let label { body["label"] = label }
        // Pairing waits on the other Mac: up to half a minute for the exchange.
        return try await api.request(Routes.REMOTE_PEERS_PAIR, method: "POST", body: body, timeout: 45)
    }
    func forget(peer id: String) async throws {
        let _: OK = try await api.request(Routes.remotePeer(id), method: "DELETE", body: Empty())
    }
    func connect(peer id: String, address: String?) async throws {
        let _: OK = try await api.request(Routes.remotePeerConnect(id), method: "POST", body: address.map { ["address": $0] } ?? [:])
    }
    func sessions(peer id: String) async throws -> [WorkspaceSession] {
        try await api.get(Routes.remotePeerTasks(id), timeout: 20)
    }
    func chat(peer id: String) -> any ChatServing { APIChatService(api: api, path: Routes.remotePeerChatRPC(id)) }
}
