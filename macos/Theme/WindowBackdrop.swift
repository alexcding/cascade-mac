import AppKit
import SwiftUI

/// What the main window's backdrop is: the sidebar's, the title bar's material under a wash
/// (`Theme.backdropWash`) laid on at `opacity`. Solid, only the sidebar stands on it; translucent,
/// every column does — the screen, the pane and their terminals, which then draw no background of
/// their own — so the window is one surface with the desktop showing through.
///
/// Set in Settings → Appearance and handed down from the window's columns through the environment
/// (`windowBackdrop`), so no surface can be solid while the one beside it is not.
struct WindowBackdrop: Equatable, Sendable {
    var isTranslucent = false
    /// How much of the wash is laid on: 1 is the sidebar's own look, 0 the material alone.
    var opacity = 1.0

    static let opacityRange: ClosedRange<Double> = 0...1
    /// How much of a control's own fill is kept over the backdrop while translucent: enough to set
    /// a pill apart from the bar it sits in, not so much that it reads as a solid block.
    static let controlOpacity = 0.5

    static func clampOpacity(_ value: Double) -> Double {
        min(opacityRange.upperBound, max(opacityRange.lowerBound, value))
    }
    static func clampOpacity(_ value: String?) -> Double {
        guard let value, let parsed = Double(value) else { return 1 }
        return clampOpacity(parsed)
    }
}

extension Theme {
    /// The wash over the backdrop's material: what makes it solid rather than see-through. In light
    /// it is a near-white cool grey, mostly opaque, as ChatGPT's sidebar is: the desktop's colour is
    /// a faint tint, not the backdrop's colour. In dark the material alone is a lighter grey than a
    /// page, and the page's own colour (`paneBackground`) brings it down to one.
    static let backdropWash = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(Theme.paneBackground).withAlphaComponent(0.65)
            : NSColor(srgbRed: 0xf2 / 255, green: 0xf3 / 255, blue: 0xf5 / 255, alpha: 0.85)
    }
}

private struct WindowTranslucentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the column this is drawn in stands on the window's backdrop (`WindowBackdrop`).
    var windowTranslucent: Bool {
        get { self[WindowTranslucentKey.self] }
        set { self[WindowTranslucentKey.self] = newValue }
    }
}
