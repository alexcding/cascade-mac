import AppKit

/// The status item's image: the app's own mark, sized from the menu bar's own thickness rather than
/// a fixed point size, so it keeps its height whatever the bar's is on this Mac. The share of usage
/// left is the item's title beside it (`AppDelegate`).
///
/// The mark is a template image and takes no tint: the bar draws it in its own black or white and
/// inverts it under the highlight.
enum StatusGlyph {
    /// Where the mark's artwork runs across its 896-wide canvas (MenuBarIcon.svg). The image is cut
    /// to it, so the gap to the title beside it is the bar's own spacing and no empty canvas.
    private static let artwork = (from: 91.6 / 896, to: 810.4 / 896)

    /// `trailing` is room after the artwork, before a title beside it. `named` loads an asset by name;
    /// tests pass their own, having no asset catalog.
    static func image(trailing: CGFloat = 0, named: (String) -> NSImage? = { NSImage(named: $0) }) -> NSImage? {
        guard let canvas = named("MenuBarIcon")?.copy() as? NSImage else { return nil }
        let side = (NSStatusBar.system.thickness * 0.72).rounded()
        canvas.size = NSSize(width: side, height: side)
        let mark = NSImage(size: NSSize(width: side * (artwork.to - artwork.from) + trailing, height: side), flipped: false) { rect in
            canvas.draw(in: NSRect(x: rect.minX - side * artwork.from, y: rect.minY, width: side, height: side))
            return true
        }
        mark.accessibilityDescription = "Cascade"
        mark.isTemplate = true
        return mark
    }
}
