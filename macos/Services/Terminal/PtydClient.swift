import Foundation
import Darwin

// All mutable transport state belongs to queue. Dispatch sources drive nonblocking
// I/O; a slow PTY cannot block the main actor or another connection. Each instance is
// one connection generation, so old replies cannot resolve a new client's requests.
final class PtydClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "craft.ptyd.socket", qos: .userInitiated)
    private var fd: Int32 = -1
    private var hasConnected = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var outgoing = Data()
    private var framer = PtyFramer()
    private var sequence: UInt64 = 0
    private var pending: [UInt64: @Sendable (Result<Data, Error>) -> Void] = [:]
    private let event: @Sendable (PtyEvent) -> Void
    private let disconnected: @Sendable (PtyError) -> Void

    init(onEvent: @escaping @Sendable (PtyEvent) -> Void,
         onDisconnect: @escaping @Sendable (PtyError) -> Void = { _ in }) {
        event = onEvent
        disconnected = onDisconnect
    }

    func connect(path: String) async throws -> PtyHello {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !hasConnected else { throw PtyError.connection("Use a new client for each terminal connection.") }
                    var address = sockaddr_un()
                    let bytes = Array(path.utf8) + [0]
                    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                        throw PtyError.connection("Terminal socket path is too long.")
                    }
                    address.sun_family = sa_family_t(AF_UNIX)
                    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                    guard socket >= 0 else { throw posixError() }
                    var flag: Int32 = 1
                    _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout.size(ofValue: flag)))
                    _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
                    let result = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    guard result == 0 else { let error = posixError(); Darwin.close(socket); throw error }
                    _ = fcntl(socket, F_SETFL, O_NONBLOCK)
                    fd = socket
                    hasConnected = true
                    let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
                    source.setEventHandler { [weak self] in self?.readAvailable() }
                    source.setCancelHandler { Darwin.close(socket) }
                    readSource = source
                    source.resume()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        do {
            // Hear only the terminals this connection creates, attaches to or restores. A daemon
            // that predates event scopes sends every terminal's events; TerminalPipe drops the rest.
            let hello: PtyHello = try await request(.init(op: "hello", dataEncoding: "base64", eventScope: "attached"))
            guard hello.protocol == 2 else { throw PtyError.protocolMismatch(hello.protocol) }
            return hello
        } catch { close(); throw error }
    }

    func request<T: Decodable & Sendable>(_ request: PtyRequest, timeout: Double = 5) async throws -> T {
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            sendAcknowledged(request, timeout: timeout) { continuation.resume(with: $0) }
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    // Enqueues synchronously onto the socket queue, preserving the caller's
    // resize order without launching independently scheduled Tasks per event.
    func sendAcknowledged(_ request: PtyRequest, timeout: Double = 5,
                          completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            guard fd >= 0 else { completion(.failure(PtyError.closed)); return }
            guard pending.count < 1024 else { completion(.failure(PtyError.overflow)); return }
            sequence += 1
            let id = sequence
            var request = request
            request.id = id
            pending[id] = completion
            send(request)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.pending.removeValue(forKey: id)?(.failure(PtyError.timeout))
            }
        }
    }

    func fire(_ request: PtyRequest) { queue.async { [self] in send(request) } }
    func close() { queue.async { [self] in fail(PtyError.closed) } }

    private func send(_ request: PtyRequest) {
        guard fd >= 0 else { return }
        do {
            var data = try JSONEncoder().encode(request)
            data.append(10)
            guard outgoing.count + data.count <= 2 * 1024 * 1024 else { throw PtyError.overflow }
            outgoing.append(data)
            flush()
        } catch { fail(error) }
    }

    private func flush() {
        while !outgoing.isEmpty && fd >= 0 {
            let count = outgoing.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { outgoing.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writeSource = source
                    source.resume()
                }
                return
            } else { fail(posixError()); return }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Yield to queued writes (especially flow pause/resume) during an output
        // flood, even when the socket never reaches EAGAIN.
        for _ in 0..<8 where fd >= 0 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                do {
                    for frame in try framer.append(Data(buffer.prefix(count))) { try receive(frame) }
                } catch { fail(error); return }
            } else if count == 0 { fail(PtyError.closed); return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else { fail(posixError()); return }
        }
    }

    private func receive(_ data: Data) throws {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PtyError.connection("Invalid daemon frame.")
        }
        if frame["ev"] != nil { event(try JSONDecoder().decode(PtyEvent.self, from: data)); return }
        guard let id = frame["id"] as? UInt64, let waiter = pending.removeValue(forKey: id) else { return }
        if let error = frame["err"] as? String { waiter(.failure(PtyError.connection(error))); return }
        do {
            let result = try JSONSerialization.data(withJSONObject: frame["ok"] ?? NSNull(), options: [.fragmentsAllowed])
            waiter(.success(result))
        } catch { waiter(.failure(error)) }
    }

    private func fail(_ error: Error) {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        fd = -1
        writeSource?.cancel(); writeSource = nil
        readSource?.cancel(); readSource = nil
        outgoing.removeAll()
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters { waiter(.failure(error)) }
        disconnected(error as? PtyError ?? .connection(error.localizedDescription))
    }

    private func posixError() -> PtyError { .socket(errno) }
}
