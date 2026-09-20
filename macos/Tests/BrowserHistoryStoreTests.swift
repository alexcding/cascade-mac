import Foundation
import Testing
@testable import Craft

@MainActor @Test func browserHistoryStoreKeepsOneEntryPerAddressNewestFirst() {
    var clock = Date(timeIntervalSince1970: 1_000)
    let store = BrowserHistoryStore(now: { clock })
    store.note(url: "https://example.com/a", title: "A")
    clock += 10
    store.note(url: "https://example.com/b", title: "B")
    clock += 10
    store.note(url: "https://example.com/a", title: "")
    #expect(store.entries.map(\.url) == ["https://example.com/a", "https://example.com/b"])
    #expect(store.entries.first?.title == "A") // An empty title keeps the one already known.
    store.note(url: "about:blank", title: "New Tab")
    store.note(url: "javascript:alert(1)", title: "Nope")
    #expect(store.entries.count == 2)

    // A snapshot is oldest first: c was visited before d, so d ranks above c.
    store.seed([.init(url: "https://example.com/a", title: "Seeded A"), .init(url: "https://example.com/c", title: "C"),
                .init(url: "https://example.com/d", title: "D")])
    #expect(store.entries.map(\.url) == ["https://example.com/a", "https://example.com/b", "https://example.com/d", "https://example.com/c"])
    #expect(store.entries.first?.title == "A") // Seeding never rewrites a real visit.
    #expect(store.entries.last?.visited == .distantPast)

    #expect(store.recent(excluding: ["https://example.com/a"]).map(\.url) == ["https://example.com/b", "https://example.com/d", "https://example.com/c"])
    #expect(store.matching("EXAMPLE", excluding: ["https://example.com/b"], limit: 1).map(\.url) == ["https://example.com/a"])
    #expect(store.matching("  ").isEmpty)
    store.remove(url: "https://example.com/b")
    #expect(store.entries.map(\.url) == ["https://example.com/a", "https://example.com/d", "https://example.com/c"])
    store.clear()
    #expect(store.entries.isEmpty)
}

@MainActor @Test func browserHistoryStoreTrimsToItsLimitDroppingTheOldest() {
    var clock = Date(timeIntervalSince1970: 0)
    let store = BrowserHistoryStore(now: { clock })
    for index in 0..<(BrowserHistoryStore.limit + 5) {
        clock += 1
        store.note(url: "https://example.com/\(index)", title: "")
    }
    #expect(store.entries.count == BrowserHistoryStore.limit)
    #expect(store.entries.first?.url == "https://example.com/\(BrowserHistoryStore.limit + 4)")
    #expect(store.entries.last?.url == "https://example.com/5")
    // Seeding at capacity: new addresses cannot displace a real visit, known ones are untouched.
    store.seed([.init(url: "https://example.com/seeded", title: "Seeded"), .init(url: "https://example.com/5", title: "Five")])
    #expect(store.entries.count == BrowserHistoryStore.limit)
    #expect(!store.entries.contains { $0.url == "https://example.com/seeded" })
    #expect(store.entries.last?.url == "https://example.com/5")
}

@MainActor @Test func browserHistoryStoreLoadKeepsFileOrderForSeededTies() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("craft-history-\(UUID().uuidString)/history.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = BrowserHistoryStore(fileURL: file)
    store.seed((0..<20).map { .init(url: "https://example.com/\($0)", title: "") })
    await store.flush()
    let reloaded = BrowserHistoryStore(fileURL: file)
    #expect(reloaded.entries.map(\.url) == store.entries.map(\.url))
}

@MainActor @Test func browserHistoryStorePersistsToItsFileAndLoadsBack() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("craft-history-\(UUID().uuidString)/history.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = BrowserHistoryStore(fileURL: file)
    store.note(url: "https://example.com/one", title: "One")
    store.note(url: "https://example.com/two", title: "Two")
    await store.flush()
    let reloaded = BrowserHistoryStore(fileURL: file)
    #expect(reloaded.entries.map(\.title) == ["Two", "One"])
    #expect(reloaded.entries.first?.visited.timeIntervalSince1970 ?? 0 > 0)
}

@MainActor @Test func contextVisitsFeedTheSharedHistoryAndRestoredContextsSeedIt() throws {
    let viewer = ViewerStore()
    let first = viewer.select(id: "task:one", url: "session:one", title: "One")
    _ = try #require(first.open("https://example.com/from-one", title: "From one"))
    #expect(viewer.browserHistory.entries.map(\.url) == ["https://example.com/from-one"])

    // A context restored from the tab cache seeds the shared history, below any real visit.
    var snapshot = first.snapshot
    snapshot.history = [.init(url: "https://example.com/restored", title: "Restored")]
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("craft-tabs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cache) }
    struct Cache: Encodable { let snapshots: [String: ContextSnapshot]; let pending: Set<String> }
    try JSONEncoder().encode(Cache(snapshots: ["task:two": snapshot], pending: [])).write(to: cache)
    let restored = ViewerStore(cacheURL: cache)
    let second = restored.select(id: "task:two", url: "session:two", title: "Two")
    #expect(second.history.map(\.url) == ["https://example.com/restored"])
    #expect(restored.browserHistory.entries.map(\.url) == ["https://example.com/restored"])
    _ = try #require(second.open("https://example.com/new", title: "New"))
    #expect(restored.browserHistory.entries.map(\.url) == ["https://example.com/new", "https://example.com/restored"])
}

@MainActor @Test func clearingBrowsingHistoryEmptiesLiveContextsSavedSnapshotsAndTheSharedStore() throws {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("craft-tabs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cache) }
    struct Cache: Codable { let snapshots: [String: ContextSnapshot]; let pending: Set<String> }
    var dormant = ContextSnapshot()
    dormant.history = [.init(url: "https://example.com/dormant", title: "Dormant")]
    dormant.historyOrder = dormant.history.map(\.id)
    try JSONEncoder().encode(Cache(snapshots: ["task:two": dormant], pending: [])).write(to: cache)

    let viewer = ViewerStore(cacheURL: cache)
    let live = viewer.select(id: "task:one", url: "session:one", title: "One")
    _ = try #require(live.open("https://example.com/live", title: "Live"))
    #expect(!live.history.isEmpty && !viewer.browserHistory.entries.isEmpty)

    viewer.clearBrowsingHistory()
    #expect(live.history.isEmpty && live.pageVisits.isEmpty)
    #expect(viewer.browserHistory.entries.isEmpty)
    // The dormant context's snapshot lost its visits too, so a relaunch cannot seed them back.
    let written = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cache))
    #expect(written.snapshots["task:two"]?.history.isEmpty == true)
    #expect(written.snapshots["task:two"]?.historyOrder?.isEmpty == true)
    #expect(written.snapshots["task:one"]?.history.isEmpty == true)
    let restored = ViewerStore(cacheURL: cache)
    _ = restored.select(id: "task:two", url: "session:two", title: "Two")
    #expect(restored.browserHistory.entries.isEmpty)
}
