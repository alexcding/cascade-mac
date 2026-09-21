import AppKit
import SwiftUI

// The native counterpart of `src/renderer/css/tokens.css`. Same palette, same names, so the two
// apps stay one design. Dark mode is a pure value swap — never write a per-widget colour.
//
// A second theme is a new `ThemePalette` assigned to `Theme.palette`; call sites never change.
//
// This carries only the tokens something currently renders. `tokens.css` also defines the nav
// text, the attention dot, the per-CLI tints, the menu surface and the syntax colours; those come
// across with the first native screen that draws them, rather than shipping unused.

/// A colour with a light and a dark value, resolved at draw time from the active `NSAppearance`.
/// One instance mirrors one custom property pair in `tokens.css` (`:root` vs `[data-theme=dark]`).
struct ThemeColor: Sendable {
    let light: UInt32
    let dark: UInt32
    var lightAlpha: Double = 1
    var darkAlpha: Double = 1

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        let (light, dark, lightAlpha, darkAlpha) = (self.light, self.dark, self.lightAlpha, self.darkAlpha)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(themeRGB: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

extension NSColor {
    fileprivate convenience init(themeRGB rgb: UInt32, alpha: Double) {
        self.init(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Every colour token one theme defines. Field names match the CSS custom properties they carry.
struct ThemePalette: Sendable {
    let surfaceHover: ThemeColor
    let border: ThemeColor
    let textSecondary, textTertiary: ThemeColor
    let accent, accentBackground: ThemeColor
    let success, successBackground: ThemeColor
    let warn, warnBackground: ThemeColor
    let danger, dangerBackground: ThemeColor
    let merged, mergedBackground: ThemeColor
    let syntaxKeyword, syntaxString, syntaxComment, syntaxNumber, syntaxFunction: ThemeColor
}

extension ThemePalette {
    /// The values in `src/renderer/css/tokens.css`.
    static let craft = ThemePalette(
        surfaceHover: .init(light: 0xF1F3F5, dark: 0x2A2A2A),
        border: .init(light: 0xE7E9EE, dark: 0x323232),
        textSecondary: .init(light: 0x565D68, dark: 0xA2A2A2),
        textTertiary: .init(light: 0x9298A3, dark: 0x6E6E6E),
        accent: .init(light: 0x2563EB, dark: 0x4B86F0),
        accentBackground: .init(light: 0xEFF4FF, dark: 0x1C2740),
        success: .init(light: 0x16A34A, dark: 0x4ADE80),
        successBackground: .init(light: 0xF0FDF4, dark: 0x14251A),
        warn: .init(light: 0xD97706, dark: 0xFBBF24),
        warnBackground: .init(light: 0xFFFBEB, dark: 0x2A2310),
        danger: .init(light: 0xDC2626, dark: 0xF87171),
        dangerBackground: .init(light: 0xFEF2F2, dark: 0x2A1A1A),
        merged: .init(light: 0x7C3AED, dark: 0xA78BFA),
        mergedBackground: .init(light: 0xF5F3FF, dark: 0x241D33),
        syntaxKeyword: .init(light: 0xCF222E, dark: 0xFF7B72),
        syntaxString: .init(light: 0x0A3069, dark: 0xA5D6FF),
        syntaxComment: .init(light: 0x6E7781, dark: 0x8B949E),
        syntaxNumber: .init(light: 0x0550AE, dark: 0x79C0FF),
        syntaxFunction: .init(light: 0x8250DF, dark: 0xD2A8FF)
    )
}

enum Theme {
    /// The active theme. Assign a different `ThemePalette` here to reskin the app.
    static let palette = ThemePalette.craft

    // Computed, not stored, so the dynamic NSColor underneath re-resolves on an appearance change.
    static var surfaceHover: Color { palette.surfaceHover.color }
    static var border: Color { palette.border.color }
    static var textSecondary: Color { palette.textSecondary.color }
    static var textTertiary: Color { palette.textTertiary.color }
    static var accent: Color { palette.accent.color }
    static var accentBackground: Color { palette.accentBackground.color }
    static var success: Color { palette.success.color }
    static var successBackground: Color { palette.successBackground.color }
    static var warn: Color { palette.warn.color }
    static var warnBackground: Color { palette.warnBackground.color }
    static var danger: Color { palette.danger.color }
    static var dangerBackground: Color { palette.dangerBackground.color }
    static var merged: Color { palette.merged.color }
    static var mergedBackground: Color { palette.mergedBackground.color }
    /// An agent CLI's own brand colour, for what is that agent's and not the app's: its usage on
    /// the Dashboard, its used context in a session. Not a palette colour, so it does not swap
    /// with the theme; both read on light and dark.
    static func agentTint(_ cli: String?) -> Color {
        cli == "codex" ? Color(red: 0.44, green: 0.48, blue: 0.94) : Color(red: 0.85, green: 0.47, blue: 0.34)
    }

    enum Typography {
        /// 11.5 — `.hook-pill`.
        static let pill = Font.system(size: 11.5)
        /// 13 semibold — `.pane-empty-t`.
        static let emptyTitle = Font.system(size: 13, weight: .semibold)
        /// 12 — `.pane-empty-s`.
        static let emptyHint = Font.system(size: 12)
    }

    /// `--bg`: the surface a content pane sits on. Follows the window appearance.
    static var paneBackground: Color { Color(nsColor: .windowBackgroundColor) }

    /// Symbols a surface shares with another, so the two cannot drift apart. A glyph only one
    /// surface draws stays at its call site.
    enum Symbol {
        /// The mark that closes a tab, wherever tabs are listed: the sidebar's Tabs rows and the
        /// browser and files tab bars. Each sizes it for its own slot.
        static let close = "xmark.circle.fill"
    }

    enum Size {
        /// 1 — a hairline rule.
        static let hairline: CGFloat = 1
        /// 32 — a large round toolbar button, and the fields that sit beside one.
        static let largeControl: CGFloat = 32
        /// 760 — the Settings column cap, matching the web page.
        static let readableColumn: CGFloat = 760
    }
}
