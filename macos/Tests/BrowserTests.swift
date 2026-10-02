import AppKit
import Foundation
import Testing
import WebKit

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


@MainActor @Test func aLinkAskingForANewWindowOpensAsAnotherPageOfThePanel() throws {
    let link = try #require(URL(string: "https://example.com/link"))
    let session = WorkspaceContext(id: "task:one", sourceURL: "", title: "Session")
    let first = try #require(session.open("https://example.com/a", title: "A"))
    #expect(first.openPopup?(link, WKWebViewConfiguration(), true) == nil)
    #expect(session.pages.map(\.url) == ["https://example.com/a", "https://example.com/link"])
}

@MainActor @Test func aPanelKeepsScriptedPopups() throws {
    let context = WorkspaceContext(id: "task:popup", sourceURL: "https://example.com/tab", title: "Tab")
    let page = try #require(context.open("https://example.com/tab", title: "Tab"))
    let link = try #require(URL(string: "https://example.com/link"))
    // A scripted popup keeps its child web view, so its opener handshake still completes.
    let popup = page.openPopup?(link, WKWebViewConfiguration(), false)
    #expect(popup != nil)
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

