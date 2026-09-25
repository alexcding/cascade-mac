import AppKit
import SwiftUI

/// The Simulator panel: the session's last simulator run, streamed by `serve-sim` to a loopback
/// page the model keeps (`SimulatorPreviewModel.webView`).
struct SimulatorPanelView: View {
    let model: SimulatorPreviewModel
    let openIntegrations: () -> Void

    var body: some View {
        Group {
            switch model.state {
            case .live:
                BrowserSurface(webView: model.webView)
            case .idle:
                ContentUnavailableView(String(localized: "No simulator running"), systemImage: "iphone",
                    description: Text(String(localized: "Run the app on a simulator to see it here.")))
            case .starting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Starting the simulator preview…")).foregroundColor(Theme.textTertiary)
                }
            case .unavailable:
                ContentUnavailableView {
                    Label(String(localized: "Simulator preview is not set up"), systemImage: "iphone.slash")
                } description: {
                    Text(String(localized: "It needs Node.js 20 or later, from Homebrew, the Node.js installer or a version manager. Cascade checks again when you come back to it."))
                } actions: {
                    Button(String(localized: "Open Integrations"), action: openIntegrations)
                    Button(String(localized: "Try Again"), action: model.retry)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label(String(localized: "The simulator preview did not start"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(String(localized: "Try Again"), action: model.retry)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
        .accessibilityIdentifier("workspace-simulator-panel")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.applicationBecameActive()
        }
    }
}
