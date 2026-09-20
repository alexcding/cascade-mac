import Foundation
import Observation

/// One page in the app-wide browser history: the address, its last known title and when it
/// was last visited from any panel.
struct BrowserHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var url: String
    var title: String
    var visited: Date
    var id: String { url }
    var host: String { URL(string: url)?.host ?? url }
    var displayTitle: String { title.isEmpty ? host : title }
}

/// Every web page visited in any panel, newest first, kept across sessions and contexts. A
/// panel's own history stays in its context snapshot; this store is the union, so the start
/// page and the address bar can offer pages first seen elsewhere. One entry per address.
/// Writes are debounced to a JSON file; a store without a file lives only in memory (tests).
@MainActor @Observable final class BrowserHistoryStore {
    static let limit = 2000
    private(set) var entries: [BrowserHistoryEntry] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var write: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode([BrowserHistoryEntry].self, from: data) {
            // Written newest first; a sort would scramble the seeded entries, which share a date.
            entries = Array(saved.prefix(Self.limit))
        }
    }

    /// A visit now: the address moves to the top, keeping the newest non-empty title.
    func note(url: String, title: String) {
        guard safeWebURL(url) != nil else { return }
        let previous = entries.first { $0.url == url }
        entries.removeAll { $0.url == url }
        entries.insert(.init(url: url, title: title.isEmpty ? (previous?.title ?? "") : title, visited: now()), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleWrite()
    }
    func note(_ record: WebPageRecord) { note(url: record.url, title: record.title) }

    /// Pages restored from a context snapshot, which carries no dates: known addresses keep
    /// their place, new ones join at the bottom so real visits always rank above them. A
    /// snapshot lists oldest first; the store lists newest first.
    func seed(_ records: [WebPageRecord]) {
        var added = false
        for record in records.reversed() where safeWebURL(record.url) != nil && !entries.contains(where: { $0.url == record.url }) {
            entries.append(.init(url: record.url, title: record.title, visited: .distantPast)); added = true
        }
        guard added else { return }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleWrite()
    }

    /// Newest first, without the addresses in `excluding` (a panel's own history, shown elsewhere).
    func recent(excluding: Set<String> = [], limit: Int = 200) -> [BrowserHistoryEntry] {
        Array(entries.lazy.filter { !excluding.contains($0.url) }.prefix(limit))
    }

    /// Entries whose address or title contains `text`, newest first, without `excluding`.
    func matching(_ text: String, excluding: Set<String> = [], limit: Int = 4) -> [BrowserHistoryEntry] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Array(entries.lazy.filter { entry in
            !excluding.contains(entry.url)
                && (entry.url.localizedCaseInsensitiveContains(needle) || entry.title.localizedCaseInsensitiveContains(needle))
        }.prefix(limit))
    }

    func remove(url: String) {
        guard entries.contains(where: { $0.url == url }) else { return }
        entries.removeAll { $0.url == url }
        scheduleWrite()
    }
    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll(); scheduleWrite()
    }

    /// Everything written so far is on disk. Tests wait on this; the app never needs to.
    func flush() async { await write?.value }

    /// Writes are chained: each waits for the one before it, so a slow write can never land
    /// after a newer one and leave a stale file behind.
    private func scheduleWrite() {
        guard let fileURL else { return }
        let previous = write
        previous?.cancel()
        let snapshot = entries
        write = Task.detached(priority: .utility) {
            await previous?.value
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            } catch { /* History is a convenience; a failed write is retried on the next visit. */ }
        }
    }
}
