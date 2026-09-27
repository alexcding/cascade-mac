import Foundation

/// A project's Jira project key field, which may list several keys comma-separated: the keys in it,
/// uppercased. A field of only commas, spaces or quotes names none, so it is no Jira project at all.
enum JiraKeys {
    static func parse(_ field: String?) -> [String] {
        (field ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))).uppercased() }
            .filter { !$0.isEmpty }
    }
}

struct JiraSite: Decodable, Sendable {
    let baseUrl: String
    var me: JiraAccount? = nil
}

/// The acli login. `accountId` is only known with a REST token; otherwise match by email.
struct JiraAccount: Decodable, Equatable, Sendable {
    var email: String?
    var accountId: String?
}
