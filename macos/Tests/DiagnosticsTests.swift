import Foundation
import Testing

private func diagnosticsFixture(_ name: String = "Fixture") throws -> DiagnosticsSnapshot {
    let object: [String: Any] = [
        "config": ["jira_api_token": "must-not-be-retained"],
        "counts": ["projects": 1, "links": 2, "events": 1000],
        "projects": [["id": "p", "name": name, "repo": "org/repo", "mergeTransition": "Done"]],
        "snapshots": ["p": ["open": 4, "lastSynced": "2026-09-12T12:00:00Z", "error": "Sync failed"]],
        "jiraSnapshots": ["board:p": ["tickets": 3, "lastSynced": NSNull(), "error": NSNull()]],
        "ghStats": ["calls": 10, "errors": 1, "avgMs": 42, "maxMs": 900, "inflight": 2, "coalesced": 7,
                    "slowest": "not-part-of-native-diagnostics"]
    ]
    return try JSONDecoder().decode(DiagnosticsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

actor DiagnosticsFixture: DiagnosticsService {
    var calls = 0
    private var requests: [Int: CheckedContinuation<DiagnosticsSnapshot, any Error>] = [:]
    func snapshot() async throws -> DiagnosticsSnapshot {
        calls += 1
        let id = calls
        // Deliberately ignores cancellation to exercise late responses across
        // navigation, backend replacement, and shutdown.
        return try await withCheckedThrowingContinuation { requests[id] = $0 }
    }
    func complete(_ id: Int, with result: Result<DiagnosticsSnapshot, any Error>) {
        requests.removeValue(forKey: id)?.resume(with: result)
    }
}

@MainActor private func waitForDiagnostics(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for diagnostics")
    throw BackendError.operation("Timed out waiting for diagnostics")
}

@MainActor @Test(.timeLimit(.minutes(1))) func diagnosticsCoalesceVisibleInvalidationsRetainFailureAndSeparateCaches() async throws {
    let service = DiagnosticsFixture()
    let model = DiagnosticsViewModel()
    model.connect(service); model.invalidate()
    #expect(await service.calls == 0)
    model.setVisible(true)
    try await waitForDiagnostics { await service.calls == 1 }
    model.refresh(); model.invalidate(); model.invalidate()
    await service.complete(1, with: .success(try diagnosticsFixture()))
    try await waitForDiagnostics { await service.calls == 2 }
    #expect(model.projects.first?.caches.map(\.count) == ["4 open PRs", "No snapshot", "3 tickets"])
    #expect(model.projects.first?.caches.first?.error == "Sync failed")
    #expect(model.projects.first?.caches.last?.lastSync == "Never synced")
    #expect(model.projects.first?.automation == "On merge: Done")
    #expect(!String(reflecting: model.snapshot).contains("must-not-be-retained"))
    #expect(!String(reflecting: model.snapshot).contains("not-part-of-native-diagnostics"))
    await service.complete(2, with: .failure(BackendError.operation("Inspector offline")))
    try await waitForDiagnostics { !model.loading }
    #expect(model.error == "Inspector offline" && model.projects.first?.name == "Fixture")
    model.refresh()
    try await waitForDiagnostics { await service.calls == 3 }
    await service.complete(3, with: .success(try diagnosticsFixture("Recovered")))
    try await waitForDiagnostics { !model.loading }
    #expect(model.error == nil && model.projects.first?.name == "Recovered")
    model.setVisible(false); model.invalidate()
    #expect(await service.calls == 3)
    model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func diagnosticsRejectLateReadsAfterNavigationReconnectAndStop() async throws {
    let old = DiagnosticsFixture(), current = DiagnosticsFixture()
    let model = DiagnosticsViewModel()
    model.connect(old); model.setVisible(true)
    try await waitForDiagnostics { await old.calls == 1 }
    model.setVisible(false)
    await old.complete(1, with: .success(try diagnosticsFixture("Hidden stale read")))
    model.setVisible(true)
    try await waitForDiagnostics { await old.calls == 2 }
    model.connect(current)
    try await waitForDiagnostics { await current.calls == 1 }
    await old.complete(2, with: .success(try diagnosticsFixture("Old backend")))
    await current.complete(1, with: .success(try diagnosticsFixture("Current backend")))
    try await waitForDiagnostics { !model.loading }
    #expect(model.projects.first?.name == "Current backend")
    model.refresh()
    try await waitForDiagnostics { await current.calls == 2 }
    model.stop()
    await current.complete(2, with: .success(try diagnosticsFixture("Stopped backend")))
    // A fresh connection and successful read also let all prior task completions
    // drain, without relying on a cancellation-cooperative service.
    model.connect(current)
    try await waitForDiagnostics { await current.calls == 3 }
    await current.complete(3, with: .success(try diagnosticsFixture("Restarted")))
    try await waitForDiagnostics { !model.loading }
    #expect(model.projects.first?.name == "Restarted" && model.error == nil)
    model.stop()
}
