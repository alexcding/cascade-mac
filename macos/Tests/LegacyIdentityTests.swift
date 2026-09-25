import Foundation
import Testing

private func scratchHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("craft-legacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support"),
                                            withIntermediateDirectories: true)
    return home
}

@Test func theOldDataFolderMovesAndItsOldPathStillResolves() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    let old = support.appendingPathComponent("TaskHub")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("rows".utf8).write(to: old.appendingPathComponent("taskhub.db"))

    let current = LegacyIdentity.carryData(home: home)
    #expect(current.path == support.appendingPathComponent("Cascade").path)
    #expect(try Data(contentsOf: current.appendingPathComponent("taskhub.db")) == Data("rows".utf8))
    // An installed status line or hook still points at the old path.
    #expect(try Data(contentsOf: old.appendingPathComponent("taskhub.db")) == Data("rows".utf8))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == current.path)
    // Asking again changes nothing.
    #expect(LegacyIdentity.carryData(home: home).path == current.path)
}

/// A TaskHub folder that Craft already carried is a link to Craft; Craft's move leaves both paths resolving.
@Test func aCraftFolderThatCarriedTaskHubMovesAndBothOldPathsStillResolve() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    let craft = support.appendingPathComponent("Craft"), taskHub = support.appendingPathComponent("TaskHub")
    try FileManager.default.createDirectory(at: craft, withIntermediateDirectories: true)
    try Data("rows".utf8).write(to: craft.appendingPathComponent("craft.db"))
    try FileManager.default.createSymbolicLink(at: taskHub, withDestinationURL: craft)

    let current = LegacyIdentity.carryData(home: home)
    #expect(current.path == support.appendingPathComponent("Cascade").path)
    #expect(try Data(contentsOf: current.appendingPathComponent("craft.db")) == Data("rows".utf8))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: craft.path) == current.path)
    #expect(try Data(contentsOf: taskHub.appendingPathComponent("craft.db")) == Data("rows".utf8))
}

@Test func preferencesAreNotCarriedWhileAnOldCopyIsRunning() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    let craft = support.appendingPathComponent("Craft")
    try FileManager.default.createDirectory(at: craft, withIntermediateDirectories: true)
    try Data("rows".utf8).write(to: craft.appendingPathComponent("craft.db"))
    let old = "craft.tests.legacy.\(UUID().uuidString)", new = "craft.tests.current.\(UUID().uuidString)"
    let source = try #require(UserDefaults(suiteName: old)), defaults = try #require(UserDefaults(suiteName: new))
    defer { source.removePersistentDomain(forName: old); defaults.removePersistentDomain(forName: new) }
    source.set("dark", forKey: "appearance")

    LegacyIdentity.carryDefaults(into: defaults, from: [old], oldCopyRunning: true)
    #expect(defaults.string(forKey: "appearance") == nil)

    // Once it has quit, the next launch carries both.
    let current = LegacyIdentity.carryData(home: home)
    LegacyIdentity.carryDefaults(into: defaults, from: [old], oldCopyRunning: false)
    #expect(try Data(contentsOf: current.appendingPathComponent("craft.db")) == Data("rows".utf8))
    #expect(defaults.string(forKey: "appearance") == "dark")
}

@Test func aNewFolderThatAlreadyHoldsADatabaseIsLeftAlone() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    for (name, database) in [("Craft", "craft.db"), ("Cascade", "craft.db")] {
        try FileManager.default.createDirectory(at: support.appendingPathComponent(name), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: support.appendingPathComponent("\(name)/\(database)"))
    }
    let current = LegacyIdentity.carryData(home: home)
    #expect(try Data(contentsOf: current.appendingPathComponent("craft.db")) == Data("Cascade".utf8))
    #expect(try Data(contentsOf: support.appendingPathComponent("Craft/craft.db")) == Data("Craft".utf8))
}

