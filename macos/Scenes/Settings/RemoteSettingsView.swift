import SwiftUI

struct RemoteSettingsView: View {
    let model: RemoteSettingsViewModel

    var body: some View {
        Section("Cascade Remote") {
            SettingsRow(title: String(localized: "Sync agent chats to iPhone"),
                        caption: String(localized: "Mirrors each running session’s chat to your iCloud, end-to-end encrypted, so Cascade Remote on an iPhone signed in to the same Apple Account can read it. Conversations are sent only while an approved iPhone has the app open.")) {
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
        if !model.waiting.isEmpty {
            Section("Waiting for approval") {
                Text("An iPhone you allow can send messages to your agents and answer their approvals. Allow one only if its code matches the code Cascade Remote shows on that iPhone.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                ForEach(model.waiting) { phone in
                    SettingsRow(title: phone.name, caption: String(localized: "Code \(phone.code)")) {
                        HStack {
                            Button("Deny") { model.deny(phone) }
                                .accessibilityIdentifier("settings-remote-deny-\(phone.id)")
                            Button("Allow") { model.approve(phone) }.buttonStyle(.borderedProminent)
                                .disabled(model.clashes(phone))
                                .accessibilityIdentifier("settings-remote-allow-\(phone.id)")
                        }
                    }
                    if model.clashes(phone) {
                        Text("Another iPhone shows this same code, which does not happen by chance. Deny this one, and remove any allowed iPhone with this code, until you know which is yours.")
                            .font(.caption).foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        if !model.approved.isEmpty {
            Section("Allowed iPhones") {
                ForEach(model.approved) { phone in
                    SettingsRow(title: phone.name, caption: String(localized: "Code \(phone.code)")) {
                        Button("Remove") { model.remove(phone) }
                            .accessibilityIdentifier("settings-remote-remove-\(phone.id)")
                    }
                }
            }
        }
        if !model.denied.isEmpty {
            Section("Denied") {
                ForEach(model.denied) { phone in
                    SettingsRow(title: phone.name, caption: String(localized: "Code \(phone.code)")) {
                        Button("Ask Again") { model.askAgain(phone) }
                            .accessibilityIdentifier("settings-remote-ask-again-\(phone.id)")
                    }
                }
            }
        }
        Section("Approvals") {
            Text("When nobody has used this Mac for two minutes, a tool approval in a session whose chat isn’t on screen waits for an allowed iPhone instead of going straight to the terminal. It still falls back to the terminal if it isn’t answered in time.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
