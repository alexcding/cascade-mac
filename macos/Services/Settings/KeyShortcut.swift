import AppKit
import SwiftUI

/// A key combination, as the menu bar, the Shortcuts settings and the model presets all store it.
struct KeyShortcut: Codable, Equatable, Hashable, Sendable {
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    var modifiers: EventModifiers {
        var value: EventModifiers = []
        if command { value.insert(.command) }
        if option { value.insert(.option) }
        if control { value.insert(.control) }
        if shift { value.insert(.shift) }
        return value
    }
    var keyboardShortcut: KeyboardShortcut? {
        key.count == 1 ? key.first.map { KeyboardShortcut(KeyEquivalent($0), modifiers: modifiers) } : nil
    }
    /// As the menu bar writes them: ⌃⌥⇧⌘ then the key.
    var title: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }
}

/// The model presets stored their shortcuts under this name first; the coding is unchanged.
typealias AgentShortcut = KeyShortcut

// An extension, so the memberwise initialiser stays.
extension KeyShortcut {
    /// Nil for a press that cannot be a shortcut: no key, or none of ⌘ ⌃ ⌥ held, which would
    /// take an ordinary letter away from the terminal.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The key as it is printed on the cap: ⇧⌘[ is "[" with shift, not "{".
        let bare = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        guard !flags.isDisjoint(with: [.command, .control, .option]),
              let pressed = bare?.lowercased(), pressed.count == 1,
              pressed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        key = pressed
        command = flags.contains(.command); option = flags.contains(.option)
        control = flags.contains(.control); shift = flags.contains(.shift)
    }

    private static let system: [KeyShortcut: String] = [
        .init(key: "q", command: true): "Quit", .init(key: "h", command: true): "Hide",
        .init(key: "h", command: true, option: true): "Hide Others", .init(key: "m", command: true): "Minimize",
        .init(key: "`", command: true): "window cycling", .init(key: ",", command: true): "Settings",
        .init(key: "c", command: true): "Copy", .init(key: "v", command: true): "Paste",
        .init(key: "x", command: true): "Cut", .init(key: "a", command: true): "Select All",
        .init(key: "z", command: true): "Undo", .init(key: "z", command: true, shift: true): "Redo",
        .init(key: "s", command: true, control: true): "Toggle Sidebar",
        .init(key: "f", command: true, control: true): "Full Screen",
    ]

    /// Combinations macOS or the standard menus own, and anything without ⌘: ⌃, ⌥ and Tab
    /// combinations are what a CLI in the terminal is steered with, and ⌘ never reaches it.
    var reservedReason: String? {
        guard command else { return "\(title) has no ⌘, so it could take a key from the CLI in the terminal." }
        return Self.system[self].map { "\(title) belongs to \($0)." }
    }
}
