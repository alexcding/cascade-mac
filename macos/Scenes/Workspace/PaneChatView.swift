import SwiftUI

/// A Chat tab of a session's pane: the new-chat form until a chat is started in it, then the chat's
/// page, edge to edge under the pane's bar.
struct PaneChatView: View {
    let tab: WorkspaceToolTab
    let workspace: SessionWorkspaceViewModel

    var body: some View {
        let chat = workspace.paneChat(for: tab)
        Group {
            if let page = chat?.chat?.page {
                ZStack(alignment: .bottom) {
                    if let webView = page.webView { ChatPageSurface(webView: webView) }
                    if let failure = page.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.warn)
                            .lineLimit(2).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.warnBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(12)
                    }
                }
            } else if let form = chat?.form {
                PaneChatComposer(model: form, existing: workspace.paneExistingChats(tab),
                                open: { workspace.openExistingPaneChat($0, in: tab) })
            } else {
                switch workspace.paneChatPhase(tab) {
                case .missing:
                    ContentUnavailableView(String(localized: "Chat not found"), systemImage: WorkspaceTool.chat.symbol,
                                           description: Text(String(localized: "This chat was deleted.")))
                case .offline:
                    ContentUnavailableView(String(localized: "Not connected"), systemImage: WorkspaceTool.chat.symbol,
                                           description: Text(String(localized: "Connect to the backend to chat.")))
                case .loading: ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Under the pane's bar, not behind it: a background into the top safe area hides its tabs.
        .paneSurface(ignoresSafeAreaEdges: [])
        // Made as the tab appears, and again when what it waits on arrives: the backend, or a
        // restored tab's chat once the list has it.
        .task(id: workspace.paneChatKey(tab)) { workspace.preparePaneChat(tab) }
        .accessibilityIdentifier("workspace-chat-panel")
    }
}

/// New Chat inside a tab, as New Task's Start: the question, and the composer under it — the
/// worktree and the session-knowledge option on its tray, the agent and model by Start. Start makes the
/// chat in the session's worktree and sends what is typed as its first message; closing the tab is
/// how it is cancelled. Under the composer, the worktree's chats no tab shows, which lists leave out:
/// one is opened in this tab instead.
struct PaneChatComposer: View {
    @Bindable var model: NewChatViewModel
    var existing: [ChatThreadShell] = []
    var open: (String) -> Void = { _ in }
    @State private var dropTargeted = false

    private var chosen: NewChatViewModel.Agent? { model.agents.first { $0.cli == model.agent } }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text("What should we chat about?").font(.system(size: 24)).tracking(-0.4)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 6) {
                ComposerTray {
                    ComposerChip(symbol: "folder", title: (model.folder as NSString).lastPathComponent, interactive: false)
                        .help(model.folder)
                        .accessibilityIdentifier("pane-chat-folder")
                    if model.offersKnowledge { knowledgeChip }
                    Spacer(minLength: 0)
                    if model.busy || (model.loading && model.agents.isEmpty) {
                        ProgressView().controlSize(.small).padding(.trailing, 8)
                    }
                } card: {
                    ComposerCard {
                        StartChatField(model: model,
                                       placeholder: AgentDrivers.of(model.agent)?.chatPlaceholder ?? String(localized: "Ask anything"),
                                       identifier: "pane-chat-prompt", dropTargeted: $dropTargeted)
                        HStack(spacing: 12) {
                            StartChatAttachButton(model: model, identifier: "pane-chat-attach")
                            Spacer(minLength: 0)
                            ComposerAgentButton(agent: model.agentMark, title: model.agentTitle,
                                                help: String(localized: "The agent and model the chat starts with"),
                                                identifier: "pane-chat-agent") { _ in
                                PaneChatAgentChooser(model: model)
                            }
                            ComposerStartButton(enabled: model.canStart, label: String(localized: "Start Chat"),
                                                identifier: "pane-chat-create") { Task { await model.start() } }
                        }
                        .frame(minHeight: 32)
                    }
                    .startChatDrop(model: model, targeted: $dropTargeted)
                }
                ComposerMessageLine {
                    if let error = model.error {
                        Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                    } else if let reason = model.knowledgeUnavailableReason {
                        Text(reason).foregroundStyle(.secondary)
                    } else if let chosen, !chosen.usable, let note = chosen.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 766)
            if !existing.isEmpty { existingChats.frame(maxWidth: 766).padding(.top, 14) }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.requestFocus() }
        .task { await model.load() }
    }

    /// Start with what the session's agent knows: off until turned on, and greyed with its reason
    /// beneath when the agent has nothing to start from.
    private var knowledgeChip: some View {
        Button { model.includeKnowledge.toggle() } label: {
            ComposerChip(symbol: model.includeKnowledge ? "checkmark.square.fill" : "square",
                         title: String(localized: "What \(model.knowledgeAgentName) knows"),
                         active: model.includeKnowledge, interactive: model.canIncludeKnowledge)
        }
        .buttonStyle(.plain)
        .disabled(!model.canIncludeKnowledge)
        .opacity(model.canIncludeKnowledge ? 1 : 0.5)
        .onChange(of: model.includeKnowledge) { _, _ in model.requestFocus() }
        .help(model.knowledgeUnavailableReason
              ?? String(localized: "The chat starts knowing what \(model.knowledgeAgentName) knows in the terminal, without showing its messages. The session is not changed."))
        .accessibilityAddTraits(model.includeKnowledge ? .isSelected : [])
        .accessibilityIdentifier("pane-chat-knowledge")
    }

    /// The worktree's chats no tab shows, as rows of Start's pickers.
    private var existingChats: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Chats in This Worktree").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(existing) { shell in
                        PickerRow(title: shell.label, accessory: status(of: shell)) {
                            AgentMark(key: shell.cli ?? "", size: 16)
                        } action: { open(shell.id) }
                        .accessibilityIdentifier("pane-chat-existing-\(shell.id)")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // As tall as its rows, up to a limit, so the composer keeps its place.
            .frame(height: min(CGFloat(existing.count) * 35, 35 * 5))
        }
    }

    private func status(of shell: ChatThreadShell) -> AnyView? {
        if shell.needsInput {
            return AnyView(Text(String(localized: "Needs input")).font(.system(size: 11)).foregroundStyle(Theme.warn))
        }
        return shell.working ? AnyView(ProgressView().controlSize(.mini)) : nil
    }
}

