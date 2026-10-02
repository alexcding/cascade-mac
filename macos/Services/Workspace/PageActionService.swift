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
    /// The agent CLI's id, or empty for a plain shell.
    let cli: String
    init(cli: String?) { self.cli = cli ?? "" }
    init(_ session: WorkspaceSession) { self.init(cli: session.cli) }
    private var agent: (any AgentDriver)? { AgentDrivers.of(cli) }
    /// The agent's glyph, as the sidebar draws it.
    var glyph: String { agent?.restingGlyph ?? "❯" }
    /// The agent's mark in the asset catalogue; a shell has none.
    var asset: String? { agent?.asset }
    var agentName: String { agent?.name ?? String(localized: "Shell") }
    /// The one-word form for tight columns: the agent's, or "Shell".
    var shortName: String { agent?.shortName ?? String(localized: "Shell") }
    /// The face its glyph is set in.
    var glyphFont: Font { agent?.markGlyphFont ?? .system(size: 14) }
    var label: String { asset == nil ? String(localized: "Has a shell session") : String(localized: "Has a \(agentName) session") }
}

@MainActor struct NativePageActionService: PageActionServing {
    let open: (OpenPageRequest) async throws -> Void
    var session: (OpenPageRequest) -> PageSessionMark? = { _ in nil }

    func openPage(_ request: OpenPageRequest) async throws { try await open(request) }
    func pageSession(_ request: OpenPageRequest) -> PageSessionMark? { session(request) }
}

/// Where a row opens: its session's agent glyph, or a mark for a row with no session, whose click
/// opens its project's Start to begin one. Grey like the sidebar at rest: the row's colour belongs to its status, not its agent.
struct PageDestinationMark: View {
    let mark: PageSessionMark?
    var body: some View {
        Group {
            if let mark {
                Text(mark.glyph).font(mark.glyphFont).foregroundStyle(.secondary)
                    .help(mark.label).accessibilityLabel(mark.label)
            } else {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .help(String(localized: "Opens a new session")).accessibilityLabel(String(localized: "Opens a new session"))
            }
        }.frame(width: 18, height: 18)
    }
}

/// The row menu for a PR or ticket: Go to Session when the page has one, else New Session, which
/// opens its project's Start with the page filled in — where a click goes too, named — and Open in
/// Browser, the one way to reach the page outside Cascade.
struct PageRowMenu: View {
    let hasSession: Bool
    var url: URL? = nil
    let open: () -> Void
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button(hasSession ? String(localized: "Go to Session") : String(localized: "New Session"), action: open)
        if let url { Button(String(localized: "Open in Browser")) { openURL(url) } }
    }
}
