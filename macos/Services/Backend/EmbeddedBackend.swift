import Foundation
import CraftBackendFFI

// The backend hosted inside this process: crates/craft-backend linked as a
// static library (its C ABI is src/ffi.rs). Requests dispatch straight into the
// same axum router the web client talks to, so routes, models and contracts are
// unchanged; there is no child process, port or health handshake to manage. The
// backend still serves an ephemeral loopback port for webhook forwarders, agent
// hooks and the web renderer, which is what `APIClient.baseURL` names.

/// The opaque backend handle with a lock that keeps every FFI call ordered
/// against `stop`. After `invalidate` no call reaches freed memory.
final class EmbeddedBackendHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: OpaquePointer?

    init(raw: OpaquePointer) { self.raw = raw }

    func with<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let raw else { return nil }
        return try body(raw)
    }

    /// Stops and frees the backend exactly once. Blocks while the runtime shuts
    /// down (bounded by the library), so callers keep it off the main actor.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard let raw else { return }
        self.raw = nil
        craft_backend_stop(raw)
    }
}

/// `BackendTransport` that answers `URLRequest`s from the embedded router.
struct EmbeddedTransport: BackendTransport {
    let handle: EmbeddedBackendHandle

    private final class Pending: @unchecked Sendable {
        let continuation: CheckedContinuation<(Int32, String?, Data), Never>
        init(_ continuation: CheckedContinuation<(Int32, String?, Data), Never>) { self.continuation = continuation }
    }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BackendError.configuration("Invalid backend route.")
        }
        var target = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { target += "?\(query)" }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Data()
        let (status, contentType, data) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String?, Data), Never>) in
            let context = Unmanaged.passRetained(Pending(continuation))
            let dispatched: Void? = handle.with { raw in
                body.withUnsafeBytes { bytes in
                    craft_backend_request(raw, method, target, bytes.bindMemory(to: UInt8.self).baseAddress, body.count,
                                            context.toOpaque()) { context, status, contentType, body, length in
                        // Runs once, on a backend runtime thread; the body is only valid during the call.
                        let pending = Unmanaged<Pending>.fromOpaque(context!).takeRetainedValue()
                        let data = body.map { Data(bytes: $0, count: length) } ?? Data()
                        pending.continuation.resume(returning: (status, contentType.map { String(cString: $0) }, data))
                    }
                }
            }
            if dispatched == nil {
                context.takeRetainedValue().continuation.resume(returning: (503, "application/json",
                    Data(#"{"error":"The embedded backend is not running."}"#.utf8)))
            }
        }
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        guard let response = HTTPURLResponse(url: url, statusCode: Int(status), httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw BackendError.incompatible
        }
        return (data, response)
    }
}

/// Broadcast events straight from the embedded backend, in place of the SSE stream.
struct EmbeddedEventStream: BackendEventStreaming {
    let handle: EmbeddedBackendHandle

    private final class Subscriber: @unchecked Sendable {
        let continuation: AsyncStream<Data>.Continuation
        init(_ continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }
    }

    func consume(from baseURL: URL, onConnect: @escaping @Sendable () async -> Void,
                 onEvent: @escaping @Sendable (ServerEvent) async -> Void) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let context = Unmanaged.passRetained(Subscriber(continuation))
        let subscription: UInt64? = handle.with { raw in
            craft_backend_subscribe(raw, context.toOpaque(), { context, json, length in
                let subscriber = Unmanaged<Subscriber>.fromOpaque(context!).takeUnretainedValue()
                subscriber.continuation.yield(Data(bytes: json!, count: length))
            }, { context in
                // Exactly once, however the subscription ends: release the subscriber and end the stream.
                Unmanaged<Subscriber>.fromOpaque(context!).takeRetainedValue().continuation.finish()
            })
        }
        guard let subscription, subscription != 0 else {
            if subscription == nil { context.release() }
            throw BackendError.startup("The embedded backend is not running.")
        }
        await onConnect()
        let handle = self.handle
        try await withTaskCancellationHandler {
            for await data in stream {
                try Task.checkCancellation()
                await onEvent(try JSONDecoder().decode(ServerEvent.self, from: data))
            }
            try Task.checkCancellation()
            // The stream only ends when the backend stops; report it like a dropped connection.
            throw BackendError.startup("The embedded backend stopped.")
        } onCancel: {
            _ = handle.with { craft_backend_unsubscribe($0, subscription) }
        }
    }
}

/// Owns the embedded backend for the app session. Mirrors `BackendProcess`: start
/// hands back the API client, stop releases everything.
public actor EmbeddedBackend: BackendProcessServing {
    public let dataDirectory: URL
    public let packaged: Bool
    // Read by eventStream() without hopping actors; only start()/stop() write it.
    private let slot = Locked<EmbeddedBackendHandle?>(nil)
    private var starting = false
    public private(set) var port: UInt16 = 0

    public init(dataDirectory: URL, packaged: Bool) {
        self.dataDirectory = dataDirectory
        self.packaged = packaged
    }

    public func start() async throws -> APIClient {
        guard slot.value == nil, !starting else { throw BackendError.startup("The backend is already starting or running.") }
        starting = true; defer { starting = false }
        let directory = dataDirectory, packaged = packaged
        let instanceID = UUID().uuidString
        // Starting opens stores and binds the loopback listener; keep that work off the caller's executor.
        let task = Task.detached(priority: .userInitiated) { () throws -> (EmbeddedBackendHandle, UInt16) in
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { throw BackendError.startup("The embedded backend could not start: data directory \(directory.path) is unavailable (\(error.localizedDescription))") }
            var raw: OpaquePointer?
            var message: UnsafeMutablePointer<CChar>?
            let code = craft_backend_start(directory.path, packaged ? 1 : 0, instanceID, &raw, &message)
            defer { craft_string_free(message) }
            guard code == 0, let raw else {
                let text = message.map { String(cString: $0) } ?? "unknown error"
                throw BackendError.startup("The embedded backend could not start: \(text)")
            }
            return (EmbeddedBackendHandle(raw: raw), craft_backend_port(raw))
        }
        do {
            let (handle, port) = try await task.value
            try Task.checkCancellation()
            guard slot.value == nil else { handle.invalidate(); throw CancellationError() }
            slot.value = handle; self.port = port
            let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, transport: EmbeddedTransport(handle: handle))
            let health = try await api.health()
            try health.validate(instanceID: instanceID)
            return api
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        guard let handle = slot.value else { return }
        slot.value = nil; port = 0
        await Task.detached { handle.invalidate() }.value
    }

    nonisolated func eventStream() -> (any BackendEventStreaming)? {
        // A stale answer only yields a stream that reports the backend stopped.
        slot.value.map { EmbeddedEventStream(handle: $0) }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
