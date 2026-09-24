import Foundation

/// Keeps the web pages within Settings → Browser's memory limit. Past it, the least recently used
/// pages that are hidden and idle are suspended, their content processes ended, and each loads
/// again when it is next shown. A popup and the page that opened it are kept while both are open.
/// WebKit does not say which process is whose, so every page is taken to hold an equal share of
/// what the content processes do.
@MainActor final class PagePool {
    var limit = MemoryLimit.unlimited { didSet { if oldValue != limit { trim() } } }
    /// Every page the viewer holds, with a web view or not.
    var pages: () -> [BrowserPage] = { [] }
    /// The page on screen, which is never suspended.
    var shown: () -> BrowserPage? = { nil }

    private var lastUse: [ObjectIdentifier: UInt64] = [:]
    private var clock: UInt64 = 0
    private var pass: Task<Void, Never>?
    private var passPending = false
    private let memory: any ProcessSampling

    init(memory: any ProcessSampling) { self.memory = memory }

    /// The page was shown, or started loading: it is now the most recently used.
    func used(_ page: BrowserPage) {
        clock += 1
        lastUse[ObjectIdentifier(page)] = clock
    }

    /// Suspends what the limit no longer holds. Passes never overlap: one asked for while another
    /// runs follows it and measures again. Returns the pass for a caller that waits on it.
    @discardableResult func trim() -> Task<Void, Never>? {
        guard limit != .unlimited else { return pass }
        passPending = true
        if let pass { return pass }
        let task = Task { [weak self] in
            while let self, self.passPending {
                self.passPending = false
                await self.trimOnce()
            }
            self?.pass = nil
        }
        pass = task
        return task
    }

    private func trimOnce() async {
        guard pages().contains(where: { $0.webView != nil }) else { return }
        let web = await memory.webFootprint()
        // Everything below runs without a suspension, so what it reads stays true while it acts.
        let live = pages().filter { $0.webView != nil }
        guard !live.isEmpty else { return }
        let ids = Set(live.map(ObjectIdentifier.init))
        lastUse = lastUse.filter { ids.contains($0.key) }
        let share = web.content / UInt64(live.count), onScreen = shown()
        let openers = Set(live.compactMap(\.opener).map(ObjectIdentifier.init))
        let members = live.sorted { (lastUse[ObjectIdentifier($0)] ?? 0) < (lastUse[ObjectIdentifier($1)] ?? 0) }.map {
            MemoryPool.Member(id: ObjectIdentifier($0), bytes: share,
                              idle: $0 !== onScreen && $0.canSuspend && !openers.contains(ObjectIdentifier($0)))
        }
        let suspending = Set(MemoryPool.evictions(members, used: web.total, limit: limit))
        for page in live where suspending.contains(ObjectIdentifier(page)) { page.evict() }
    }
}
