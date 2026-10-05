import AppKit

// The sidebar's glyphs. Everything the system has a symbol for is an SF Symbol, so it takes the
// sidebar's weight, scale and tint like any other Mac app's. Brand marks have no symbol and stay
// vector art: GitHub's is a template tinted by the row, Jira's keeps its colours.
@MainActor enum SidebarIcons {
    private static let symbols: [String: [String]] = [
        // The Overview: pull requests first, with reviews and tickets beside them.
        "pullRequests": ["list.bullet"],
        "automation": ["timer"],
        "folder": ["folder"],
        "close": [Theme.Symbol.close],
        "plus": ["plus"],
        "globe": ["globe"],
        "pin": ["pin"],
        "pinFilled": ["pin.fill"],
    ]
    private static let brands: [String: String] = [
        "github": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#000" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>"##,
        "jira": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#2684FF" d="M14.7 7.3 8.5 1.1 7.9.5 3.2 5.2l-2 2a1 1 0 0 0 0 1.4l4 4 .7.7 4.7-4.7 1.4-1.4a1 1 0 0 0 0-.9zM7.9 9.8 5.8 7.7l2.1-2.1L10 7.7 7.9 9.8z"/><path fill="#2684FF" opacity=".6" d="M7.9 5.6a3.5 3.5 0 0 1 0-4.9L3.2 5.2 5.8 7.7 7.9 5.6zM10 7.7 7.9 9.8a3.5 3.5 0 0 1 0 4.9l4.7-4.7L10 7.7z"/></svg>"##,
    ]
    /// Drawn marks with no SF Symbol: a forked session's, the chat page's fork button in a regular symbol's lines;
    /// New Task's, a pencil leaving an open square, drawn in a regular symbol's lines at the row's size.
    private static let marks: [String: String] = [
        "newSession": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><g fill="none" stroke="#000" stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round"><path d="M7.25 2.25H4.75a2.5 2.5 0 0 0-2.5 2.5v6.5a2.5 2.5 0 0 0 2.5 2.5h6.5a2.5 2.5 0 0 0 2.5-2.5V8.75"/><path d="M12.2 1.95a1.35 1.35 0 0 1 1.9 1.9L8.6 9.35l-2.55.6.6-2.55z"/></g></svg>"##,
        "fork": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="none" stroke="#000" stroke-width="1.4" d="M1.5 8H7l6.5-6.5M9 1.5h4.5V6M9 10l4.5 4.5M9 14.5h4.5V10"/></svg>"##,
    ]
    private static var cache: [String: NSImage] = [:]

    /// A symbol as the system hands it out, with no size of its own: the source list sizes a row's
    /// icon for its row size, and a button sizes its glyph for its control size. A name this table
    /// does not know is taken as an SF Symbol's own, as one chosen for a project is.
    static func symbol(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let image = (symbols[name] ?? [name]).lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) }.first
        cache[name] = image
        return image
    }

    /// A session's pin, a step smaller than a button would draw it, so it sits no larger than the
    /// status dot it stands in for under the pointer.
    static let pinSize: CGFloat = 11
    static func pinSymbol(_ name: String) -> NSImage? {
        let key = "\(name)@pin"
        if let hit = cache[key] { return hit }
        let image = symbol(name)?.withSymbolConfiguration(.init(pointSize: pinSize, weight: .medium))
        cache[key] = image
        return image
    }

    /// A project row's hover buttons, Settings and New Task: a size up from the pin, as they stand
    /// beside a folder rather than in a status dot's place. New Task is its own drawn mark.
    static let projectActionSize: CGFloat = 13
    static func projectActionSymbol(_ name: String) -> NSImage? {
        if marks[name] != nil { return mark(name, size: projectActionSize + 2) }
        let key = "\(name)@projectAction"
        if let hit = cache[key] { return hit }
        let image = symbol(name)?.withSymbolConfiguration(.init(pointSize: projectActionSize, weight: .regular))
        cache[key] = image
        return image
    }

    /// A row's own icon, baked into the image, sized by how much it covers rather than by one point
    /// size: at one size a folder is a quarter wider than the Dashboard's grid and reads as the bigger
    /// icon, and a glyph of lines and dots reads as the smaller. Each is drawn at the size where its
    /// glyph covers the area of a `SidebarMetrics.glyphSide` square, so every row's icon, a project's
    /// own symbol included, reads as the same size, but no wider than `SidebarMetrics.glyphMaxWidth`: a
    /// flat glyph such as a list's lines would otherwise grow to cover the area and read as the wider.
    static func rowSymbol(_ name: String) -> NSImage? {
        let key = "\(name)@row"
        if let hit = cache[key] { return hit }
        let size = SidebarMetrics.symbolSize
        // A drawn mark is told its box, as a symbol its point size, and is measured the same way.
        let render: (CGFloat) -> NSImage? = marks[name] == nil
            ? { symbol(name)?.withSymbolConfiguration(.init(pointSize: $0, weight: .regular)) }
            : { drawn(name, size: $0) }
        guard let measured = render(size) else { return nil }
        var image = measured
        if let glyph = glyphSize(measured), glyph.width > 0, glyph.height > 0 {
            let byArea = size * SidebarMetrics.glyphSide / (glyph.width * glyph.height).squareRoot()
            let byWidth = size * SidebarMetrics.glyphMaxWidth / glyph.width
            let fitted = byWidth < byArea ? (byWidth * 2).rounded(.down) / 2 : (byArea * 2).rounded() / 2
            if fitted != size, let resized = render(fitted) { image = resized }
        }
        cache[key] = image
        return image
    }

    /// How big a symbol's glyph is drawn, in points: the extent of its ink, read off a drawing at twice
    /// the scale. Neither the image's size, which carries margins, nor its alignment rect, which follows
    /// the text line, says it.
    static func glyphSize(_ image: NSImage) -> CGSize? {
        let scale: CGFloat = 2
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = bitmap.bitmapData else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 76 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// A drawn mark, as a template the row tints, in a box of `size` points.
    static func mark(_ name: String, size: CGFloat) -> NSImage? {
        let key = "mark:\(name)@\(size)"
        if let hit = cache[key] { return hit }
        let image = drawn(name, size: size)
        cache[key] = image
        return image
    }

    private static func drawn(_ name: String, size: CGFloat) -> NSImage? {
        guard let svg = marks[name], let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
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
