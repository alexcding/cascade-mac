import Foundation
import GhosttyTerminal
import Testing

@Test func terminalStyleWashesItsBackgroundOnlyWhenTranslucent() {
    // Solid: no line at all, so Ghostty's own default (opaque) stands.
    #expect(!TerminalStyle().resolve().configuration.rendered.contains("background-opacity"))
    let translucent = TerminalStyle(backgroundOpacity: 0.6).resolve().configuration.rendered
    #expect(translucent.contains("background-opacity = 0.6"))
}

@Test func backdropOpacityClampsToTheSlidersRange() {
    #expect(WindowBackdrop.clampOpacity(-1) == 0)
    #expect(WindowBackdrop.clampOpacity("2") == 1)
    #expect(WindowBackdrop.clampOpacity("0.4") == 0.4)
    #expect(WindowBackdrop.clampOpacity("not a number") == 1)
    #expect(WindowBackdrop.clampOpacity(nil) == 1)
}

@MainActor @Test func windowBackdropPersistsAndTheToggleReachesTheTerminals() throws {
    let suite = "window-backdrop-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let shell = ShellStore(preferences: preferences)
    #expect(shell.windowBackdrop == WindowBackdrop())
    #expect(shell.terminalStyle.backgroundOpacity == 1)
    var windowChanges = 0, terminalChanges = 0
    shell.windowBackgroundChanged = { windowChanges += 1 }
    shell.terminalStyleChanged = { terminalChanges += 1 }

    // The slider moves the backdrop alone: a terminal draws no background of its own either way.
    shell.setWindowBackdropOpacity(0.4); shell.setWindowBackdropOpacity(0.4)
    #expect(windowChanges == 1 && terminalChanges == 0)

    shell.setWindowTranslucent(true); shell.setWindowTranslucent(true)
    #expect(windowChanges == 2 && terminalChanges == 1)
    #expect(shell.terminalStyle.backgroundOpacity == 0)
    #expect(ShellStore(preferences: preferences).windowBackdrop == WindowBackdrop(isTranslucent: true, opacity: 0.4))

    shell.setWindowTranslucent(false)
    #expect(shell.terminalStyle.backgroundOpacity == 1)
    #expect(ShellStore(preferences: preferences).windowBackdrop == WindowBackdrop(isTranslucent: false, opacity: 0.4))
}
