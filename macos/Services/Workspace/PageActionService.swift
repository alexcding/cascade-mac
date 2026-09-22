import SwiftUI

@MainActor protocol PageActionServing {
    func openPage(_ request: OpenPageRequest) async throws
    /// The session the page already has, so a row can mark it and its menu say Go to Session.
    func pageSession(_ request: OpenPageRequest) -> PageSessionMark?
}

extension PageActionServing {
    func pageSession(_ request: OpenPageRequest) -> PageSessionMark? { nil }
}

/// What a list row shows of the session its page has: the agent running it.
struct PageSessionMark: Equatable, Sendable {
    /// `claude`, `codex`, or empty for a plain shell.
    let cli: String
    init(cli: String?) { self.cli = cli ?? "" }
    init(_ session: WorkspaceSession) { self.init(cli: session.cli) }
    /// The agent's glyph, as the sidebar draws it.
    var glyph: String { switch cli { case "claude": "✻"; case "codex": "⠿"; default: "❯" } }
    /// The agent's mark in the asset catalogue; a shell has none.
    var asset: String? { switch cli { case "claude": "AgentClaude"; case "codex": "AgentCodex"; default: nil } }
    var agentName: String { switch cli { case "claude": "Claude Code"; case "codex": "Codex"; default: "shell" } }
    /// The one-word form for tight columns: "Claude", "Codex" or "Shell".
    var shortName: String { switch cli { case "claude": "Claude"; case "codex": "Codex"; default: "Shell" } }
    var label: String { "Has a \(agentName) session" }
}

@MainActor struct NativePageActionService: PageActionServing {
    let open: (OpenPageRequest) async throws -> Void
    var session: (OpenPageRequest) -> PageSessionMark? = { _ in nil }

    func openPage(_ request: OpenPageRequest) async throws { try await open(request) }
    func pageSession(_ request: OpenPageRequest) -> PageSessionMark? { session(request) }
}

/// Where a row opens: its session's agent glyph, or a globe for a row with no session, which opens a
/// tab. Grey like the sidebar at rest: the row's colour belongs to its status, not its agent.
struct PageDestinationMark: View {
    let mark: PageSessionMark?
    var body: some View {
        Group {
            if let mark {
                Text(mark.glyph).font(.system(size: mark.cli == "codex" ? 16 : 14, weight: mark.cli == "claude" ? .ultraLight : .regular)).foregroundStyle(.secondary)
                    .help(mark.label).accessibilityLabel(mark.label)
            } else {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .help("Opens in a tab").accessibilityLabel("Opens in a tab")
            }
        }.frame(width: 18, height: 18)
    }
}

/// The row menu for a PR or ticket. The first item is what a click does: the page's session when it
/// has one, else a tab; the other way of opening follows. Open in Tab always makes a tab, behind the
/// current screen, even for a page with a session. A new session is started with the agent picked
/// from the submenu.
struct PageRowMenu: View {
    /// The agents a New Session menu offers, in menu order.
    static let agents: [SessionAgent] = [.claude, .codex, .shell]
    let hasSession: Bool
    let open: () -> Void
    let session: (SessionAgent?) -> Void
    var body: some View {
        if hasSession {
            Button("Go to Session") { session(nil) }; Button("Open in Tab", action: open)
        } else {
            Button("Open in Tab", action: open)
            Menu("New Session") { ForEach(Self.agents) { agent in Button(agent.label) { session(agent) } } }
        }
    }
}
