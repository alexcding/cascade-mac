import SwiftUI

/// New Task: the picked project's Start, whose project chip switches between projects, or on its
/// Chat side a chat's composer. A Task | Chat switch leads the composer's tray on either side.
struct NewSessionView: View {
    let model: NewSessionViewModel

    var body: some View {
        if model.mode == .chat {
            chatSide.padding(28)
        } else if let project = model.project, let composer = model.composer {
            ProjectComposerView(project: project, model: composer, projects: model.projects, onChooseProject: model.choose,
                                onNewProject: model.newProject, modeControl: AnyView(NewTaskModeControl(model: model)))
                // Each composer is its own view: a switch of project, or a composer rebuilt for the same
                // one on reconnect, takes the old one off screen and brings the new one on.
                .id(ObjectIdentifier(composer))
                .padding(28)
        } else if model.projects.isEmpty {
            // Nothing to start a task in yet: Start as it is with a project, its chip offering New Project.
            NewTaskNoProjectComposer(model: model).padding(28)
        } else {
            Text("Connect to start sessions.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// New Task's Task side with no project to start a session in: Start's composer as it is with one,
/// whose project chip opens the projects (none yet) and New Project. Nothing starts until one is made.
private struct NewTaskNoProjectComposer: View {
    let model: NewSessionViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text("What should we build?")
                .font(.system(size: 32)).tracking(-0.6).multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                ComposerTray {
                    NewTaskModeControl(model: model)
                    ProjectChip(title: String(localized: "Choose Project"), projects: [], current: nil, choose: { _ in },
                                newProject: model.newProject, help: String(localized: "The project the session starts in"),
                                identifier: "project-composer-project") {}
                    Spacer(minLength: 0)
                } card: {
                    ComposerCard {
                        ComposerTextField(placeholder: String(localized: "Describe a task or branch, or paste a pull request, issue or Jira link"), text: $text, focused: $focused,
                                          disabled: true, identifier: "project-composer") {}
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            ComposerStartButton(enabled: false, label: String(localized: "Create Session"),
                                                identifier: "project-composer-create") {}
                        }
                        .frame(minHeight: 32)
                    }
                }
                ComposerMessageLine {
                    Text("Add a project with a folder to start sessions in it.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 766)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .help(String(localized: "Start a task with a worktree of its own, or a chat in a folder as it is"))
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

/// New Task's Chat side: the question, and Start's composer — the Task | Chat switch and the chat's
/// project on its tray, the agent and model by Start. The chat works in the picked project's folder,
/// or, of no project, in a scratch folder of its own; never on a branch or worktree of its own. Start makes the chat, sends what is typed as its first message, and goes to it.
private struct NewTaskChatComposer: View {
    let page: NewSessionViewModel
    @Bindable var model: NewChatViewModel
    @State private var dropTargeted = false

    private var chosen: NewChatViewModel.Agent? { model.agents.first { $0.cli == model.agent } }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text("What should we ask?")
                .font(.system(size: 32)).tracking(-0.6).multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                ComposerTray {
                    NewTaskModeControl(model: page)
                    placeChip
                    Spacer(minLength: 0)
                    if model.busy || (model.loading && model.agents.isEmpty) {
                        ProgressView().controlSize(.small).padding(.trailing, 8)
                    }
                } card: {
                    ComposerCard {
                        StartChatField(model: model, placeholder: model.askPlaceholder, identifier: "new-task-chat-prompt",
                                       dropTargeted: $dropTargeted)
                        HStack(spacing: 12) {
                            StartChatAttachButton(model: model, identifier: "new-task-chat-attach")
                            Spacer(minLength: 0)
                            ComposerAgentButton(agent: model.agentMark, title: model.agentTitle,
                                                help: String(localized: "The agent and model the chat starts with"),
                                                identifier: "new-task-chat-agent", openLabel: String(localized: "Select effort")) { close in
                                PaneChatAgentChooser(model: model, done: close)
                            }
                            ComposerStartButton(enabled: model.canStart, label: String(localized: "Start Chat"),
                                                identifier: "new-task-chat-create") { Task { await model.start() } }
                        }
                        .frame(minHeight: 32)
                    }
                    .startChatDrop(model: model, targeted: $dropTargeted)
                }
                ComposerMessageLine {
                    if let error = model.error {
                        Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                    } else if let chosen, !chosen.usable, let note = chosen.note {
                        Text(note).foregroundStyle(.secondary)
                    } else if let name = model.projectName {
                        Text("The agent works in \(name)’s folder as it is. It asks before running tools.").foregroundStyle(.secondary)
                    } else {
                        Text("The agent works in a folder of the chat's own. It asks before running tools.").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 766)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.requestFocus() }
        .task { await model.load() }
    }

    /// The project the chat starts in, or none: Task's project chip, with No Project.
    private var placeChip: some View {
        ProjectChip(symbol: model.standalone ? "bubble.left" : "folder",
                    title: model.projectName ?? String(localized: "No Project"),
                    projects: page.projects, current: model.projectID, choose: { page.chooseChatProject($0) },
                    newProject: page.newChatProject, noProject: { page.chooseChatProject(nil) },
                    noneSelected: model.standalone, help: String(localized: "The project the chat works in"),
                    identifier: "new-task-chat-project") { model.requestFocus() }
            .disabled(!model.canMove)
    }
}
