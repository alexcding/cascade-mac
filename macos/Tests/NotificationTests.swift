import Foundation
import Testing

private func review(_ number: Int = 1, at marker: String? = "first", category: String = "review", pending: Bool = true) -> TrayPR {
    TrayPR(url: "https://example.com/pr/\(number)", repo: "owner/repo", number: number,
           title: "A change", state: "OPEN", category: category, awaitingMyReview: true,
           reviewPending: pending, requestedAt: marker, projectName: nil, ci: nil)
}

@Test func reviewAnnouncementsSeedSilentlyAndTrackRequestsRatherThanReviewOrbit() {
    var tracker = ReviewAnnouncementTracker()
    #expect(tracker.consume([review()]).isEmpty)
    #expect(tracker.consume([review()]).isEmpty)
    #expect(tracker.consume([review(at: "again")]).count == 1)
    #expect(tracker.consume([review(at: "again"), review(2, category: "other")]).isEmpty)
    #expect(tracker.consume([review(pending: false)]).isEmpty)
    #expect(tracker.consume([review(at: "later")]).count == 1)
    #expect(tracker.consume([review(at: nil)]).count == 1)
    #expect(tracker.consume([review(at: nil)]).isEmpty)
    #expect(tracker.consume([]).isEmpty)
    #expect(tracker.consume([review(2)]).map(\.number) == [2])
}

@MainActor final class RecordingNotifications: NotificationDelivery {
    var status = NotificationAccess(permission: .authorized, soundAllowed: true)
    var notices: [NativeNotice] = []
    var sounds: [String] = []
    var requests = 0
    var fail = false
    func access() async -> NotificationAccess { status }
    func requestAuthorization() async throws { requests += 1; status.permission = .authorized }
    func deliver(_ notice: NativeNotice) async throws {
        if fail { throw CocoaError(.fileWriteUnknown) }
        notices.append(notice)
    }
    func playReviewSound(_ path: String) throws { sounds.append(path) }
}

@MainActor @Test func reviewDeliveryBatchesSoundAndRespectsPermissionWithoutPrompting() async {
    let recorder = RecordingNotifications()
    let store = NotificationStore()
    store.configure(recorder)
    store.receiveReviews([], sound: "system")
    store.receiveReviews([review(), review(2)], sound: "/tmp/chime.aiff")
    await store.waitForDelivery()
    #expect(recorder.notices.count == 2)
    #expect(recorder.sounds == ["/tmp/chime.aiff"])
    #expect(recorder.requests == 0)
    await store.stop() // Simulate a backend reconnect, preserving the seed.
    store.receiveReviews([review(), review(2)], sound: "system")
    await store.waitForDelivery()
    #expect(recorder.notices.count == 2)
    recorder.status.permission = .denied
    store.receiveReviews([review(at: "new")], sound: "system")
    await store.waitForDelivery()
    #expect(recorder.notices.count == 2 && recorder.sounds.count == 1)
    recorder.status.permission = .notDetermined
    store.refreshAuthorization()
    await store.waitForDelivery()
    store.onAction = { [weak store] action in if action == .enable { store?.requestAuthorization() } }
    store.enable()
    await store.waitForDelivery()
    #expect(recorder.requests == 1 && store.permission == .authorized)
    store.receiveReviews([review(at: "new")], sound: "system")
    await store.waitForDelivery()
    #expect(recorder.notices.count == 2) // Granting permission doesn't replay old requests.
    recorder.status.soundAllowed = false
    store.receiveReviews([review(at: "newer")], sound: "system")
    await store.waitForDelivery()
    #expect(recorder.notices.count == 3 && recorder.sounds.count == 1)
    recorder.status.soundAllowed = true
    store.receiveReviews([review(at: "silent")], sound: "off")
    await store.waitForDelivery()
    #expect(recorder.notices.count == 4 && recorder.sounds.count == 1)
    await store.stop()
}

private func activity(_ stamp: String, type: String = "pr_merged", url: String = "https://example.com/pr/1") throws -> ActivityEvent {
    let data = try JSONSerialization.data(withJSONObject: ["type": type, "created_at": stamp,
        "payload": ["repo": "owner/repo", "pr": ["number": 1, "title": "A change", "url": url], "error": "Offline"]])
    return try JSONDecoder().decode(ActivityEvent.self, from: data)
}

@MainActor @Test func activityHasOneSurfaceDeduplicatesAndKeepsBoundedRecentHistory() async throws {
    let recorder = RecordingNotifications()
    let store = NotificationStore()
    store.configure(recorder)
    store.isMainWindowFocused = { true }
    let first = try activity("first")
    store.receiveActivity(first, enabled: true)
    await store.waitForDelivery()
    #expect(store.toast?.title == "Pull request merged in repo")
    #expect(recorder.notices.isEmpty)
    store.isMainWindowFocused = { false }
    store.receiveActivity(first, enabled: true)
    await store.waitForDelivery()
    #expect(recorder.notices.isEmpty && store.recent.count == 1)
    store.receiveActivity(try activity("second"), enabled: true)
    await store.waitForDelivery()
    #expect(recorder.notices.count == 1 && recorder.sounds.isEmpty)
    for i in 0..<30 { store.receiveActivity(try activity("disabled-\(i)"), enabled: false) }
    await store.waitForDelivery()
    #expect(store.recent.count == 20 && recorder.notices.count == 1)
    var opened: NativeNotice?
    store.onAction = { action in if case .openDelivered(let notice) = action { opened = notice } }
    store.openDelivered(recorder.notices[0])
    #expect(opened?.url == "https://example.com/pr/1")
    // Emitting an action alone cannot dismiss a toast before navigation succeeds.
    #expect(store.toast != nil)
    await store.stop()
}

@Test func activitySSEDecodesTypedPayloadAndRejectsUnsafeLinks() throws {
    let event = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"activity","event":{"type":"jira_transition_failed","created_at":"2026-09-12T00:00:00Z","payload":{"key":"APP-12","error":"Permission denied"}}}"#.utf8))
    #expect(event.event?.message.title == "Failed to transition APP-12")
    #expect(event.event?.message.body == "Permission denied")
    #expect(try activity("a", url: "file:///tmp/test").message.url == nil)
    #expect(try activity("b", type: "future_event").message.title == "Future Event")
}

@MainActor @Test func deliveryFailureIsVisibleAndDoesNotReplayOnRefresh() async {
    let recorder = RecordingNotifications()
    recorder.fail = true
    let store = NotificationStore()
    store.configure(recorder)
    store.receiveReviews([], sound: "system")
    store.receiveReviews([review()], sound: "system")
    await store.waitForDelivery()
    #expect(store.error != nil && recorder.sounds.isEmpty)
    recorder.fail = false
    store.receiveReviews([review()], sound: "system")
    await store.waitForDelivery()
    #expect(recorder.notices.isEmpty)
    await store.stop()
}
