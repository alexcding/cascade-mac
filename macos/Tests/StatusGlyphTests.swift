import AppKit
import Testing
@testable import Cascade

/// A solid square standing in for the mark: the test bundle has no asset catalog.
private func stand(_ name: String) -> NSImage? {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.black.setFill(); rect.fill(); return true }
}

@MainActor @Test func theMarkIsTheBarsOwnTemplateUntilAReviewPaintsItBronze() throws {
    #expect(StatusGlyph.image(review: false, named: stand)?.isTemplate == true)
    let image = try #require(StatusGlyph.image(review: true, named: stand))
    #expect(!image.isTemplate)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    let color = try #require(bitmap.colorAt(x: 16, y: 16))
    // Bronze: warm, and far from the template's black.
    #expect(color.redComponent > color.blueComponent + 0.2 && color.greenComponent > 0.3)
}
