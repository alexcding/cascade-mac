import AppKit
import Foundation
import Testing
import WebKit

// Past a memory limit, the least recently used idle session's agent stops and the least recently
// used hidden page is suspended. A busy one is never stopped, and Unlimited, the default, stops nothing.

private let megabyte: UInt64 = 1 << 20

/// A daemon that runs whatever shells it is told of, and ends them when asked.
private actor FakeDaemon: TerminalRuntimeControlling {
    private(set) var shells: [String: Int32] = [:]
    init(running keys: [String]) { for (index, key) in keys.enumerated() { shells[key] = Int32(100 + index) } }
    func stopPaired(keys: Set<String>) { for key in keys { shells[key] = nil } }
    func stopExisting() { shells.removeAll() }
    func pairedShells() -> [String: Int32] { shells }
}

/// Every session tree holds `session`, and WebKit holds `web`. Process groups are read for real:
/// the processes a test runs are real.
struct FixedMemory: ProcessSampling {
    var session: UInt64 = 0
    var web = WebFootprint()
    func footprints(of roots: [String: Int32]) -> [String: UInt64] { roots.mapValues { _ in session } }
    func webFootprint() -> WebFootprint { web }
    func processGroups(of root: Int32) async -> Set<Int32>? { await NativeProcessResourceSampler().processGroups(of: root) }
}

/// A session pool over agents that each hold the same, so what it stops follows only from when each
/// was shown and whether it is busy.
@MainActor private final class PoolFixture {
    let daemon: FakeDaemon
    let pool: SessionPool
    var shown: String? { didSet { if let shown { pool.shown(shown) } } }
    var busy: Set<String> = []
    var refusesStops = false
    private(set) var stops: [String] = []

    init(_ ids: [String], running: [String]? = nil, megabytesEach: UInt64, limit: MemoryLimit) {
        daemon = FakeDaemon(running: running ?? ids)
        pool = SessionPool(control: daemon, memory: FixedMemory(session: megabytesEach * megabyte), limit: limit)
        pool.sessions = { [unowned self] in
            ids.map { .init(id: $0, agent: true, shown: $0 == shown, idle: $0 != shown && !busy.contains($0) && !stops.contains($0)) }
        }
        pool.stop = { [unowned self] id in
            guard !refusesStops else { return false }
            await daemon.stopPaired(keys: [id])
            stops.append(id)
            return true
        }
    }

    /// A sidebar switch: the session shown, then the pool's pass.
    func switchTo(_ id: String) async {
        shown = id
        await pool.trim()?.value
    }
}

@Test func memoryLimitsReadTheirSettingAndDefaultToUnlimited() {
    #expect(MemoryLimit(setting: nil) == .unlimited && MemoryLimit(setting: "3") == .unlimited)
    #expect(MemoryLimit(setting: "4") == .fourGB && MemoryLimit.fourGB.bytes == 4 << 30)
    #expect(MemoryLimit.unlimited.bytes == nil && MemoryLimit.unlimited.title == "Unlimited" && MemoryLimit.oneGB.title == "1 GB")
}

@Test func evictionsTakeIdleMembersLeastRecentFirstUntilThePoolFits() {
    let members: [MemoryPool.Member<String>] = [.init(id: "oldest", bytes: 300 * megabyte, idle: true),
        .init(id: "busy", bytes: 300 * megabyte, idle: false), .init(id: "older", bytes: 300 * megabyte, idle: true),
        .init(id: "recent", bytes: 300 * megabyte, idle: true)]
    // 1.2 GB against 1 GB: one stop fits it.
    #expect(MemoryPool.evictions(members, used: 1200 * megabyte, limit: .oneGB) == ["oldest"])
    // Making room for one about to start takes another, passing over the busy one.
    #expect(MemoryPool.evictions(members, used: 1200 * megabyte, incoming: 300 * megabyte, limit: .oneGB) == ["oldest", "older"])
    // A pool that cannot fit stops every idle member and keeps the busy one.
    #expect(MemoryPool.evictions(members, used: 4000 * megabyte, limit: .oneGB) == ["oldest", "older", "recent"])
    #expect(MemoryPool.evictions(members, used: 900 * megabyte, limit: .oneGB).isEmpty)
    #expect(MemoryPool.evictions(members, used: 4000 * megabyte, limit: .unlimited).isEmpty)
}

@MainActor @Test func openingASessionPastTheLimitStopsTheLeastRecentlyShownIdleAgent() async {
    // Three agents of 300 MB against the 1 GB minimum, all shown once; a fourth is opened.
    let fixture = PoolFixture(["a", "b", "c", "d"], running: ["a", "b", "c"], megabytesEach: 300, limit: .oneGB)
    for id in ["a", "b", "c"] { await fixture.switchTo(id) }
    #expect(fixture.stops.isEmpty)
    // Its agent is about to start, taken to hold what the others do: room is made for it.
    await fixture.switchTo("d")
    #expect(fixture.stops == ["a"] && fixture.pool.stopped == ["a"])
    #expect(await fixture.daemon.shells.keys.sorted() == ["b", "c"])
    // Opening it again starts it: no longer the pool's to keep stopped.
    fixture.pool.started("a")
    #expect(fixture.pool.stopped.isEmpty)
}

@MainActor @Test func anAgentMidTurnKeepsRunningUntilItsTurnEndsThenStops() async {
    // Two agents of 600 MB against the 1 GB minimum. The one left is working when the switch comes.
    let fixture = PoolFixture(["a", "b"], megabytesEach: 600, limit: .oneGB)
    fixture.shown = "b"
    fixture.busy = ["b"]
    await fixture.switchTo("a")
    #expect(fixture.stops.isEmpty)
    #expect(await fixture.daemon.shells.count == 2)
    // Its turn ends: now it can go, and the pool is still over.
    fixture.busy = []
    await fixture.pool.trim()?.value
    #expect(fixture.stops == ["b"])
}

