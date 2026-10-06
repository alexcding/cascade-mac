import SwiftUI

/// New Task: the picked project's Start, whose project chip switches between projects, or on its
/// Chat side a chat's composer. A Task | Chat switch leads the composer's tray on either side.
struct NewSessionView: View {
    let model: NewSessionViewModel

    var body: some View {
        if model.mode == .chat, model.place != nil {
            chatSide.padding(28)
        } else if let project = model.project, let composer = model.composer {
            ProjectComposerView(project: project, model: composer, projects: model.projects, onChooseProject: model.choose,
                                onNewProject: model.newProject, modeControl: AnyView(NewTaskModeControl(model: model)))
                // Each composer is its own view: a switch of project, or a composer rebuilt for the same
                // one on reconnect, takes the old one off screen and brings the new one on.
                .id(ObjectIdentifier(composer))
                .padding(28)
        } else if model.projects.isEmpty {
            // Nothing to start a task in yet: the way to make the first project is right here. The
            // switch stays, since a chat needs only a folder.
            VStack(spacing: 0) {
                NewTaskModeControl(model: model).padding(.top, 28)
                noProjects
            }
        } else {
            Text("Connect to start sessions.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noProjects: some View {
        ContentUnavailableView {
            Label(String(localized: "No Projects"), systemImage: "folder")
        } description: {
            Text("Add a project with a folder to start sessions in it.")
        } actions: {
            Button(String(localized: "New Project…"), action: model.newProject)
                .buttonStyle(.bordered).controlSize(.large)
                .accessibilityIdentifier("new-task-new-project")
        }
    }

    @ViewBuilder private var chatSide: some View {
        if let chat = model.chat {
            NewTaskChatComposer(page: model, model: chat)
                // A chat made for another place, or anew on reconnect, is a composer of its own.
                .id(ObjectIdentifier(chat))
        } else {
            Text("Connect to start chats.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Task | Chat, at the head of the composer's tray: two plain buttons on a rounded track in the
/// tray chips' hover fill, the chosen one raised on a white (dark: elevated) plate.
struct NewTaskModeControl: View {
    let model: NewSessionViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NewSessionViewModel.Mode.allCases) { mode in
                NewTaskModeButton(mode: mode, selected: model.mode == mode) { model.setMode(mode) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.border))
        .fixedSize()
        .padding(.leading, 4).padding(.trailing, 6)
        .help(String(localized: "Start a task with a worktree of its own, or a chat about the project"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Start"))
        .accessibilityIdentifier("new-task-mode")
    }
}

private struct NewTaskModeButton: View {
    let mode: NewSessionViewModel.Mode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Theme.textSecondary)
                .padding(.vertical, 5).padding(.horizontal, 14)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.segmentSelected)
                            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("new-task-mode-\(mode.rawValue)")
    }
}

/// New Task's Chat side: the question, and Start's composer — the Task | Chat switch, the project (or
/// No Project…, a folder) and the session whose agent's knowledge the chat starts with on its tray;
/// the agent and model by Start. Start makes the chat, sends what is typed as its first message, and
/// goes to it.
private struct NewTaskChatComposer: View {
    let page: NewSessionViewModel
    @Bindable var model: NewChatViewModel
    @FocusState private var focused: Bool
    @State private var choosingProject = false
    @State private var choosingKnowledge = false

    private var chosen: NewChatViewModel.Agent? { model.agents.first { $0.cli == model.agent } }
    /// The project's name, or with no project the folder's, or No Project… before one is picked.
    private var placeName: String {
        if page.needsChatFolder { return String(localized: "No Project…") }
        return model.projectName ?? (model.folder as NSString).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                if page.needsChatFolder { Text("What should we ask?") }
                else { Text("What should we ask about \(Text(placeName).underline(pattern: .dot))?") }
            }
                .font(.system(size: 32)).tracking(-0.6).multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                ComposerTray {
                    NewTaskModeControl(model: page)
                    projectChip
                    if model.offersKnowledgeSources { knowledgeChip }
                    Spacer(minLength: 0)
                    if model.busy || (model.loading && model.agents.isEmpty) {
                        ProgressView().controlSize(.small).padding(.trailing, 8)
                    }
                } card: {
                    ComposerCard {
                        ComposerTextField(placeholder: model.askPlaceholder, text: $model.prompt, focused: $focused,
                                          disabled: model.busy, identifier: "new-task-chat-prompt") { Task { await model.start() } }
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            ComposerAgentButton(agent: model.agentMark, title: model.agentTitle,
                                                help: String(localized: "The agent and model the chat starts with"),
                                                identifier: "new-task-chat-agent") { _ in
                                PaneChatAgentChooser(model: model)
                            }
                            ComposerStartButton(enabled: model.canStart, label: String(localized: "Start Chat"),
                                                identifier: "new-task-chat-create") { Task { await model.start() } }
                        }
                        .frame(minHeight: 32)
                    }
                }
                ComposerMessageLine {
                    if let error = model.error {
                        Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                    } else if let note = model.knowledgeNote {
                        Text(note).foregroundStyle(.secondary)
                    } else if let chosen, !chosen.usable, let note = chosen.note {
                        Text(note).foregroundStyle(.secondary)
                    } else if page.needsChatFolder {
                        Text("Pick the folder the chat's agent works in.").foregroundStyle(.secondary)
                    } else if model.standalone {
                        Text("The agent works in \(model.folder). It asks before running tools.").foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: 766)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
        .task { await model.load() }
    }

    /// The project the chat works in, or the folder of a chat with none; it opens the projects, and
    /// No Project… under them.
    private var projectChip: some View {
        // With no project to pick, the chip goes straight to the folder picker.
        Button {
            if page.projects.isEmpty { Task { await page.chooseNoProject() } } else { choosingProject.toggle() }
        } label: {
            ComposerChip(symbol: model.standalone ? "questionmark.folder" : "folder", title: placeName, active: choosingProject)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .onChange(of: choosingProject) { _, open in if !open { focused = true } }
        .popover(isPresented: $choosingProject, arrowEdge: .top) {
            ProjectPicker(projects: page.projects, current: page.chatFolder == nil ? page.projectID : nil,
                          choose: page.choose, newProject: page.newProject,
                          noProject: { Task { await page.chooseNoProject() } }) {
                choosingProject = false
            }
        }
        .help(model.standalone ? model.folder : String(localized: "The project the chat works in"))
        .accessibilityIdentifier("new-task-chat-project")
    }

    /// The session whose agent's knowledge the chat starts with: none until one is picked, and
    /// greyed with its reason when no session has a conversation to start from.
    private var knowledgeChip: some View {
        let source = model.chosenKnowledgeSource
        return Button { choosingKnowledge.toggle() } label: {
            ComposerChip(symbol: "brain",
                         title: source.map { String(localized: "What \($0.title)’s agent knows") }
                            ?? String(localized: "What a session’s agent knows"),
                         chevron: true, active: choosingKnowledge || source != nil, interactive: model.canChooseKnowledge)
        }
        .buttonStyle(.plain)
        .disabled(!model.canChooseKnowledge)
        .opacity(model.canChooseKnowledge ? 1 : 0.5)
        .onChange(of: choosingKnowledge) { _, open in if !open { focused = true } }
        .popover(isPresented: $choosingKnowledge, arrowEdge: .top) {
            KnowledgePicker(model: model) { choosingKnowledge = false }
        }
        .help(model.knowledgeSourcesReason
              ?? String(localized: "Start the chat knowing what a session’s agent knows. The chat works in that session’s worktree; the session is not changed."))
        .accessibilityAddTraits(source != nil ? .isSelected : [])
        .accessibilityIdentifier("new-task-chat-knowledge")
    }
}

/// The knowledge chip's popover: no session, then the project's sessions with an agent conversation.
private struct KnowledgePicker: View {
    let model: NewChatViewModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            PickerRow(symbol: "circle.slash", title: String(localized: "Start Knowing Nothing"),
                      selected: model.knowledgeSourceID == nil) { pick(nil) }
            Divider().padding(.vertical, 4)
            ForEach(model.knowledgeSources) { source in
                PickerRow(title: source.title, selected: model.knowledgeSourceID == source.id) {
                    AgentMark(key: source.cli, size: 16)
                } action: { pick(source.id) }
                .help(source.worktree)
                .accessibilityIdentifier("new-task-chat-knowledge-\(source.id)")
            }
        }
        .padding(8)
        .frame(width: 300)
    }

    private func pick(_ id: String?) {
        done()
        Task { await model.chooseKnowledge(id) }
    }
}
