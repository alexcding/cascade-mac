import AppKit

/// Everything a file editor is styled from besides its font, assembled from the stored preferences.
/// One theme per appearance, so the editor follows the app between light and dark.
struct EditorStyle: Equatable, Sendable {
    /// Empty means the default theme.
    var darkTheme = ""
    var lightTheme = ""
    var showMinimap = true

    func theme(dark: Bool) -> CodeTheme { CodeTheme.named(dark ? darkTheme : lightTheme, dark: dark) }
}

/// The colours of one code theme for one appearance. `background` is nil where the theme takes the
/// window's own text background, as the default does.
struct CodeTheme: Equatable, Sendable, Identifiable {
    let name: String
    let dark: Bool
    let background: UInt32?
    let text: UInt32
    let selection: UInt32
    let keyword, string, comment, number, function, type: UInt32
    var id: String { name }

    /// The app's own syntax tokens: the default for both appearances.
    static func standard(dark: Bool) -> CodeTheme {
        let palette = Theme.palette
        func value(_ color: ThemeColor) -> UInt32 { dark ? color.dark : color.light }
        return CodeTheme(name: "", dark: dark, background: nil, text: dark ? 0xE6E6E6 : 0x16181D,
                         selection: dark ? 0x3A4A66 : 0xC9DCFF,
                         keyword: value(palette.syntaxKeyword), string: value(palette.syntaxString),
                         comment: value(palette.syntaxComment), number: value(palette.syntaxNumber),
                         function: value(palette.syntaxFunction), type: value(palette.syntaxFunction))
    }

