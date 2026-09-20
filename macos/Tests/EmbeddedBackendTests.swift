import Foundation
import Testing
@testable import Craft

// The backend linked into the process (crates/craft-backend/src/ffi.rs) behind
// the same APIClient the app uses everywhere.
struct EmbeddedBackendTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("craft-embedded-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func servesRoutesInProcessAndPublishesItsLoopbackPort() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = EmbeddedBackend(dataDirectory: directory, packaged: false)
        let api = try await backend.start()
        let port = await backend.port
        #expect(port > 0)
        #expect(api.baseURL.port == Int(port))
        #expect(try String(contentsOf: directory.appendingPathComponent(".server-port"), encoding: .utf8) == String(port))

        let health = try await api.health()
        #expect(health.runtime == "rust")
        #expect(health.pid == ProcessInfo.processInfo.processIdentifier)
        let projects: [Project] = try await api.get(Routes.PROJECTS)
        #expect(projects.isEmpty)
        let query: ProjectPRSnapshot? = try? await api.get(APIClient.query(Routes.projectPrs("missing"), ["state": "open", "snapshot": "1"]))
        #expect(query == nil)
        // Errors keep the HTTP contract: a JSON error body becomes BackendError.operation.
        do {
            let _: Project = try await api.get(Routes.project("missing"))
            Issue.record("Expected a not-found error")
        } catch let error as BackendError {
            guard case .operation(let message) = error else { Issue.record("Unexpected error \(error)"); return }
            #expect(message == "Not found")
        }

        // The loopback listener serves the same router for forwarders and the web UI.
        let (data, response) = try await URLSession.shared.data(from: api.baseURL.appendingPathComponent("api/backend/health"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(BackendHealth.self, from: data).pid == health.pid)

        let stream = try #require(backend.eventStream())
        await backend.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".server-port").path))
        #expect(backend.eventStream() == nil)
        await #expect(throws: BackendError.self) { let _: [Project] = try await api.get(Routes.PROJECTS) }
        await #expect(throws: BackendError.self) { try await stream.consume(from: api.baseURL, onConnect: {}, onEvent: { _ in }) }
    }

    @Test func deliversBroadcastEventsWithoutSSE() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = EmbeddedBackend(dataDirectory: directory, packaged: false)
        let api = try await backend.start()
        let stream = try #require(backend.eventStream())
        let events = AsyncStream<ServerEvent>.makeStream()
        let connected = AsyncStream<Void>.makeStream()
        let consumer = Task {
            try await stream.consume(from: api.baseURL, onConnect: { connected.continuation.yield(()) },
                                     onEvent: { events.continuation.yield($0) })
        }
        var connections = connected.stream.makeAsyncIterator()
        _ = await connections.next()

        struct Tab: Encodable, Sendable { let url: String; let kind: String }
        struct Saved: Decodable, Sendable {}
        let _: Saved = try await api.request(Routes.TABS, method: "POST", body: Tab(url: "https://example.com/", kind: "web"))

        let received = try await withThrowingTaskGroup(of: ServerEvent?.self) { group in
            group.addTask {
                for await event in events.stream where event.type == "tabs" { return event }
                return nil
            }
            group.addTask { try await Task.sleep(for: .seconds(10)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(received?.type == "tabs")

        // Cancelling the consumer unsubscribes; stopping afterwards is clean.
        consumer.cancel()
        _ = await consumer.result
        await backend.stop()
    }

    @Test func stopEndsAnOpenSubscription() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = EmbeddedBackend(dataDirectory: directory, packaged: false)
        let api = try await backend.start()
        let stream = try #require(backend.eventStream())
        let consumer = Task { try await stream.consume(from: api.baseURL, onConnect: {}, onEvent: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        await backend.stop()
        let outcome = await consumer.result
        guard case .failure(let error) = outcome, let backendError = error as? BackendError,
              case .startup(let message) = backendError else { Issue.record("Expected the stream to report the stop, got \(outcome)"); return }
        #expect(message.contains("stopped"))
        // A second stop is a no-op and a restart works on the same directory.
        await backend.stop()
        let again = try await backend.start()
        let restarted = try await again.health()
        #expect(restarted.runtime == "rust")
        await backend.stop()
    }

    @Test func startFailureIsReportedNotFatal() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("craft-embedded-file-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: file) }
        let backend = EmbeddedBackend(dataDirectory: file, packaged: false)
        do {
            _ = try await backend.start()
            Issue.record("Expected start to fail on a file path")
        } catch let error as BackendError {
            guard case .startup(let message) = error else { Issue.record("Unexpected \(error)"); return }
            #expect(message.contains("could not start"))
        }
    }
}
