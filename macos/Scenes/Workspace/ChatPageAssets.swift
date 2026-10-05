import Foundation
import WebKit

/// Serves the bundled chat page (`Resources/ChatPage`, built from `macos/web/chat`). Its code
/// highlighter splits into chunks loaded on demand, so any plain file name in that folder is
/// served; nothing outside it, and nothing but html, css and js.
final class ChatPageAssets: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "cascade-chat"
    nonisolated static let pageURL = URL(string: "\(scheme)://page/ChatPage.html")!
    nonisolated private static let types = ["html": "text/html", "css": "text/css", "js": "text/javascript"]

    #if DEBUG
    /// The unit-test bundle compiles these sources but carries no app resources, so tests point
    /// this at `Resources/ChatPage` in the source tree. A release build has no such switch.
    nonisolated(unsafe) static var directoryOverride: URL?
    #else
    nonisolated static var directoryOverride: URL? { nil }
    #endif

    nonisolated static func data(for url: URL) -> (Data, String)? {
        let name = url.lastPathComponent
        guard url.scheme == scheme, url.host == "page", url.path == "/\(name)",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              !name.hasPrefix("."), let type = types[url.pathExtension] else { return nil }
        let bundle = Bundle(for: ChatPageAssets.self), stem = (name as NSString).deletingPathExtension
        // A synchronized resource folder may or may not keep its directory in the bundle.
        guard let file = directoryOverride?.appendingPathComponent(name)
                ?? bundle.url(forResource: stem, withExtension: url.pathExtension, subdirectory: "ChatPage")
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