    /// Alphabetical within each appearance; the pickers list them in this order.
    static let catalog: [CodeTheme] = [
        CodeTheme(name: "Ayu Light", dark: false, background: 0xFCFCFC, text: 0x5C6166, selection: 0xD1E4F4,
                  keyword: 0xFA8D3E, string: 0x86B300, comment: 0x787B80, number: 0xA37ACC, function: 0xF2AE49, type: 0x399EE6),
        CodeTheme(name: "Catppuccin Latte", dark: false, background: 0xEFF1F5, text: 0x4C4F69, selection: 0xCCD0DA,
                  keyword: 0x8839EF, string: 0x40A02B, comment: 0x9CA0B0, number: 0xFE640B, function: 0x1E66F5, type: 0xDF8E1D),
        CodeTheme(name: "Gruvbox Light", dark: false, background: 0xFBF1C7, text: 0x3C3836, selection: 0xD5C4A1,
                  keyword: 0x9D0006, string: 0x79740E, comment: 0x928374, number: 0x8F3F71, function: 0x427B58, type: 0xB57614),
        CodeTheme(name: "Light+", dark: false, background: 0xFFFFFF, text: 0x000000, selection: 0xADD6FF,
                  keyword: 0x0000FF, string: 0xA31515, comment: 0x008000, number: 0x098658, function: 0x795E26, type: 0x267F99),
        CodeTheme(name: "Night Owl Light", dark: false, background: 0xFBFBFB, text: 0x403F53, selection: 0xE0E0E0,
                  keyword: 0x994CC3, string: 0xC96765, comment: 0x989FB1, number: 0xAA0982, function: 0x4876D6, type: 0x0C969B),
        CodeTheme(name: "One Light", dark: false, background: 0xFAFAFA, text: 0x383A42, selection: 0xE5E5E6,
                  keyword: 0xA626A4, string: 0x50A14F, comment: 0xA0A1A7, number: 0x986801, function: 0x4078F2, type: 0xC18401),
        CodeTheme(name: "Rosé Pine Dawn", dark: false, background: 0xFAF4ED, text: 0x575279, selection: 0xDFDAD9,
                  keyword: 0x286983, string: 0xEA9D34, comment: 0x9893A5, number: 0x907AA9, function: 0xD7827E, type: 0x56949F),
        CodeTheme(name: "Solarized Light", dark: false, background: 0xFDF6E3, text: 0x657B83, selection: 0xEEE8D5,
                  keyword: 0x859900, string: 0x2AA198, comment: 0x93A1A1, number: 0xD33682, function: 0x268BD2, type: 0xB58900),
        CodeTheme(name: "Tokyo Night Day", dark: false, background: 0xE1E2E7, text: 0x3760BF, selection: 0xB6BFE2,
                  keyword: 0x9854F1, string: 0x587539, comment: 0x848CB5, number: 0xB15C00, function: 0x2E7DE9, type: 0x007197),
        CodeTheme(name: "Tomorrow", dark: false, background: 0xFFFFFF, text: 0x4D4D4C, selection: 0xD6D6D6,
                  keyword: 0x8959A8, string: 0x718C00, comment: 0x8E908C, number: 0xF5871F, function: 0x4271AE, type: 0xC99E00),
        CodeTheme(name: "Xcode Light", dark: false, background: 0xFFFFFF, text: 0x262626, selection: 0xB2D7FF,
                  keyword: 0x9B2393, string: 0xC41A16, comment: 0x5D6C79, number: 0x1C00CF, function: 0x326D74, type: 0x0B4F79),
        CodeTheme(name: "Ayu Dark", dark: true, background: 0x0B0E14, text: 0xBFBDB6, selection: 0x1B3A5B,
                  keyword: 0xFF8F40, string: 0xAAD94C, comment: 0x5C6773, number: 0xD2A6FF, function: 0xFFB454, type: 0x59C2FF),
        CodeTheme(name: "Ayu Mirage", dark: true, background: 0x1F2430, text: 0xCCCAC2, selection: 0x34455A,
                  keyword: 0xFFAD66, string: 0xD5FF80, comment: 0x6C7A8B, number: 0xDFBFFF, function: 0xFFD173, type: 0x73D0FF),
        CodeTheme(name: "Catppuccin Mocha", dark: true, background: 0x1E1E2E, text: 0xCDD6F4, selection: 0x45475A,
                  keyword: 0xCBA6F7, string: 0xA6E3A1, comment: 0x6C7086, number: 0xFAB387, function: 0x89B4FA, type: 0xF9E2AF),
        CodeTheme(name: "Cobalt2", dark: true, background: 0x193549, text: 0xFFFFFF, selection: 0x0050A4,
                  keyword: 0xFF9D00, string: 0xA5FF90, comment: 0x0088FF, number: 0xFF628C, function: 0xFFC600, type: 0x80FFBB),
        CodeTheme(name: "Dark+", dark: true, background: 0x1E1E1E, text: 0xD4D4D4, selection: 0x264F78,
                  keyword: 0x569CD6, string: 0xCE9178, comment: 0x6A9955, number: 0xB5CEA8, function: 0xDCDCAA, type: 0x4EC9B0),
        CodeTheme(name: "Dracula", dark: true, background: 0x282A36, text: 0xF8F8F2, selection: 0x44475A,
                  keyword: 0xFF79C6, string: 0xF1FA8C, comment: 0x6272A4, number: 0xBD93F9, function: 0x50FA7B, type: 0x8BE9FD),
        CodeTheme(name: "GitHub Dark Dimmed", dark: true, background: 0x22272E, text: 0xADBAC7, selection: 0x264466,
                  keyword: 0xF47067, string: 0x96D0FF, comment: 0x768390, number: 0x6CB6FF, function: 0xDCBDFB, type: 0xF69D50),
        CodeTheme(name: "Gruvbox Dark", dark: true, background: 0x282828, text: 0xEBDBB2, selection: 0x504945,
                  keyword: 0xFB4934, string: 0xB8BB26, comment: 0x928374, number: 0xD3869B, function: 0x8EC07C, type: 0xFABD2F),
        CodeTheme(name: "Monokai", dark: true, background: 0x272822, text: 0xF8F8F2, selection: 0x49483E,
                  keyword: 0xF92672, string: 0xE6DB74, comment: 0x75715E, number: 0xAE81FF, function: 0xA6E22E, type: 0x66D9EF),
        CodeTheme(name: "Night Owl", dark: true, background: 0x011627, text: 0xD6DEEB, selection: 0x1D3B53,
                  keyword: 0xC792EA, string: 0xECC48D, comment: 0x637777, number: 0xF78C6C, function: 0x82AAFF, type: 0xFFCB8B),
        CodeTheme(name: "Nord", dark: true, background: 0x2E3440, text: 0xD8DEE9, selection: 0x434C5E,
                  keyword: 0x81A1C1, string: 0xA3BE8C, comment: 0x616E88, number: 0xB48EAD, function: 0x88C0D0, type: 0x8FBCBB),
        CodeTheme(name: "One Dark", dark: true, background: 0x282C34, text: 0xABB2BF, selection: 0x3E4451,
                  keyword: 0xC678DD, string: 0x98C379, comment: 0x5C6370, number: 0xD19A66, function: 0x61AFEF, type: 0xE5C07B),
        CodeTheme(name: "Rosé Pine", dark: true, background: 0x191724, text: 0xE0DEF4, selection: 0x403D52,
                  keyword: 0x31748F, string: 0xF6C177, comment: 0x6E6A86, number: 0xC4A7E7, function: 0xEBBCBA, type: 0x9CCFD8),
        CodeTheme(name: "Solarized Dark", dark: true, background: 0x002B36, text: 0x839496, selection: 0x073642,
                  keyword: 0x859900, string: 0x2AA198, comment: 0x586E75, number: 0xD33682, function: 0x268BD2, type: 0xB58900),
        CodeTheme(name: "Tokyo Night", dark: true, background: 0x1A1B26, text: 0xA9B1D6, selection: 0x283457,
                  keyword: 0xBB9AF7, string: 0x9ECE6A, comment: 0x565F89, number: 0xFF9E64, function: 0x7AA2F7, type: 0x2AC3DE),
        CodeTheme(name: "Tomorrow Night", dark: true, background: 0x1D1F21, text: 0xC5C8C6, selection: 0x373B41,
                  keyword: 0xB294BB, string: 0xB5BD68, comment: 0x969896, number: 0xDE935F, function: 0x81A2BE, type: 0xF0C674),
        CodeTheme(name: "Xcode Dark", dark: true, background: 0x1F1F24, text: 0xDFDFE0, selection: 0x515B70,
                  keyword: 0xFC5FA3, string: 0xFC6A5D, comment: 0x6C7986, number: 0xD0BF69, function: 0x67B7A4, type: 0x5DD8FF),
    ]

    static func names(dark: Bool) -> [String] { catalog.filter { $0.dark == dark }.map(\.name) }
    static func has(_ name: String, dark: Bool) -> Bool { catalog.contains { $0.name == name && $0.dark == dark } }
    /// An unknown or empty name is the default, so a theme removed in a later build degrades quietly.
    static func named(_ name: String, dark: Bool) -> CodeTheme {
        catalog.first { $0.name == name && $0.dark == dark } ?? standard(dark: dark)
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }
}
