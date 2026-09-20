import AppKit
import Foundation
import Testing

@Test func trayReviewClassificationCountsOnlyPendingRequests() throws {
    let data = Data(#"[{"url":"https://example.com/1","repo":"o/r","number":1,"title":"Requested","state":"OPEN","category":"review","awaitingMyReview":true,"reviewPending":true},{"url":"https://example.com/2","repo":"o/r","number":2,"title":"Already reviewed","state":"OPEN","category":"other","awaitingMyReview":true},{"url":"https://example.com/3","repo":"o/r","number":3,"title":"Mine","state":"OPEN","category":"mine","awaitingMyReview":false}]"#.utf8)
    let prs = try JSONDecoder().decode([TrayPR].self, from: data)
    #expect(prs.filter(\.pendingReview).map(\.number) == [1])
    #expect(safeWebURL("file:///tmp/a") == nil)
    #expect(safeWebURL("https://user:secret@example.com") == nil)
    #expect(backendTimestamp("2026-09-12T00:00:00.123Z") != nil)
    #expect(backendTimestamp("2026-09-12T00:00:00Z") != nil)
    let limit = UsageSnapshot.Window(usedPct: 120, resetsAt: nil, label: nil)
    #expect(limit.remaining == 0)
    let now = try #require(backendTimestamp("2026-09-12T00:00:00Z"))
    let half = UsageSnapshot.Window(usedPct: 30, resetsAt: "2026-09-12T02:30:00Z", label: nil)
    #expect(half.paceRemaining(duration: 5 * 3600, now: now) == 50)
    #expect(half.paceRemaining(duration: 5 * 3600, now: now.addingTimeInterval(86400)) == 0)
    #expect(limit.paceRemaining(duration: 5 * 3600, now: now) == nil)
}

private actor TodayLogService: LogService {
    let body: String
    init(_ body: String) { self.body = body }
    func entries(category: String, errorsOnly: Bool) throws -> [LogEntry] {
        #expect(category == "event" && !errorsOnly)
        return try JSONDecoder().decode([LogEntry].self, from: Data(body.utf8))
    }
    func categories() -> [String] { [] }
    func clear(category: String) {}
}

@MainActor @Test(.timeLimit(.minutes(1))) func todayActivityShowsOnlyTodaysEventsAndLoadsWhenOpened() async throws {
    // Local noon, so "today" and "yesterday" are the same days in every time zone.
    let now = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_789_000_000)))
    let stamp = ISO8601DateFormatter()
    let today = stamp.string(from: now.addingTimeInterval(-600))
    let yesterday = stamp.string(from: now.addingTimeInterval(-86400))
    let service = TodayLogService(#"[{"seq":2,"category":"event","level":"info","type":"pr_merged","payload":"{\"pr\":{\"number\":4,\"url\":\"https://github.com/o/r/pull/4\"}}","created_at":"\#(today)"},{"seq":3,"category":"event","level":"error","type":"sync_failed","payload":"{}","created_at":"\#(today)"},{"seq":1,"category":"event","level":"info","type":"pr_opened","payload":"{}","created_at":"\#(yesterday)"}]"#)
    let model = TodayActivityViewModel(now: { now })
    model.connect(service)
    #expect(!model.loaded && !model.loading) // nothing is fetched until the bell opens it
    model.setVisible(true)
    while !model.loaded { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.entries.map(\.seq) == [2, 3])

    var opened: [Int] = []
    model.openPage = { opened.append($0.seq) }
    let merged = try #require(model.entries.first { $0.seq == 2 }), failed = try #require(model.entries.first { $0.seq == 3 })
    #expect(model.canOpen(merged) && !model.canOpen(failed))
    let openedMerged = await model.open(merged), openedFailed = await model.open(failed)
    #expect(openedMerged && !openedFailed)
    #expect(opened == [2])
    model.openPage = { _ in throw BackendError.operation("offline") }
    let openedOffline = await model.open(merged)
    #expect(!openedOffline)
    #expect(model.error?.contains("offline") == true)

    model.setVisible(false)
    model.setVisible(true) // reopening starts from "Loading…", never the previous rows
    #expect(model.entries.isEmpty && !model.loaded && model.error == nil)
    while !model.loaded { try await Task.sleep(for: .milliseconds(5)) }
    model.setVisible(false)
}
