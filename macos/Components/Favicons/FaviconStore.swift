import AppKit
import LinkPresentation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Site icons for web tabs, keyed by host. The icon the site's page declares is tried first,
/// then `/favicon.ico`, then DuckDuckGo's icon service for public hosts. Images live
/// for the process; a finished fetch posts `SidebarAvatars.loaded` so AppKit rows refresh,
/// and `images` is observable so SwiftUI toolbars update on their own.
@MainActor @Observable final class FaviconStore {
    static let shared = FaviconStore()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var failures: [String: Date] = [:]

    static func host(of url: String) -> String? {
        guard let components = URL(string: url), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme ?? "") else { return nil }
        return host.lowercased()
    }

    /// Hosts whose name may be sent to the public icon service: a routable, dotted public name.
    /// Bare names, `.local`/`.internal`/`.lan`/`.corp`/`.home`/`.test` suffixes and IP literals stay private.
    static func isPublicHost(_ host: String) -> Bool {
        guard host.contains("."), host != "localhost" else { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") { return false }
        let suffix = host.split(separator: ".").last.map(String.init) ?? ""
        return !["local", "internal", "lan", "corp", "home", "test", "localhost", "intranet"].contains(suffix)
    }

    func image(forURL url: String) -> NSImage? { Self.host(of: url).flatMap { image(host: $0, url: url) } }

    func image(host: String, url: String? = nil) -> NSImage? {
        if let hit = images[host] { return hit }
        // A failed fetch may retry after a minute, not on every row refresh and not never.
        if let failed = failures[host], Date().timeIntervalSince(failed) < 60 { return nil }
        guard pending.insert(host).inserted else { return nil }
        Task {
            defer { pending.remove(host) }
            if let image = await Self.fetch(host, scheme: url.flatMap { URL(string: $0)?.scheme } ?? "https") {
                failures[host] = nil
                images[host] = image
                NotificationCenter.default.post(name: SidebarAvatars.loaded, object: nil)
            } else {
                failures[host] = Date()
            }
        }
        return nil
    }

    private static func fetch(_ host: String, scheme: String) async -> NSImage? {
        if let image = await declaredIcon(host, scheme: scheme) { return image }
        var candidates = ["\(scheme)://\(host)/favicon.ico"]
        if isPublicHost(host) { candidates.append("https://icons.duckduckgo.com/ip3/\(host).ico") }
        for candidate in candidates {
            guard let url = URL(string: candidate),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512 * 1024,
                  let image = NSImage(data: data), image.size.width > 0 else { continue }
            return image
        }
        return nil
    }

    /// The icon the site's own page declares — its touch icon or largest `<link rel="icon">` —
    /// chosen by LinkPresentation the way Safari chooses one for its tiles.
    private static func declaredIcon(_ host: String, scheme: String) async -> NSImage? {
        guard let url = URL(string: "\(scheme)://\(host)/") else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let data: Data? = await withCheckedContinuation { continuation in
            provider.startFetchingMetadata(for: url) { metadata, _ in
                guard let icon = metadata?.iconProvider else { return continuation.resume(returning: nil) }
                _ = icon.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
            }
        }
        guard let data, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        return image
    }
}

/// The favicon for `url` at toolbar size, or a globe until one has loaded.
struct FaviconImage: View {
    let url: String
    var size: CGFloat = 16
    /// The globe's point size when there is no favicon; nil fills the box, as a small icon should.
    var fallbackSize: CGFloat?
    private var store = FaviconStore.shared

    init(url: String, size: CGFloat = 16, fallbackSize: CGFloat? = nil) { self.url = url; self.size = size; self.fallbackSize = fallbackSize }

    var body: some View {
        if let image = store.image(forURL: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe").font(.system(size: fallbackSize ?? size - 2)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
