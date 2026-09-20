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
        if let index = components.firstIndex(of: "browse"), index + 1 < components.count {
            let key = components[index + 1].uppercased()
            if key.range(of: "^[A-Z][A-Z0-9]+-[0-9]+$", options: .regularExpression) != nil {
                return .init(url: value, kind: "jira", key: key)
            }
        }
        return nil
    }
    static func jiraBranch(key: String, summary: String) -> String {
        let slug = summary.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? key : "\(key)-\(slug.prefix(40))"
    }
}
