import SwiftUI

struct GitChangesSheet: View {
    @Bindable var model: GitChangesActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.committedHash == nil {
                TextField(String(localized: "Commit message (blank uses “Update working changes”)"), text: $model.message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(4...8)
                    .padding(10)
                    .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                    .disabled(model.busy)
                Toggle(String(localized: "Include untracked files"), isOn: $model.includeUntracked)
                    .disabled(model.busy || model.snapshot?.untracked.isEmpty != false)
                Text(String(localized: "Commits all tracked changes on disk. Save editor buffers first to include them."))
                    .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let behind = model.snapshot?.behind, behind > 0 {
                banner(String(localized: "Behind upstream by \(behind) commits. A push may require updating your branch."),
                       systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
            }
            if let status = model.status { banner(status, systemImage: "checkmark.circle.fill", tint: Theme.success) }
            if let error = model.error { banner(error, systemImage: "exclamationmark.triangle.fill", tint: Theme.warn) }
            actions
        }
        .padding(16)
        .frame(width: 400)
        .interactiveDismissDisabled(model.busy)
        .task { await model.load(keepingOutcome: true) }
    }

    /// The branch the commit lands on and how it stands against its upstream, with the worktree's
    /// path as its tooltip; Refresh at the end.
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(model.snapshot?.branch.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Commit and Push"),
                      systemImage: "arrow.triangle.branch")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(model.summary).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .help(model.worktree)
            Spacer(minLength: 4)
            if let ahead = model.snapshot?.ahead, ahead > 0 { count("arrow.up", ahead) }
            if let behind = model.snapshot?.behind, behind > 0 { count("arrow.down", behind) }
            if model.busy || model.loading { ProgressView().controlSize(.small) }
            Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") { Task { await model.load() } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help(String(localized: "Refresh"))
                .disabled(model.busy || model.loading)
        }
    }

    private func count(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text(verbatim: "\(value)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Theme.surfaceHover, in: Capsule())
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Commit is the default, as ⌘↩ has always been; Push shows only once there is something to push.
    /// The default action sits last, where a dialog puts it.
    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            if model.committedHash != nil {
                Button(String(localized: "New Commit"), action: model.beginNextCommit).disabled(model.busy).commitStyle()
                Button(String(localized: "Push")) { Task { await model.perform(.push) } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!model.canPush).commitStyle(prominent: true)
            } else {
                if (model.snapshot?.ahead ?? 0) > 0 {
                    Button(String(localized: "Push")) { Task { await model.perform(.push) } }.disabled(!model.canPush).commitStyle()
                }
                Button(String(localized: "Commit and Push")) { Task { await model.perform(.commitAndPush) } }
                    .disabled(!model.canCommit).commitStyle()
                Button(String(localized: "Commit")) { Task { await model.perform(.commit) } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!model.canCommit).commitStyle(prominent: true)
            }
        }
        .controlSize(.large)
    }
}

private extension View {
    /// Glass on macOS 26 and bordered before it, never tinted with the accent: the default action
    /// is marked by its weight and ⌘↩ instead.
    @ViewBuilder func commitStyle(prominent: Bool = false) -> some View {
        let label = fontWeight(prominent ? .semibold : .regular)
        if #available(macOS 26.0, *) { label.buttonStyle(.glass) } else { label.buttonStyle(.bordered) }
    }
}
