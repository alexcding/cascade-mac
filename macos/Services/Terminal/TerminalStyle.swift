import Foundation
import GhosttyTerminal
import GhosttyTheme

/// Everything a terminal surface is configured from, resolved in one place.
///
/// The surface is configured from these settings alone: no Ghostty config file is read, and
/// nothing is inherited from an installed Ghostty app. What the tab shows is what runs.
struct TerminalStyle: Equatable, Sendable {
    var font = CodeFont(size: 13)
    /// Re-applies CoreText font smoothing when glyphs are rasterised. Defaults on: without it
    /// libghostty renders noticeably thinner than the standalone Ghostty app, which is the
    /// state this setting exists to correct.
    var thicken = true
    var thickenStrength = defaultThickenStrength
    /// Theme names from the compiled catalogue. Empty means the package default pair.
    var darkTheme = ""
    var lightTheme = ""
    /// Ghostty `keybind` values, one per entry, as they would be written in a config file
    /// (`shift+enter=text:\x1b\r`). Ghostty parses the `\x` escapes in `text:` itself.
    var keybinds = defaultKeybinds

    struct Resolved {
        var configuration = TerminalConfiguration()
        var theme = TerminalTheme.default
        /// Everything that did not apply, in the order it was found. Surfaced in Settings and
        /// above the pane; never fatal, because a bad theme name must not cost you a shell.
        var issues: [String] = []
    }

    func resolve() -> Resolved {
        var resolved = Resolved()
        var configuration = TerminalConfiguration().fontSize(Float(font.size))
        if !font.family.isEmpty { configuration = configuration.fontFamily(font.family) }
        configuration = configuration.fontThicken(thicken)
        if thicken { configuration = configuration.fontThickenStrength(thickenStrength) }
        for binding in keybinds {
            guard Self.keybindProblem(binding) == nil else {
                resolved.issues.append("Ignored keybind \"\(binding)\": expected trigger=action.")
                continue
            }
            configuration = configuration.custom("keybind", binding)
        }
        resolved.configuration = configuration

        var theme = TerminalTheme.default
        for (name, isDark) in [(darkTheme, true), (lightTheme, false)] where !name.isEmpty {
            guard let match = GhosttyThemeCatalog.theme(named: name) else {
                resolved.issues.append("No terminal theme named \(name).")
                continue
            }
            if isDark { theme.dark = match.toTerminalConfiguration() } else { theme.light = match.toTerminalConfiguration() }
        }
        resolved.theme = theme
        return resolved
    }

    /// Theme names offered by the pickers, alphabetical. Computed once: the catalogue runs to
    /// several hundred entries and this is read inside a Picker's ForEach.
    static let themeNames: [String] = GhosttyThemeCatalog.allThemes.map(\.name).sorted()

    /// Whether the catalogue has this theme. A direct lookup, not a scan of `themeNames`.
    static func hasTheme(_ name: String) -> Bool { GhosttyThemeCatalog.theme(named: name) != nil }

    /// The keybinds a fresh install starts with. Shift+Enter sends ESC CR (a newline in
    /// Claude Code and other agent CLIs, not a submit); Shift+Backspace sends ^U to clear the line.
    static let defaultKeybinds: [String] = [
        #"shift+enter=text:\x1b\r"#,
        #"shift+backspace=text:\x15"#,
    ]

    /// Keybinds are stored as one setting, newline-separated. `nil` (never saved) means the
    /// defaults; an empty string means the user removed every binding.
    static func keybinds(fromSetting value: String?) -> [String] {
        guard let value else { return defaultKeybinds }
        return value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func keybindsSetting(_ keybinds: [String]) -> String { keybinds.joined(separator: "\n") }

    /// Why a keybind cannot be handed to Ghostty, or nil when it is well-formed. Ghostty rejects
    /// a malformed line and a rejected line fails the whole config, so a typo must never reach it.
    static func keybindProblem(_ binding: String) -> String? {
        let trimmed = binding.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "=") else { return "Missing “=” between the key and its action." }
        let trigger = trimmed[..<eq], action = trimmed[trimmed.index(after: eq)...]
        if trigger.isEmpty { return "Missing the key to press." }
        if trigger.contains(where: \.isWhitespace) { return "The key must not contain spaces." }
        let parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map { $0.lowercased() }
        if parts.contains("") { return "Empty part in the key combination." }
        for modifier in parts.dropLast() where !keybindModifiers.contains(modifier) {
            return "Unknown modifier “\(modifier)”; use shift, ctrl, alt, super or cmd."
        }
        if action.isEmpty { return "Missing the action to run." }
        return nil
    }
    /// Modifier names Ghostty accepts in a trigger, with the aliases it documents.
    private static let keybindModifiers: Set<String> = [
        "shift", "ctrl", "control", "alt", "opt", "option", "super", "cmd", "command",
        "global", "all", "unconsumed", "performable",
    ]

    /// The same style with no keybinds. The surface falls back to this when Ghostty rejects a
    /// binding, because a rejected line discards the whole config, font and theme included.
    var withoutKeybinds: TerminalStyle { var copy = self; copy.keybinds = []; return copy }

    static let thickenStrengthRange: ClosedRange<Int> = 0...255
    static let defaultThickenStrength = 10

    /// Ghostty rejects a strength outside 0...255, and a rejected line fails the whole config.
    static func clampThickenStrength(_ value: Int) -> Int {
        min(thickenStrengthRange.upperBound, max(thickenStrengthRange.lowerBound, value))
    }
    static func clampThickenStrength(_ value: String?) -> Int {
        guard let value, let parsed = Int(value) else { return defaultThickenStrength }
        return clampThickenStrength(parsed)
    }
}