@MainActor @Test func aSessionNeverShownGoesBeforeAnyShown() async {
    let fixture = PoolFixture(["x", "y", "z", "w"], megabytesEach: 300, limit: .oneGB)
    fixture.shown = "x"
    fixture.shown = "y"
    await fixture.switchTo("w")
    #expect(fixture.stops == ["z"])
}

@MainActor @Test func unlimitedStopsNothingAndALimitAppliesAsSoonAsItIsSet() async {
    let fixture = PoolFixture(["a", "b", "c", "d", "e"], megabytesEach: 300, limit: .unlimited)
    for id in ["a", "b", "c", "d", "e"] { await fixture.switchTo(id) }
    #expect(fixture.pool.trim() == nil && fixture.stops.isEmpty)
    fixture.pool.limit = .oneGB
    await fixture.pool.trim()?.value
    #expect(fixture.stops == ["a", "b"])
}

@MainActor @Test func aStopThatDoesNotHappenLeavesTheSessionUnmarked() async {
    let fixture = PoolFixture(["a", "b", "c", "d"], megabytesEach: 300, limit: .oneGB)
    fixture.refusesStops = true
    await fixture.switchTo("d")
    #expect(fixture.pool.stopped.isEmpty)
}

@MainActor @Test func aPagePoolSuspendsTheLeastRecentlyUsedHiddenIdlePages() async {
    _ = NSApplication.shared
    let pages = (1...4).map { BrowserPage(WebPageRecord(url: "https://example.test/\($0)", title: "\($0)")) }
    for page in pages { page.materialize(load: false) }
    // The oldest page opened a sign-in popup, which is still open.
    let popup = BrowserPage(WebPageRecord(url: "about:blank", title: "Sign in"))
    popup.materialize(configuration: WKWebViewConfiguration(), load: false)
    popup.opener = pages[0]
    defer { (pages + [popup]).forEach { $0.evict() } }
    // 300 MB of content a page, and 200 MB of networking and GPU they share: 1.7 GB against 1 GB.
    let pool = PagePool(memory: FixedMemory(web: .init(total: 1700 * megabyte, content: 1500 * megabyte)))
    pool.pages = { pages + [popup] }
    pool.shown = { pages[3] }
    for page in [pages[0], pages[1], pages[2], popup, pages[3]] { pool.used(page) }
    #expect(pool.trim() == nil)
    // The opener and its popup stay, as does the page on screen: the two between them go.
    pool.limit = .oneGB
    await pool.trim()?.value
    #expect(pages.map { $0.webView != nil } == [true, false, false, true] && popup.webView != nil)
}

@MainActor @Test func theViewerSuspendsAHiddenPagePastItsLimitAndLoadsItAgainWhenShown() async throws {
    _ = NSApplication.shared
    let viewer = ViewerStore(memory: FixedMemory(web: .init(total: 1400 * megabyte, content: 1200 * megabyte)))
    viewer.pageMemoryLimit = .oneGB
    let first = try #require(viewer.select(id: "tab:1", url: "", title: "1").open("https://example.test/1"))
    let second = try #require(viewer.select(id: "tab:2", url: "", title: "2").open("https://example.test/2"))
    defer { first.evict(); second.evict() }
    // Two live pages at 600 MB each: the one left behind goes.
    try await poolEventually { first.webView == nil }
    #expect(second.webView != nil)
    // Shown again, it loads again, and the other, now hidden, goes in its place.
    viewer.select(id: "tab:1", url: "", title: "1")
    #expect(first.webView != nil)
    try await poolEventually { second.webView == nil }
}

@MainActor @Test func memoryLimitsPersistLocallyAndFollowTheBackend() async throws {
    let suite = "memory-limits-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let shell = ShellStore(preferences: preferences)
    #expect(shell.sessionMemoryLimit == .unlimited && shell.pageMemoryLimit == .unlimited)
    var changes = 0
    shell.memoryLimitsChanged = { changes += 1 }
    shell.setSessionMemoryLimit(.oneGB); shell.setSessionMemoryLimit(.oneGB); shell.setPageMemoryLimit(.fourGB)
    #expect(changes == 2)
    let relaunched = ShellStore(preferences: preferences)
    #expect(relaunched.sessionMemoryLimit == .oneGB && relaunched.pageMemoryLimit == .fourGB)

    let synced = ShellStore(preferences: try #require(UserDefaults(suiteName: "\(suite)-synced")))
    defer { preferences.removePersistentDomain(forName: "\(suite)-synced") }
    synced.connect(SettingsSnapshot(values: ["sessionMemoryLimit": "2", "pageMemoryLimit": "8"]))
    try await poolEventually { synced.sessionMemoryLimit == .twoGB && synced.pageMemoryLimit == .eightGB }
}

private actor SettingsSnapshot: ShellDataServing {
    let values: [String: String?]
    init(values: [String: String?]) { self.values = values }
    func reviews() -> [TrayPR] { [] }
    func usage() throws -> UsageSnapshot { throw BackendError.operation("Usage unavailable") }
    func settings() -> [String: String?] { values }
    func setSetting(_ key: String, value: String) {}
    func acknowledgeReview(repo: String, number: Int) {}
}

@MainActor private func poolEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw BackendError.operation("The pool did not settle") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
