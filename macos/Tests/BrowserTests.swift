import AppKit
import Foundation
import Testing
import WebKit

@Test func oldTabImportPreservesOrderActivePageClosedRootAndFileEntries() throws {
    let tab = SavedTab(kind: "github", title: "PR", url: "https://github.com/fixture/repo/pull/1", cur: "https://example.com/current",
        paneView: "off", pageClosed: false,
        links: [.init(kind: "web", url: "https://example.com/one", title: "One"),
                .init(kind: "file", url: "file:///tmp/file.swift", title: "File", path: "/tmp/file.swift"),
                .init(kind: "web", url: "https://example.com/two", title: "Two", active: true)],
        history: [.init(kind: "file", path: "/tmp/old.swift"), .init(kind: "web", url: "https://example.com/history", title: "History")])
    let snapshot = ContextSnapshot.importing(tab)
    #expect(snapshot.pages.map(\.url) == ["https://example.com/current", "https://example.com/one", "https://example.com/two"])
    #expect(snapshot.activeID == snapshot.pages.last?.id)
    #expect(snapshot.pane == "off")
    #expect(snapshot.legacyDocuments?.first?.path == "/tmp/file.swift")
    #expect(snapshot.legacyFileHistory?.first?.path == "/tmp/old.swift")
    #expect(snapshot.history.first?.title == "History")
    var closed = tab; closed.pageClosed = true
    #expect(ContextSnapshot.importing(closed).pages.count == 2)
    let older = try JSONDecoder().decode(ContextSnapshot.self, from: Data(#"{"pages":[],"history":[],"pane":"term"}"#.utf8))
    #expect(older.legacyDocuments == nil)
}

@MainActor @Test func contextTabsKeepOneOrderReopenHistoryAndDoNotPersistBuildMode() throws {
    let context = WorkspaceContext(id: "task:one", sourceURL: "session:one", title: "Bare session")
    #expect(context.pages.isEmpty)
    let first = try #require(context.open("https://example.com/a", title: "A"))
    let second = try #require(context.open("https://example.com/b", title: "B"))
    context.select(first)
    let third = try #require(context.open("https://example.com/c", title: "C"))
    #expect(context.pages.map(\.title) == ["A", "C", "B"])
    #expect(context.open("https://example.com/c") === third)
    context.close(third)
    #expect(context.activeID == second.id)
    #expect(context.history.contains { $0.url == third.url })
    #expect(context.snapshot.pane == "term")
    let restored = WorkspaceContext(id: context.id, sourceURL: "session:one", title: "", snapshot: context.snapshot)
    #expect(restored.pages.map(\.record) == context.pages.map(\.record))
    #expect(restored.activeID == second.id)
    #expect(restored.open("file:///tmp/secret") == nil)
    #expect(restored.open("javascript:alert(1)") == nil)
    #expect(restored.open("https://user:password@example.com") == nil)
}

