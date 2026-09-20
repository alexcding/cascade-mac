import Foundation

struct TrayPR: Decodable, Identifiable, Equatable, Sendable {
    struct CI: Decodable, Equatable, Sendable {
        let status: String?
        let conclusion: String?
    }
    let url: String
    let repo: String
    let number: Int
    let title: String
    let state: String
    let category: String
    let awaitingMyReview: Bool?
    var reviewPending: Bool?
    var requestedAt: String? = nil
    let projectName: String?
    let ci: CI?
    var id: String { "\(repo)#\(number)" }
    var pendingReview: Bool { state == "OPEN" && category == "review" && reviewPending == true }
    var webURL: URL? { safeWebURL(url) }
    var ciLabel: String {
        if ci?.status == "in_progress" { return "CI running" }
        switch ci?.conclusion {
        case "success": return "CI passed"
        case "failure": return "CI failed"
        default: return "No CI status"
        }
    }
}

func safeWebURL(_ value: String) -> URL? {
    guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil, url.user == nil, url.password == nil else { return nil }
    return url
}

/// What someone typed into an address field, as a web URL. A full http(s) URL passes through;
/// an address without a scheme (`example.com`, `www.example.com/path`, `localhost:3000`,
/// `192.168.1.5:8080`) gets `https://`, or `http://` for local hosts. Anything else, including
/// other schemes such as `file:` and `javascript:`, is not a web address.
func webAddress(_ input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = safeWebURL(text) { return url }
    guard !text.isEmpty, !text.contains("://"), !text.contains(where: \.isWhitespace),
          let url = URL(string: "http://" + text), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    let ipv4 = host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
    let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || ipv4 || host.contains(":")
    // A bare word ("notes") is not an address; a scheme-shaped prefix ("javascript:x") parses as
    // host plus a non-numeric port and is rejected by URL itself.
    guard local || host.contains(".") else { return nil }
    return safeWebURL((local ? "http://" : "https://") + text)
}

func backendTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system = "auto", light, dark
    public var id: String { rawValue }
    var title: String { self == .system ? "System" : rawValue.capitalized }
}

struct UsageSnapshot: Decodable, Equatable, Sendable {
    struct Agent: Decodable, Equatable, Sendable { let tokens: Double; let cost: Double }
    struct Window: Decodable, Equatable, Sendable {
        let usedPct: Double
        let resetsAt: String?
        let label: String?
        var remaining: Double { max(0, min(100, 100 - usedPct)) }
        func paceRemaining(duration: TimeInterval, now: Date) -> Double? {
            guard duration > 0, let resetsAt, let reset = backendTimestamp(resetsAt) else { return nil }
            return max(0, min(100, reset.timeIntervalSince(now) / duration * 100))
        }
    }
    struct Limits: Decodable, Equatable, Sendable {
        let session: Window?
        let weekly: Window?
        let scoped: [Window]?
    }
    let claude: Agent?
    let codex: Agent?
    let limits: Limits?
    let codexLimits: Limits?
    let asOf: String?
}
