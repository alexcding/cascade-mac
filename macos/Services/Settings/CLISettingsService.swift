import Foundation

enum ManagedCLI: String, CaseIterable, Identifiable, Sendable {
    /// `ghWebhook` is not a program of its own: it is gh's `cli/gh-webhook` extension, which the
    /// backend's webhook forwarders run. The backend reports it beside the CLIs.
    /// `node` and `serveSim` are the Simulator panel's: optional, so first-run setup never asks for them.
    case claude, codex, gh, ghWebhook, acli, node, serveSim
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"; case .codex: "Codex"; case .gh: "GitHub CLI"; case .ghWebhook: "GitHub webhooks (gh extension)"
        case .acli: "Atlassian CLI"; case .node: "Node.js 20 or later"; case .serveSim: "serve-sim"
        }
    }
    var supportsHooks: Bool { self == .claude || self == .codex }
    /// An extension is only ever installed or not: it has no sign-in of its own to report.
    var isExtension: Bool { self == .ghWebhook }
    var isSimulatorPreview: Bool { self == .node || self == .serveSim }
    static var required: [ManagedCLI] { allCases.filter { !$0.isSimulatorPreview } }
    static var simulatorPreview: [ManagedCLI] { allCases.filter(\.isSimulatorPreview) }
    var loginCommand: String? { switch self { case .gh: "gh auth login"; case .acli: "acli jira auth login"; default: nil } }
    /// A one-line install, for tools that have one worth copying whatever else is installed.
    /// Node's depends on Homebrew: `CLIAvailability.installCommand(for:homebrew:)`. serve-sim
    /// has none — `npx` fetches it, so Node is all it needs.
    var installCommand: String? { self == .ghWebhook ? "gh extension install cli/gh-webhook" : nil }
    var installationGuide: URL {
        let address: String = switch self {
        case .claude: "https://docs.claude.com/en/docs/claude-code/setup"
        case .codex: "https://github.com/openai/codex"
        case .gh: "https://cli.github.com"
        case .ghWebhook: "https://github.com/cli/gh-webhook"
        case .acli: "https://developer.atlassian.com/cloud/acli/guides/install-macos/"
        case .node: "https://nodejs.org/en/download"
        case .serveSim: "https://github.com/expo/serve-sim"
        }
        return URL(string: address)!
    }
}

struct CLIAvailability: Decodable, Sendable {
    let present: Bool
    var authed: Bool?
    /// Node only: what `node --version` printed, and whether serve-sim can run on it.
    var version: String?
    var supported: Bool?
    /// Node: which installer put it there (`Homebrew`, `installer`, `nvm`, `fnm`, `Volta`, `asdf`,
    /// `mise`, `nodenv`, `other`). serve-sim: `installed`, or `npx` when it is fetched on use.
    var source: String?
    /// serve-sim only: what keeps it from running — `node` (none, or older than 20) or `npx`.
    var needs: String?
    /// Present, but not confirmed usable: Node older than 20, or a version nobody could read.
    /// Only a confirmed 20 or later counts, so an unreadable version warns rather than passes.
    func outdated(for cli: ManagedCLI) -> Bool { cli == .node && present && supported != true }
    /// The command worth copying for this state. Node through Homebrew only where there is one:
    /// upgrade a Homebrew Node, install one beside any other. A version manager's Node is the
    /// user's to update in that manager, so the guide covers it.
    func installCommand(for cli: ManagedCLI, homebrew: Bool) -> String? {
        guard cli == .node else { return cli.installCommand }
        guard homebrew, !present || outdated(for: cli) else { return nil }
        if present && source != "Homebrew" && source != "installer" { return nil }
        return present && source == "Homebrew" ? "brew upgrade node" : "brew install node"
    }
    func label(for cli: ManagedCLI) -> String {
        if cli == .serveSim {
            guard present else { return needs == "npx" ? "Needs npx, which comes with npm" : "Needs Node.js 20 or later" }
            return source == "npx" ? "Fetched automatically on first use" : "Installed"
        }
        guard present else { return cli.isExtension ? "Not installed" : "Not found" }
        if cli == .node {
            let via = source.flatMap(Self.sourceName).map { " · \($0)" } ?? ""
            switch (supported, version) {
            case (true, let version?): return "Installed · \(version)\(via)"
            case (false, let version?): return "\(version)\(via), needs 20 or later"
            default: return "Installed · version unknown"
            }
        }
        if cli.supportsHooks || cli.isExtension || cli.isSimulatorPreview { return "Installed" }
        switch authed {
        case true: return "Signed in"
        case false: return "Not signed in"
        default: return "Installed; sign-in status unavailable"
        }
    }
    private static func sourceName(_ source: String) -> String? {
        switch source {
        case "installer": "Node.js installer"
        case "other": nil
        default: source
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
