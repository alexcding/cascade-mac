import Foundation

protocol ShellDataServing: Sendable {
    func reviews() async throws -> [TrayPR]
    func usage() async throws -> UsageSnapshot
    func settings() async throws -> [String: String?]
    func setSetting(_ key: String, value: String) async throws
    func acknowledgeReview(repo: String, number: Int) async throws
}

struct APIShellDataService: ShellDataServing {
    let api: APIClient
    func reviews() async throws -> [TrayPR] { try await api.get(Routes.PRS_TRAY) }
    func usage() async throws -> UsageSnapshot { try await api.get(Routes.USAGE) }
    func settings() async throws -> [String: String?] { try await api.get(Routes.SETTINGS) }
    func setSetting(_ key: String, value: String) async throws { try await api.setSetting(key, value: value) }
    func acknowledgeReview(repo: String, number: Int) async throws { try await api.acknowledgeReview(repo: repo, number: number) }
}
