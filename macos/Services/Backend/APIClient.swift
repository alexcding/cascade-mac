import Foundation

public enum BackendError: LocalizedError, Sendable {
    case configuration(String)
    case http(Int)
    case incompatible
    case startup(String)
    case oversizedEvent
    case operation(String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .startup(let message), .operation(let message): message
        case .http(let status): "The backend returned HTTP \(status)."
        case .incompatible: "This address is not a compatible Craft backend."
        case .oversizedEvent: "The backend sent an oversized stream event."
        }
    }
}

/// How `APIClient` reaches the backend: `URLSession` over loopback HTTP, or the
/// embedded backend's in-process dispatch (`EmbeddedTransport`). Both answer with
/// an `HTTPURLResponse`, so status and JSON handling are identical either way.
public protocol BackendTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: BackendTransport {
    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse) { try await data(for: request) }
}

public struct BackendHealth: Decodable, Sendable {
    public let service: String
    public let `protocol`: Int
    public let pid: Int32
    public let instanceId: String?
    public let runtime: String?

    public init(service: String, protocol: Int, pid: Int32, instanceId: String?, runtime: String? = nil) {
        self.service = service; self.protocol = `protocol`; self.pid = pid
        self.instanceId = instanceId; self.runtime = runtime
    }

    public func validate(instanceID: String? = nil) throws {
        guard service == "craft", self.protocol == 1, runtime == nil || runtime == "rust",
              instanceID == nil || instanceId == instanceID else { throw BackendError.incompatible }
    }
}

public struct Project: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let repo: String
    public let color: String?
    public let workspace: String
    var ide: String? = nil
    var ideTarget: String? = nil
    var runScheme: String? = nil
    var runSim: String? = nil
    var jiraProjectKey: String? = nil
    var jql: String? = nil
    var ideCmd: String? = nil
    var workflows: [WorkflowRecipe]? = nil
    var forwardWebhooks: Bool? = nil
    var mergeTransition: String? = nil
    var fixVersionEnabled: Bool? = nil
    var fixVersionPrefix: String? = nil
    var fixVersionScript: String? = nil
}

// Actor isolation keeps response decoding off the UI actor. Only decoded snapshots
// cross into the store; network operations remain cancellable.
public actor APIClient {
    private struct Failure: Decodable { let error: String? }
    public let baseURL: URL
    private let transport: any BackendTransport

    public init(baseURL: URL, session: URLSession = .shared) throws {
        try self.init(baseURL: baseURL, transport: session)
    }

    public init(baseURL: URL, transport: any BackendTransport) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "http", ["127.0.0.1", "localhost", "[::1]"].contains(parts.host ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw BackendError.configuration("The backend address must be a loopback HTTP origin.")
        }
        self.baseURL = baseURL
        self.transport = transport
    }

    public func get<T: Decodable & Sendable>(_ path: String, as type: T.Type = T.self, timeout: TimeInterval = 10) async throws -> T {
        var request = URLRequest(url: try url(path))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.perform(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
           let failure = try? JSONDecoder().decode(Failure.self, from: data), let error = failure.error {
            throw BackendError.operation(error)
        }
        try Self.validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func health() async throws -> BackendHealth {
        let value: BackendHealth = try await get(Routes.BACKEND_HEALTH)
        try value.validate()
        return value
    }

    func setPinned(_ pinned: Bool, for sessionID: String) async throws {
        struct Payload: Encodable { let pinned: Bool }
        var request = URLRequest(url: try url(Routes.taskPin(sessionID)))
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(pinned: pinned))
        let (_, response) = try await transport.perform(request)
        try Self.validate(response)
    }

    func acknowledgeReview(repo: String, number: Int) async throws {
        struct Payload: Encodable, Sendable { let repo: String; let number: Int }
        try await send(Routes.PRS_VIEWED, method: "POST", body: Payload(repo: repo, number: number))
    }

    func setSetting(_ key: String, value: String) async throws {
        struct Payload: Encodable, Sendable { let value: String }
        try await send(Routes.settingsKey(key), method: "PUT", body: Payload(value: value))
    }

    private func send<T: Encodable & Sendable>(_ path: String, method: String, body: T) async throws {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await transport.perform(request)
        try Self.validate(response)
    }

    func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String, method: String, body: Body, timeout: TimeInterval = 120
    ) async throws -> Response {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.perform(request)
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), let message = failure.error {
            throw BackendError.operation(message)
        }
        try Self.validate(response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    nonisolated static func query(_ path: String, _ values: [String: String]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        return components.string ?? path
    }

    func url(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
        else { throw BackendError.configuration("Invalid backend route.") }
        return url
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.incompatible }
        guard (200..<300).contains(http.statusCode) else { throw BackendError.http(http.statusCode) }
    }
}
