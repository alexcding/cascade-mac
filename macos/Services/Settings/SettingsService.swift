import Foundation

struct AppConfigDraft: Equatable, Sendable {
    var pollInterval = "60"
    var jiraPollInterval = "120"
    var jiraLimit = "100"
    var jiraBaseURL = ""
    var jiraAPIToken = ""
    var worktreeLocation = WorktreeLocation.sibling
    var worktreeRoot = ""
    var worktreeInclude = WorktreeLocation.defaultInclude
    var worktreeDeleteBranch = false
    var worktreeFetch = false

    init(_ values: [String: String] = [:]) {
        pollInterval = values["poll_interval"] ?? "60"
        jiraPollInterval = values["jira_poll_interval"] ?? "120"
        jiraLimit = values["jira_limit"] ?? "100"
        jiraBaseURL = values["jira_base_url"] ?? ""
        jiraAPIToken = values["jira_api_token"] ?? ""
        worktreeLocation = values["worktree_location"].flatMap(WorktreeLocation.init(rawValue:)) ?? .sibling
        worktreeRoot = values["worktree_root"] ?? ""
        worktreeInclude = values["worktree_include"] ?? WorktreeLocation.defaultInclude
        worktreeDeleteBranch = values["worktree_delete_branch"] == "true"
        worktreeFetch = values["worktree_fetch"] == "true"
    }
    var values: [String: String] {
        ["poll_interval": pollInterval, "jira_poll_interval": jiraPollInterval, "jira_limit": jiraLimit,
         "jira_base_url": jiraBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
         "jira_api_token": jiraAPIToken.trimmingCharacters(in: .whitespacesAndNewlines),
         "worktree_location": worktreeLocation.rawValue,
         "worktree_root": worktreeRoot.trimmingCharacters(in: .whitespacesAndNewlines),
         "worktree_include": worktreeInclude,
         "worktree_delete_branch": worktreeDeleteBranch ? "true" : "false",
         "worktree_fetch": worktreeFetch ? "true" : "false"]
    }
    var validationError: String? {
        guard let interval = Int(pollInterval), (15...86400).contains(interval) else { return String(localized: "PR polling must be between 15 and 86400 seconds.") }
        guard let interval = Int(jiraPollInterval), (30...86400).contains(interval) else { return String(localized: "Jira polling must be between 30 and 86400 seconds.") }
        guard let limit = Int(jiraLimit), (1...10000).contains(limit) else { return String(localized: "The ticket limit must be between 1 and 10000.") }
        let raw = jiraBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            guard let url = safeWebURL(raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.query == nil, parts.fragment == nil else { return String(localized: "Enter a Jira HTTP or HTTPS site URL without credentials, query, or fragment.") }
        }
        if worktreeLocation == .custom {
            let root = worktreeRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard root.hasPrefix("/") || root == "~" || root.hasPrefix("~/") else { return String(localized: "Choose a folder for new worktrees.") }
        }
        return nil
    }
}

/// Where the backend makes a session's new worktree (`crates/cascade-backend/src/worktrees.rs`).
/// Existing worktrees stay where they are: git's own worktree list is what finds them.
enum WorktreeLocation: String, CaseIterable, Identifiable, Sendable {
    case sibling, inside, custom
    /// What the backend copies when neither Settings nor the repo's `.worktreeinclude` names patterns.
    static let defaultInclude = ".env*"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sibling: String(localized: "Next to the project")
        case .inside: String(localized: "Inside the project")
        case .custom: String(localized: "Custom folder")
        }
    }
    var example: String {
        switch self {
        case .sibling: "<project>.worktrees/<branch>"
        case .inside: String(localized: "<project>/.worktrees/<branch>; ignored by Git through .git/info/exclude.")
        case .custom: "<folder>/<project folder>-<id>/<branch>"
        }
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
/// code font, the code themes and the editor's preview; Worktrees is where a session's worktree
/// is made and what it gets on the way; CLIs carries every tool connection
/// including Jira; System is the read-only diagnostics; Activity is the event log, which has its
/// own coordinator and is not a form.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", browser = "Browser", worktrees = "Worktrees", terminal = "Terminal", editor = "Text Editor", clis = "Integrations", shortcuts = "Shortcuts", system = "System", activity = "Activity"
    var id: String { rawValue }
}

/// What "Clear…" under Browser removes. History is the app's own visit list; website
/// data is everything WebKit stores for the embedded browser (cookies, caches, local storage).
enum BrowsingDataScope: String, CaseIterable, Identifiable, Sendable {
    case history, websiteData
    var id: String { rawValue }
    var title: String { self == .history ? String(localized: "Browsing history") : String(localized: "Cookies and site data") }
    var buttonTitle: String { self == .history ? String(localized: "Clear History…") : String(localized: "Clear Cookies…") }
    var confirmationTitle: String {
        self == .history ? String(localized: "Clear browsing history?") : String(localized: "Clear cookies and site data?")
    }
    var confirmationMessage: String {
        self == .history
            ? String(localized: "Remove all visited pages from history and address suggestions.")
            : String(localized: "Remove cookies, caches, and site storage from Cascade’s browser. You will be signed out of websites.")
    }
    var clearedNotice: String { self == .history ? String(localized: "Browsing history cleared.") : String(localized: "Cookies and site data cleared.") }
}
