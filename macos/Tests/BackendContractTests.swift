import Testing
import Foundation

@Test func routeEncodingMatchesJavaScript() async throws {
    #expect(Routes.settingsKey("a/b ?#%é") == "/api/settings/a%2Fb%20%3F%23%25%C3%A9")
    #expect(Routes.jiraKeyTransition("A/B") == "/api/jira/A%2FB/transition")
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:3000")!)
    let url = try await api.url(Routes.settingsKey("a/b"))
    #expect(url.absoluteString == "http://127.0.0.1:3000/api/settings/a%2Fb")
}

@Test func refusesRemoteOriginsAndWrongService() throws {
    #expect(throws: BackendError.self) { try APIClient(baseURL: URL(string: "https://example.com")!) }
    #expect(throws: BackendError.self) { try APIClient(baseURL: URL(string: "http://localhost:3000/foreign")!) }
    #expect(throws: BackendError.self) {
        try BackendHealth(service: "other", protocol: 1, pid: 1, instanceId: nil).validate()
    }
    #expect(throws: BackendError.self) {
        try BackendHealth(service: "craft", protocol: 1, pid: 1, instanceId: "another").validate(instanceID: "ours")
    }
}

@Test func streamFramingPreservesUnicodeAndMultilineData() throws {
    var parser = SSEParser()
    var events: [Data] = []
    let input = ": heartbeat\r\nretry: 1000\r\ndata: {\r\ndata: \"type\":\"sync\",\"projectId\":\"é\"}\r\n\r\ndata: {\"type\":\"tabs\"}\n\n"
    for byte in input.utf8 { if let data = try parser.feed(byte) { events.append(data) } }
    #expect(events.count == 2)
    let first = try JSONDecoder().decode(ServerEvent.self, from: events[0])
    #expect(first.type == "sync")
    #expect(first.projectId == "é")
}

@Test func streamParserBoundsUnterminatedFrames() throws {
    var parser = SSEParser()
    for _ in 0..<1_048_576 { _ = try parser.feed(65) }
    #expect(throws: BackendError.self) { _ = try parser.feed(65) }
}

@Test func configurationResolvesRustDevelopmentRuntime() throws {
    let development = try BackendConfiguration.current(arguments: ["Craft", "--backend-root", "/tmp/repo"], environment: [:])
    guard case .embedded = development.mode else { Issue.record("Expected the embedded backend for a checkout run"); return }
    #expect(!development.packaged)
    let child = try BackendConfiguration.current(arguments: ["Craft", "--backend-root", "/tmp/repo", "--backend-path", "/tmp/repo/crates/craft-backend/target/debug/craft-backend", "--backend-port", "4000"], environment: [:])
    guard case .owned(let executable, _) = child.mode else { Issue.record("Expected owned mode"); return }
    #expect(child.baseURL.port == 4000)
    #expect(executable.path == "/tmp/repo/crates/craft-backend/target/debug/craft-backend")
    #expect(throws: BackendError.self) {
        try BackendConfiguration.current(arguments: ["Craft", "--backend-url"], environment: [:])
    }
    let config = try BackendConfiguration.current(arguments: ["Craft", "--backend-url", "http://127.0.0.1:4321"], environment: [:])
    guard case .external = config.mode else { Issue.record("Expected external mode"); return }
    #expect(config.baseURL.port == 4321)
}
