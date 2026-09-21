import SwiftUI

struct AutomationView: View {
    @Bindable var model: AutomationViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Event forwarding") {
                    Toggle("Forward GitHub webhooks", isOn: $model.draft.forwardWebhooks)
                        .accessibilityIdentifier("automation-forward")
                    Text("Receive pull-request and CI changes immediately. Polling continues when forwarding is unavailable.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(model.forwardingStatus).font(.caption)
                        Spacer()
                        Button("Refresh Status") { Task { await model.refreshStatus() } }
                    }
                }
                if model.project.hasJira { Section("On GitHub PR merge") {
                    Text("Apply these optional actions in order to each linked Jira ticket.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("1. Set Fix Version", isOn: $model.draft.fixVersionEnabled)
                        .accessibilityIdentifier("automation-fix-version")
                    if model.draft.fixVersionEnabled {
                        Text("Create the version if missing and assign it to the ticket. Requires a Jira API token in Settings → Connections.")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Version template")
                            TextField("Version template", text: $model.draft.fixVersionScript, axis: .vertical)
                                .labelsHidden().multilineTextAlignment(.leading).lineLimit(3...8)
                                .font(.system(.body, design: .monospaced)).accessibilityIdentifier("automation-script")
                        }
                        Text("Use {year}, {month}, {day}, {isoWeek} (zero-padded), {m}, {d}, {w} (unpadded), or {prNumber}. Add an offset with +N or -N, such as {year-2026} or {y-2000} for a short year; offset values are not padded. Dates follow this Mac's time zone. Literal text such as a platform prefix is kept. Example: ios-{year-2026}.{m}.{d}")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Preview Version") { Task { await model.previewVersion() } }.disabled(!model.canPreview)
                            if model.previewing { ProgressView().controlSize(.small) }
                            if let preview = model.preview {
                                Text("Preview: \(preview.version) (\(preview.exists ? "already exists" : "will be created"))")
                                    .textSelection(.enabled).accessibilityIdentifier("automation-preview")
                            }
                        }
                        Text("Preview uses the current draft and a sample PR. It does not create a Jira version.").font(.caption).foregroundStyle(.secondary)
                        if let error = model.previewError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                    TextField("2. Transition ticket to", text: $model.draft.mergeTransition).accessibilityIdentifier("automation-transition")
                    Text("Leave blank to skip the transition. The status must be allowed by the ticket’s workflow.")
                        .font(.caption).foregroundStyle(.secondary)
                } }
            }.formStyle(.grouped).accessibilityIdentifier("automation-form").disabled(model.busy)
            if model.changedElsewhere { Text("Automation changed elsewhere. Revert to load it, or save to replace it with your draft.").foregroundStyle(.orange) }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if model.saved && !model.dirty { Text("Automation saved").foregroundStyle(.secondary) }
                Spacer()
                Button("Revert Automation", action: model.revert).disabled((!model.dirty && !model.changedElsewhere) || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save Automation") { Task { await model.save() } }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }.task { await model.refreshStatus() }.onDisappear { model.pause() }
    }
}
