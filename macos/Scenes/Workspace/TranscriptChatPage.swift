import AppKit
import Foundation
import WebKit

/// Serves the bundled chat page (`Resources/ChatPage`, built from `macos/web/chat`). Its code
/// highlighter splits into chunks loaded on demand, so any plain file name in that folder is
/// served; nothing outside it, and nothing but html, css and js.
final class ChatPageAssets: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "cascade-chat"
    nonisolated static let pageURL = URL(string: "\(scheme)://page/ChatPage.html")!
    nonisolated private static let types = ["html": "text/html", "css": "text/css", "js": "text/javascript"]

    nonisolated static func data(for url: URL) -> (Data, String)? {
        let name = url.lastPathComponent
        guard url.scheme == scheme, url.host == "page", url.path == "/\(name)",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              !name.hasPrefix("."), let type = types[url.pathExtension] else { return nil }
        let bundle = Bundle(for: ChatPageAssets.self), stem = (name as NSString).deletingPathExtension
        // A synchronized resource folder may or may not keep its directory in the bundle.
        guard let file = bundle.url(forResource: stem, withExtension: url.pathExtension, subdirectory: "ChatPage")
                ?? bundle.url(forResource: stem, withExtension: url.pathExtension),
              let data = try? Data(contentsOf: file) else { return nil }
        return (data, type)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (data, type) = Self.data(for: url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "\(type); charset=utf-8", "Content-Length": "\(data.count)", "Cache-Control": "no-store",
              ]) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }

    // Every response completes inside `start`, so there is never a task left to stop.
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// What the page draws: the whole conversation, replaced on every push.
struct ChatPageState: Encodable, Equatable {
    let turns: [TranscriptTurn]
    let busy: Bool
    let pending: String?
    /// `pending` is held until the agent is back at its prompt, not yet typed.
    let queued: Bool
    let loaded: Bool
    let permission: AgentPermissionPrompt?
}

/// The web view the conversation is drawn in (prototype). Push-only, like the diff page: Swift
/// renders state into it, and it answers with `ready`, `copy`, `open`, `download`, `permission` and `error`.
@MainActor final class TranscriptChatPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    /// A click on an approval card: the request's id, and `allow`, `deny` or `pass`.
    var onPermission: (String, String) -> Void = { _, _ in }
    private(set) var failure: String?
    private var ready = false
    private var state: ChatPageState?
    private var rendered: ChatPageState?
    /// Where this chat's zoom is kept, so it survives relaunch; nil keeps it for this page only.
    private let zoomKey: String?

    /// Each session's chat has its own zoom, kept across launches like a browser's for a site.
    init(zoomKey: String? = nil) {
        self.zoomKey = zoomKey
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ChatPageAssets(), forURLScheme: ChatPageAssets.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(ChatMessageReceiver(owner: self), name: "chat")
        webView.navigationDelegate = self
        // The page paints its own ground; a white flash before it loads is not ours.
        webView.setValue(false, forKey: "drawsBackground")
        if let zoomKey, let zoom = UserDefaults.standard.object(forKey: zoomKey) as? Double { webView.pageZoom = zoom }
        webView.load(URLRequest(url: ChatPageAssets.pageURL))
    }

    /// ⌘+ / ⌘− step it, as a browser page's; nil (⌘0) goes back to actual size.
    func zoom(_ delta: Double?) {
        webView.pageZoom = delta.map { min(3, max(0.5, webView.pageZoom + $0)) } ?? 1
        if let zoomKey { UserDefaults.standard.set(Double(webView.pageZoom), forKey: zoomKey) }
    }

    /// Whether the keyboard is in the conversation itself.
    var hasFocus: Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: webView)
    }

    func render(_ state: ChatPageState) {
        self.state = state
        push()
    }

    func close() {
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
        webView.removeFromSuperview()
    }

    private func push() {
        guard ready, let state, state != rendered,
              let data = try? JSONEncoder().encode(state) else { return }
        rendered = state
        webView.evaluateJavaScript("window.nativeChat.render(\(String(decoding: data, as: UTF8.self)))") { [weak self] _, error in
            guard let self, let error else { return }
            self.failure = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == ChatPageAssets.pageURL ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Start the page afresh; it asks for the conversation again with `ready`.
        ready = false; rendered = nil
        webView.load(URLRequest(url: ChatPageAssets.pageURL))
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url == ChatPageAssets.pageURL,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true; rendered = nil; failure = nil; push()
        case "copy":
            guard let text = body["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "open":
            guard let text = body["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            NSWorkspace.shared.open(url)
        case "download":
            guard let name = body["name"] as? String, let text = body["data"] as? String,
                  text.utf8.count <= 64 << 20, let data = Data(base64Encoded: text) else { return }
            _ = Self.saveToDownloads(data, named: name)
        case "permission":
            // Only the request on screen can be answered.
            guard let id = body["id"] as? String, id == rendered?.permission?.id,
                  let decision = body["decision"] as? String else { return }
            // A request the card could not show whole is never allowed from it, only denied or
            // handed to the terminal's own prompt.
            guard ["allow", "deny", "pass"].contains(decision),
                  decision != "allow" || rendered?.permission?.truncated == false else { return }
            onPermission(id, decision)
        case "error":
            if let text = body["message"] as? String, text.utf8.count <= 4096 { failure = text }
        default: break
        }
    }

    /// Writes a file the page handed over into Downloads under the name it asked for, reduced to
    /// a plain file name, numbered like the browser does (`table 2.csv`) rather than overwriting.
    nonisolated static func saveToDownloads(_ data: Data, named name: String,
                                            in folder: URL? = nil) -> URL? {
        guard let folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return nil }
        var plain = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(200))
        while plain.hasPrefix(".") { plain.removeFirst() }
        plain = plain.trimmingCharacters(in: .whitespaces)
        if plain.isEmpty { plain = "download" }
        let stem = (plain as NSString).deletingPathExtension, ext = (plain as NSString).pathExtension
        for index in 1...999 {
            let candidate = index == 1 ? plain : ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let file = folder.appendingPathComponent(candidate)
            // `withoutOverwriting` fails on an existing name, so a race cannot clobber a file.
            if (try? data.write(to: file, options: .withoutOverwriting)) != nil {
                // Marked as downloaded, as a browser would: what an agent wrote gets Gatekeeper's check.
                var marked = file
                var values = URLResourceValues()
                values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                               kLSQuarantineAgentNameKey as String: "Cascade"]
                try? marked.setResourceValues(values)
                return file
            }
            if !FileManager.default.fileExists(atPath: file.path) { return nil }
        }
        return nil
    }
}

@MainActor private final class ChatMessageReceiver: NSObject, WKScriptMessageHandler {
    weak var owner: TranscriptChatPage?
    init(owner: TranscriptChatPage) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
