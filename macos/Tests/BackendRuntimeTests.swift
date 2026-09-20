import Foundation
import Testing

private let runtimeURL = URL(string: "http://127.0.0.1:43219")!

private actor ControlledRuntimeProcess: BackendProcessServing {
    var starts = 0
    var stops = 0
    private let suspended: Bool
    private var pending: CheckedContinuation<APIClient, any Error>?
    init(suspended: Bool = false) { self.suspended = suspended }
    func start() async throws -> APIClient {
        starts += 1
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try APIClient(baseURL: runtimeURL)
    }
    func finish(failing: Bool = false) throws {
        let result = pending
        pending = nil
        if failing { result?.resume(throwing: BackendError.startup("Retired process failed")) }
        else { result?.resume(returning: try APIClient(baseURL: runtimeURL)) }
    }
    func stop() { stops += 1 }
}

private actor ControlledRuntimeStream: BackendEventStreaming {
    var consumes = 0
    private var connected: (@Sendable () async -> Void)?
    private var message: (@Sendable (ServerEvent) async -> Void)?
    private var pending: CheckedContinuation<Void, any Error>?
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func consume(from baseURL: URL, onConnect: @escaping @Sendable () async -> Void,
                 onEvent: @escaping @Sendable (ServerEvent) async -> Void) async throws {
        consumes += 1
        if fails { throw BackendError.operation("Stream unavailable") }
        // Deliberately retain callbacks and delay cancellation completion to model
        // a network operation that is already delivering an event during shutdown.
        try await withCheckedThrowingContinuation { continuation in
            connected = onConnect
            message = onEvent
            pending = continuation
        }
    }
    func emit() async {
        await connected?()
        await message?(ServerEvent(type: "sync", projectId: nil, id: nil))
    }
    func finish() { pending?.resume(); pending = nil }
}

@MainActor private final class ControlledRuntimeFactory: BackendRuntimeFactory {
    var processes: [ControlledRuntimeProcess]
    var streams: [ControlledRuntimeStream]
    var delays: [Int] = []
    var pauseLimit = 6
    var suspendPause = false
    init(processes: [ControlledRuntimeProcess], streams: [ControlledRuntimeStream] = []) {
        self.processes = processes; self.streams = streams
    }
    func configuration() -> BackendConfiguration { .init(baseURL: runtimeURL, mode: .external) }
    func process(configuration: BackendConfiguration) -> any BackendProcessServing { processes.removeFirst() }
    func stream() -> any BackendEventStreaming { streams.removeFirst() }
    func pause(seconds: Int) async throws {
        delays.append(seconds)
        if suspendPause { try await Task.sleep(for: .seconds(30)) }
        if delays.count >= pauseLimit { throw CancellationError() }
    }
}

@MainActor private func runtimeEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw BackendError.operation("Runtime condition was not reached") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor @Test(arguments: [false, true]) func backendRuntimeRetiredStartupCannotStopReplacement(failing: Bool) async throws {
    let retired = ControlledRuntimeProcess(suspended: true), replacement = ControlledRuntimeProcess()
    let runtime = BackendRuntime(factory: ControlledRuntimeFactory(processes: [retired, replacement]))
    let oldStart = Task { try await runtime.start() }
    try await runtimeEventually { await retired.starts == 1 }
    await runtime.stop()
    _ = try await runtime.start()
    try await retired.finish(failing: failing)
    do { _ = try await oldStart.value; Issue.record("Retired start succeeded") } catch { }
    #expect(await replacement.stops == 0)
    #expect(await retired.stops >= 1)
    await runtime.stop()
    #expect(await replacement.stops == 1)
}

@MainActor @Test func backendRuntimeRetiredStreamCannotPublishIntoReplacement() async throws {
    let process = ControlledRuntimeProcess()
    let oldStream = ControlledRuntimeStream(), newStream = ControlledRuntimeStream()
    let runtime = BackendRuntime(factory: ControlledRuntimeFactory(processes: [process], streams: [oldStream, newStream]))
    var events: [BackendRuntimeEvent] = []
    runtime.onEvent = { events.append($0) }
    _ = try await runtime.start()
    runtime.startEvents()
    runtime.startEvents()
    try await runtimeEventually { await oldStream.consumes == 1 }
    await oldStream.emit()
    #expect(events == [.starting(runtimeURL), .connected, .message(.init(type: "sync", projectId: nil, id: nil))])
    var stopping = false
    let stop = Task { stopping = true; await runtime.stopEvents() }
    try await runtimeEventually { stopping }
    runtime.startEvents()
    try await runtimeEventually { await newStream.consumes == 1 }
    events.removeAll()
    await oldStream.emit()
    #expect(events.isEmpty)
    await oldStream.finish()
    await stop.value
    await newStream.emit()
    #expect(events == [.connected, .message(.init(type: "sync", projectId: nil, id: nil))])
    var shuttingDown = false
    let shutdown = Task { shuttingDown = true; await runtime.stop() }
    try await runtimeEventually { shuttingDown }
    events.removeAll()
    await newStream.emit()
    #expect(events.isEmpty)
    await newStream.finish()
    await shutdown.value
    #expect(await process.stops == 1)
}

@MainActor @Test func backendRuntimeBackoffIsBoundedAndDuplicateStartIsRejected() async throws {
    let process = ControlledRuntimeProcess(), stream = ControlledRuntimeStream(fails: true)
    let factory = ControlledRuntimeFactory(processes: [process], streams: [stream])
    let runtime = BackendRuntime(factory: factory)
    _ = try await runtime.start()
    do { _ = try await runtime.start(); Issue.record("Duplicate start succeeded") } catch { }
    #expect(await process.starts == 1)
    runtime.startEvents()
    try await runtimeEventually { factory.delays.count == 6 }
    #expect(factory.delays == [1, 2, 4, 8, 15, 15])
    await runtime.stop()
    #expect(await process.stops == 1)
}

@MainActor @Test func backendRuntimeCancellationReleasesStartupAndAllowsRetry() async throws {
    let cancelled = ControlledRuntimeProcess(suspended: true), replacement = ControlledRuntimeProcess()
    let runtime = BackendRuntime(factory: ControlledRuntimeFactory(processes: [cancelled, replacement]))
    let start = Task { try await runtime.start() }
    try await runtimeEventually { await cancelled.starts == 1 }
    start.cancel()
    try await cancelled.finish()
    do { _ = try await start.value; Issue.record("Cancelled start succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(await cancelled.stops == 1)
    _ = try await runtime.start()
    await runtime.stop()
    #expect(await replacement.stops == 1)
}

@MainActor @Test func backendRuntimeStopCancelsReconnectPause() async throws {
    let process = ControlledRuntimeProcess(), stream = ControlledRuntimeStream(fails: true)
    let factory = ControlledRuntimeFactory(processes: [process], streams: [stream])
    factory.suspendPause = true
    let runtime = BackendRuntime(factory: factory)
    _ = try await runtime.start()
    runtime.startEvents()
    try await runtimeEventually { factory.delays == [1] }
    await runtime.stop()
    #expect(await stream.consumes == 1)
    #expect(await process.stops == 1)
}
