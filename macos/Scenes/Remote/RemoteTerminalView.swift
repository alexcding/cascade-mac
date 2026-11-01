import SwiftUI

/// A paired Mac's session, opened here: its agent's terminal on that Mac, live, typed into from
/// this one. The agent runs there with that Mac's CLI and sign-ins; this Mac only attaches. The
/// terminal keeps that Mac's size, so the view shows it as large as it is there.
@MainActor @Observable final class RemoteTerminalModel {
    let peer: String
    let sessionID: String
    let terminal: TerminalSession
    private(set) var title: String
    private(set) var macName: String
    @ObservationIgnored private var retired = false
    /// Asks the app for a fresh connection, after this one failed or its terminal ended.
    @ObservationIgnored var onReconnect: () -> Void = {}

    init(peer: String, session: WorkspaceSession, macName: String, terminal: TerminalSession) {
        self.peer = peer
        sessionID = session.id
        title = session.label
        self.macName = macName
        self.terminal = terminal
    }

    func update(session: WorkspaceSession, macName: String) {
        guard !retired else { return }
        if title != session.label { title = session.label }
        if self.macName != macName { self.macName = macName }
    }

    func setStyle(_ style: TerminalStyle) {
        guard !retired else { return }
        terminal.presentation.style = style
    }

    /// Whether this connection is over and will not come back by itself: it failed, or the
    /// terminal there ended. A new model attaches again.
    var isOver: Bool {
        switch terminal.connectionState {
        case .reconnecting: return false
        case .exited, .disconnected: return true
        default: return terminal.error != nil
        }
    }

    func reconnect() {
        guard !retired else { return }
        onReconnect()
    }

    /// The session or its Mac is gone: the connection ends and the model is done.
    func retire() {
        guard !retired else { return }
        retired = true
        terminal.disconnect()
    }
}

struct RemoteTerminalView: View {
    let model: RemoteTerminalModel

    var body: some View {
        TerminalPane(session: model.terminal)
            .overlay(alignment: .bottom) {
                if model.isOver {
                    Button(String(localized: "Reconnect")) { model.reconnect() }
                        .accessibilityIdentifier("remote-terminal-reconnect")
                        .padding(16)
                }
            }
            .accessibilityIdentifier("remote-terminal")
    }
}

extension RemoteTerminalModel: HashableObject {}
