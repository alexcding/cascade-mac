import SwiftUI
import WebKit

/// A chat session's screen: its page, edge to edge. The page draws the conversation, the composer
/// and its pickers; the toolbar above carries the title, the agent and the folder.
struct ChatView: View {
    let model: ChatViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let webView = model.page.webView {
                ChatPageSurface(webView: webView)
            }
            if let failure = model.page.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .lineLimit(2).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.warnBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-screen")
    }
}

/// Puts the model's web view on screen. It never makes one: the view model owns it, so the
/// conversation survives the view being rebuilt.
struct ChatPageSurface: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> ChatPageSurfaceHost { ChatPageSurfaceHost() }
    func updateNSView(_ host: ChatPageSurfaceHost, context: Context) { host.show(webView) }
    static func dismantleNSView(_ host: ChatPageSurfaceHost, coordinator: ()) { host.show(nil) }
}

final class ChatPageSurfaceHost: NSView {
    func show(_ webView: WKWebView?) {
        for view in subviews where view !== webView { view.removeFromSuperview() }
        guard let webView, webView.superview !== self else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

/// The toolbar's title for a chat: the agent's mark, then the chat's title.
struct ChatToolbarTitle: View {
    let model: ChatViewModel
    var body: some View {
        PageTitle(title: model.title) {
            if let cli = model.cli { AgentMark(key: cli, size: 16) }
        }
        .help(model.cwd)
    }
}

/// An archived chat's way back into the lists.
struct ChatUnarchiveButton: View {
    let model: ChatViewModel
    var body: some View {
        Button { model.unarchive() } label: {
            Label(String(localized: "Unarchive"), systemImage: "tray.and.arrow.up")
        }
        .help(String(localized: "This chat is archived. Unarchive it to list it in the sidebar again."))
        .accessibilityIdentifier("chat-unarchive")
    }
}
