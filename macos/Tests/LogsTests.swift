import Foundation
import Testing

private actor LogFixture: LogService {
    var fails = false
    var cleared: [String] = []
    var deleted = false
    var reads: [(String, Bool)] = []
    func fail(_ value: Bool) { fails = value }
    func categories() -> [String] { ["event", "poller"] }
    func entries(category: String, errorsOnly: Bool) async throws -> [LogEntry] {
        reads.append((category, errorsOnly))
        if category == "event" { try await Task.sleep(for: .milliseconds(80)) }
        if fails { throw BackendError.operation("Logs offline") }
        if deleted { return [] }
        return try JSONDecoder().decode([LogEntry].self, from: Data("[{\"seq\":1,\"category\":\"\(category)\",\"level\":\"info\",\"type\":\"fixture_event\",\"payload\":\"plain text\",\"created_at\":\"2026-09-12T12:00:00Z\"}]".utf8))
    }
    func clear(category: String) throws {
        if fails { throw BackendError.operation("Clear unavailable") }
        cleared.append(category); deleted = true
    }
}

@MainActor @Test func logFiltersRejectStaleResponsesAndClearTheConfirmedCategoryOnly() async throws {
    let service = LogFixture()
    let model = LogsViewModel(pageActions: ProjectPageActions(), copy: { _ in })
    let coordinator = LogsCoordinator(model: model)
    model.connect(service)
    model.refresh()
    try await Task.sleep(for: .milliseconds(10))
    model.category = "poller"
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.rows.first?.category == "poller")
    model.errorsOnly = true
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    let last = await service.reads.last
    #expect(last?.0 == "poller" && last?.1 == true)
    let count = await service.reads.count
    model.errorsOnly = true; model.category = "poller"
    await Task.yield()
    #expect(await service.reads.count == count)
    await service.fail(true)
    model.refresh()
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.rows.count == 1 && model.error == "Logs offline")
    model.requestClear()
    coordinator.cancel(id: try #require(coordinator.confirmation).id)
    #expect(await service.cleared.isEmpty)
    model.requestClear()
    let request = try #require(coordinator.confirmation)
    await coordinator.confirm(id: request.id)
    #expect(model.rows.count == 1 && model.clearError == "Clear unavailable")
    #expect(coordinator.confirmation == request && model.error == "Logs offline")
    await service.fail(false)
    model.refresh()
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error == nil && model.clearError == "Clear unavailable")
    model.category = "all"
    await coordinator.confirm(id: request.id) // retry the reviewed category after the visible filter changes
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await service.cleared == ["poller"])
    #expect(model.rows.isEmpty)
    #expect(coordinator.confirmation == nil)
    await model.stop()
}

@Test func logPayloadsPreserveRawTextAndRejectUnsafeEventLinks() throws {
    let rows = try JSONDecoder().decode([LogEntry].self, from: Data(#"""
    [
      {"seq":1,"category":"event","level":"info","type":"pr_opened","payload":"{\"repo\":\"o/r\",\"pr\":{\"number\":42,\"title\":\"Native UI\",\"url\":\"https://github.com/o/r/pull/42\"}}","created_at":"2026-09-12T12:00:00Z"},
      {"seq":2,"category":"poller","level":"warn","type":"parse_failed","payload":"not JSON <literal>","created_at":"bad timestamp"},
      {"seq":3,"category":"event","level":"error","type":"pr_opened","payload":"{\"pr\":{\"url\":\"file:///tmp/local\"}}","created_at":"2026-09-12T12:00:00Z"}
    ]
    """#.utf8))
    #expect(rows[0].title == "Pull request opened in r" && rows[0].detail == "#42 Native UI")
    #expect(rows[0].link == "https://github.com/o/r/pull/42")
    #expect(rows[1].detail == "not JSON <literal>" && rows[1].timestamp == "bad timestamp")
    #expect(rows[2].link == nil)
}
