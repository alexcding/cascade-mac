import Foundation

/// Keeps the web pages within Settings → Browser's memory limit. Past it, the least recently used
/// pages that are hidden and idle are suspended, their content processes ended, and each loads
/// again when it is next shown, back where it was. A popup and the page that opened it are kept
/// while both are open. Each page is charged the content process it runs in, split with any page
/// sharing it. The processes WebKit shares between pages, networking and GPU, and the app's own
/// web views, the diff and the Simulator, are not pages and count for nothing.
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
        let processes = Set(pages().compactMap(\.contentProcess))
        guard !processes.isEmpty else { return }
        let measured = await memory.footprints(of: Dictionary(uniqueKeysWithValues: processes.map { (String($0), $0) }))
        // Everything below runs without a suspension, so what it reads stays true while it acts.
        let live = pages().filter { $0.webView != nil }
        let ids = Set(live.map(ObjectIdentifier.init))
        lastUse = lastUse.filter { ids.contains($0.key) }
        // A page whose process was not read, or that has moved to another since, is not measured.
        let charged: [(page: BrowserPage, process: Int32, bytes: UInt64)] = live.compactMap { page in
            guard let process = page.contentProcess, let bytes = measured[String(process)] else { return nil }
            return (page, process, bytes)
        }
        let sharing = Dictionary(charged.map { ($0.process, UInt64(1)) }, uniquingKeysWith: +)
        let held = Dictionary(charged.map { ($0.process, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let used = held.values.reduce(0, +)
        // The page coming on screen has no process to read yet: it is taken to hold what the others
        // do, and room is made for it.
        let onScreen = shown()
        let arriving = onScreen.map { page in
            page.webView != nil && !charged.contains { $0.page === page } && safeWebURL(page.url) != nil
        } == true
        let incoming = arriving && !held.isEmpty ? used / UInt64(held.count) : 0
        let openers = Set(live.compactMap(\.opener).map(ObjectIdentifier.init))
        let members = charged.sorted { (lastUse[ObjectIdentifier($0.page)] ?? 0) < (lastUse[ObjectIdentifier($1.page)] ?? 0) }.map {
            MemoryPool.Member(id: ObjectIdentifier($0.page), bytes: $0.bytes / sharing[$0.process, default: 1],
                              idle: $0.page !== onScreen && $0.page.canSuspend && !openers.contains(ObjectIdentifier($0.page)))
        }
        let suspending = Set(MemoryPool.evictions(members, used: used, incoming: incoming, limit: limit))
        for page in live where suspending.contains(ObjectIdentifier(page)) { page.suspend() }
    }
}
