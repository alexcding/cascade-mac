import SwiftUI

struct MicrophoneAccessView: View {
    let model: MicrophoneAccessViewModel
    var body: some View {
        Section("Microphone") {
            SettingsRow(title: "Microphone access",
                        caption: "Voice input in terminal sessions and agents runs under Craft's permission.") {
                HStack {
                    if model.loading || model.requesting { ProgressView().controlSize(.small) }
                    if model.canRequest {
                        Button("Allow Microphone", action: model.requestAccess).accessibilityIdentifier("settings-microphone-request")
                    } else if model.canOpenSystemSettings {
                        Button("Open Privacy Settings", action: model.openSystemSettings).accessibilityIdentifier("settings-microphone-open")
                    } else if let status = model.status {
                        StatusPill(text: Self.pillText(status), tone: status == .authorized ? .success : .neutral,
                                   identifier: "settings-microphone-pill")
                    }
                }
            }
            // The pill already says "Allowed"; the explanatory line is only for states that need action.
            if !model.authorized {
                Text(model.statusText).font(.caption).foregroundStyle(Theme.textSecondary).accessibilityIdentifier("settings-microphone-status")
            }
        }
    }
    private static func pillText(_ status: MicrophoneAccessStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        }
    }
}
