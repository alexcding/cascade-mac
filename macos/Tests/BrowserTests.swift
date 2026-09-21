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


@MainActor @Test func aLinkAskingForANewWindowBecomesASidebarTabOnlyWhereThePanelHoldsOnePage() throws {
    // A sidebar tab is one page, pinned or not: a link that asked for a new window leaves for the
    // Tabs list rather than opening a second page this panel has no tab bar for.
    let tab = WorkspaceContext(id: "tab:one", sourceURL: "https://example.com/tab", title: "Tab")
    var opened: [String] = []
    tab.openSidebarTab = { url, _ in opened.append(url) }
    let page = try #require(tab.open("https://example.com/tab", title: "Tab"))
    let link = try #require(URL(string: "https://example.com/link"))
    #expect(page.openPopup?(link, WKWebViewConfiguration(), true) == nil)
    #expect(opened == ["https://example.com/link"])
    #expect(tab.pages.map(\.url) == ["https://example.com/tab"])

    // A session's second panel opens the same link as another of its own pages.
    let session = WorkspaceContext(id: "task:one", sourceURL: "", title: "Session")
    session.openSidebarTab = { url, _ in opened.append(url) }
    let first = try #require(session.open("https://example.com/a", title: "A"))
    #expect(first.openPopup?(link, WKWebViewConfiguration(), true) == nil)
    #expect(opened.count == 1)
    #expect(session.pages.map(\.url) == ["https://example.com/a", "https://example.com/link"])
}

@MainActor @Test func aOnePagePanelKeepsScriptedPopupsAndFallsBackToItselfWhenTheTabsListRefuses() throws {
    let context = WorkspaceContext(id: "tab:popup", sourceURL: "https://example.com/tab", title: "Tab")
    var opened: [String] = []
    context.openSidebarTab = { url, _ in opened.append(url) }
    let page = try #require(context.open("https://example.com/tab", title: "Tab"))
    let link = try #require(URL(string: "https://example.com/link"))

    // A scripted popup keeps its child web view, so its opener handshake still completes, and it
    // opens here rather than in the sidebar — a diverted popup would come back with no opener.
    let popup = page.openPopup?(link, WKWebViewConfiguration(), false)
    #expect(popup != nil)
    #expect(opened.isEmpty)
    #expect(context.pages.map(\.url) == ["https://example.com/tab", "https://example.com/link"])
    context.pages.last.map(context.close)

    // A link the Tabs list cannot take — the backend is not connected yet — opens in this panel
    // rather than nowhere.
    context.openSidebarTab = { _, keepInPanel in keepInPanel() }
    #expect(page.openPopup?(link, WKWebViewConfiguration(), true) == nil)
    #expect(context.pages.map(\.url) == ["https://example.com/tab", "https://example.com/link"])
}

@MainActor @Test func menuTrackingOutlivesTheTurnTheMenuClosesOn() async {
    // Verified against AppKit: `NSMenu.popUp(positioning:at:in:)` — the call WebKit's
    // WebContextMenuProxyMac shows a page's context menu with — posts both notifications, so the
    // page menu's Open Link in New Window is seen as a link the user opened.
    PageMenuTracking.observe()
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
    #expect(PageMenuTracking.active)
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
    // The chosen item's action runs on the close, so the flag must survive it and go on the next turn.
    #expect(PageMenuTracking.active)
    await Task.yield()
    #expect(!PageMenuTracking.active)
}

@MainActor @Test func aPanelsKindFollowsItsIdThroughPromotion() throws {
    #expect(WorkspaceContext(id: "tab:one", sourceURL: "", title: "Tab").kind == .tab)
    #expect(WorkspaceContext(id: "task:one", sourceURL: "", title: "Session").kind == .session)
    #expect(WorkspaceContext(id: "scratch", sourceURL: "", title: "Terminal").kind == .scratch)
    // A tab promoted into a session stops being one page: its panel now has tabs of its own.
    let viewer = ViewerStore()
    let context = viewer.select(id: "tab:promoted", url: "", title: "Tab")
    #expect(context.holdsOnePage)
    try viewer.promoteContext(from: "tab:promoted", to: "task:promoted")
    #expect(context.kind == .session && !context.holdsOnePage)
}
