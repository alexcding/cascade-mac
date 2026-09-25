import SwiftUI

struct GitChangesSheet: View {
    @Bindable var model: GitChangesActions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Commit and Push")).font(.title2.weight(.semibold))
            Text(model.worktree).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let branch = model.snapshot?.branch, !branch.isEmpty { Label(branch, systemImage: "arrow.triangle.branch") }
            Text(model.summary).font(.callout)
            if let behind = model.snapshot?.behind, behind > 0 {
                Text(String(localized: "Behind upstream by \(behind) commits. A push may require updating your branch.")).foregroundStyle(.orange)
            }
            if model.committedHash == nil {
                TextField(String(localized: "Commit message (blank uses “Update working changes”)"), text: $model.message, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(model.busy)
                Toggle(String(localized: "Include untracked files"), isOn: $model.includeUntracked)
                    .disabled(model.busy || model.snapshot?.untracked.isEmpty != false)
                Text(String(localized: "Commits all tracked changes on disk. Save editor buffers first to include them."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = model.status { Text(status).foregroundStyle(.green).textSelection(.enabled) }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(String(localized: "Refresh")) { Task { await model.load() } }.disabled(model.busy || model.loading)
                Spacer()
                if model.busy || model.loading { ProgressView().controlSize(.small) }
                if model.committedHash != nil {
                    Button(String(localized: "New Commit"), action: model.beginNextCommit).disabled(model.busy)
                } else {
                    Button(String(localized: "Commit")) { Task { await model.perform(.commit) } }
                        .keyboardShortcut(.return, modifiers: .command).disabled(!model.canCommit)
                    Button(String(localized: "Commit and Push")) { Task { await model.perform(.commitAndPush) } }.disabled(!model.canCommit)
                }
                Button(String(localized: "Push")) { Task { await model.perform(.push) } }.disabled(!model.canPush)
            }
        }.padding(24).frame(width: 620)
        .interactiveDismissDisabled(model.busy)
        .task { await model.load() }
    }
}
