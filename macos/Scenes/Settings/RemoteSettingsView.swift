import SwiftUI

struct RemoteSettingsView: View {
    let model: RemoteSettingsViewModel

    var body: some View {
        Section("Cascade Remote") {
            SettingsRow(title: String(localized: "Sync agent chats to iPhone"),
                        caption: String(localized: "Mirrors each running session’s chat to your iCloud, end-to-end encrypted, so Cascade Remote on an iPhone signed in to the same Apple Account can read it and send messages.")) {
                Toggle("Sync agent chats to iPhone", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!model.available && !model.enabled)
                    .accessibilityIdentifier("settings-remote-enabled")
            }
            Text(model.statusText)
                .foregroundStyle(model.failed ? Theme.danger : Theme.textSecondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings-remote-status")
        }
        Section("Approvals") {
            Text("When nobody has used this Mac for two minutes, a tool approval in a session whose chat isn’t on screen waits for your iPhone instead of going straight to the terminal. It still falls back to the terminal if it isn’t answered in time.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
