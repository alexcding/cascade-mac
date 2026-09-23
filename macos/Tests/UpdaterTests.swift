import Foundation
import Testing

@Test func updateConfigurationRequiresPackagedReleaseHTTPSAndEd25519Key() {
    let key = Data(repeating: 42, count: 32).base64EncodedString()
    let valid: [String: Any] = ["SUFeedURL": "https://updates.example.org/appcast.xml", "SUPublicEDKey": key]
    #expect(UpdateConfiguration.unavailableReason(debug: false, packaged: true, info: valid) == nil)
    #expect(UpdateConfiguration.unavailableReason(debug: true, packaged: true, info: valid) != nil)
    #expect(UpdateConfiguration.unavailableReason(debug: false, packaged: false, info: valid) != nil)
    for feed in ["", "$(CRAFT_UPDATE_FEED_URL)", "http://updates.example.org/feed", "file:///tmp/feed",
                 "https://user:password@example.org/feed", "https://example.org/feed#fragment"] {
        #expect(UpdateConfiguration.unavailableReason(debug: false, packaged: true,
            info: ["SUFeedURL": feed, "SUPublicEDKey": key]) != nil)
    }
    for key in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()] {
        #expect(UpdateConfiguration.unavailableReason(debug: false, packaged: true,
            info: ["SUFeedURL": valid["SUFeedURL"]!, "SUPublicEDKey": key]) != nil)
    }
}

@Test func packagedBundleRequiresAnAppWithTheBundledPtyDaemon() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Craft.app"), helpers = app.appendingPathComponent("Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    #expect(!PackagedBundle.isPackaged(app))
    let daemon = helpers.appendingPathComponent("craft-ptyd")
    try Data().write(to: daemon)
    #expect(!PackagedBundle.isPackaged(app))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
    #expect(PackagedBundle.isPackaged(app))
    let folder = root.appendingPathComponent("Craft")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: helpers, to: folder.appendingPathComponent("Contents/Helpers"))
    #expect(!PackagedBundle.isPackaged(folder))
}

@MainActor private final class TerminationFixture {
    var reasons: [AppTerminationCoordinator.Reason] = []
    var replies: [(AppTerminationCoordinator.Reason, Bool)] = []
    var failures: [Error] = []
    var confirmation: CheckedContinuation<Void, Error>?
    lazy var coordinator = AppTerminationCoordinator(prepare: { [self] reason in
        reasons.append(reason)
        try await withCheckedThrowingContinuation { confirmation = $0 }
    }, finished: { [self] reason, approved in replies.append((reason, approved)) },
       failed: { [self] error in failures.append(error) })
    func resolve(_ error: Error? = nil) {
        if let error { confirmation?.resume(throwing: error) } else { confirmation?.resume() }
        confirmation = nil
    }
}

@MainActor private func awaitTermination(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw BackendError.operation("Timed out waiting for termination fixture")
}

@MainActor @Test func updateRestartWaitsForDocumentsCoalescesRequestsAndAllowsCancelThenRetry() async throws {
    let fixture = TerminationFixture(), reason = AppTerminationCoordinator.Reason.update
    let coordinator = fixture.coordinator
    #expect(coordinator.systemTermination(updateRequested: true) == .later)
    #expect(coordinator.systemTermination(updateRequested: true) == .later)
    #expect(coordinator.systemTermination(updateRequested: false) == .later)
    try await awaitTermination { fixture.confirmation != nil }
    #expect(fixture.reasons == [reason] && fixture.replies.isEmpty && !coordinator.approved)
    fixture.resolve(CancellationError())
    try await awaitTermination { fixture.replies.count == 1 }
    #expect(!fixture.replies[0].1 && fixture.failures[0] is CancellationError)
    #expect(coordinator.pending == nil && !coordinator.approved)
    // Sparkle does not repeat willRelaunch when the user retries installation.
    #expect(coordinator.systemTermination(updateRequested: true) == .later)
    try await awaitTermination { fixture.confirmation != nil }
    fixture.resolve()
    try await awaitTermination { fixture.replies.count == 2 }
    #expect(fixture.reasons == [reason, reason] && fixture.replies[1].1)
    #expect(coordinator.systemTermination(updateRequested: false) == .now)
}

@MainActor @Test func quitFailureKeepsAppAliveAndDoesNotBecomeAnUpdateRestart() async throws {
    let fixture = TerminationFixture(), coordinator = fixture.coordinator
    #expect(coordinator.systemTermination(updateRequested: false) == .later)
    #expect(coordinator.systemTermination(updateRequested: false) == .later)
    try await awaitTermination { fixture.confirmation != nil }
    #expect(coordinator.systemTermination(updateRequested: true) == .later)
    #expect(fixture.reasons == [.quit])
    fixture.resolve(BackendError.operation("Daemon shutdown failed"))
    try await awaitTermination { fixture.replies.count == 1 }
    #expect(!fixture.replies[0].1 && !coordinator.approved)
    #expect(fixture.failures.first?.localizedDescription == "Daemon shutdown failed")
    #expect(coordinator.systemTermination(updateRequested: false) == .later)
    try await awaitTermination { fixture.confirmation != nil }
    fixture.resolve()
    try await awaitTermination { fixture.replies.count == 2 }
    #expect(fixture.reasons == [.quit, .quit] && fixture.replies[1].1)
    #expect(coordinator.systemTermination(updateRequested: false) == .now)
}

@MainActor @Test func systemQuitUsesOneCleanupTransaction() async throws {
    let fixture = TerminationFixture(), coordinator = fixture.coordinator
    #expect(coordinator.systemTermination(updateRequested: false) == .later)
    #expect(coordinator.systemTermination(updateRequested: false) == .later)
    try await awaitTermination { fixture.confirmation != nil }
    #expect(fixture.reasons == [.quit])
    fixture.resolve()
    try await awaitTermination { fixture.replies.count == 1 }
    #expect(fixture.replies[0].0 == .quit && fixture.replies[0].1)
    #expect(coordinator.systemTermination(updateRequested: false) == .now)
}
