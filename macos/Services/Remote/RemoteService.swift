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
    /// The paired Mac's projects, name and icon only: its sessions are listed under them.
    func projects(peer id: String) async throws -> [RemoteProject]
    /// Each of the paired Mac's sessions' agent states, as its app draws them; an older Cascade
    /// there does not serve them, and the read fails.
    func sessionStatus(peer id: String) async throws -> [String: RemoteSessionStatus]
    /// A paired Mac's session's conversation, named by the session; with `thread`, as the chat
    /// page's read-only thread (`{revision, snapshot}`).
    func sessionTranscript(peer id: String, session: String, since: String?) async throws -> AgentTranscript
    func sessionTranscriptThread(peer id: String, session: String, threadID: String, since: String?) async throws -> JSONValue
    /// Asks a paired Mac to do something with a session or project there (`RemoteCommand`): done
    /// at once (a rename), or handed to its app, whose answer comes as `session-command-done`.
    func command(peer id: String, _ command: RemoteCommand) async throws -> RemoteCommandAccepted
    /// This app's answer to a paired Mac's command, by its key.
    func commandResult(key: String, ok: Bool, error: String?, data: JSONValue?) async throws
    /// Tells the backend this Mac's sessions' agent states, for paired Macs' sidebars.
    func setSessionStatus(_ sessions: [String: RemoteSessionStatus]) async throws
    /// Opens a connection to the paired Mac's session terminals and answers the local socket the
    /// app's terminal client connects to, once, as to its own daemon (`TerminalSession.remote`).
    func openTerminal(peer id: String) async throws -> String
    /// Tells the backend where this app's terminal daemon listens, for paired Macs' terminals.
    func setTerminalDaemon(socket: String) async throws
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
    func projects(peer id: String) async throws -> [RemoteProject] {
        try await api.get(Routes.remotePeerProjects(id), timeout: 20)
    }
    func sessionStatus(peer id: String) async throws -> [String: RemoteSessionStatus] {
        try await api.get(Routes.remotePeerSessionStatus(id), timeout: 20)
    }
    func sessionTranscript(peer id: String, session: String, since: String?) async throws -> AgentTranscript {
        var query = ["task": session]
        if let since { query["since"] = since }
        return try await api.get(APIClient.query(Routes.remotePeerSessionTranscript(id), query), timeout: 20)
    }
    func sessionTranscriptThread(peer id: String, session: String, threadID: String, since: String?) async throws -> JSONValue {
        var query = ["task": session, "format": "thread", "threadId": threadID]
        if let since { query["since"] = since }
        return try await api.get(APIClient.query(Routes.remotePeerSessionTranscript(id), query), timeout: 20)
    }
    func command(peer id: String, _ command: RemoteCommand) async throws -> RemoteCommandAccepted {
        try await api.request(Routes.remotePeerSessionCommand(id), method: "POST", body: command, timeout: 20)
    }
    func commandResult(key: String, ok: Bool, error: String?, data: JSONValue?) async throws {
        struct Body: Encodable, Sendable { let key: String; let ok: Bool; let error: String?; let data: JSONValue? }
        let _: OK = try await api.request(Routes.REMOTE_COMMAND_RESULT, method: "POST", body: Body(key: key, ok: ok, error: error, data: data))
    }
    func setSessionStatus(_ sessions: [String: RemoteSessionStatus]) async throws {
        let _: OK = try await api.request(Routes.REMOTE_SESSION_STATUS, method: "POST", body: ["sessions": sessions])
    }
    func openTerminal(peer id: String) async throws -> String {
        struct Opened: Decodable, Sendable { let socket: String }
        let opened: Opened = try await api.request(Routes.remotePeerTerminal(id), method: "POST", body: Empty(), timeout: 30)
        return opened.socket
    }
    func setTerminalDaemon(socket: String) async throws {
        let _: OK = try await api.request(Routes.REMOTE_TERMINAL_DAEMON, method: "POST", body: ["socket": socket])
    }
    func chat(peer id: String) -> any ChatServing { APIChatService(api: api, path: Routes.remotePeerChatRPC(id)) }
}

/// What a paired Mac is asked to do with a session (`task`) or in a project there: `rename`
/// (args `name`), `start`, `removal` (what removing would lose), `remove`, `fork`, `create`.
struct RemoteCommand: Encodable, Sendable, Equatable {
    var op: String
    var task: String?
    var project: String?
    var args: [String: JSONValue] = [:]
}

/// New Task on a paired Mac's project: a session there on a new branch, its agent started there
/// with the first message, if one is given.
struct RemoteNewTask: Equatable, Sendable {
    var branch: String
    var agent: SessionAgent
    var prompt: String
}

/// A paired Mac's answer to a command: done, or handed to its app under `key`.
struct RemoteCommandAccepted: Decodable, Sendable {
    var done: Bool?
    var key: String?
}

/// A session's agent state as its Mac's app draws it: its terminal running, its agent working,
/// or waiting for an answer.
struct RemoteSessionStatus: Codable, Equatable, Sendable {
    var live = false
    var busy = false
    var needsInput = false
    /// Known to be at its prompt, as its hooks said.
    var idle = false
    var cli: String?
    /// The agent's conversation, and the terminal it runs in: the host reads the session's
    /// transcript by them (`listener::session_transcript`).
    var conversation: String?
    var runID: String?

    enum CodingKeys: String, CodingKey { case live, busy, needsInput, idle, cli, conversation, runID = "runId" }
}

/// A paired Mac's project, as it shows one to this Mac: no path, repository or Jira.
struct RemoteProject: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    var icon: String?
}

/// Where a remote session's terminal is reached (`TerminalSession.remote`): the Mac's name, for
/// what the terminal says, and a fresh relayed socket for each connect.
struct RemoteTerminalSource: Sendable {
    let name: String
    let socket: @Sendable () async throws -> String
}
