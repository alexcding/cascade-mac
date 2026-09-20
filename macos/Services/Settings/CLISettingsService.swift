import Foundation

enum ManagedCLI: String, CaseIterable, Identifiable, Sendable {
    /// `ghWebhook` is not a program of its own: it is gh's `cli/gh-webhook` extension, which the
    /// backend's webhook forwarders run. The backend reports it beside the CLIs.
    case claude, codex, gh, ghWebhook, acli
    var id: String { rawValue }
    var title: String { switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .gh: "GitHub CLI"; case .ghWebhook: "GitHub webhooks (gh extension)"; case .acli: "Atlassian CLI" } }
    var supportsHooks: Bool { self == .claude || self == .codex }
    /// An extension is only ever installed or not: it has no sign-in of its own to report.
    var isExtension: Bool { self == .ghWebhook }
    var loginCommand: String? { switch self { case .gh: "gh auth login"; case .acli: "acli jira auth login"; default: nil } }
    /// A one-line install, for tools that have one worth copying.
    var installCommand: String? { self == .ghWebhook ? "gh extension install cli/gh-webhook" : nil }
    var installationGuide: URL {
        let address: String = switch self {
        case .claude: "https://docs.claude.com/en/docs/claude-code/setup"
        case .codex: "https://github.com/openai/codex"
        case .gh: "https://cli.github.com"
        case .ghWebhook: "https://github.com/cli/gh-webhook"
        case .acli: "https://developer.atlassian.com/cloud/acli/guides/install-macos/"
        }
        return URL(string: address)!
    }
}

struct CLIAvailability: Decodable, Sendable {
    let present: Bool
    var authed: Bool?
    func label(for cli: ManagedCLI) -> String {
        guard present else { return cli.isExtension ? "Not installed" : "Not found" }
        if cli.supportsHooks || cli.isExtension { return "Installed" }
        switch authed {
        case true: return "Signed in"
        case false: return "Not signed in"
        default: return "Installed; sign-in status unavailable"
        }
    }
}

protocol CLISettingsService: Sendable {
    func probe() async throws -> [String: CLIAvailability]
    func hooks() async throws -> [String: String]
    func setHook(_ cli: ManagedCLI, installed: Bool) async throws -> [String: String]
    /// Craft's Claude Code status line, installed for every session. It reports in the same
    /// status map as the hooks, under `statusLineKey`.
    func setStatusLine(installed: Bool) async throws -> [String: String]
}
extension CLISettingsService {
    static var statusLineKey: String { "claude-statusline" }
    func setStatusLine(installed: Bool) async throws -> [String: String] {
        throw BackendError.operation("This backend cannot change the status line.")
    }
}

struct APICLISettingsService: CLISettingsService {
    let api: APIClient
    func probe() async throws -> [String: CLIAvailability] { try await api.get(Routes.CLI_TOOLS, timeout: 30) }
    func hooks() async throws -> [String: String] { try await api.get(Routes.AGENT_HOOKS) }
    func setHook(_ cli: ManagedCLI, installed: Bool) async throws -> [String: String] {
        struct Result: Decodable, Sendable { let status: [String: String] }
        let result: Result = try await api.request(Routes.agentHook(cli.rawValue), method: installed ? "POST" : "DELETE", body: [String: String]())
        return result.status
    }
    func setStatusLine(installed: Bool) async throws -> [String: String] {
        struct Result: Decodable, Sendable { let status: [String: String] }
        let result: Result = try await api.request(Routes.agentHook(Self.statusLineKey), method: installed ? "POST" : "DELETE", body: [String: String]())
        return result.status
    }
}
