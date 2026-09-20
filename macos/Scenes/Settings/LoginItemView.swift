import AppKit
import SwiftUI

struct LoginItemView: View {
    let model: LoginItemViewModel
    /// Development builds cannot register a login item, so the group is hidden rather than shown
    /// disabled with an explanation, unless a stale registration still needs to be removable.
    private var hidden: Bool {
        guard let state = model.state else { return false }
        return state.registrationUnavailableReason != nil && !state.registered
    }
    var body: some View {
        if !hidden { startup }
    }
    private var startup: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(get: { model.registered }, set: model.setEnabled))
                .disabled(!model.canToggle).accessibilityIdentifier("settings-launch-at-login")
            Text(model.statusText).foregroundStyle(Theme.textSecondary).accessibilityIdentifier("settings-login-item-status")
            if model.changing { ProgressView("Updating login item…").controlSize(.small) }
            if let reason = model.state?.registrationUnavailableReason { Text(reason).font(.caption).foregroundStyle(Theme.textSecondary) }
            if model.needsApproval {
                Button("Open Login Items Settings", action: model.openSystemSettings).disabled(!model.canOpenSystemSettings)
            }
            if let error = model.error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
        }
    }
}
