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
    var localization = ChatPageLocalization()
}

/// App-owned page text travels with the snapshot; transcript content remains unchanged.
struct ChatPageLocalization: Encodable, Equatable {
    /// A BCP 47 tag, as `Intl` requires: `en_US@rg=cazzzz` is `en-US-u-rg-cazzzz`, and the page's
    /// date and number formatting throws on anything else.
    var locale = Locale.current.identifier(.bcp47)
    var language = Bundle.main.preferredLocalizations.first ?? "en"
    var strings: [String: String] = [
        "Close": String(localized: "Close"),
        "Copied": String(localized: "Copied"),
        "Copy Code": String(localized: "Copy Code"),
        "Copy Link": String(localized: "Copy Link"),
        "Copy Table": String(localized: "Copy Table"),
        "Copy as %@": String(localized: "Copy as %@"),
        "%@ at %@": String(localized: "%@ at %@", comment: "Chat date line: a day, then a time"),
        "Download Diagram": String(localized: "Download Diagram"),
        "Download File": String(localized: "Download File"),
        "Download Image": String(localized: "Download Image"),
        "Download Table": String(localized: "Download Table"),
        "Download as %@": String(localized: "Download as %@"),
        "Exit Full Screen": String(localized: "Exit Full Screen"),
        "Image unavailable": String(localized: "Image unavailable"),
        "Open External Link": String(localized: "Open External Link"),
        "Open Link": String(localized: "Open Link"),
        "Reset View": String(localized: "Reset View"),
        "View Full Screen": String(localized: "View Full Screen"),
        "You are about to open an external link.": String(localized: "You are about to open an external link."),
        "Zoom In": String(localized: "Zoom In"),
        "Zoom Out": String(localized: "Zoom Out"),
        "Conversation": String(localized: "Conversation"),
        "Copy": String(localized: "Copy"),
        "Ran": String(localized: "Ran"),
        "Read": String(localized: "Read"),
        "Edited": String(localized: "Edited"),
        "Created": String(localized: "Created"),
        "Searched": String(localized: "Searched"),
        "Fetched": String(localized: "Fetched"),
        "Searched the web": String(localized: "Searched the web"),
        "Delegated": String(localized: "Delegated"),
        "Updated plan": String(localized: "Updated plan"),
        "Tool": String(localized: "Tool"),
        "Failed": String(localized: "Failed"),
        "Command": String(localized: "Command"),
        "Error": String(localized: "Error"),
        "Output": String(localized: "Output"),
        "Thought": String(localized: "Thought"),
        "Worked": String(localized: "Worked"),
        "Working": String(localized: "Working"),
        "Worked for %@": String(localized: "Worked for %@"),
        "Run this command?": String(localized: "Run this command?"),
        "Edit this file?": String(localized: "Edit this file?"),
        "Create this file?": String(localized: "Create this file?"),
        "Apply this patch?": String(localized: "Apply this patch?"),
        "Fetch this page?": String(localized: "Fetch this page?"),
        "Search the web?": String(localized: "Search the web?"),
        "Allow %@?": String(localized: "Allow %@?"),
        "Too long to show here in full. Review it in the terminal.": String(localized: "Too long to show here in full. Review it in the terminal."),
        "Review in Terminal": String(localized: "Review in Terminal"),
        "Allow": String(localized: "Allow"),
        "Deny": String(localized: "Deny"),
        "No conversation yet. Send a message to start.": String(localized: "No conversation yet. Send a message to start."),
        "Waiting to send": String(localized: "Waiting to send"),
        "Scroll to latest": String(localized: "Scroll to latest"),
        "The chat page failed to load.": String(localized: "The chat page failed to load."),
    ]
}

/// The web view the conversation is drawn in (prototype). Push-only, like the diff page: Swift
/// renders state into it, and it answers with `ready`, `copy`, `open`, `download`, `permission` and `error`.
@MainActor final class TranscriptChatPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    /// A click on an approval card: the request's id, and `allow`, `deny` or `pass`.
    var onPermission: (String, String) -> Void = { _, _ in }
    /// A link clicked in the conversation; false leaves it to the system browser.
    var onOpen: (URL) -> Bool = { _ in false }
    private(set) var failure: String?
    private var ready = false
    private var state: ChatPageState?
    private var rendered: ChatPageState?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ChatPageAssets(), forURLScheme: ChatPageAssets.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(ChatMessageReceiver(owner: self), name: "chat")
        webView.navigationDelegate = self
        // The page paints its own ground; a white flash before it loads is not ours.
        webView.setValue(false, forKey: "drawsBackground")
        if let zoom = UserDefaults.standard.object(forKey: Self.zoomKey) as? Double { webView.pageZoom = zoom }
        Self.open.add(self)
        webView.load(URLRequest(url: ChatPageAssets.pageURL))
    }

    /// One size for every chat, kept across launches, as the terminal font is.
    private static let zoomKey = "workspace.chatZoom"
    /// The chats built so far, which a change of size reaches at once, as a terminal font change does.
    private static let open = NSHashTable<TranscriptChatPage>.weakObjects()

    /// ⌘+ / ⌘− step it, as a browser page's; nil (⌘0) goes back to actual size. Every chat follows.
    func zoom(_ delta: Double?) {
        let zoom = delta.map { min(3, max(0.5, webView.pageZoom + $0)) } ?? 1
        UserDefaults.standard.set(Double(zoom), forKey: Self.zoomKey)
        for page in Self.open.allObjects { page.webView.pageZoom = zoom }
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
        Self.open.remove(self)
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
            if !onOpen(url) { NSWorkspace.shared.open(url) }
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
