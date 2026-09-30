import Foundation

protocol ShellDataServing: Sendable {
    func reviews() async throws -> [TrayPR]
    func usage() async throws -> UsageSnapshot
    func acknowledgeReview(repo: String, number: Int) async throws
}

struct APIShellDataService: ShellDataServing {
    let api: APIClient
    func reviews() async throws -> [TrayPR] { try await api.get(Routes.PRS_TRAY) }
    func usage() async throws -> UsageSnapshot { try await api.get(Routes.USAGE) }
    func acknowledgeReview(repo: String, number: Int) async throws { try await api.acknowledgeReview(repo: repo, number: number) }
}
