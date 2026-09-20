import Foundation
import Testing
@testable import Craft

@MainActor @Test func browserBookmarkStoreTogglesOneBookmarkPerWebAddressInAddedOrder() {
    let store = BrowserBookmarkStore()
    store.toggle(url: "https://example.com/one", title: "One")
    store.toggle(url: "https://github.com/", title: "GitHub")
    #expect(store.bookmarks.map(\.title) == ["One", "GitHub"] && store.contains("https://github.com/"))
    store.toggle(url: "https://example.com/one", title: "Renamed")
    #expect(store.bookmarks.map(\.url) == ["https://github.com/"]) // A second toggle removes it.
    store.toggle(url: "about:blank", title: "")
    store.toggle(url: "file:///tmp/a.txt", title: "Local")
    #expect(store.bookmarks.count == 1 && !store.canBookmark("about:blank")) // Web pages only.
    #expect(store.matching("git").map(\.url) == ["https://github.com/"] && store.matching("nope").isEmpty && store.matching("  ").isEmpty)
    #expect(BrowserBookmark(url: "https://example.com/x", title: "", added: .now).displayTitle == "example.com")
}

@MainActor @Test func browserBookmarkStorePersistsToItsFileAndLoadsBack() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("craft-bookmarks-\(UUID().uuidString)/bookmarks.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = BrowserBookmarkStore(fileURL: file)
    store.toggle(url: "https://example.com/one", title: "One")
    store.toggle(url: "https://example.com/two", title: "Two")
    store.remove(url: "https://example.com/one")
    await store.flush()
    let reloaded = BrowserBookmarkStore(fileURL: file)
    #expect(reloaded.bookmarks.map(\.title) == ["Two"])
}
