import SwiftUI

/// New Chat: the agent and its model, and the folder it works in.
struct NewChatSheet: View {
    @Bindable var model: NewChatViewModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(model.projectName.map { String(localized: "New Chat in \($0)") } ?? String(localized: "New Chat"))
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
                    .accessibilityIdentifier("new-chat-agent")
                }
            }
            SheetField(String(localized: "Model")) {
                HStack(spacing: 8) {
                    Picker(String(localized: "Model"), selection: $model.model) {
                        ForEach(model.models) { option in Text(option.title).tag(Optional(option.slug)) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(model.models.isEmpty)
                    .accessibilityIdentifier("new-chat-model")
                    if model.loadingModels { ProgressView().controlSize(.small) }
                }
            }
            SheetField(String(localized: "Folder"), last: true) {
                HStack(spacing: 8) {
                    Text(model.folder).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.standalone {
                        Button(String(localized: "Choose…")) { Task { await model.changeFolder() } }
                            .controlSize(.small)
                    }
                }
                if model.missingFolder {
                    SheetHint(String(localized: "This project has no workspace folder. Set one in the project’s settings to start a chat in it."), isError: true)
                } else {
                    SheetHint(model.standalone
                        ? Text("The agent works in this folder. It asks before running tools.")
                        : Text("The agent works in the project’s folder. It asks before running tools."))
                }
            }
            if let error = model.error {
                SheetHint(error, isError: true).padding(.top, 12)
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: cancel).keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(String(localized: "Start Chat")) { Task { await model.create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
                    .accessibilityIdentifier("new-chat-create")
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(model.busy)
        .task { await model.load() }
    }
}
