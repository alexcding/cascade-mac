import Foundation
import Observation

/// One completion: a search phrase, or a site the endpoint would navigate to (`text` is its URL).
struct SearchSuggestion: Equatable, Sendable, ExpressibleByStringLiteral {
    let text: String
    var title = ""
    var isSite = false
    init(text: String, title: String = "", isSite: Bool = false) { self.text = text; self.title = title; self.isSite = isSite }
    init(stringLiteral value: String) { text = value }
}

/// Search-phrase and site completions for the address bar, from the suggest endpoint Chrome and Firefox
/// use. Keyless and undocumented, so failures are silent and never surface as an error. One
/// request in flight per store, debounced, results cached for the process.
@MainActor @Observable final class SearchSuggestionStore {
    static let shared = SearchSuggestionStore()
    private(set) var results: [String: [SearchSuggestion]] = [:]
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var fetch: (String) async -> [SearchSuggestion]

    init(fetch: ((String) async -> [SearchSuggestion])? = nil) {
        self.fetch = fetch ?? Self.fetchFromGoogle
    }

    private static let cacheLimit = 50
    @ObservationIgnored private var order: [String] = []
    /// A failed or empty fetch is retried after a short while, not remembered for the process.
    @ObservationIgnored private var failures: [String: Date] = [:]

    /// Completions already known for `text`. Pure: reading never starts a request.
    func cached(_ text: String) -> [SearchSuggestion] { results[Self.key(text)] ?? [] }

    /// Asks for completions when unknown. Debounced: a newer text cancels the pending request.
    func prefetch(_ text: String) {
        let key = Self.key(text)
        guard !key.isEmpty, results[key] == nil else { return }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 30 { return }
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let phrases = await fetch(key)
            guard !Task.isCancelled else { return }
            store(key, phrases)
        }
    }

    private static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Bounded: the oldest queries fall out once past the limit.
    private func store(_ key: String, _ phrases: [SearchSuggestion]) {
        guard !phrases.isEmpty else { failures[key] = Date(); return }
        failures[key] = nil
        results[key] = phrases
        order.removeAll { $0 == key }; order.append(key)
        while order.count > Self.cacheLimit, let oldest = order.first { order.removeFirst(); results[oldest] = nil }
    }

    /// `["<query>", ["<phrase>", ...], ["<title>", ...], [], {"google:suggesttype": [...]}]`, the
    /// Chrome-client shape. A `NAVIGATION` entry is a site: its phrase is the URL, its title the
    /// page's. Everything past the phrases is optional, which is also the Firefox-client shape.
    static func parse(_ data: Data) -> [SearchSuggestion] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 2,
              let phrases = json[1] as? [String] else { return [] }
        let titles = json.count > 2 ? json[2] as? [String] ?? [] : []
        let types = json.lazy.compactMap { $0 as? [String: Any] }.first?["google:suggesttype"] as? [String] ?? []
        return phrases.enumerated().map { index, phrase in
            let site = types.indices.contains(index) && types[index] == "NAVIGATION" && webAddress(phrase) != nil
            return SearchSuggestion(text: phrase, title: site && titles.indices.contains(index) ? titles[index] : "", isSite: site)
        }
    }

    private static func fetchFromGoogle(_ text: String) async -> [SearchSuggestion] {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [.init(name: "client", value: "chrome"), .init(name: "oe", value: "utf-8"), .init(name: "q", value: text)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }
}
