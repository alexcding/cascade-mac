import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The session's conversation as a chat, drawn opaquely over its terminal (prototype). The
/// terminal keeps running underneath at its own size, so switching back shows it unchanged.
///
/// Until the agent has been seen at its prompt since it started, the terminal stays in view with
/// a banner over its top edge instead: what the agent asks first (trust this folder, review its
/// hooks) is answered there. One view owns the chat's lifetime either way, so moving from the
/// banner to the chat neither stops its polling nor hands its approvals back.
struct TranscriptChatOverlay: View {
    @Bindable var chat: TranscriptChatModel
    let busy: Bool
    /// Known to be at its prompt, where typing is safe.
    let idle: Bool
    /// When this app started the agent, if it did.
    let startedAt: Date?
    /// The workspace is the one on screen. A hidden page cannot take the keyboard, so a focus
    /// request waits for this.
    let active: Bool
    /// The chat began or stopped covering the terminal, which takes or gives up the keyboard.
    let coverChanged: () -> Void
    @State private var choosingFiles = false
    @State private var dropTargeted = false

    private static let column: CGFloat = 740

    private struct AgentState: Equatable { let busy: Bool, idle: Bool, startedAt: Date? }

    var body: some View {
        ZStack(alignment: .top) {
            if chat.coversTerminal { conversation } else { waiting }
        }
        .onAppear { chat.appear() }
        .onDisappear { chat.disappear() }
        .onChange(of: AgentState(busy: busy, idle: idle, startedAt: startedAt), initial: true) { _, state in
            chat.setAgentState(busy: state.busy, idle: state.idle, startedAt: state.startedAt)
        }
        .onChange(of: chat.coversTerminal) { _, _ in coverChanged() }
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

    /// Only as big as its text, over the terminal's top edge like the terminal's own notices.
    private var waiting: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Theme.textSecondary)
            Text(String(localized: "Chat opens once \(chat.agentName) is ready. Answer anything it asks here first."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(String(localized: "Open Chat"), action: chat.openChat).buttonStyle(.link)
        }
        .font(Theme.Typography.emptyHint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.paneBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: Theme.Size.hairline))
        .padding(10)
        .accessibilityIdentifier("transcript-chat-waiting")
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
            if let notice = chat.hookNotice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notice).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "Hook Settings"), action: chat.openHookSettings).buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 4)
            }
            if chat.queuedPrompt != nil {
                HStack(spacing: 10) {
                    Text(String(localized: "Sends when \(chat.agentName) is back at its prompt")).font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button(String(localized: "Cancel"), action: chat.cancelQueued).buttonStyle(.link).font(.caption)
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
                                  placeholder: String(localized: "Ask \(chat.agentName) anything, / for commands, @ for files"),
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
            Image(systemName: row.kind == .command ? "command" : "doc")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
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
}

/// Takes Escape in its window for as long as it is in one; leaving the window removes the monitor.
/// A key the field is composing with an input method is the input method's to cancel.
private struct EscapeCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, event.keyCode == 53,
                      window.attachedSheet == nil,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                self.action?()
                return nil
            }
        }
    }
}