/// A status line, or a run with `--data-dir`, can make the new folder before the app ever moves anything.
@Test func aNewFolderWithNoDatabaseStillReceivesTheOldData() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    let old = support.appendingPathComponent("TaskHub"), new = support.appendingPathComponent("Cascade")
    try FileManager.default.createDirectory(at: old.appendingPathComponent("statusline"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: new.appendingPathComponent("statusline"), withIntermediateDirectories: true)
    try Data("rows".utf8).write(to: old.appendingPathComponent("taskhub.db"))
    try Data("old".utf8).write(to: old.appendingPathComponent("statusline/original.json"))
    try Data("new".utf8).write(to: new.appendingPathComponent("statusline/original.json"))

    let current = LegacyIdentity.carryData(home: home)
    #expect(try Data(contentsOf: current.appendingPathComponent("taskhub.db")) == Data("rows".utf8))
    // What the new folder already had wins, and the old copy is not thrown away.
    #expect(try Data(contentsOf: current.appendingPathComponent("statusline/original.json")) == Data("new".utf8))
    #expect(try Data(contentsOf: old.appendingPathComponent("statusline/original.json")) == Data("old".utf8))
}

@Test func oldPreferencesAreCarriedOnceAndNeverOverANewValue() throws {
    let old = "craft.tests.legacy.\(UUID().uuidString)", new = "craft.tests.current.\(UUID().uuidString)"
    let source = try #require(UserDefaults(suiteName: old)), defaults = try #require(UserDefaults(suiteName: new))
    defer { source.removePersistentDomain(forName: old); defaults.removePersistentDomain(forName: new) }
    source.set(0.4, forKey: "workspace.contextPaneFraction")
    source.set("dark", forKey: "appearance")
    defaults.set("light", forKey: "appearance")

    LegacyIdentity.carryDefaults(into: defaults, from: [old], oldCopyRunning: false)
    #expect(defaults.double(forKey: "workspace.contextPaneFraction") == 0.4)
    #expect(defaults.string(forKey: "appearance") == "light")

    source.set(0.9, forKey: "workspace.contextPaneFraction")
    LegacyIdentity.carryDefaults(into: defaults, from: [old], oldCopyRunning: false)
    #expect(defaults.double(forKey: "workspace.contextPaneFraction") == 0.4)
}

@Test func theNewerOldNameWinsWhenBothHaveAPreference() throws {
    let craft = "craft.tests.craft.\(UUID().uuidString)", taskHub = "craft.tests.taskhub.\(UUID().uuidString)"
    let new = "craft.tests.current.\(UUID().uuidString)"
    let newer = try #require(UserDefaults(suiteName: craft)), older = try #require(UserDefaults(suiteName: taskHub))
    let defaults = try #require(UserDefaults(suiteName: new))
    defer { [craft, taskHub, new].forEach(UserDefaults().removePersistentDomain(forName:)) }
    newer.set("dark", forKey: "appearance")
    older.set("light", forKey: "appearance")
    older.set(0.4, forKey: "workspace.contextPaneFraction")

    LegacyIdentity.carryDefaults(into: defaults, from: [craft, taskHub], oldCopyRunning: false)
    #expect(defaults.string(forKey: "appearance") == "dark")
    #expect(defaults.double(forKey: "workspace.contextPaneFraction") == 0.4)
}

@Test func findingNoOldPreferencesIsNotRecordedAsDone() throws {
    let old = "craft.tests.legacy.\(UUID().uuidString)", new = "craft.tests.current.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: new))
    defer { UserDefaults().removePersistentDomain(forName: old); defaults.removePersistentDomain(forName: new) }
    LegacyIdentity.carryDefaults(into: defaults, from: [old], oldCopyRunning: false)

    let source = try #require(UserDefaults(suiteName: old))
    source.set("dark", forKey: "appearance")
    LegacyIdentity.carryDefaults(into: defaults, from: [old], oldCopyRunning: false)
    #expect(defaults.string(forKey: "appearance") == "dark")
}
