import Foundation

public struct ServerEvent: Decodable, Sendable, Equatable {
    public let type: String
    public let projectId: String?
    public let id: String?
    public var event: ActivityEvent? = nil
    public var runId: String? = nil
    public var cli: String? = nil
    public var sessionId: String? = nil
    public var source: String? = nil
    /// Snapshot domain; absent on inventory changes and events from older backends.
    public var scope: String? = nil
    /// `ide-warmup` only: the worktree being prepared and how far it got.
    public var worktree: String? = nil
    public var status: String? = nil
    public var label: String? = nil
    public var message: String? = nil
    /// `terminal-open-url` only: the web address a terminal's BROWSER asked to open.
    public var url: String? = nil
    /// `agent-permission` only: what the agent asks to run, for the chat view to allow or deny.
    public var request: AgentPermissionPrompt.Details? = nil
    /// `agent-permission-done` only: `answered`, `terminal` (the CLI shows its own prompt), or
    /// `cancelled` (nothing waits on it any more).
    public var outcome: String? = nil
}

/// A tool approval an agent is waiting on, offered by its `PermissionRequest` hook.
public struct AgentPermissionPrompt: Encodable, Equatable, Sendable {
    public struct Details: Codable, Equatable, Sendable {
        public let tool: String
        public let detail: String
        public let reason: String
        /// A file change's two sides, when the tool is one.
        public var old: String? = nil
        public var new: String? = nil
        /// Too long to show whole: the card sends it to the terminal rather than let it be allowed.
        public var truncated: Bool? = nil
    }
    public let id: String
    public let tool: String
    public let detail: String
    public let reason: String
    public let old: String?
    public let new: String?
    public let truncated: Bool

    init(id: String, details: Details) {
        self.id = id; tool = details.tool; detail = details.detail; reason = details.reason
        old = details.old; new = details.new; truncated = details.truncated ?? false
    }
}

// Byte framing preserves empty lines, CRLF and UTF-8 split between network reads.
// A bounded parser avoids accumulating an unbounded malformed event or line.
struct SSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var afterCR = false
    private let limit = 1_048_576

    mutating func feed(_ byte: UInt8) throws -> Data? {
        if afterCR {
            afterCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            afterCR = byte == 13
            return try finishLine()
        }
        guard line.count + eventBytes < limit else { throw BackendError.oversizedEvent }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            return dataLines.isEmpty ? nil : Data(dataLines.joined(separator: "\n").utf8)
        }
        let text = String(decoding: line, as: UTF8.self)
        if text == "data" || text.hasPrefix("data:") {
            var value = text == "data" ? "" : String(text.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            eventBytes += line.count + 1
            guard eventBytes < limit else { throw BackendError.oversizedEvent }
            dataLines.append(value)
        }
        return nil
    }
}

public actor SSEClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 86_400
        session = URLSession(configuration: config)
    }

    // Caller owns reconnect policy. Awaiting the handler applies backpressure and
    // cancellation ends the underlying URLSession operation with the caller's task.
    public func consume(
        from baseURL: URL,
        onConnect: @escaping @Sendable () async -> Void,
        onEvent: @escaping @Sendable (ServerEvent) async -> Void
    ) async throws {
        let api = try APIClient(baseURL: baseURL)
        var request = URLRequest(url: try await api.url(Routes.STREAM))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try APIClient.validate(response)
        guard response.mimeType == "text/event-stream" else { throw BackendError.incompatible }
        await onConnect()
        var parser = SSEParser()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let data = try parser.feed(byte) {
                let event = try JSONDecoder().decode(ServerEvent.self, from: data)
                await onEvent(event)
            }
        }
    }
}
