import AppKit
import Foundation
import GhosttyTerminal
import Testing
import UniformTypeIdentifiers

private final class InputBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    func take() -> Data { lock.lock(); defer { lock.unlock() }; let result = bytes; bytes.removeAll(); return result }
}

@MainActor private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("craft-paste-\(UUID().uuidString)"))
    board.clearContents()
    fill(board)
    return board
}

@MainActor @Test func pastedPathsReadTheWayGhosttyPastesThem() {
    #expect(TerminalPastePayload.escape("/tmp/a test(1).txt") == "/tmp/a\\ test\\(1\\).txt")
    #expect(TerminalPastePayload.escape("/tmp/日本語.txt") == "/tmp/日本語.txt")
    // A file copied in Finder carries its display name as the string too;
    // taking the string first would paste the name instead of the path.
    #expect(TerminalPastePayload.text(string: "a test.txt", urls: [URL(fileURLWithPath: "/tmp/a test.txt")])
        == "/tmp/a\\ test.txt")
    #expect(TerminalPastePayload.text(string: nil, urls: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b c")])
        == "/a /b\\ c")
    #expect(TerminalPastePayload.text(string: nil, urls: [URL(string: "https://example.com/a b")!])
        == "https://example.com/a%20b")
    #expect(TerminalPastePayload.text(string: "plain text", urls: []) == "plain text")
    #expect(TerminalPastePayload.text(string: "", urls: []) == nil)
    #expect(TerminalPastePayload.text(string: nil, urls: []) == nil)

    #expect(TerminalPastePayload.stageable(from: pasteboard { _ in }) == nil)
    // Text is text: it must never be written to a file on the way in.
    #expect(TerminalPastePayload.stageable(from: pasteboard { $0.setString("echo hello", forType: .string) }) == nil)
    let file = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL]) }
    #expect(TerminalPastePayload.stageable(from: file) == nil, "A file already has a path")
    let image = pasteboard { $0.setData(Data("not really a png".utf8), forType: .png) }
    #expect(TerminalPastePayload.stageable(from: image) != nil)
}

/// A clipboard holding only bytes — a screenshot, an image copied out of a web
/// page — has no path to paste. Cmd+V stages it as a file and the path reaches
/// the pty like any other paste; everything else stays on ghostty's own paste
/// binding.
@MainActor @Test(.timeLimit(.minutes(1))) func terminalStagesPastedBytesAsFiles() async throws {
    _ = NSApplication.shared
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString)")
    let previousStaging = TerminalFileStaging.directory
    TerminalFileStaging.directory = staging
    defer {
        TerminalFileStaging.directory = previousStaging
        try? FileManager.default.removeItem(at: staging)
    }
    let bytes = Data("pretend this is a screenshot".utf8)
    let input = InputBytes()
    let memory = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
    let state = TerminalViewState()
    let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    view.delegate = state
    view.controller = state.controller
    view.configuration = .init(backend: .inMemory(memory), fontSize: 13)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.contentView = nil; window.close() }
    view.layoutSubtreeIfNeeded()
    for _ in 0 ..< 100 {
        if state.surface != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(state.surface != nil)
    view.setSurfaceVisible(false)

    func pasted() async throws -> String {
        var bytes = Data()
        for _ in 0 ..< 200 where bytes.isEmpty {
            bytes = input.take()
            if bytes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func pressCommandV() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1,
            windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        ))
    }

    TerminalPastePayload.clipboard = pasteboard { $0.setData(bytes, forType: .png) }
    defer { TerminalPastePayload.clipboard = .general }
    #expect(window.makeFirstResponder(view))
    #expect(view.performKeyEquivalent(with: try pressCommandV()))
    let staged = staging.appendingPathComponent("image.png")
    #expect(try await pasted() == staged.path)
    #expect(try Data(contentsOf: staged) == bytes)

    // A second paste must not overwrite a path a shell may still be holding.
    TerminalPastePayload.clipboard = pasteboard { $0.setData(bytes, forType: .png) }
    #expect(view.performKeyEquivalent(with: try pressCommandV()))
    #expect(try await pasted() == staging.appendingPathComponent("image-1.png").path)

    // Text and file URLs stay ghostty's own paste binding's business: that
    // path answers the key, and nothing is written to disk on the way.
    TerminalPastePayload.clipboard = pasteboard { $0.setString("echo hello", forType: .string) }
    _ = view.performKeyEquivalent(with: try pressCommandV())
    try await Task.sleep(for: .milliseconds(120))
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted() == ["image-1.png", "image.png"])
}
