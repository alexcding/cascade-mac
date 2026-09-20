import Foundation

// One acknowledged write at a time. A failed or ambiguous delivery stops the
// stream; retrying could execute a command twice or append to a partial paste.
final class TerminalInputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var inFlight = 0
    private var draining = false
    private var closed = false
    private let limit: Int
    private let chunkSize: Int
    private let send: @Sendable (Data) async throws -> Void
    private let error: @Sendable (String) -> Void

    init(limit: Int = 1024 * 1024, chunkSize: Int = 64 * 1024,
         send: @escaping @Sendable (Data) async throws -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.limit = limit; self.chunkSize = chunkSize; self.send = send; error = onError
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard data.count <= limit - pending.count - inFlight else {
            closed = true; pending.removeAll(); lock.unlock()
            error("Terminal input exceeded its buffer limit. Earlier input may have been sent; remaining input was stopped. Check the shell before reattaching.")
            return
        }
        pending.append(data)
        let start = !draining
        draining = true
        lock.unlock()
        if start { Task.detached(priority: .userInitiated) { await self.drain() } }
    }

    private func next() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !pending.isEmpty else { draining = false; return nil }
        let data = Data(pending.prefix(chunkSize))
        pending.removeFirst(data.count); inFlight = data.count
        return data
    }

    private func acknowledge() {
        lock.lock(); inFlight = 0; lock.unlock()
    }

    private func fail(_ failure: Error) {
        lock.lock()
        let report = !closed
        closed = true; pending.removeAll(); inFlight = 0; draining = false
        lock.unlock()
        if report {
            error("Terminal input delivery failed: \(failure.localizedDescription) Earlier input may have been sent; remaining input was stopped. Check the shell before reattaching.")
        }
    }

    private func drain() async {
        while let data = next() {
            do { try await send(data); acknowledge() }
            catch { fail(error); return }
        }
    }

    func close() {
        lock.lock(); closed = true; pending.removeAll(); lock.unlock()
    }

    // Atomically freeze delivery before deciding whether a new connection can
    // enable input. Pending or unacknowledged bytes require manual recovery.
    func freezeForReconnect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let safe = !closed && pending.isEmpty && inFlight == 0
        closed = true
        pending.removeAll()
        return safe
    }
}
