import AppKit
import Foundation
import GhosttyTerminal
import Testing

private func pasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: .init("terminal-drop-\(UUID().uuidString)"))
    board.clearContents()
    return board
}

@MainActor @Test func terminalDropTypesDroppedFilesAsEscapedPaths() throws {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    board.writeObjects([URL(fileURLWithPath: "/tmp/one.png") as NSURL, URL(fileURLWithPath: "/tmp/My Shot (1).png") as NSURL])
    let content = try #require(TerminalDrop.read(board))
    var typed: String?
    TerminalDrop.deliver(content) { typed = $0 }
    #expect(typed == #"/tmp/one.png /tmp/My\ Shot\ \(1\).png"#)
}

/// Staging itself is `TerminalPastePayload`'s, covered by the paste tests; staging here as well would
/// race them over the shared staging directory.
@MainActor @Test func terminalDropStagesAnImageWithNoFileAndIgnoresText() throws {
    let image = pasteboard()
    defer { image.releaseGlobally() }
    image.setData(Data("pretend this is a png".utf8), forType: .png)
    guard case .stage = TerminalDrop.read(image) else { Issue.record("A web page's image should be staged"); return }

    // A file already has a path, even when it is an image.
    let file = pasteboard()
    defer { file.releaseGlobally() }
    file.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])
    guard case .text(#"/tmp/shot.png"#) = TerminalDrop.read(file) else { Issue.record("A file should type its path"); return }

    let text = pasteboard()
    defer { text.releaseGlobally() }
    text.setString("just text", forType: .string)
    #expect(TerminalDrop.read(text) == nil)
}

