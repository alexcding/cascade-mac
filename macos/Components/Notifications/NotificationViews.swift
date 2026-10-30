import SwiftUI

/// The Notifications group — its own `Section`, rows through `SettingsRow` so the Form aligns them.
struct NotificationPreferencesView: View {
    let shell: ShellStore
    var sounds: [ReviewSound] = []

    var body: some View {
        Section("Notifications") {
            SettingsRow(title: String(localized: "Review sound")) {
                HStack {
                    Picker("Review sound", selection: Binding(get: { shell.reviewSound }, set: shell.setReviewSound)) {
                        Text("Glass (default)").tag("system")
                        Text("None").tag("off")
                        ForEach(sounds) { Text($0.name).tag($0.path) }
                        if !["system", "off"].contains(shell.reviewSound) && !sounds.contains(where: { $0.path == shell.reviewSound }) {
                            Text(URL(fileURLWithPath: shell.reviewSound).deletingPathExtension().lastPathComponent)
                                .tag(shell.reviewSound)
                        }
                    }.labelsHidden().accessibilityIdentifier("settings-review-sound")
                    Button { shell.notifications.previewSound(shell.reviewSound) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Preview").disabled(shell.reviewSound == "off")
                        .accessibilityLabel("Preview Sound").accessibilityIdentifier("settings-preview-sound")
                }
            }
            Toggle(isOn: Binding(get: { shell.activityNotify }, set: shell.setActivityNotify)) {
                Text("Activity notifications")
            }.accessibilityIdentifier("settings-activity-notify")
            if shell.notifications.permission != .authorized {
                LabeledContent {
                    if shell.notifications.permission == .notDetermined {
                        Button("Enable Notifications") { shell.notifications.enable() }
                            .disabled(!shell.notifications.canEnable)
                    }
                } label: {
                    Text("Permission")
                    Text(shell.notifications.permission == .denied
                         ? String(localized: "Allow Cascade in System Settings → Notifications.")
                         : shell.notifications.permission.label)
                }
            }
            if let error = shell.notifications.error { Text(error).foregroundStyle(Theme.danger) }
            if let error = shell.notifications.actionError { Text(error).foregroundStyle(Theme.danger) }
        }
    }
}
