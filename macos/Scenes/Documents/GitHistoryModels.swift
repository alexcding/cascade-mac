import Foundation

struct GitCommit: Decodable, Equatable, Identifiable, Sendable {
    struct Ref: Decodable, Equatable, Sendable { let type: String; let name: String }
    let sha: String
    let short: String
    let parents: [String]
    let author: String
    let email: String
    let date: String
    let subject: String
    let refs: [Ref]
    var id: String { sha }
    var initials: String {
        let words = author.split(whereSeparator: \.isWhitespace)
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    var dateLabel: String { backendTimestamp(date)?.formatted(date: .abbreviated, time: .omitted) ?? date }
    var searchText: String { [sha, subject, author, email].joined(separator: " ") }
}
struct GitHistoryPage: Decodable, Equatable, Sendable {
    let commits: [GitCommit]
    let branch: String?
    let viewing: String?
    let base: String?
    let historyRevision: String?
    /// For a branch's own commits, whether older history lies past them; false when the branch
    /// shares no commit with its base.
    var older: Bool? = nil
}
struct GitCommitDetail: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let sha: String
        let short: String
        let parents: [String]
        let author: String
        let authorEmail: String
        let authorDate: String
        let committer: String
        let committerEmail: String
        let commitDate: String
        let message: String
        var authorLabel: String {
            [author, authorEmail, backendTimestamp(authorDate)?.formatted(date: .abbreviated, time: .shortened) ?? authorDate]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var subject: String { String(message.split(separator: "\n", maxSplits: 1).first ?? "") }
    }
    let meta: Metadata
    let diff: String
}
/// Ahead-only lists the commits this branch added on top of its base (`base..HEAD`); without it,
/// the history of `ref`, by default the worktree's own, which is where loading older commits
/// carries on.
struct GitHistoryQuery: Equatable, Sendable {
    var aheadOnly = true
    var base = ""
    var ref = "HEAD"
}
protocol GitHistoryService: Sendable {
    func log(worktree: String, query: GitHistoryQuery, skip: Int, limit: Int) async throws -> GitHistoryPage
    func detail(worktree: String, sha: String) async throws -> GitCommitDetail
}
struct APIGitHistoryService: GitHistoryService {
    let api: APIClient
    func log(worktree: String, query: GitHistoryQuery, skip: Int, limit: Int) async throws -> GitHistoryPage {
        struct Response: Decodable, Sendable {
            let commits: [GitCommit]?
            let branch: String?
            let viewing: String?
            let base: String?
            let historyRevision: String?
            let older: Bool?
            let error: String?
        }
        let value: Response = try await api.get(APIClient.query(Routes.GIT_LOG, [
            "path": worktree, "limit": String(limit), "skip": String(skip),
            "aheadOnly": query.aheadOnly ? "1" : "0", "base": query.base, "ref": query.aheadOnly ? "" : query.ref,
        ]), timeout: 30)
        if let error = value.error { throw BackendError.operation(error) }
        guard let commits = value.commits, commits.allSatisfy({ Self.validSHA($0.sha) }) else {
            throw BackendError.operation(String(localized: "The backend returned invalid commit history."))
        }
        return .init(commits: commits, branch: value.branch, viewing: value.viewing, base: value.base,
                     historyRevision: value.historyRevision, older: value.older)
    }
    func detail(worktree: String, sha: String) async throws -> GitCommitDetail {
        guard Self.validSHA(sha) else { throw BackendError.operation(String(localized: "Invalid commit identifier.")) }
        struct Response: Decodable, Sendable { let meta: GitCommitDetail.Metadata?; let diff: String?; let error: String? }
        let value: Response = try await api.get(APIClient.query(Routes.GIT_SHOW, ["path": worktree, "sha": sha]), timeout: 30)
        if let error = value.error { throw BackendError.operation(error) }
        guard let meta = value.meta, meta.sha == sha, let diff = value.diff else {
            throw BackendError.operation(String(localized: "The backend returned a different commit."))
        }
        return .init(meta: meta, diff: diff)
    }
    static func validSHA(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
struct HistoricalPatchService: DiffService {
    let diff: String
    func load(worktree: String) async throws -> DiffSnapshot {
        .init(diff: diff, untracked: [], branch: nil, fileLinks: false)
    }
}
