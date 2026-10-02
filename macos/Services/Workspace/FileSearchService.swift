import Foundation

/// A worktree's files, as git lists them: those matching a typed query, ranked by the backend,
/// and the whole list in path order for the Files tab's tree.
protocol FileSearchService: Sendable {
    func files(in root: String, matching query: String) async throws -> [String]
    /// Every file, worktree-relative; `truncated` when the backend's cap left some out.
    func allFiles(in root: String) async throws -> (files: [String], truncated: Bool)
}

struct APIFileSearchService: FileSearchService {
    let api: APIClient
    private struct Response: Decodable, Sendable {
        let files: [String]
        let truncated: Bool?
    }
    func files(in root: String, matching query: String) async throws -> [String] {
        let result: Response = try await api.get(APIClient.query(Routes.FILES, ["path": root, "q": query]))
        return result.files
    }
    func allFiles(in root: String) async throws -> (files: [String], truncated: Bool) {
        let result: Response = try await api.get(APIClient.query(Routes.FILES, ["path": root, "all": "1"]))
        return (result.files, result.truncated ?? false)
    }
}
