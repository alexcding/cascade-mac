import AppKit
import Foundation
import Testing

@MainActor private final class RecordingShellAppearance: ShellAppearanceApplying {
    var applied: [AppAppearance] = []
    func apply(_ appearance: AppAppearance) { applied.append(appearance) }
}

private actor ControlledShellData: ShellDataServing {
    var reads = 0
    var writes: [(String, String)] = []
    private var snapshot: CheckedContinuation<[String: String?], any Error>?
    func reviews() -> [TrayPR] { [] }
    func usage() throws -> UsageSnapshot { throw BackendError.operation("Usage unavailable") }
    func settings() async throws -> [String: String?] {
        reads += 1
        return try await withCheckedThrowingContinuation { snapshot = $0 }
    }
    func finish(_ values: [String: String?]) { snapshot?.resume(returning: values); snapshot = nil }
    func setSetting(_ key: String, value: String) throws {
        writes.append((key, value))
        throw BackendError.operation("Write unavailable")
    }
    func acknowledgeReview(repo: String, number: Int) { }
}

@MainActor private func shellEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw BackendError.operation("Shell condition was not reached") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor @Test func shellFactoryRestoresAppearanceAndOnlyCoordinatorAppliesChanges() throws {
    let suite = "shell-appearance-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("dark", forKey: "native.theme")
    let platform = RecordingShellAppearance()
    let factory = NativeShellFeatureFactory(preferences: preferences, appearance: platform)
    let shell = factory.shell(notifications: NotificationStore())
    shell.applyAppearance()
    #expect(platform.applied.isEmpty)
    let coordinator = factory.coordinator(model: shell)
    defer { withExtendedLifetime(coordinator) {} }
    shell.applyAppearance()
    #expect(platform.applied == [.dark])
    var styleChanges = 0
    shell.documentStyleChanged = { styleChanges += 1 }
    shell.setAppearance(.light)
    shell.setAppearance(.light)
    #expect(platform.applied == [.dark, .light] && styleChanges == 1)
    #expect(preferences.string(forKey: "native.theme") == "light")
    let callback = shell.onAction
    shell.setAppearance(.system)
    callback(.applyAppearance(.light))
    #expect(platform.applied == [.dark, .light, .system])
    #expect(preferences.string(forKey: "native.theme") == "auto")
}

@MainActor @Test func shellCoordinatorRejectsReplacedBindingsAndRetirement() throws {
    let suite = "shell-bindings-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let shell = ShellStore(preferences: preferences), other = ShellStore(preferences: preferences)
    let platform = RecordingShellAppearance()
    var first: ShellCoordinator? = ShellCoordinator(model: shell, appearance: platform)
    let original = shell.onAction
    first?.bind(other)
    original(.applyAppearance(.system))
    #expect(platform.applied.isEmpty)
    let old = other.onAction
    let replacement = ShellCoordinator(model: other, appearance: platform)
    old(.applyAppearance(.system))
    #expect(platform.applied.isEmpty)
    other.applyAppearance()
    #expect(platform.applied == [.system])
    first?.retire()
    other.applyAppearance() // Retiring the old coordinator cannot erase the new binding.
    #expect(platform.applied == [.system, .system])
    replacement.retire()
    other.applyAppearance()
    #expect(platform.applied.count == 2)
    first = nil
    original(.applyAppearance(.system))
    #expect(platform.applied.count == 2)
}

@MainActor @Test func shellSnapshotChangesUseModelObserversAndDuplicateSnapshotsAreQuiet() async throws {
    let suite = "shell-snapshot-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let shell = ShellStore(preferences: preferences), service = ControlledShellData()
    let platform = RecordingShellAppearance(), coordinator = ShellCoordinator(model: shell, appearance: platform)
    defer { withExtendedLifetime(coordinator) {} }
    shell.connect(service)
    try await shellEventually { await service.reads == 1 }
    let snapshot: [String: String?] = ["theme": "dark"]
    await service.finish(snapshot)
    try await shellEventually { shell.appearance == .dark }
    #expect(platform.applied == [.dark])
    try await shellEventually { shell.loadSettings(); return await service.reads == 2 }
    await service.finish(snapshot)
    try await shellEventually { shell.loadSettings(); return await service.reads == 3 }
    #expect(platform.applied == [.dark])
    #expect(preferences.string(forKey: "native.theme") == "dark")
    await service.finish(snapshot)
    await shell.stop()
}

