import Foundation
import Observation

/// One bookmarked page: the address, its title when it was bookmarked and when that was.
struct BrowserBookmark: Codable, Identifiable, Equatable, Sendable {
    var url: String
    var title: String
    var added: Date
    var id: String { url }
    var host: String { URL(string: url)?.host ?? url }
    var displayTitle: String { title.isEmpty ? host : title }
}

/// The pages bookmarked from any panel, in the order they were added, kept across sessions and
/// contexts. One bookmark per address. Writes are debounced to a JSON file, as the history's
/// are; a store without a file lives only in memory (tests).
@MainActor @Observable final class BrowserBookmarkStore {
    private(set) var bookmarks: [BrowserBookmark] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var write: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        bookmarks = (try? decoder.decode([BrowserBookmark].self, from: data)) ?? []
    }

    func contains(_ url: String) -> Bool { bookmarks.contains { $0.url == url } }

    /// Only web pages: a blank tab or a local document has nothing to come back to.
    func canBookmark(_ url: String) -> Bool { safeWebURL(url) != nil }

    /// Adds the page, or removes it when it is already bookmarked.
    func toggle(url: String, title: String) {
        if contains(url) { remove(url: url); return }
        guard canBookmark(url) else { return }
        bookmarks.append(BrowserBookmark(url: url, title: title, added: now()))
        scheduleWrite()
    }

    func remove(url: String) {
        let count = bookmarks.count
        bookmarks.removeAll { $0.url == url }
        if bookmarks.count != count { scheduleWrite() }
    }

    /// Bookmarks whose title or address contains `text`, in their saved order.
    func matching(_ text: String, limit: Int = 4) -> [BrowserBookmark] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Array(bookmarks.lazy.filter {
            $0.url.localizedCaseInsensitiveContains(needle) || $0.title.localizedCaseInsensitiveContains(needle)
        }.prefix(limit))
    }

    /// Everything written so far is on disk. Tests wait on this; the app never needs to.
    func flush() async { await write?.value }

    /// Writes are chained: each waits for the one before it, so a slow write can never land
    /// after a newer one and leave a stale file behind.
    private func scheduleWrite() {
        guard let fileURL else { return }
        let previous = write
        previous?.cancel()
        let snapshot = bookmarks
        write = Task.detached(priority: .utility) {
            await previous?.value
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            } catch { /* A failed write is retried on the next change. */ }
        }
    }
}
