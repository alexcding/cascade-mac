import SwiftUI

struct GitChangesSheet: View {
    @Bindable var model: GitChangesActions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Commit and Push").font(.title2.weight(.semibold))
            Text(model.worktree).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let branch = model.snapshot?.branch, !branch.isEmpty { Label(branch, systemImage: "arrow.triangle.branch") }
            Text(model.summary).font(.callout)
            if let behind = model.snapshot?.behind, behind > 0 {
                Text("Behind upstream by \(behind) commits. A push may require updating your branch.").foregroundStyle(.orange)
            }
            if model.committedHash == nil {
                TextField("Commit message (blank uses “Update working changes”)", text: $model.message, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(model.busy)
                Toggle("Include untracked files", isOn: $model.includeUntracked)
                    .disabled(model.busy || model.snapshot?.untracked.isEmpty != false)
                Text("Commits all tracked changes on disk. Save editor buffers first to include them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = model.status { Text(status).foregroundStyle(.green).textSelection(.enabled) }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Refresh") { Task { await model.load() } }.disabled(model.busy || model.loading)
                Spacer()
                if model.busy || model.loading { ProgressView().controlSize(.small) }
                if model.committedHash != nil {
                    Button("New Commit", action: model.beginNextCommit).disabled(model.busy)
                } else {
                    Button("Commit") { Task { await model.perform(.commit) } }
                        .keyboardShortcut(.return, modifiers: .command).disabled(!model.canCommit)
                    Button("Commit and Push") { Task { await model.perform(.commitAndPush) } }.disabled(!model.canCommit)
                }
                Button("Push") { Task { await model.perform(.push) } }.disabled(!model.canPush)
            }
        }.padding(24).frame(width: 620)
        .interactiveDismissDisabled(model.busy)
        .task { await model.load() }
    }
}
