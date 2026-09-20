import AppKit

// The sidebar's glyphs. Everything the system has a symbol for is an SF Symbol, so it takes the
// sidebar's weight, scale and tint like any other Mac app's. Brand marks have no symbol and stay
// vector art: GitHub's is a template tinted by the row, Jira's keeps its colours.
@MainActor enum SidebarIcons {
    private static let symbols: [String: [String]] = [
        // The first name this system has: text.rectangle.page arrived with macOS 15, and the app runs on 14.
        "dashboard": ["text.rectangle.page", "doc.text"],
        "folder": ["folder"],
        "close": ["xmark"],
        "plus": ["plus"],
        "globe": ["globe"],
        "pin": ["pin"],
        "pinFilled": ["pin.fill"],
    ]
    private static let brands: [String: String] = [
        "github": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#000" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>"##,
        "jira": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#2684FF" d="M14.7 7.3 8.5 1.1 7.9.5 3.2 5.2l-2 2a1 1 0 0 0 0 1.4l4 4 .7.7 4.7-4.7 1.4-1.4a1 1 0 0 0 0-.9zM7.9 9.8 5.8 7.7l2.1-2.1L10 7.7 7.9 9.8z"/><path fill="#2684FF" opacity=".6" d="M7.9 5.6a3.5 3.5 0 0 1 0-4.9L3.2 5.2 5.8 7.7 7.9 5.6zM10 7.7 7.9 9.8a3.5 3.5 0 0 1 0 4.9l4.7-4.7L10 7.7z"/></svg>"##,
    ]
    private static var cache: [String: NSImage] = [:]

    /// A symbol as the system hands it out, with no size of its own: the source list sizes a row's
    /// icon for its row size, and a button sizes its glyph for its control size.
    static func symbol(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let image = symbols[name]?.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) }.first
        cache[name] = image
        return image
    }

    /// The "+" on the Tabs heading and on a project row: the one accessory that is an action of its
    /// own rather than a state of the row, so it is drawn a step larger and heavier than the pin
    /// and close marks. It still fits the 18pt accessory slot.
    static var addSymbol: NSImage? {
        let key = "plus@add"
        if let hit = cache[key] { return hit }
        let image = symbol("plus")?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        cache[key] = image
        return image
    }

    /// A row's own icon, a step larger than the list would draw it. The size is baked into the image:
    /// the source list resets its cell's image view to the row size's 13pt, but leaves the image alone.
    static func rowSymbol(_ name: String) -> NSImage? {
        let key = "\(name)@row"
        if let hit = cache[key] { return hit }
        let image = symbol(name)?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.symbolSize, weight: .regular))
        cache[key] = image
        return image
    }

    /// Brand art is a drawing, not a font glyph, so it is told its box, in points.
    static func brand(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let hit = cache[key] { return hit }
        guard let svg = brands[name], let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = name != "jira"
        image.accessibilityDescription = name
        cache[key] = image
        return image
    }
}
