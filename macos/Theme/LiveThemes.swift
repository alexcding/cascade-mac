import SwiftUI

/// The looks the Live tab can be drawn in, picked from its own bar and kept as a preference. Each
/// is a palette swap over the one layout (`LivePanelView`): a ground, lines and text, a band behind
/// the row that is working, and one colour per section — the agent, its tools, its subagents and
/// its log. Native follows the system's appearance; the others keep their own ground, as a
/// terminal's or a drawing's does.
enum LiveTheme: String, CaseIterable, Identifiable {
    case terminal, native, graphite, swiss, blueprint, pastel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: String(localized: "Terminal")
        case .native: String(localized: "Native")
        case .graphite: String(localized: "Graphite")
        case .swiss: String(localized: "Swiss")
        case .blueprint: String(localized: "Blueprint")
        case .pastel: String(localized: "Pastel")
        }
    }

    var palette: LivePalette {
        switch self {
        case .terminal:
            .init(ground: .fixed(0x1B2130), surface: .fixed(0x1B2130), line: .fixed(0x56627A), text: .fixed(0xE4E8F0),
                  muted: .fixed(0x8892A6), band: .fixed(0x283146), agent: .fixed(0x7CD3E3), tools: .fixed(0x86D7A2),
                  subagents: .fixed(0x8EADF5), log: .fixed(0xB6A1EE), danger: .fixed(0xF28B82), radius: 0, monospaced: true)
        case .native:
            .init(ground: .init(light: 0xF5F5F7, dark: 0x1E1E20), surface: .init(light: 0xFFFFFF, dark: 0x2A2A2D),
                  line: .init(light: 0xD2D2D7, dark: 0x3A3A3E), text: .init(light: 0x1D1D1F, dark: 0xF5F5F7),
                  muted: .init(light: 0x6E6E73, dark: 0x98989D), band: .init(light: 0xE9F1FC, dark: 0x22344F),
                  agent: .init(light: 0x0A64D8, dark: 0x4B9BFF), tools: .init(light: 0x1A7F37, dark: 0x32D74B),
                  subagents: .init(light: 0x7C3AED, dark: 0xBF9BFF), log: .init(light: 0xB25000, dark: 0xFF9F0A),
                  danger: .init(light: 0xD70015, dark: 0xFF6961), radius: 12, monospaced: false)
        case .graphite:
            .init(ground: .fixed(0x111214), surface: .fixed(0x1A1B1E), line: .fixed(0x2E3036), text: .fixed(0xE8E8EA),
                  muted: .fixed(0x8B8D94), band: .fixed(0x22252B), agent: .fixed(0x7AA2FF), tools: .fixed(0x4ADE80),
                  subagents: .fixed(0xC4B5FD), log: .fixed(0xF0A36B), danger: .fixed(0xF87171), radius: 10, monospaced: false)
        case .swiss:
            .init(ground: .fixed(0xFFFFFF), surface: .fixed(0xFFFFFF), line: .fixed(0x111111), text: .fixed(0x111111),
                  muted: .fixed(0x555555), band: .fixed(0xF0F0F0), agent: .fixed(0xD0021B), tools: .fixed(0x111111),
                  subagents: .fixed(0x111111), log: .fixed(0xD0021B), danger: .fixed(0xD0021B), radius: 0, monospaced: false)
        case .blueprint:
            .init(ground: .fixed(0x0D3A8A), surface: .fixed(0x0D3A8A), line: .fixed(0xC8D8F5), text: .fixed(0xFFFFFF),
                  muted: .fixed(0xB9CBEE), band: .fixed(0x1D4FA6), agent: .fixed(0xFFD166), tools: .fixed(0x9EF0CF),
                  subagents: .fixed(0xFFFFFF), log: .fixed(0xFFB4A8), danger: .fixed(0xFFB4A8), radius: 0, monospaced: true)
        case .pastel:
            .init(ground: .fixed(0xFBFAF7), surface: .fixed(0xFFFFFF), line: .fixed(0xD9D2C7), text: .fixed(0x2B2D42),
                  muted: .fixed(0x6D6F85), band: .fixed(0xFFE9DD), agent: .fixed(0xC2551F), tools: .fixed(0x2F855A),
                  subagents: .fixed(0x6B4FC4), log: .fixed(0x2F6FB0), danger: .fixed(0xB4233C), radius: 14, monospaced: false,
                  tintsBoxes: true)
        }
    }
}

/// One Live look's colours and shapes. `tintsBoxes` washes each box in its section's colour, as a
/// pastel infographic does; the others draw boxes as outlines on the surface.
struct LivePalette {
    let ground, surface, line, text, muted, band: ThemeColor
    let agent, tools, subagents, log, danger: ThemeColor
    let radius: CGFloat
    let monospaced: Bool
    var tintsBoxes = false

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }
}

extension ThemeColor {
    /// The same in light and dark: a look that keeps its own ground.
    static func fixed(_ value: UInt32) -> ThemeColor { ThemeColor(light: value, dark: value) }
}
