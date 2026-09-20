import Foundation

protocol BackendProcessServing: Sendable {
    func start() async throws -> APIClient
    func stop() async
    /// An owner that delivers events itself (the embedded backend); nil means SSE.
    func eventStream() -> (any BackendEventStreaming)?
}
extension BackendProcessServing {
    func eventStream() -> (any BackendEventStreaming)? { nil }
}
extension BackendProcess: BackendProcessServing {}

protocol BackendEventStreaming: Sendable {
    func consume(from baseURL: URL, onConnect: @escaping @Sendable () async -> Void,
                 onEvent: @escaping @Sendable (ServerEvent) async -> Void) async throws
}
extension SSEClient: BackendEventStreaming {}

@MainActor protocol BackendRuntimeFactory {
    func configuration() throws -> BackendConfiguration
    func process(configuration: BackendConfiguration) -> any BackendProcessServing
    func stream() -> any BackendEventStreaming
    func pause(seconds: Int) async throws
}

struct NativeBackendRuntimeFactory: BackendRuntimeFactory {
    func configuration() throws -> BackendConfiguration { try .current() }
    func process(configuration: BackendConfiguration) -> any BackendProcessServing {
        if case .embedded(let dataDirectory) = configuration.mode {
            return EmbeddedBackend(dataDirectory: dataDirectory, packaged: configuration.packaged)
        }
        return BackendProcess(configuration: configuration)
    }
    func stream() -> any BackendEventStreaming { SSEClient() }
    func pause(seconds: Int) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

enum BackendRuntimeEvent: Equatable {
    case starting(URL)
    case connected
    case reconnecting(String?)
    case message(ServerEvent)
}

@MainActor protocol BackendRuntimeServing: AnyObject {
    var onEvent: (BackendRuntimeEvent) -> Void { get set }
    func start() async throws -> APIClient
    func startEvents()
    func stopEvents() async
    func stop() async
}

// Process and stream lifetime belong to this runtime, independently of navigation
// or mounted views. Each start and stream gets an identity; late callbacks from
// a retired connection cannot enter a replacement app session.
@MainActor final class BackendRuntime: BackendRuntimeServing {
    var onEvent: (BackendRuntimeEvent) -> Void = { _ in }
    private let factory: any BackendRuntimeFactory
    private var owner: (any BackendProcessServing)?
    private var baseURL: URL?
    private var generation = UUID()
    private var streamID: UUID?
    private var streamTask: Task<Void, Never>?

    init(factory: any BackendRuntimeFactory = NativeBackendRuntimeFactory()) { self.factory = factory }

    func start() async throws -> APIClient {
        guard owner == nil else { throw BackendError.startup("The backend runtime is already starting or running.") }
        let configuration = try factory.configuration()
        let process = factory.process(configuration: configuration)
        let request = UUID()
        generation = request
        owner = process
        onEvent(.starting(configuration.baseURL))
        do {
            let api = try await process.start()
            try Task.checkCancellation()
            guard generation == request else { throw CancellationError() }
            // The embedded backend's loopback port is only known after start.
            baseURL = api.baseURL
            return api
        } catch {
            if generation == request { owner = nil; baseURL = nil }
            // Always stop the captured owner, never whatever a newer start owns.
            await process.stop()
            throw error
        }
    }

    func startEvents() {
        guard owner != nil, let baseURL, streamTask == nil else { return }
        let request = UUID(), generation = generation, factory = factory
        streamID = request
        let stream = owner?.eventStream() ?? factory.stream()
        streamTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                var failure: String?
                do {
                    try await stream.consume(from: baseURL, onConnect: { [weak self] in
                        await self?.deliver(.connected, generation: generation, streamID: request)
                    }, onEvent: { [weak self] event in
                        await self?.deliver(.message(event), generation: generation, streamID: request)
                    })
                    delay = 1
                } catch {
                    if Task.isCancelled { break }
                    failure = error.localizedDescription
                }
                guard !Task.isCancelled else { break }
                self?.deliver(.reconnecting(failure), generation: generation, streamID: request)
                do { try await factory.pause(seconds: delay) } catch { break }
                delay = min(delay * 2, 15)
            }
        }
    }

    private func deliver(_ event: BackendRuntimeEvent, generation: UUID, streamID: UUID) {
        guard self.generation == generation, self.streamID == streamID, owner != nil else { return }
        onEvent(event)
    }

    func stopEvents() async {
        streamID = nil
        let pending = streamTask
        streamTask = nil
        pending?.cancel()
        await pending?.value
    }

    func stop() async {
        generation = UUID()
        let previous = owner
        owner = nil
        baseURL = nil
        await stopEvents()
        await previous?.stop()
    }
}
