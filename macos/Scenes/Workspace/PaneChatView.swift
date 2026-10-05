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
                PaneNewChatForm(model: form, existing: workspace.paneExistingChats(tab),
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

/// New Chat inside a tab: which agent and which of its models. It works in the session's worktree,
/// which it shows; closing the tab is how it is cancelled. Above it, the worktree's chats no tab
/// shows, which lists leave out: one is opened in this tab instead.
struct PaneNewChatForm: View {
    @Bindable var model: NewChatViewModel
    var existing: [ChatThreadShell] = []
    var open: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !existing.isEmpty {
                SheetTitle(String(localized: "Chats in This Worktree"))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(existing) { shell in
                        Button { open(shell.id) } label: { PaneExistingChatRow(shell: shell) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pane-chat-existing-\(shell.id)")
                    }
                }
                .padding(.bottom, 20)
            }
            SheetTitle(String(localized: "New Chat"))
            SheetField(String(localized: "Agent")) {
                if model.loading && model.agents.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Picker(String(localized: "Agent"), selection: $model.agent) {
                        ForEach(model.agents) { agent in
                            Label {
                                Text(agent.note.map { "\(agent.name) — \($0)" } ?? agent.name)
                            } icon: {
                                AgentMark(key: agent.cli, size: 14)
                            }
                            .tag(Optional(agent.cli))
                            .selectionDisabled(!agent.usable)
                        }
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    .accessibilityIdentifier("pane-chat-agent")
                }
            }
            SheetField(String(localized: "Model")) {
                HStack(spacing: 8) {
                    Picker(String(localized: "Model"), selection: $model.model) {
                        ForEach(model.models) { option in Text(option.title).tag(Optional(option.slug)) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(model.models.isEmpty)
                    .accessibilityIdentifier("pane-chat-model")
                    if model.loadingModels { ProgressView().controlSize(.small) }
                }
            }
            if model.offersKnowledge {
                SheetField(String(localized: "Knowledge")) {
                    Toggle(String(localized: "Include what the session’s agent knows"), isOn: $model.includeKnowledge)
                        .toggleStyle(.checkbox)
                        .disabled(!model.canIncludeKnowledge)
                        .accessibilityIdentifier("pane-chat-knowledge")
                    if let reason = model.knowledgeUnavailableReason {
                        SheetHint(Text(reason))
                    } else {
                        SheetHint(Text("The chat starts knowing what \(model.knowledgeAgentName) knows in the terminal, without showing its messages. The session is not changed."))
                    }
                }
            }
            SheetField(String(localized: "Folder"), last: true) {
                Text(model.folder).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                SheetHint(Text("The agent works in this session’s worktree, in a conversation of its own. It asks before running tools."))
            }
            if let error = model.error {
                SheetHint(error, isError: true).padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(String(localized: "Start Chat")) { Task { await model.create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreate)
                    .accessibilityIdentifier("pane-chat-create")
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.load() }
    }
}

/// One of the worktree's chats in a tab's form: its agent's glyph, its title, and whether it is
/// working or waiting on the person.
private struct PaneExistingChatRow: View {
    let shell: ChatThreadShell

    var body: some View {
        HStack(spacing: 8) {
            AgentMark(key: shell.cli ?? "", size: 14)
            Text(shell.label).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if shell.needsInput {
                Text(String(localized: "Needs input")).font(.system(size: 11)).foregroundStyle(Theme.warn)
            } else if shell.working {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
