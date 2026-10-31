import Foundation

enum ManagedCLI: String, CaseIterable, Identifiable, Sendable {
    /// `ghWebhook` is not a program of its own: it is gh's `cli/gh-webhook` extension, which the
    /// backend's webhook forwarders run. The backend reports it beside the CLIs.
    /// `ghWebhook` is optional too: polling catches every change without it, so it sits in the
    /// GitHub webhooks card rather than the CLI list.
    case claude, codex, gh, ghWebhook, acli
    var id: String { rawValue }
    /// The agent CLI's driver, for the tools that are agents; its facts are the driver's.
    var agent: (any AgentDriver)? { AgentDrivers.of(rawValue) }
    var title: String {
        if let agent { return agent.name }
        return switch self {
        case .gh: "GitHub CLI"; case .ghWebhook: String(localized: "gh webhook extension")
        case .acli: "Atlassian CLI"
        default: rawValue
        }
    }
    var supportsHooks: Bool { agent != nil }
    /// An extension is only ever installed or not: it has no sign-in of its own to report.
    var isExtension: Bool { self == .ghWebhook }
    static var required: [ManagedCLI] { allCases.filter { !$0.isExtension } }
    static var webhooks: [ManagedCLI] { allCases.filter(\.isExtension) }
    var loginCommand: String? { switch self { case .gh: "gh auth login"; case .acli: "acli jira auth login"; default: nil } }
    /// A one-line install, for tools that have one worth copying whatever else is installed.
    var installCommand: String? { self == .ghWebhook ? "gh extension install cli/gh-webhook" : nil }
    var installationGuide: URL {
        if let agent { return agent.installationGuide }
        let address: String = switch self {
        case .gh: "https://cli.github.com"
        case .ghWebhook: "https://github.com/cli/gh-webhook"
        case .acli: "https://developer.atlassian.com/cloud/acli/guides/install-macos/"
        default: "https://github.com"
        }
        return URL(string: address)!
    }
}

struct CLIAvailability: Decodable, Sendable {
    let present: Bool
    var authed: Bool?
    func label(for cli: ManagedCLI) -> String {
        guard present else { return cli.isExtension ? String(localized: "Not installed") : String(localized: "Not found") }
        if cli.supportsHooks || cli.isExtension { return String(localized: "Installed") }
        switch authed {
        case true: return String(localized: "Signed in")
        case false: return String(localized: "Not signed in")
        default: return String(localized: "Installed; sign-in status unavailable")
        }
    }
}

protocol CLISettingsService: Sendable {
    func probe() async throws -> [String: CLIAvailability]
    func hooks() async throws -> [String: String]
    func setHook(_ cli: ManagedCLI, installed: Bool) async throws -> [String: String]
    /// Cascade's Claude Code status line, installed for every session. It reports in the same
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
