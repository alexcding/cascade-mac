import Foundation
import WebKit

/// Serves the bundled diff page. ES modules do not load over `file://`, and the embedded
/// backend serves no static files, so the page gets a scheme of its own. Only the files
/// named here exist; everything else on the scheme is a 404.
final class DiffPageAssets: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "craft-diff"
    nonisolated static let pageURL = URL(string: "\(scheme)://page/DiffPage.html")!
    nonisolated private static let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript"]
    nonisolated private static let files: Set<String> = ["DiffPage.html", "DiffPage.css", "DiffPage.js", "DiffParse.mjs", "DiffHighlight.mjs"]

    /// The unit-test bundle compiles these sources but carries no app resources, so tests point
    /// this at `Resources/DiffPage` in the source tree. Production always reads the bundle.
    nonisolated(unsafe) static var directoryOverride: URL?

    nonisolated static func data(for url: URL) -> (Data, String)? {
        let name = url.lastPathComponent
        guard url.scheme == scheme, url.host == "page", url.path == "/\(name)", files.contains(name),
              let type = types[url.pathExtension] else { return nil }
        let bundle = Bundle(for: DiffPageAssets.self), stem = (name as NSString).deletingPathExtension
        // A synchronized resource folder may or may not keep its directory in the bundle.
        guard let file = directoryOverride?.appendingPathComponent(name)
                ?? bundle.url(forResource: stem, withExtension: url.pathExtension)
                ?? bundle.url(forResource: stem, withExtension: url.pathExtension, subdirectory: "DiffPage"),
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
