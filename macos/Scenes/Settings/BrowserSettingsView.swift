import SwiftUI

/// The ad-blocking card under Settings → Browser. A Section for a grouped Form.
struct BrowserAdBlockSection: View {
    let model: BrowserSettingsViewModel
    var body: some View {
        Section("Ad blocking") {
            // The title opens the App Store page, installed or not.
            SettingsRow(title: "uBlock Origin Lite", caption: model.statusText, titleAction: model.install) {
                if model.installed {
                    Toggle("Block ads", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                        .labelsHidden().accessibilityIdentifier("settings-adblock-enabled")
                } else if model.state == .notInstalled {
                    Button("Get on the App Store", action: model.install)
                        .accessibilityIdentifier("settings-adblock-install")
                }
            }
        }
    }
}
