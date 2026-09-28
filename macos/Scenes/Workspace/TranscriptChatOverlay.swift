import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The session's conversation as a chat, drawn opaquely over its terminal (prototype). The
/// terminal keeps running underneath at its own size, so switching back shows it unchanged.
///
/// It covers the terminal from the moment it is shown, even while the agent is still starting: a
/// message written before the agent is at its prompt is held (`TranscriptChatModel.deliverable`),
/// so it cannot answer a question the agent asks first in the terminal.
struct TranscriptChatOverlay: View {
    @Bindable var chat: TranscriptChatModel
    let busy: Bool
    /// Known to be at its prompt, where typing is safe.
    let idle: Bool
    /// May be showing an approval or a question in the terminal, which typing would answer.
    let asking: Bool
    /// When this app started the agent, if it did.
    let startedAt: Date?
    /// The workspace is the one on screen. A hidden page cannot take the keyboard, so a focus
    /// request waits for this.
    let active: Bool
    /// What the empty message field reads.
    let placeholder: String
    @State private var choosingFiles = false
    @State private var dropTargeted = false

    private static let column: CGFloat = 740

    private struct AgentState: Equatable { let busy: Bool, idle: Bool, asking: Bool, startedAt: Date? }

    var body: some View {
        conversation
            .onAppear { chat.appear() }
            .onDisappear { chat.disappear() }
            .onChange(of: AgentState(busy: busy, idle: idle, asking: asking, startedAt: startedAt), initial: true) { _, state in
                chat.setAgentState(busy: state.busy, idle: state.idle, asking: state.asking, startedAt: state.startedAt)
            }
            .accessibilityIdentifier("transcript-chat")
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
    }

    /// The conversation itself is the bundled chat page (`TranscriptChatPage`); only the composer
    /// is native, so typing never waits on the page.
    @ViewBuilder private var transcript: some View {
        if let page = chat.page {
            BrowserSurface(webView: page.webView)
        } else {
            Spacer()
        }
    }

    private var modelName: String {
        chat.turns.last { $0.model != nil }?.model ?? chat.agentName
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = chat.error {
                Text(error).font(.caption).foregroundStyle(Theme.danger).lineLimit(2).padding(.horizontal, 4)
            }
            // The conversation shows a held message as waiting; these take it back or push it on.
            if chat.queuedPrompt != nil {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(String(localized: "Cancel"), action: chat.cancelQueued).buttonStyle(.link).font(.caption)
                        .disabled(chat.sending && !chat.paused)
                    Button(String(localized: "Send Now")) { Task { await chat.sendQueuedNow() } }
                        .buttonStyle(.link).font(.caption)
                        .disabled(!chat.canSendQueuedNow)
                        .help(String(localized: "Types it into the terminal now. If the agent is asking something there, this answers it."))
                }
                .padding(.horizontal, 4)
            }
            // A card of its own just above the field, as wide as it: the conversation makes room.
            if !chat.suggestions.isEmpty {
                ChatSuggestionList(suggestions: chat.suggestions, highlighted: chat.highlighted,
                                   dismiss: { chat.dismissSuggestions() }) { index in
                    Task { await chat.acceptSuggestion(index) }
                }
                .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 14) {
                // Takes the keyboard from the terminal when it appears, and again when a session
                // switched to by its shortcut asks for it: the terminal stays in the window
                // underneath and would otherwise keep it.
                ChatComposerField(chat: chat, text: chat.draft, files: chat.attachments, caret: chat.caret,
                                  focusRequest: chat.focusRequest, active: active,
                                  placeholder: placeholder,
                                  dropTargeted: $dropTargeted)
                HStack(spacing: 12) {
                    Button { choosingFiles = true } label: {
                        Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(!chat.canAttach)
                    .help("Attach files to your message. Remove a file’s chip to detach it.")
                    Spacer()
                    Text(modelName).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Button {
                        Task { await chat.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            .frame(width: 30, height: 30)
                            .background(chat.canSend ? Color.primary : Theme.textTertiary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!chat.canSend)
                    .help(String(localized: "Send to the terminal"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(dropTargeted ? Theme.accent : Theme.border, lineWidth: dropTargeted ? 2 : Theme.Size.hairline))
            .onDrop(of: ChatAttachmentReader.dropTypes, isTargeted: $dropTargeted) { providers in
                chat.canAttach && ChatAttachmentReader.drop(providers, into: chat)
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { chat.attach(ChatAttachmentReader.files(urls)) }
            }
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 6)
        .frame(maxWidth: Self.column + 48)
        .frame(maxWidth: .infinity)
    }
}

/// The rows over the message field: what `/` or `@` is completing to. The field keeps the
/// keyboard; the arrows move the highlight and Tab or Return take it. Escape closes it wherever
/// the keyboard is in its window, since the field can lose it while the list stays up.
struct ChatSuggestionList: View {
    let suggestions: [ChatSuggestion]
    let highlighted: Int
    let dismiss: () -> Void
    let choose: (Int) -> Void

    private static let rowHeight: CGFloat = 32
    private static let visibleRows = 6

    static func height(showing count: Int) -> CGFloat { CGFloat(min(count, visibleRows)) * rowHeight + 12 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, row in
                        Button { choose(index) } label: { label(row, highlighted: index == highlighted) }
                            .buttonStyle(.plain)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: Self.height(showing: suggestions.count))
            .onChange(of: highlighted) { _, index in
                if suggestions.indices.contains(index) { proxy.scrollTo(suggestions[index].id) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: Theme.Size.hairline))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .background(EscapeCatcher(action: dismiss))
        .accessibilityIdentifier("transcript-chat-suggestions")
    }

    private func label(_ row: ChatSuggestion, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if row.kind == .command {
                symbol("command")
            } else {
                // The title is the mention: "@" and the path, each escaped character after a backslash.
                FileIcon(name: String(row.title.dropFirst()).replacing(/\\(.)/) { String($0.1) }) { symbol("doc") }
            }
            Text(row.title)
                .font(.system(size: 14))
                .lineLimit(1)
                .layoutPriority(1)
            Text(row.detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(row.kind == .file ? .head : .tail)
            Spacer(minLength: 8)
            if let badge = row.badge {
                Text(badge).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).frame(width: 16)
    }
}

/// Takes Escape in its window for as long as it is in one; leaving the window removes the monitor.
/// A key the field is composing with an input method is the input method's to cancel, and a list
/// on a session page the deck keeps hidden is not the one on screen.
private struct EscapeCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        /// Removed with the view too: a window closed under it frees the view without moving it.
        private var monitor: Monitor?

        final class Monitor: @unchecked Sendable {
            let token: Any
            init(_ token: Any) { self.token = token }
            deinit { NSEvent.removeMonitor(token) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor = nil
            guard window != nil else { return }
            let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, event.keyCode == 53,
                      !self.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                self.action?()
                return nil
            }
            monitor = token.map(Monitor.init)
        }
    }
}

