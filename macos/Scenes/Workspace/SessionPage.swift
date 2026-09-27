import Foundation

struct SessionPage: Equatable, Sendable {
    let url: String
    let kind: String
    let key: String
    static func parse(_ raw: String) -> Self? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = safeWebURL(value) else { return nil }
        let components = url.path.split(separator: "/").map(String.init)
        if url.host?.lowercased() == "github.com", components.count >= 4, components[2] == "pull",
           components[3].range(of: "^[0-9]+$", options: .regularExpression) != nil, (Int(components[3]) ?? 0) > 0 {
            return .init(url: value, kind: "github", key: "")
        }
        // A GitHub issue's key is `owner/repo#12`: its number alone is shared by every repo.
        if url.host?.lowercased() == "github.com", components.count >= 4, components[2] == "issues",
           components[3].range(of: "^[0-9]+$", options: .regularExpression) != nil, (Int(components[3]) ?? 0) > 0 {
            return .init(url: value, kind: "issue", key: "\(components[0])/\(components[1])#\(Int(components[3]) ?? 0)".lowercased())
        }
        if let index = components.firstIndex(of: "browse"), index + 1 < components.count {
            let key = components[index + 1].uppercased()
            if key.range(of: "^[A-Z][A-Z0-9]+-[0-9]+$", options: .regularExpression) != nil {
                return .init(url: value, kind: "jira", key: key)
            }
        }
        return nil
    }
    static func jiraBranch(key: String, summary: String) -> String {
        let slug = slug(summary)
        return slug.isEmpty ? key : "\(key)-\(slug)"
    }
    /// GitHub's own branch name for an issue: its number, then its title.
    static func issueBranch(number: Int, title: String) -> String {
        let slug = slug(title)
        return slug.isEmpty ? "issue-\(number)" : "\(number)-\(slug)"
    }
    /// The issue number in an issue page's key, `owner/repo#12`.
    var issueNumber: Int? { kind == "issue" ? key.split(separator: "#").last.flatMap { Int($0) } : nil }
    /// The repository in an issue page's key.
    var issueRepo: String? { kind == "issue" ? key.split(separator: "#").first.map(String.init) : nil }
    private static func slug(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
    }
}
