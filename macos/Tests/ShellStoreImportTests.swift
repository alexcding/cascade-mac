import Foundation
import Testing

/// The one-time import of what an earlier version kept in the backend: every preference this Mac
/// has no value for is adopted and applied at once, a value it has is kept, and the import runs once.
@MainActor @Test func theOneTimeImportAdoptsWhatThisMacHasNoValueForAndAppliesIt() throws {
    let suite = "legacy-import-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    // A value this Mac already has, set on this Mac, is never overwritten.
    preferences.set("glass", forKey: "native.reviewSound")
    let shell = ShellStore(preferences: preferences)
    #expect(shell.needsLegacyPreferenceImport)
    #expect(shell.appearance == .system && shell.sessionMemoryLimit == .unlimited)
    var terminalChanges = 0, documentChanges = 0
    shell.terminalStyleChanged = { terminalChanges += 1 }
    shell.documentStyleChanged = { documentChanges += 1 }
    shell.importLegacyPreferences([
        "theme": "dark",
        "reviewSound": "purr",
        "term_font_family": "Menlo", "term_font_size": "15",
        "sessionMemoryLimit": MemoryLimit.oneGB.rawValue,
        "board_filter_p1": "alice",
        "gitClientCmd": "",
        "unknownLater": nil,
        "native.context.abc": "{\"snapshots\":{}}",
        "poll_interval": "30",
    ])
    #expect(!shell.needsLegacyPreferenceImport)
    #expect(shell.appearance == .dark, "a backend value this Mac lacked is adopted")
    #expect(shell.reviewSound == "glass", "a value this Mac has is kept")
    #expect(shell.terminalCodeFont == CodeFont(family: "Menlo", size: 15))
    #expect(shell.sessionMemoryLimit == .oneGB)
    #expect(preferences.string(forKey: "native.boardFilter.p1") == "alice")
    #expect(preferences.string(forKey: "native.gitClientCmd") == nil, "an empty value is nothing to adopt")
    #expect(preferences.string(forKey: "native.native.context.abc") == nil, "a page-tab snapshot is not a preference")
    #expect(preferences.string(forKey: "native.poll_interval") == nil, "the backend's own settings stay there")
    #expect(terminalChanges >= 1 && documentChanges >= 1, "the adopted values reach the views")
    // What was adopted is this Mac's now, and the import does not run again.
    let relaunched = ShellStore(preferences: preferences)
    #expect(relaunched.appearance == .dark && relaunched.terminalCodeFont.family == "Menlo")
    shell.importLegacyPreferences(["theme": "light"])
    #expect(shell.appearance == .dark)
}

/// A Mac that already had every preference mirrored locally adopts only the board filters, and
/// nothing is announced to the views for values that did not change.
@MainActor @Test func theOneTimeImportChangesNothingThisMacAlreadyHas() throws {
    let suite = "legacy-import-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("light", forKey: "native.theme")
    preferences.set("Monaco", forKey: "native.term_font_family")
    let shell = ShellStore(preferences: preferences)
    var terminalChanges = 0
    shell.terminalStyleChanged = { terminalChanges += 1 }
    shell.importLegacyPreferences(["theme": "dark", "term_font_family": "Menlo", "board_filter_p2": "bob"])
    #expect(shell.appearance == .light && shell.terminalCodeFont.family == "Monaco")
    #expect(preferences.string(forKey: "native.boardFilter.p2") == "bob")
    #expect(terminalChanges == 0)
    #expect(!shell.needsLegacyPreferenceImport)
}
