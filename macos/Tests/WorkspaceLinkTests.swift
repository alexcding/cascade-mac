import AppKit
import Foundation
import GhosttyTerminal
import Testing

@Test func workspaceLinksResolveLocalLocationsWithoutExecutingSchemes() throws {
    func parse(_ value: String) -> WorkspaceLink? { WorkspaceLink.parse(value, directory: "/work/src", home: "/home/test") }
    #expect(parse("main.swift:12:3") == .file(.init(path: "/work/src/main.swift", line: 12, column: 3)))
    #expect(parse("../main.swift:5") == .file(.init(path: "/work/main.swift", line: 5)))
    #expect(parse("~/file.swift:2") == .file(.init(path: "/home/test/file.swift", line: 2)))
    #expect(parse("file:///tmp/file%20name.swift#L9C4") == .file(.init(path: "/tmp/file name.swift", line: 9, column: 4)))
    #expect(parse("file://localhost/tmp/name%3A12") == .file(.init(path: "/tmp/name:12")))
    #expect(parse("file:///tmp/test.swift:9:4") == .file(.init(path: "/tmp/test.swift", line: 9, column: 4)))
    #expect(parse("https://example.com/a.swift:12") == .web(URL(string: "https://example.com/a.swift:12")!))
    for invalid in ["", "javascript:alert(1)", "ssh://host/a", "file://remote/tmp/a", "file:relative", "file:///tmp/a?secret=1",
                    "file:///tmp/a#invalid", "file:///tmp/a%00", "file:///tmp/a%0a", "main.swift:0", "main.swift:1000001",
                    "main.swift:999999999999999999999999999", "main.swift:2:0", "~someone/a", "bad\npath"] {
        #expect(parse(invalid) == nil, "Should refuse \(invalid)")
    }
}

@Test func diffLocationsStayInsideCanonicalWorktree() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = directory.appendingPathComponent("outside.swift")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.swift"), withDestinationURL: outside)
    let location = try WorkingFileLocation.resolve("Sources/file.swift", line: 12, root: root.path)
    #expect(location.path == root.resolvingSymlinksInPath().appendingPathComponent("Sources/file.swift").path)
    #expect(location.line == 12)
    for path in ["../outside.swift", "Sources/../../outside.swift", "/tmp/outside.swift", "escape.swift", ""] {
        #expect(throws: (any Error).self) { try WorkingFileLocation.resolve(path, line: 1, root: root.path) }
    }
}

@MainActor private final class LinkDelegateFixture: TerminalSurfaceViewDelegate, TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate, TerminalSurfaceCloseDelegate {
    var title = "", directory = "", closed = false
    func terminalDidChangeTitle(_ title: String) { self.title = title }
    func terminalDidChangeWorkingDirectory(_ path: String) { directory = path }
    func terminalDidClose(processAlive: Bool) { closed = processAlive }
}

@MainActor @Test func terminalLinkAdapterPreservesDelegateAndCurrentDirectory() {
    _ = NSApplication.shared
    let view = WorkspaceTerminalView(frame: .zero), recipient = LinkDelegateFixture()
    view.delegate = recipient
    var opened: (String, String?, Bool)?
    view.openLink = { opened = ($0, $1, $2) }
    view.terminalDidChangeTitle("Working")
    view.terminalDidChangeWorkingDirectory("/work/new-directory")
    view.terminalDidRequestOpenURL("file:///work/a.swift#L5", kind: .text)
    view.terminalDidClose(processAlive: true)
    #expect(recipient.title == "Working" && recipient.directory == "/work/new-directory" && recipient.closed)
    #expect(opened?.0 == "file:///work/a.swift#L5" && opened?.1 == "/work/new-directory")
    #expect(view.delegate === recipient)
    view.delegate = nil
    #expect(view.delegate == nil)
}