@MainActor @Test func shellEditorStyleSyncsSavesAndReadsUnknownThemesAsDefault() async throws {
    let suite = "shell-editor-style-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    // A dark theme saved for the light appearance, and a name no build has.
    preferences.set("Dracula", forKey: "native.editorThemeLight")
    preferences.set("Removed Theme", forKey: "native.editorThemeDark")
    let shell = ShellStore(preferences: preferences), service = ControlledShellData()
    #expect(shell.editorStyle == EditorStyle())
    var changes = 0
    shell.documentStyleChanged = { changes += 1 }
    shell.connect(service)
    try await shellEventually { await service.reads == 1 }
    await service.finish(["editorThemeDark": "Dracula", "editorThemeLight": "Dracula Pro", "editorMinimap": "off"])
    try await shellEventually { shell.editorStyle.darkTheme == "Dracula" }
    #expect(shell.editorStyle == EditorStyle(darkTheme: "Dracula", lightTheme: "", showMinimap: false))
    #expect(preferences.string(forKey: "native.editorMinimap") == "off")
    #expect(changes > 0)
    shell.setEditorTheme(light: "Nord") // Dark only: refused, and said so.
    #expect(shell.editorStyle.lightTheme == "" && shell.settingsError != nil)
    shell.setEditorTheme(light: "One Light"); shell.setEditorMinimap(true)
    #expect(shell.editorStyle == EditorStyle(darkTheme: "Dracula", lightTheme: "One Light", showMinimap: true))
    #expect(preferences.string(forKey: "native.editorThemeLight") == "One Light")
    try await shellEventually { await service.writes.map(\.0).contains("editorMinimap") }
    await shell.stop()
}

@MainActor @Test func shellOfflineEditsSurviveFailedWritesAndOlderSnapshot() async throws {
    let suite = "shell-offline-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let shell = ShellStore(preferences: preferences), service = ControlledShellData()
    let platform = RecordingShellAppearance(), coordinator = ShellCoordinator(model: shell, appearance: platform)
    defer { withExtendedLifetime(coordinator) {} }
    shell.setAppearance(.light)
    shell.connect(service)
    try await shellEventually { await service.reads == 1 }
    await service.finish(["theme": "dark"])
    try await shellEventually { shell.trayUpdated != nil }
    // Starting the next read proves that the previous snapshot was processed.
    try await shellEventually { shell.loadSettings(); return await service.reads == 2 }
    shell.setAppearance(.system) // Supersedes the read already in flight.
    await service.finish(["theme": "dark", "usageAgent": "codex"])
    try await shellEventually { shell.loadSettings(); return await service.reads == 3 }
    #expect(shell.appearance == .system)
    #expect(shell.usageAgent == "claude") // Reject the whole stale snapshot, including unedited fields.
    #expect(platform.applied == [.light, .system])
    let pending = preferences.dictionary(forKey: "native.pendingSettings") as? [String: String]
    #expect(pending?["theme"] == "auto")
    await service.finish([:])
    await shell.stop()
}

@MainActor @Test func nativeShellAppearanceAppliesSystemLightAndDark() {
    _ = NSApplication.shared
    let saved = NSApp.appearance
    defer { NSApp.appearance = saved }
    let platform = NativeShellAppearance()
    platform.apply(.dark)
    #expect(NSApp.appearance?.name == .darkAqua)
    platform.apply(.light)
    #expect(NSApp.appearance?.name == .aqua)
    platform.apply(.system)
    #expect(NSApp.appearance == nil)
}
