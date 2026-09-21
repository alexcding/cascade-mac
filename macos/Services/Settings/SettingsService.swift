import Foundation

struct AppConfigDraft: Equatable, Sendable {
    var pollInterval = "60"
    var jiraPollInterval = "120"
    var jiraLimit = "100"
    var jiraBaseURL = ""
    var jiraAPIToken = ""

    init(_ values: [String: String] = [:]) {
        pollInterval = values["poll_interval"] ?? "60"
        jiraPollInterval = values["jira_poll_interval"] ?? "120"
        jiraLimit = values["jira_limit"] ?? "100"
        jiraBaseURL = values["jira_base_url"] ?? ""
        jiraAPIToken = values["jira_api_token"] ?? ""
    }
    var values: [String: String] {
        ["poll_interval": pollInterval, "jira_poll_interval": jiraPollInterval, "jira_limit": jiraLimit,
         "jira_base_url": jiraBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
         "jira_api_token": jiraAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    var validationError: String? {
        guard let interval = Int(pollInterval), (15...86400).contains(interval) else { return "PR polling must be between 15 and 86400 seconds." }
        guard let interval = Int(jiraPollInterval), (30...86400).contains(interval) else { return "Jira polling must be between 30 and 86400 seconds." }
        guard let limit = Int(jiraLimit), (1...10000).contains(limit) else { return "The ticket limit must be between 1 and 10000." }
        let raw = jiraBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            guard let url = safeWebURL(raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.query == nil, parts.fragment == nil else { return "Enter a Jira HTTP or HTTPS site URL without credentials, query, or fragment." }
        }
        return nil
    }
}

struct ReviewSound: Decodable, Identifiable, Sendable {
    let name: String
    let path: String
    var id: String { path }
}

protocol SettingsService: Sendable {
    func config() async throws -> [String: String]
    func save(_ patch: [String: String]) async throws
    func sounds() async throws -> [ReviewSound]
}

struct APISettingsService: SettingsService {
    let api: APIClient
    func config() async throws -> [String: String] { try await api.get(Routes.CONFIG) }
    func save(_ patch: [String: String]) async throws {
        let _: OperationOK = try await api.request(Routes.CONFIG, method: "POST", body: patch)
    }
    func sounds() async throws -> [ReviewSound] { try await api.get(Routes.SOUNDS) }
}

/// General holds the app appearance, startup and behaviour preferences; Browser is the embedded
/// browser's data and ad blocking; Terminal is
/// everything the Ghostty surface is configured from, including its own font; Text Editor is the
/// code font, the code themes and the editor's preview; CLIs carries every tool connection
/// including Jira; System is the read-only diagnostics; Activity is the event log, which has its
/// own coordinator and is not a form.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", browser = "Browser", terminal = "Terminal", editor = "Text Editor", clis = "Integrations", shortcuts = "Shortcuts", system = "System", activity = "Activity"
    var id: String { rawValue }
}

/// What "Clear…" under Browser removes. History is the app's own visit list; website
/// data is everything WebKit stores for the embedded browser (cookies, caches, local storage).
enum BrowsingDataScope: String, CaseIterable, Identifiable, Sendable {
    case history, websiteData
    var id: String { rawValue }
    var title: String { self == .history ? "Browsing history" : "Cookies and site data" }
    var buttonTitle: String { self == .history ? "Clear History…" : "Clear Cookies…" }
    var clearedNotice: String { self == .history ? "Browsing history cleared." : "Cookies and site data cleared." }
}
