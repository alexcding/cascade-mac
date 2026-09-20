import Foundation

struct AutomationDraft: Encodable, Equatable, Sendable {
    var forwardWebhooks: Bool
    var mergeTransition: String
    var fixVersionEnabled: Bool
    var fixVersionPrefix: String
    var fixVersionScript: String

    init(_ project: Project) {
        forwardWebhooks = project.forwardWebhooks ?? true
        mergeTransition = project.mergeTransition ?? ""
        fixVersionEnabled = project.fixVersionEnabled ?? false
        fixVersionPrefix = project.fixVersionPrefix ?? ""
        fixVersionScript = project.fixVersionScript ?? ""
    }
    var payload: Self {
        var value = self
        value.mergeTransition = mergeTransition.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fixVersionPrefix = fixVersionPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}

struct FixVersionPreview: Decodable, Equatable, Sendable {
    let version: String
    let exists: Bool
}

protocol AutomationService: Sendable {
    func save(projectID: String, draft: AutomationDraft) async throws -> Project
    func preview(projectID: String, prefix: String, script: String) async throws -> FixVersionPreview
    func forwarders() async throws -> [String]
}

struct APIAutomationService: AutomationService {
    let api: APIClient
    func save(projectID: String, draft: AutomationDraft) async throws -> Project {
        try await api.request(Routes.project(projectID), method: "PUT", body: draft.payload)
    }
    func preview(projectID: String, prefix: String, script: String) async throws -> FixVersionPreview {
        struct Input: Encodable { let prefix: String; let script: String }
        return try await api.request(Routes.projectFixversionPreview(projectID), method: "POST", body: Input(prefix: prefix, script: script))
    }
    func forwarders() async throws -> [String] { try await api.get(Routes.FORWARDERS) }
}
