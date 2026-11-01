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
    /// What the empty message field reads in Chat.
    let placeholder: String
    /// The conversation as a chat over the terminal, as a session's Chat mode on this Mac is: read
    /// from that Mac's transcript, typed into its terminal here.
    private(set) var showsChat = false
    private(set) var chat: TranscriptChatModel?
    @ObservationIgnored private var retired = false
    /// Asks the app for a fresh connection, after this one failed or its terminal ended.
    @ObservationIgnored var onReconnect: () -> Void = {}
    /// Asks that Mac to start the session's terminal and agent there, as Reattach does, when it
    /// is not running; nothing when it is.
    @ObservationIgnored var onStart: () async throws -> Void = {}
    /// Starting it there, and why that failed.
    private(set) var starting = false
    private(set) var startError: String?
    /// Makes the chat on first show; nil for a session that runs no agent.
    @ObservationIgnored var makeChat: (() -> TranscriptChatModel)?
    /// The agent's state as that Mac's app last reported it.
    @ObservationIgnored var agentState: () -> RemoteSessionStatus? = { nil }

    init(peer: String, session: WorkspaceSession, macName: String, terminal: TerminalSession) {
        self.peer = peer
        sessionID = session.id
        title = session.label
        placeholder = session.agent.chatPlaceholder
        self.macName = macName
        self.terminal = terminal
    }

    var canShowChat: Bool { !retired && makeChat != nil }
    private var chatModeKey: String { "remote.chatMode.\(peer).\(sessionID)" }
    /// Chat or Terminal, as last chosen for this session here.
    var chosenChat: Bool { UserDefaults.standard.bool(forKey: chatModeKey) }

    func setChatShown(_ shown: Bool) {
        guard canShowChat else { return }
        UserDefaults.standard.set(shown, forKey: chatModeKey)
        if shown, chat == nil { chat = makeChat?() }
        terminal.coveredByChat = shown
        if showsChat != shown { showsChat = shown }
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

    /// Never attached: the session is not running there, so it is started first.
    var neverAttached: Bool { terminal.shellPID == nil }

    /// Starts the session there if it is not running, then attaches afresh.
    func reconnect() {
        guard !retired, !starting else { return }
        starting = true; startError = nil
        Task { [weak self] in
            guard let self else { return }
            // Running there, as that Mac says, it is only attached to again.
            if agentState()?.live != true {
                do { try await onStart() } catch { startError = error.localizedDescription }
            }
            starting = false
            // A start that failed still attaches to a terminal attached before: an older Cascade
            // there, or one busy with the session, may yet have it running.
            guard !retired, startError == nil || !neverAttached else { return }
            onReconnect()
        }
    }

    /// The session or its Mac is gone: the connection ends and the model is done.
    func retire() {
        guard !retired else { return }
        retired = true
        chat?.retire()
        terminal.disconnect()
    }
}

struct RemoteTerminalView: View {
    let model: RemoteTerminalModel

    var body: some View {
        TerminalPane(session: model.terminal)
            .allowsHitTesting(!model.showsChat)
            .overlay(alignment: .top) {
                if model.showsChat, let chat = model.chat {
                    let state = model.agentState()
                    TranscriptChatOverlay(chat: chat, workspace: nil, busy: state?.busy == true, idle: state?.idle == true,
                                          asking: state?.needsInput == true, startedAt: nil, active: true,
                                          placeholder: model.placeholder)
                }
            }
            .overlay(alignment: .bottom) {
                if model.isOver {
                    VStack(spacing: 8) {
                        if let error = model.startError {
                            Text(error).font(.caption).foregroundStyle(Theme.danger)
                        }
                        Button(model.neverAttached ? String(localized: "Start on \(model.macName)") : String(localized: "Reconnect")) {
                            model.reconnect()
                        }
                        .disabled(model.starting)
                        .accessibilityIdentifier("remote-terminal-reconnect")
                    }
                    .padding(16)
                }
            }
            .accessibilityIdentifier("remote-terminal")
    }
}

extension RemoteTerminalModel: HashableObject {}
