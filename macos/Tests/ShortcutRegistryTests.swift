import Foundation
import Testing
@testable import Craft

@MainActor private func registry() -> ShortcutRegistry {
    let suite = "shortcut-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return ShortcutRegistry(defaults: defaults)
}

@MainActor @Test func defaultShortcutsNeverCollideOrShadowTheSystem() {
    var seen: [KeyShortcut: ShellCommand] = [:]
    for command in ShellCommand.allCases {
        guard let shortcut = command.defaultShortcut else { continue }
        #expect(seen[shortcut] == nil, "\(shortcut.title) is both \(seen[shortcut]?.title ?? "") and \(command.title)")
        #expect(shortcut.reservedReason == nil)
        #expect(shortcut.command, "\(command.title) could take \(shortcut.title) from the CLI in the terminal")
        seen[shortcut] = command
    }
    #expect(ShellCommand.allCases.filter { $0.group == nil } == [.settings, .checkForUpdates])
}

@MainActor @Test func assigningATakenShortcutIsRefused() {
    let registry = registry()
    let run = KeyShortcut(key: "r", command: true)
    #expect(registry.assign(run, to: .refresh) != nil)
    #expect(registry.shortcut(for: .refresh) == ShellCommand.refresh.defaultShortcut)
    #expect(registry.conflict(run) != nil)
    #expect(registry.assign(KeyShortcut(key: "q", command: true), to: .refresh) != nil)
    #expect(registry.assign(run, to: .runProject) == nil)
    // No ⌘: the terminal's CLI may read it.
    #expect(registry.assign(KeyShortcut(key: "p", option: true), to: .refresh) != nil)
    #expect(registry.conflict(KeyShortcut(key: "`", control: true)) != nil)
}

@MainActor @Test func overridesClearResetAndPersist() {
    let suite = "shortcut-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let registry = ShortcutRegistry(defaults: defaults)
    let custom = KeyShortcut(key: "b", command: true)
    #expect(registry.assign(custom, to: .runProject) == nil)
    registry.assign(nil, to: .stopBuild)
    let reloaded = ShortcutRegistry(defaults: defaults)
    #expect(reloaded.shortcut(for: .runProject) == custom)
    #expect(reloaded.shortcut(for: .stopBuild) == nil)
    #expect(reloaded.command(for: custom) == .runProject)
    // ⌘R is free once Run moved off it.
    #expect(reloaded.assign(KeyShortcut(key: "r", command: true), to: .reloadPage) == nil)
    reloaded.resetAll()
    #expect(!reloaded.hasCustom)
    #expect(reloaded.shortcut(for: .stopBuild) == ShellCommand.stopBuild.defaultShortcut)
}

@MainActor @Test func restoringADefaultAnotherCommandTookIsRefused() {
    let registry = registry()
    let run = ShellCommand.runProject.defaultShortcut!
    #expect(registry.assign(KeyShortcut(key: "b", command: true), to: .runProject) == nil)
    #expect(registry.assign(run, to: .reloadPage) == nil)
    #expect(registry.reset(.runProject) != nil)
    #expect(registry.shortcut(for: .runProject) == KeyShortcut(key: "b", command: true))
    #expect(registry.command(for: run) == .reloadPage)
    #expect(registry.reset(.reloadPage) == nil)
    #expect(registry.reset(.runProject) == nil)
    #expect(registry.command(for: run) == .runProject)
}

@MainActor @Test func everyBindableCommandIsInTheMenuBar() throws {
    // A row in Settings → Shortcuts that no menu item carries would record a key nothing fires.
    let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("App/CraftCommands.swift"), encoding: .utf8)
    for command in ShellCommand.allCases where command.group != nil && command.sessionIndex == nil {
        #expect(source.contains("command(.\(command.rawValue))"), "\(command.title) has no menu item")
    }
}
