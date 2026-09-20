import Foundation

/// The files of one worktree that match a typed query, ranked by the backend.
protocol FileSearchService: Sendable {
    func files(in root: String, matching query: String) async throws -> [String]
}

struct APIFileSearchService: FileSearchService {
    let api: APIClient
    func files(in root: String, matching query: String) async throws -> [String] {
        struct Response: Decodable, Sendable { let files: [String] }
        let result: Response = try await api.get(APIClient.query(Routes.FILES, ["path": root, "q": query]))
        return result.files
    }
}
