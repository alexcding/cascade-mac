import AppKit
import Observation

/// Every command's key combination: the default, or what Settings → Shortcuts put in its place.
/// The menu bar, the key monitors and the preset recorder all read this one table, so a
/// combination belongs to one thing at a time.
@MainActor @Observable
final class ShortcutRegistry {
    static let shared = ShortcutRegistry()

    /// A cleared command is stored with an empty key, so it does not fall back to its default.
    private var overrides: [String: KeyShortcut]
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "shortcuts.overrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: KeyShortcut].self, from: $0) } ?? [:]
    }

    func shortcut(for command: ShellCommand) -> KeyShortcut? {
        guard let stored = overrides[command.rawValue] else { return command.defaultShortcut }
        return stored.key.isEmpty ? nil : stored
    }
    func isCustom(_ command: ShellCommand) -> Bool { overrides[command.rawValue] != nil }
    var hasCustom: Bool { !overrides.isEmpty }

    func command(for shortcut: KeyShortcut) -> ShellCommand? {
        ShellCommand.allCases.first { self.shortcut(for: $0) == shortcut }
    }
    func command(for event: NSEvent) -> ShellCommand? { KeyShortcut(event: event).flatMap(command(for:)) }

    /// Why `shortcut` cannot go to `command`, or nil when it can. `command` is nil for something
    /// outside the table, such as a model preset.
    func conflict(_ shortcut: KeyShortcut, for command: ShellCommand? = nil) -> String? {
        if let reason = shortcut.reservedReason { return reason }
        if let owner = self.command(for: shortcut), owner != command { return String(localized: "\(shortcut.title) is already assigned to \(owner.title).") }
        return nil
    }

    /// Nil clears the command. Returns the conflict instead of assigning when there is one.
    @discardableResult func assign(_ shortcut: KeyShortcut?, to command: ShellCommand) -> String? {
        if let shortcut, let conflict = conflict(shortcut, for: command) { return conflict }
        if shortcut == command.defaultShortcut { overrides[command.rawValue] = nil }
        else { overrides[command.rawValue] = shortcut ?? KeyShortcut(key: "") }
        save()
        return nil
    }
    /// Back to the default, unless another command has taken it since: then the conflict is
    /// returned and the command keeps what it has.
    @discardableResult func reset(_ command: ShellCommand) -> String? {
        if let shortcut = command.defaultShortcut, let conflict = conflict(shortcut, for: command) { return conflict }
        overrides[command.rawValue] = nil
        save()
        return nil
    }
    func resetAll() { overrides = [:]; save() }

    private func save() {
        if overrides.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// How Settings → Shortcuts groups the commands: the menus that hold them, in menu-bar order,
/// then tabs and the browser, whose commands are spread across several menus.
enum ShortcutGroup: String, CaseIterable, Identifiable {
    case file = "File", view = "View", product = "Product", go = "Go", tabs = "Tabs", browser = "Browser"
    var id: String { rawValue }
    var commands: [ShellCommand] { ShellCommand.allCases.filter { $0.group == self } }
}

extension ShellCommand {
    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .terminal: String(localized: "Terminal")
        case .activity: String(localized: "Activity")
        case .settings: String(localized: "Settings…")
        case .sidebar: String(localized: "Focus Sidebar")
        case .refresh: String(localized: "Refresh")
        case .tray: String(localized: "Reviews & Usage")
        case .biggerFont: String(localized: "Zoom In")
        case .smallerFont: String(localized: "Zoom Out")
        case .resetFont: String(localized: "Actual Size")
        case .checkForUpdates: String(localized: "Check for Updates…")
        case .newProject: String(localized: "New Project…")
        case .newSession: String(localized: "New Session…")
        case .newTab: String(localized: "New Tab")
        case .newSidebarTab: String(localized: "New Sidebar Tab")
        case .openFile: String(localized: "Open File…")
        case .saveFile: String(localized: "Save File")
        case .closePage: String(localized: "Close Tab / Window")
        case .findPage: String(localized: "Find in Page…")
        case .back: String(localized: "Back")
        case .forward: String(localized: "Forward")
        case .nextPage: String(localized: "Next Tab")
        case .previousPage: String(localized: "Previous Tab")
        case .zoomIn: String(localized: "Zoom Page In")
        case .zoomOut: String(localized: "Zoom Page Out")
        case .resetZoom: String(localized: "Reset Page Zoom")
        case .reloadPage: String(localized: "Reload Page")
        case .nextModel: String(localized: "Next Model")
        case .previousModel: String(localized: "Previous Model")
        case .toggleChat: String(localized: "Switch Terminal / Chat")
        case .runProject: String(localized: "Run")
        case .stopBuild: String(localized: "Stop")
        case .nextSession: String(localized: "Next Session")
        case .previousSession: String(localized: "Previous Session")
        case .session1, .session2, .session3, .session4, .session5, .session6, .session7, .session8, .session9, .session10:
            String(localized: "Show Session \((sessionIndex ?? 0) + 1)")
        }
    }

    /// Nil for a command that takes no key of its own: ⌘, is SwiftUI's, and checking for updates
    /// is too rare to spend one on.
    var group: ShortcutGroup? {
        switch self {
        case .settings, .checkForUpdates: nil
        case .newProject, .newSession, .openFile, .saveFile, .closePage: .file
        case .newTab, .newSidebarTab, .nextPage, .previousPage: .tabs
        case .back, .forward, .reloadPage, .findPage, .zoomIn, .zoomOut, .resetZoom: .browser
        case .overview, .terminal, .sidebar, .activity: .go
        case .nextSession, .previousSession: .go
        case .session1, .session2, .session3, .session4, .session5, .session6, .session7, .session8, .session9, .session10: .go
        case .runProject, .stopBuild, .nextModel, .previousModel, .toggleChat: .product
        case .refresh, .tray, .biggerFont, .smallerFont, .resetFont: .view
        }
    }

    /// One scheme, no two alike: ⌘R/⌘. build as in Xcode, ⌘1–9 and ⌘0 the first ten sessions and
    /// ⌘[ ] the ones either side, ⌘+/− zoom whatever is in focus. Actual Size, Back, Forward, the
    /// panel's tab cycling and page-only zoom gave their keys to sessions, or never had one.
    var defaultShortcut: KeyShortcut? {
        if let index = sessionIndex { return KeyShortcut(key: String((index + 1) % 10), command: true) }
        return switch self {
        case .overview: KeyShortcut(key: "h", command: true, shift: true)
        case .terminal: KeyShortcut(key: "t", command: true, control: true)
        case .sidebar: KeyShortcut(key: "s", command: true, option: true)
        case .refresh: KeyShortcut(key: "r", command: true, shift: true)
        case .tray: KeyShortcut(key: "u", command: true, shift: true)
        case .biggerFont: KeyShortcut(key: "=", command: true)
        case .smallerFont: KeyShortcut(key: "-", command: true)
        case .newSession: KeyShortcut(key: "n", command: true)
        case .newProject: KeyShortcut(key: "p", command: true)
        case .newTab: KeyShortcut(key: "t", command: true)
        case .newSidebarTab: KeyShortcut(key: "t", command: true, option: true)
        case .openFile: KeyShortcut(key: "o", command: true)
        case .saveFile: KeyShortcut(key: "s", command: true)
        case .closePage: KeyShortcut(key: "w", command: true)
        case .findPage: KeyShortcut(key: "f", command: true)
        case .nextSession: KeyShortcut(key: "]", command: true)
        case .previousSession: KeyShortcut(key: "[", command: true)
        case .reloadPage: KeyShortcut(key: "r", command: true, option: true)
        case .runProject: KeyShortcut(key: "r", command: true)
        // Two keys, left hand: switching models is done mid-thought, without looking. It wraps,
        // so Previous Model needs no key of its own until someone gives it one.
        case .nextModel: KeyShortcut(key: "d", command: true)
        case .stopBuild: KeyShortcut(key: ".", command: true)
        // VS Code's panel key: the terminal and the chat over it are one agent, shown two ways.
        case .toggleChat: KeyShortcut(key: "j", command: true)
        default: nil
        }
    }

    /// The terminal surface binds these itself and would consume them before the menu, so the
    /// app claims them ahead of the responder chain.
    var claimedAheadOfResponders: Bool { sessionIndex != nil || [.nextSession, .previousSession, .newTab, .newSidebarTab, .nextPage, .previousPage, .nextModel, .previousModel, .toggleChat].contains(self) }
}
