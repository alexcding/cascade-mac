import Foundation

protocol ShellDataServing: Sendable {
    /// The stored pull requests, and nothing more: it never starts a sync.
    func reviews() async throws -> [TrayPR]
    /// The stored pull requests for someone looking (the tray opened, the app started): the
    /// backend answers the same, and syncs behind the answer what has gone stale.
    func lookAtReviews() async throws -> [TrayPR]
    func usage() async throws -> UsageSnapshot
    func acknowledgeReview(repo: String, number: Int) async throws
}

extension ShellDataServing {
    func lookAtReviews() async throws -> [TrayPR] { try await reviews() }
}

struct APIShellDataService: ShellDataServing {
    let api: APIClient
    func reviews() async throws -> [TrayPR] { try await api.get(Routes.PRS_TRAY) }
    func lookAtReviews() async throws -> [TrayPR] { try await api.get(APIClient.query(Routes.PRS_TRAY, ["look": "1"])) }
    func usage() async throws -> UsageSnapshot { try await api.get(Routes.USAGE) }
    func acknowledgeReview(repo: String, number: Int) async throws { try await api.acknowledgeReview(repo: repo, number: number) }
}
