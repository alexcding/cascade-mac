import Foundation

// Decode only the inspector fields used by the native screen. In particular, the
// legacy endpoint's configuration dictionary (which can contain tokens) is ignored.
struct DiagnosticsSnapshot: Decodable, Sendable {
    struct Counts: Decodable, Sendable { let projects: Int; let links: Int; let events: Int }
    struct ProjectEntry: Decodable, Sendable {
        let id: String
        let name: String
        let repo: String
        let mergeTransition: String?
    }
    struct Cache: Decodable, Sendable {
        let open: Int?
        let tickets: Int?
        let lastSynced: String?
        let error: String?
    }
    struct GitHubMetrics: Decodable, Sendable {
        let calls: Int
        let errors: Int
        let avgMs: Int
        let maxMs: Int
        let inflight: Int
        let coalesced: Int
    }
    let counts: Counts
    let projects: [ProjectEntry]
    let snapshots: [String: Cache]
    let jiraSnapshots: [String: Cache]
    let ghStats: GitHubMetrics
}

protocol DiagnosticsService: Sendable {
    func snapshot() async throws -> DiagnosticsSnapshot
}

struct APIDiagnosticsService: DiagnosticsService {
    let api: APIClient
    func snapshot() async throws -> DiagnosticsSnapshot { try await api.get(Routes.DB) }
}
