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
    /// The chosen segment of a segmented switch over a `border` track: white, and in dark an
    /// elevated control's grey.
    let segmentSelected: ThemeColor
    let textSecondary, textTertiary: ThemeColor
    let accent, accentBackground: ThemeColor
    let success, successBackground: ThemeColor
    let warn, warnBackground: ThemeColor
    let danger, dangerBackground: ThemeColor
    let merged, mergedBackground: ThemeColor
    let syntaxKeyword, syntaxString, syntaxComment, syntaxNumber, syntaxFunction: ThemeColor
    /// The chat page's picker panel (Synara's, on its default theme), for the app's own pickers
    /// to read as the same: its fill, text, muted text, hairline, the fill under the pointer and
    /// under the pick, its accent, its star, and its shadow.
    let chatPanel, chatPanelText, chatPanelMuted, chatPanelBorder, chatPanelHover, chatPanelSelected: ThemeColor
    let chatPanelAccent, chatPanelStar, chatPanelShadow: ThemeColor
}

extension ThemePalette {
    /// The values in `src/renderer/css/tokens.css`.
    static let cascade = ThemePalette(
        surfaceHover: .init(light: 0xF1F3F5, dark: 0x2A2A2A),
        border: .init(light: 0xE7E9EE, dark: 0x323232),
        segmentSelected: .init(light: 0xFFFFFF, dark: 0x5A5A5E),
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
        syntaxFunction: .init(light: 0x8250DF, dark: 0xD2A8FF),
        // As the built chat page resolves them (`--popover`, `--color-text-foreground`,
        // `--muted-foreground`, `--border`, `--color-background-button-secondary-hover`,
        // `--color-background-elevated-secondary`, `--color-text-accent`, Tailwind's amber-400,
        // and the picker's own shadow) in light and dark.
        chatPanel: .init(light: 0xFFFFFF, dark: 0x171717),
        chatPanelText: .init(light: 0x0D0D0D, dark: 0xFCFCFC),
        chatPanelMuted: .init(light: 0x0D0D0D, dark: 0xFCFCFC, lightAlpha: 0.596, darkAlpha: 0.58),
        chatPanelBorder: .init(light: 0x0D0D0D, dark: 0xFCFCFC, lightAlpha: 0.07, darkAlpha: 0.07),
        chatPanelHover: .init(light: 0x0D0D0D, dark: 0xFCFCFC, lightAlpha: 0.03, darkAlpha: 0.04),
        chatPanelSelected: .init(light: 0x0D0D0D, dark: 0xFCFCFC, lightAlpha: 0.04, darkAlpha: 0.008),
        chatPanelAccent: .init(light: 0x0169CC, dark: 0x3386D6),
        chatPanelStar: .init(light: 0xFBBF24, dark: 0xFBBF24),
        chatPanelShadow: .init(light: 0x0D0D0D, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.30)
    )
}

enum Theme {
    /// The active theme. Assign a different `ThemePalette` here to reskin the app.
    static let palette = ThemePalette.cascade

    // Computed, not stored, so the dynamic NSColor underneath re-resolves on an appearance change.
    static var surfaceHover: Color { palette.surfaceHover.color }
    static var border: Color { palette.border.color }
    static var segmentSelected: Color { palette.segmentSelected.color }
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
    static var chatPanel: Color { palette.chatPanel.color }
    static var chatPanelText: Color { palette.chatPanelText.color }
    static var chatPanelMuted: Color { palette.chatPanelMuted.color }
    static var chatPanelBorder: Color { palette.chatPanelBorder.color }
    static var chatPanelHover: Color { palette.chatPanelHover.color }
    static var chatPanelSelected: Color { palette.chatPanelSelected.color }
    static var chatPanelAccent: Color { palette.chatPanelAccent.color }
    static var chatPanelStar: Color { palette.chatPanelStar.color }
    static var chatPanelShadow: Color { palette.chatPanelShadow.color }

    enum Typography {
        /// 11.5 — `.hook-pill`.
        static let pill = Font.system(size: 11.5)
        /// 13 semibold — `.pane-empty-t`.
        static let emptyTitle = Font.system(size: 13, weight: .semibold)
        /// 12 — `.pane-empty-s`.
        static let emptyHint = Font.system(size: 12)
    }

    /// The colour of Start's send button: black on a light
    /// window, white on a dark one. The text colour, so it follows the appearance by itself.
    static var prominent: Color { Color(nsColor: .labelColor) }
    /// What sits on `prominent`: the window's own colour, white in light and dark in dark.
    static var onProminent: Color { Color(nsColor: .windowBackgroundColor) }

    /// `--bg`: the surface a content pane sits on. Follows the window appearance.
    static var paneBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// Behind text typed into a multi-line field: the system's text background.
    static var fieldBackground: Color { Color(nsColor: .textBackgroundColor) }

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
        /// 36 — the window toolbar's own controls (extra large, as AppKit sizes a segmented control
        /// there), and the pills that line up with them under it.
        static let toolbarControl: CGFloat = 36
        /// 760 — the Settings column cap, matching the web page.
        static let readableColumn: CGFloat = 760
    }
}
