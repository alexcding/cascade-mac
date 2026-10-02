import AppKit
import Foundation
import Testing

@MainActor private final class RecordingShellAppearance: ShellAppearanceApplying {
    var applied: [AppAppearance] = []
    func apply(_ appearance: AppAppearance) { applied.append(appearance) }
}

@MainActor @Test func shellFactoryRestoresAppearanceAndOnlyCoordinatorAppliesChanges() throws {
    let suite = "shell-appearance-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("dark", forKey: "native.theme")
    let platform = RecordingShellAppearance()
    let factory = NativeShellFeatureFactory(preferences: preferences, appearance: platform, fileIcons: nil)
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

@MainActor @Test func shellEditorStyleReadsSavedThemesAndRefusesUnknownOnes() throws {
    let suite = "shell-editor-style-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    // A dark theme saved for the light appearance, and a name no build has: both read as Default.
    preferences.set("Dracula", forKey: "native.editorThemeLight")
    preferences.set("Removed Theme", forKey: "native.editorThemeDark")
    let shell = ShellStore(preferences: preferences)
    #expect(shell.editorStyle == EditorStyle())
    var changes = 0
    shell.documentStyleChanged = { changes += 1 }
    shell.setEditorTheme(dark: "Dracula")
    #expect(shell.editorStyle == EditorStyle(darkTheme: "Dracula", lightTheme: ""))
    #expect(preferences.string(forKey: "native.editorThemeDark") == "Dracula")
    #expect(changes > 0)
    shell.setEditorTheme(light: "Nord") // Dark only: refused, and said so.
    #expect(shell.editorStyle.lightTheme == "" && shell.settingsError != nil)
    shell.setEditorTheme(light: "One Light")
    #expect(shell.editorStyle == EditorStyle(darkTheme: "Dracula", lightTheme: "One Light"))
    #expect(preferences.string(forKey: "native.editorThemeLight") == "One Light")
    #expect(shell.settingsError == nil) // An accepted change clears the refusal.
    // The next launch reads what was saved.
    #expect(ShellStore(preferences: preferences).editorStyle == EditorStyle(darkTheme: "Dracula", lightTheme: "One Light"))
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
