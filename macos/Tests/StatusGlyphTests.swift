import AppKit
import Testing
@testable import Cascade

/// A solid square standing in for the mark: the test bundle has no asset catalog.
private func stand(_ name: String) -> NSImage? {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.black.setFill(); rect.fill(); return true }
}

@MainActor @Test func theMarkIsTheBarsOwnTemplateWithRoomForATitle() throws {
    let bare = try #require(StatusGlyph.image(named: stand))
    let titled = try #require(StatusGlyph.image(trailing: 2, named: stand))
    #expect(bare.isTemplate && titled.isTemplate)
    #expect(titled.size.width == bare.size.width + 2 && titled.size.height == bare.size.height)
}
