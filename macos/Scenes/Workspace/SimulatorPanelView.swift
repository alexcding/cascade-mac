import AppKit
import SwiftUI
import WebKit

/// The Simulator panel: the session's last simulator run, streamed by `serve-sim` to a loopback
/// page. The page is serve-sim's own and drives the device itself, so the web view gets no
/// bridge, no file access and no data that outlives it.
struct SimulatorPanelView: View {
    let model: SimulatorPreviewModel
    let openIntegrations: () -> Void

    var body: some View {
        Group {
            switch model.state {
            case .live(let url):
                SimulatorWebView(url: url, failed: model.pageFailed)
            case .idle:
                ContentUnavailableView("No simulator running", systemImage: "iphone",
                    description: Text("Run the app on a simulator to see it here."))
            case .starting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Starting the simulator preview…").foregroundColor(Theme.textTertiary)
                }
            case .unavailable:
                ContentUnavailableView {
                    Label("Simulator preview is not set up", systemImage: "iphone.slash")
                } description: {
                    Text("It needs Node.js 20 or later, from Homebrew, the Node.js installer or a version manager. Craft checks again when you come back to it.")
                } actions: {
                    Button("Open Integrations", action: openIntegrations)
                    Button("Try Again", action: model.retry)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("The simulator preview did not start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: model.retry)
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

private struct SimulatorWebView: NSViewRepresentable {
    let url: URL
    let failed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(failed: failed) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityIdentifier("simulator-preview-webview")
        view.load(URLRequest(url: url))
        return view
    }

    /// Another device's stream is another helper, on its own port.
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.failed = failed
        if view.url?.host != url.host || view.url?.port != url.port { view.load(URLRequest(url: url)) }
    }

    /// A helper that is gone refuses the connection; the panel then offers Try Again.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var failed: (String) -> Void
        init(failed: @escaping (String) -> Void) { self.failed = failed }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error.localizedDescription)
        }
    }
}
