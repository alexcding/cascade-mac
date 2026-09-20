import SwiftUI

// new-session-dialog.js, natively: the project is in the title, never a choice. Labels sit
// above their fields (.form-label), hints under them (.form-hint), and every choice is the
// same segmented control.
struct NewSessionView: View {
    @Bindable var model: NewSessionViewModel
    let cancel: () -> Void
    @FocusState private var focus: Field?
    private enum Field { case input, pullRequestBranch }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(model.title)

            SheetField("Branch name or URL") {
                TextField(model.placeholder, text: $model.input)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .input)
                    .accessibilityIdentifier("session-branch")
                    .onSubmit { Task { await model.create() } }
                let hint = model.fieldHint
                SheetHint(hint.text, isError: hint.isError)
            }
            if model.showsPullRequestBranch {
                SheetField("Branch for that pull request") {
                    TextField(model.placeholder, text: $model.pullRequestBranch)
                        .textFieldStyle(.roundedBorder).focused($focus, equals: .pullRequestBranch)
                        .onSubmit { Task { await model.create() } }
                }
                .onAppear { focus = .pullRequestBranch }
            }
            if let worktree = model.worktreeHint {
                SheetField("Worktree") {
                    Text(worktree).font(.system(size: 13)).textSelection(.enabled)
                }
            }
            SheetField("Branch from") {
                Picker("Branch from", selection: $model.draft.base) {
                    ForEach(model.branches, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                if let referenceError = model.referenceError { SheetHint(referenceError, isError: true) }
            }
            SheetField("Agent", last: true) {
                SegmentedChoice(options: [("Claude", SessionAgent.claude), ("Codex", .codex), ("Shell only", .shell)],
                                selection: $model.draft.agent)
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(.top, 12)
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction).disabled(model.creating)
                Button(model.creating ? "Creating…" : "Create") { Task { await model.create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(24).frame(width: 400)
        .disabled(model.completed)
        .interactiveDismissDisabled(model.creating)
        .task { await model.prepare() }
        .onAppear { focus = .input }
        .onDisappear(perform: model.cancelReferenceLoading)
    }
}

/// .theme-toggle / .theme-opt: plain text options, the chosen one outlined.
private struct SegmentedChoice<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.1) { label, value in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color(nsColor: .separatorColor) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}
