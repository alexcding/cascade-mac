import Foundation
import GhosttyTerminal

// Output travels from the socket straight to this bounded pipeline, never through
// observable app state. Ghostty parses on its own serial queue; the drain fence is
// waited on a worker, so parsing and replay cannot block the UI actor.
final class TerminalPipe: @unchecked Sendable {
    struct Diagnostics: Codable, Sendable {
        let queuedBytes: Int
        let queuedEvents: Int
        let peakQueuedBytes: Int
        let peakQueuedEvents: Int
        let receivedBytes: UInt64
        let pauseCount: UInt64
        let resumeCount: UInt64
        let failed: Bool
    }
    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "craft.terminal.output", qos: .userInitiated)
    private var client: PtydClient?
    private var termID: String?
    private var input: TerminalInputQueue?
    private var replaying = true
    private var attaching = true
    private var buffered: [PtyEvent] = []
    private var queuedBytes = 0
    private var queuedEvents = 0
    private var peakQueuedBytes = 0
    private var peakQueuedEvents = 0
    private var receivedBytes: UInt64 = 0
    private var pauseCount: UInt64 = 0
    private var resumeCount: UInt64 = 0
    private var paused = false
    private var failed = false
    private var lastSequence: UInt64 = 0
    private var lastStateSequence: UInt64?
    private var ended = false
    private var inputEnqueues = 0
    private var latestViewport: InMemoryTerminalViewport?
    private var ownsGeometryResponses = false
    private var ownsAppearanceResponses = false
    private var latestAppearance: PtyAppearance?
    private let error: @Sendable (String) -> Void
    private let exited: @Sendable (Int) -> Void
    private(set) var memory: InMemoryTerminalSession!
    var isClosed: Bool { lock.withLock { failed } }
    var diagnostics: Diagnostics {
        lock.withLock { .init(queuedBytes: queuedBytes, queuedEvents: queuedEvents,
            peakQueuedBytes: peakQueuedBytes, peakQueuedEvents: peakQueuedEvents,
            receivedBytes: receivedBytes, pauseCount: pauseCount, resumeCount: resumeCount, failed: failed) }
    }

    init(onError: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int) -> Void) {
        error = onError
        exited = onExit
        memory = InMemoryTerminalSession(write: { [weak self] in self?.write($0) }, resize: { [weak self] in
            self?.resize($0)
        }, appearance: { [weak self] in self?.appearanceChanged($0) }, suppressesPixelOnlyResizes: false)
    }

    func bind(client: PtydClient, id: String, geometryOwned: Bool = false, appearanceOwned: Bool = false) {
        lock.lock()
        self.client = client; termID = id
        ownsGeometryResponses = geometryOwned
        ownsAppearanceResponses = appearanceOwned
        input?.close()
        input = TerminalInputQueue(send: { data in
            let _: Bool? = try await client.request(.init(op: "write", term: id, bytes: data))
        }, onError: { [weak self] message in
            guard let self else { return }
            self.lock.lock(); self.failLocked(message); self.lock.unlock()
        })
        lock.unlock()
    }

    @MainActor
    func prepareAppearance() throws -> PtyAppearance {
        guard memory.enableAppearanceCallbacks(), let appearance = lock.withLock({ latestAppearance }) else {
            throw PtyError.connection("The native terminal could not provide its configured colors.")
        }
        try appearance.validate()
        return appearance
    }

    private func appearanceChanged(_ values: [UInt32]) {
        let appearance = PtyAppearance(values: values)
        lock.lock(); defer { lock.unlock() }
        guard !failed, latestAppearance != appearance else { return }
        do { try appearance.validate() }
        catch { failLocked(error.localizedDescription); return }
        latestAppearance = appearance
        guard ownsAppearanceResponses, let client, let termID else { return }
        client.sendAcknowledged(.init(op: "appearance", term: termID, appearance: appearance)) { [weak self] result in
            guard case .failure(let error) = result, let self else { return }
            self.lock.lock(); self.failLocked(error.localizedDescription); self.lock.unlock()
        }
    }

    func synchronizeAppearance() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            guard !failed, ownsAppearanceResponses, let client, let termID, let latestAppearance else {
                continuation.resume(throwing: PtyError.closed); return
            }
            client.sendAcknowledged(.init(op: "appearance", term: termID, appearance: latestAppearance)) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    func measuredGeometry() async throws -> PtyGeometry {
        for _ in 0..<100 {
            let (failed, viewport) = lock.withLock { (self.failed, latestViewport) }
            guard !failed else { throw PtyError.closed }
            if let viewport, viewport.cellWidthPixels > 0, viewport.cellHeightPixels > 0 {
                let geometry = PtyGeometry(viewport)
                try geometry.validate()
                return geometry
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PtyError.connection("The native terminal did not report measured cell pixels.")
    }

    func synchronizeGrid() async throws {
        for _ in 0..<100 {
            // Read and enqueue under the same lock as callbacks. A newer resize
            // cannot overtake this fence and then be overwritten by an old size.
            let sent: Bool = try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                guard !failed, let client, termID != nil else { continuation.resume(throwing: PtyError.closed); return }
                guard let viewport = latestViewport else { continuation.resume(returning: false); return }
                do {
                    client.sendAcknowledged(try resizeRequestLocked(viewport)) { result in
                        continuation.resume(with: result.map { _ in true })
                    }
                } catch { continuation.resume(throwing: error) }
            }
            if sent { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PtyError.connection("The native terminal did not report its grid size.")
    }

    func receive(_ event: PtyEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard event.id == termID, !failed else { return }
        queuedEvents += 1
        peakQueuedEvents = max(peakQueuedEvents, queuedEvents)
        guard queuedEvents <= 16384 else { failLocked("Terminal output exceeded its event limit."); return }
        if event.ev == "inputError" {
            failLocked("Terminal input delivery failed: \(event.message ?? "PTY write failed.") Earlier input may have been sent; remaining input was stopped. Check the shell before reattaching.")
            return
        }
        if event.ev == "data" {
            guard let bytes = event.bytes, event.seq != nil else {
                failLocked("The terminal daemon sent an incomplete byte frame."); return
            }
            queuedBytes += bytes.count
            receivedBytes &+= UInt64(bytes.count)
            peakQueuedBytes = max(peakQueuedBytes, queuedBytes)
            guard queuedBytes <= 8 * 1024 * 1024 else { failLocked("Terminal output exceeded its buffer limit."); return }
            if queuedBytes > 1024 * 1024 && !paused { flowLocked(true) }
        }
        if attaching {
            buffered.append(event)
        }
        else { scheduleLocked(event) }
    }

    @MainActor
    func attach(_ snapshot: PtySnapshot, daemonOwnsStateResponses: Bool = false, daemonOwnsIdentityResponses: Bool = false, daemonOwnsGeometryResponses: Bool = false, daemonOwnsAppearanceResponses: Bool = false, onReady: @escaping @Sendable () -> Void) async throws {
        try snapshot.header.validate()
        guard daemonOwnsGeometryResponses == (snapshot.header.geometry != nil),
              !daemonOwnsGeometryResponses || daemonOwnsIdentityResponses else {
            throw PtyError.connection("The terminal snapshot geometry does not match its response owner.")
        }
        guard daemonOwnsAppearanceResponses == (snapshot.header.appearance != nil) else {
            throw PtyError.connection("The terminal snapshot appearance does not match its response owner.")
        }
        guard snapshot.bytes.count == snapshot.header.size else {
            throw PtyError.connection("The terminal snapshot is incomplete.")
        }
        guard memory.restoreSnapshot(snapshot.bytes) else {
            throw PtyError.connection("The terminal snapshot could not be imported; the shell is still running.")
        }
        if daemonOwnsGeometryResponses {
            guard memory.enableHostGeometryResponses() else {
                throw PtyError.connection("Terminal geometry response ownership could not be configured.")
            }
        } else if daemonOwnsIdentityResponses {
            guard memory.enableHostIdentityResponses() else {
                throw PtyError.connection("Terminal identity response ownership could not be configured.")
            }
        } else if daemonOwnsStateResponses, !memory.enableHostStateResponses() {
            throw PtyError.connection("Terminal state response ownership could not be configured.")
        }
        if let appearance = snapshot.header.appearance {
            guard memory.applyHostAppearance(appearance.values), memory.enableHostAppearanceResponses() else {
                throw PtyError.connection("Terminal color response ownership could not be configured.")
            }
        }
        let memory = memory!
        // Metadata uses Ghostty's bounded app mailbox. Keep draining it while
        // the worker publishes, including when an occluded surface has no ticks.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                _ = memory.flushSnapshotMetadataCallbacks()
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return }
            }
        }
        let published = await Task.detached(operation: { memory.publishSnapshotMetadata() }).value
        ticker.cancel()
        guard published,
              memory.flushSnapshotMetadataCallbacks() else {
            throw PtyError.connection("The restored terminal metadata could not be published.")
        }
        try Task.checkCancellation()
        finishSnapshotAttachment(snapshot.header, onReady: onReady)
    }

    private func finishSnapshotAttachment(_ header: PtySnapshot.Header, onReady: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return }
        lastSequence = header.seq
        lastStateSequence = header.stateSeq
        // Import does not replay historical side effects. Live protocol replies
        // must be delivered while the UI still gates user interaction.
        replaying = false
        for event in buffered {
            if (event.ev == "data" || event.ev == "resize" || event.ev == "appearance"), let state = event.stateSeq, state <= header.stateSeq {
                consumedLocked(event.bytes?.count ?? 0)
            } else { scheduleLocked(event) }
            if failed { break }
        }
        buffered.removeAll()
        attaching = false
        outputQueue.async { [self] in
            lock.lock()
            let ready = !failed && !ended
            lock.unlock()
            if ready { onReady() }
        }
    }

    func attach(_ attachment: PtyAttachment, onReady: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return }
        do { try attachment.validateReplay() }
        catch { failLocked(error.localizedDescription); return }
        lastSequence = attachment.seq
        let replay = attachment.bytes
        queuedBytes += replay.count
        peakQueuedBytes = max(peakQueuedBytes, queuedBytes)
        guard queuedBytes <= 8 * 1024 * 1024 else { failLocked("Terminal attachment exceeded its buffer limit."); return }
        if queuedBytes > 1024 * 1024 && !paused { flowLocked(true) }
        outputQueue.async { [self] in
            memory.receive(replay)
            memory.waitForPendingOutput()
            lock.lock()
            guard !failed else { lock.unlock(); return }
            replaying = false
            consumedLocked(replay.count, event: false)
            lock.unlock()
            onReady()
        }
        for event in buffered {
            if event.ev == "data", (event.seq ?? 0) <= attachment.seq {
                consumedLocked(event.bytes?.count ?? 0)
            } else { scheduleLocked(event) }
        }
        buffered.removeAll()
        attaching = false
    }

    private func scheduleLocked(_ event: PtyEvent) {
        guard !failed else { return }
        if let state = lastStateSequence, event.ev == "data" || event.ev == "resize" || event.ev == "appearance" {
            guard let next = event.stateSeq, let sequence = event.seq else {
                failLocked("The terminal daemon omitted ordered state metadata."); return
            }
            guard next > state else { consumedLocked(event.bytes?.count ?? 0); return }
            guard state < UInt64.max, next == state + 1 else {
                failLocked("Terminal state sequence gap; reattachment required."); return
            }
            if event.ev == "appearance" {
                guard ownsAppearanceResponses, sequence == lastSequence, let appearance = event.appearance else {
                    failLocked("The terminal returned an invalid ordered appearance change."); return
                }
                do { try appearance.validate() } catch { failLocked(error.localizedDescription); return }
                lastStateSequence = next
                outputQueue.async { [self] in
                    lock.lock(); let active = !failed; lock.unlock()
                    guard active else { return }
                    let applied = memory.applyHostAppearance(appearance.values)
                    lock.lock(); defer { lock.unlock() }
                    if !applied { failLocked("The terminal could not apply its ordered color change.") }
                    consumedLocked(0)
                }
                return
            }
            if event.ev == "resize" {
                guard sequence == lastSequence, let cols = event.cols, let rows = event.rows,
                      cols > 0, rows > 0, cols <= 4096, rows <= 4096,
                      UInt32(cols) * UInt32(rows) <= 1024 * 1024 else {
                    failLocked("The terminal daemon returned an invalid ordered resize."); return
                }
                lastStateSequence = next
                guard ownsGeometryResponses == (event.geometry != nil) else {
                    failLocked("The terminal daemon changed geometry response ownership during a resize."); return
                }
                if let geometry = event.geometry {
                    do { try geometry.validate() }
                    catch { failLocked(error.localizedDescription); return }
                    guard geometry.cols == cols, geometry.rows == rows else {
                        failLocked("The terminal daemon returned inconsistent resize geometry."); return
                    }
                }
                outputQueue.async { [self] in
                    lock.lock(); let active = !failed; lock.unlock()
                    guard active else { return }
                    let applied: Bool
                    if let geometry = event.geometry {
                        applied = memory.applyHostGeometry(columns: cols, rows: rows,
                            cellWidthPixels: geometry.cellWidthPixels, cellHeightPixels: geometry.cellHeightPixels)
                    } else { applied = memory.applyHostGridSize(columns: cols, rows: rows) }
                    if !applied {
                        lock.lock(); failLocked("The terminal could not apply its ordered grid change."); lock.unlock()
                    }
                    lock.lock(); consumedLocked(0); lock.unlock()
                }
                return
            }
            guard lastSequence < UInt64.max, sequence == lastSequence + 1 else {
                failLocked("Terminal output sequence gap; reattachment required."); return
            }
            lastStateSequence = next
        }
        if event.ev == "data", let sequence = event.seq, let bytes = event.bytes {
            guard sequence > lastSequence else { consumedLocked(bytes.count); return }
            guard sequence == lastSequence + 1 else { failLocked("Terminal output sequence gap; reconnect required."); return }
            lastSequence = sequence
            outputQueue.async { [self] in
                lock.lock(); let active = !failed; lock.unlock()
                guard active else { return }
                memory.receive(bytes)
                memory.waitForPendingOutput()
                lock.lock(); consumedLocked(bytes.count); lock.unlock()
            }
        } else if event.ev == "exit" {
            ended = true
            outputQueue.async { [self] in
                memory.waitForPendingOutput()
                lock.lock(); replaying = true; consumedLocked(0); lock.unlock()
                exited(event.exitCode ?? 0)
            }
        } else { consumedLocked(0) }
    }

    private func consumedLocked(_ count: Int, event: Bool = true) {
        queuedBytes = max(0, queuedBytes - count)
        if event { queuedEvents = max(0, queuedEvents - 1) }
        if paused && queuedBytes < 256 * 1024 { flowLocked(false) }
    }

    private func flowLocked(_ pause: Bool) {
        paused = pause
        if pause { pauseCount &+= 1 } else { resumeCount &+= 1 }
        client?.fire(.init(op: "flow", term: termID, pause: pause))
    }

    private func failLocked(_ message: String) {
        guard !failed else { return }
        failed = true
        input?.close()
        buffered.removeAll()
        if paused { flowLocked(false) }
        client?.close()
        error(message)
    }

    private func write(_ data: Data) {
        lock.lock()
        // The drain fence keeps replies to historical terminal queries from being
        // injected into the live shell after the replay has supposedly finished.
        guard !replaying, !failed, !ended, termID != nil else { lock.unlock(); return }
        let input = input
        inputEnqueues += 1
        lock.unlock()
        input?.enqueue(data)
        lock.lock(); inputEnqueues -= 1; lock.unlock()
    }

    private func resizeRequestLocked(_ viewport: InMemoryTerminalViewport) throws -> PtyRequest {
        var request = PtyRequest(op: "resize", term: termID, cols: viewport.columns, rows: viewport.rows)
        if ownsGeometryResponses {
            let geometry = PtyGeometry(viewport)
            try geometry.validate()
            request.geometry = geometry
        }
        return request
    }

    private func resize(_ viewport: InMemoryTerminalViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let previous = latestViewport
        latestViewport = viewport
        guard !failed, termID != nil, let client else { return }
        if let previous {
            let unchanged = ownsGeometryResponses ? PtyGeometry(previous) == PtyGeometry(viewport)
                : previous.columns == viewport.columns && previous.rows == viewport.rows
            if unchanged { return }
        }
        do {
            client.sendAcknowledged(try resizeRequestLocked(viewport)) { [weak self, weak client] result in
                guard case .failure(let error) = result, let self else { return }
                if (error as? PtyError)?.permitsReconnect == true {
                    // Size changes are recoverable from the next snapshot. Let
                    // the existing disconnect path assess pending user input.
                    client?.close()
                    return
                }
                self.lock.lock(); defer { self.lock.unlock() }
                self.failLocked("Terminal resize failed: \(error.localizedDescription)")
            }
        } catch { failLocked(error.localizedDescription) }
    }

    func close() {
        lock.lock()
        failed = true
        input?.close()
        buffered.removeAll()
        if paused { flowLocked(false) }
        client?.close()
        client = nil
        lock.unlock()
    }

    func freezeForReconnect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let idleInput = input?.freezeForReconnect() == true
        let safe = !failed && !ended && !attaching && inputEnqueues == 0 && idleInput
        failed = true
        buffered.removeAll()
        if paused { flowLocked(false) }
        client?.close()
        client = nil
        return safe
    }
}
