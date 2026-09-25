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
    @State private var focusHandled = 0
    /// Taken from the terminal on appear: it stays in the window underneath and would otherwise
    /// keep the keyboard.
    @FocusState private var composing: Bool
    @State private var choosingFiles = false
    @State private var dropTargeted = false
    @State private var pasteMonitor = ChatPasteMonitor()

    private static let column: CGFloat = 740

    private struct AgentState: Equatable { let busy: Bool, idle: Bool, startedAt: Date? }

    var body: some View {
        ZStack(alignment: .top) {
            if chat.coversTerminal { conversation } else { waiting }
        }
        .onAppear {
            chat.appear()
            if chat.coversTerminal { composing = true }
            // Text is the field's own to paste; files and screenshots become attachments. Only a
            // ⌘V in this chat's window: the field keeps its focus while another window has the keys.
            pasteMonitor.start { [chat] event in
                composing && event.window != nil && event.window === chat.page?.webView.window && chat.canAttach && ChatAttachmentReader.paste(from: .general, into: chat)
            }
        }
        .onDisappear {
            chat.disappear()
            pasteMonitor.stop()
        }
        .onChange(of: AgentState(busy: busy, idle: idle, startedAt: startedAt), initial: true) { _, state in
            chat.setAgentState(busy: state.busy, idle: state.idle, startedAt: state.startedAt)
        }
        .onChange(of: chat.coversTerminal) { _, _ in coverChanged() }
        // A session switched to by its shortcut hands the keyboard here rather than to the terminal.
        .onChange(of: chat.focusRequest) { _, _ in takeFocus() }
        .onChange(of: active) { _, _ in takeFocus() }
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
            Text("Chat opens once \(chat.agentName) is ready. Answer anything it asks here first.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Chat", action: chat.openChat).buttonStyle(.link)
        }
        .font(Theme.Typography.emptyHint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.paneBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: Theme.Size.hairline))
        .padding(10)
        .accessibilityIdentifier("transcript-chat-waiting")
    }

    /// After the pass that shows the page: the deck unhides it in the same update, and focus set
    /// on a view still hidden is dropped.
    private func takeFocus() {
        guard active, chat.coversTerminal, chat.focusRequest != focusHandled else { return }
        let request = chat.focusRequest
        DispatchQueue.main.async {
            guard active, chat.coversTerminal else { return }
            focusHandled = request
            composing = true
        }
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
                    Button("Hook Settings", action: chat.openHookSettings).buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 4)
            }
            if chat.queuedPrompt != nil {
                HStack(spacing: 10) {
                    Text("Sends when \(chat.agentName) is back at its prompt").font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button("Cancel", action: chat.cancelQueued).buttonStyle(.link).font(.caption)
                    Button("Send Now") { Task { await chat.sendQueuedNow() } }
                        .buttonStyle(.link).font(.caption)
                        .disabled(!chat.canSendQueuedNow)
                        .help("Types it into the terminal now. If the agent is asking something there, this answers it.")
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 14) {
                if !chat.attachments.isEmpty {
                    ChatAttachmentStrip(attachments: chat.attachments, remove: chat.removeAttachment)
                }
                TextField("Ask \(chat.agentName) anything", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($composing)
                    .onSubmit { Task { await chat.send() } }
                    // Typed into the terminal as it is written, so the agent's own menus follow it.
                    .onChange(of: chat.draft) { _, _ in chat.lineChanged() }
                HStack(spacing: 12) {
                    Button { choosingFiles = true } label: {
                        Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(!chat.canAttach)
                    .help("Attach files. They are pasted into the terminal ahead of the message.")
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
                    .help("Send to the terminal")
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