/// Start's chat field, New Task's and a pane's: the message with its files as chips, as the terminal
/// chat's overlay writes one. Files paste and drop into it; Return starts, Shift- or Option-Return
/// starts a new line.
struct StartChatField: View {
    let model: NewChatViewModel
    let placeholder: String
    let identifier: String
    @Binding var dropTargeted: Bool

    var body: some View {
        ChatComposerField(chat: model, text: model.prompt, files: model.attachments, caret: model.caret,
                          focusRequest: model.focusRequest, active: true, placeholder: placeholder,
                          dropTargeted: $dropTargeted, fontSize: 15, editable: !model.busy, identifier: identifier)
            .frame(minHeight: 44, alignment: .topLeading)
    }
}

/// Start's paperclip: picks files and folders for the first message, placed as chips at the caret.
struct StartChatAttachButton: View {
    let model: NewChatViewModel
    let identifier: String
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .disabled(!model.canAttach)
        .help(String(localized: "Attach files or folders. Images go with the message; other files are named by their path."))
        .accessibilityLabel(String(localized: "Attach"))
        .accessibilityIdentifier(identifier)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(ChatAttachmentReader.files(urls)) }
            model.requestFocus()
        }
    }
}

extension View {
    /// Files and images dropped anywhere on Start's card land in its message, the card ringed while
    /// they are over it.
    func startChatDrop(model: NewChatViewModel, targeted: Binding<Bool>) -> some View {
        overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 2).opacity(targeted.wrappedValue ? 1 : 0).allowsHitTesting(false))
            .onDrop(of: ChatAttachmentReader.dropTypes, isTargeted: targeted) { providers in
                model.canAttach && ChatAttachmentReader.drop(providers, into: model)
            }
    }
}

/// A chat composer's agent menu, a pane's and New Task's: the chat agents as tabs along the top, and
/// the chosen one's models under them. Picks keep it open; a click outside closes it.
struct PaneChatAgentChooser: View {
    @Bindable var model: NewChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(model.agents) { agent in
                    if let mark = SessionAgent(rawValue: agent.cli) {
                        AgentTab(agent: mark, selected: model.agent == agent.cli,
                                 unavailable: agent.usable ? nil : agent.note ?? String(localized: "Not available")) {
                            model.agent = agent.cli
                        }
                    }
                }
            }
            .padding(8)
            Divider()
            if model.models.isEmpty {
                Text(model.loadingModels ? String(localized: "Loading models…") : String(localized: "No models to choose from."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Model").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                    ForEach(model.models) { option in
                        ChoiceRow(title: option.title, selected: model.model == option.slug) { model.model = option.slug }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 320)
    }
}
