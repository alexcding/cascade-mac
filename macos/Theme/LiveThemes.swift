import SwiftUI

/// The looks the Live tab can be drawn in, picked from its own bar and kept as a preference. Each
/// is a palette swap over the one layout (`LivePanelView`): a ground, lines and text, a band behind
/// the row that is working, and one colour per section — the agent, its tools, its subagents and
/// its log. Native, the default, follows the system's appearance and stands on the pane's own
/// background, in a drawn diagram's pastels: each box filled with its section's colour, dark
/// connectors, a red dot running along them. The others keep their own ground, as a terminal's or
/// a drawing's does.
enum LiveTheme: String, CaseIterable, Identifiable {
    case native, terminal, swiss, blueprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: String(localized: "Terminal")
        case .native: String(localized: "Default")
        case .swiss: String(localized: "Swiss")
        case .blueprint: String(localized: "Blueprint")
        }
    }

    var palette: LivePalette {
        switch self {
        case .terminal:
            .init(ground: .fixed(0x1B2130), surface: .fixed(0x1B2130), line: .fixed(0x56627A), text: .fixed(0xE4E8F0),
                  muted: .fixed(0x8892A6), band: .fixed(0x283146), agent: .fixed(0x7CD3E3), tools: .fixed(0x86D7A2),
                  subagents: .fixed(0x8EADF5), log: .fixed(0xB6A1EE), danger: .fixed(0xF28B82), radius: 0, monospaced: true)
        case .native:
            // The band is a white card on its box's wash, as the drawing's inner cards are.
            .init(ground: nil, surface: .init(light: 0xFFFFFF, dark: 0x2A2A2D),
                  line: .init(light: 0xD2D2D7, dark: 0x3A3A3E), text: .init(light: 0x1D1D1F, dark: 0xF5F5F7),
                  muted: .init(light: 0x6E6E73, dark: 0x98989D), band: .init(light: 0xFFFFFF, dark: 0xFFFFFF, darkAlpha: 0.1),
                  agent: .init(light: 0x2F62CC, dark: 0x7BA7F7), tools: .init(light: 0x2F7D1E, dark: 0x7FCB6A),
                  subagents: .init(light: 0x8A3FC2, dark: 0xC79BF2), log: .init(light: 0xB8590A, dark: 0xF2A45C),
                  danger: .init(light: 0xCF3A32, dark: 0xF47C74), radius: 12, monospaced: false,
                  wash: 0.14, edge: 0.65, arrow: .init(light: 0x2D3138, dark: 0xC2C6CF), flow: .init(light: 0xF04D5A, dark: 0xFF6B76))
        case .swiss:
            .init(ground: .fixed(0xFFFFFF), surface: .fixed(0xFFFFFF), line: .fixed(0x111111), text: .fixed(0x111111),
                  muted: .fixed(0x555555), band: .fixed(0xF0F0F0), agent: .fixed(0xD0021B), tools: .fixed(0x111111),
                  subagents: .fixed(0x111111), log: .fixed(0xD0021B), danger: .fixed(0xD0021B), radius: 0, monospaced: false)
        case .blueprint:
            .init(ground: .fixed(0x0D3A8A), surface: .fixed(0x0D3A8A), line: .fixed(0xC8D8F5), text: .fixed(0xFFFFFF),
                  muted: .fixed(0xB9CBEE), band: .fixed(0x1D4FA6), agent: .fixed(0xFFD166), tools: .fixed(0x9EF0CF),
                  subagents: .fixed(0xFFFFFF), log: .fixed(0xFFB4A8), danger: .fixed(0xFFB4A8), radius: 0, monospaced: true)
        }
    }
}

/// One Live look's colours and shapes: boxes are outlines on its surface, unless it fills them.
struct LivePalette {
    /// What the panel stands on: none where it is the pane's own background.
    let ground: ThemeColor?
    let surface, line, text, muted, band: ThemeColor
    let agent, tools, subagents, log, danger: ThemeColor
    let radius: CGFloat
    let monospaced: Bool
    /// How much of its section's colour fills a box, and how much of it draws the box's edge: none
    /// and all of it where boxes are outlines.
    var wash = 0.0, edge = 1.0
    /// A connector's line and arrowhead, and the dot that runs along it. A look that names neither
    /// draws the line in `line`, and the head and the dot in its agent's colour.
    var arrow, flow: ThemeColor?

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
    }
}

extension ThemeColor {
    /// The same in light and dark: a look that keeps its own ground.
    static func fixed(_ value: UInt32) -> ThemeColor { ThemeColor(light: value, dark: value) }
}
