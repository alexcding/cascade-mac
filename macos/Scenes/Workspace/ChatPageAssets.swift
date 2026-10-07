import Foundation
import WebKit

/// Serves the bundled chat page (`Resources/ChatPage`, built from `macos/web/chat`). Its code
/// highlighter splits into chunks loaded on demand, so any plain file name in that folder is
/// served; nothing outside it, and nothing but html, css and js.
///
/// It also serves the chat's saved image attachments at the path the page builds for them
/// (Synara's `/attachments/<id>`, resolved against the page's origin), read from the backend
/// through `attachments.read`: the page still reaches nothing but this scheme. Only a plain
/// attachment id is asked for, and only an image is answered.
@MainActor final class ChatPageAssets: NSObject, WKURLSchemeHandler {
    /// Reads one saved attachment: `attachments.read`'s `{mimeType, dataBase64}`.
    typealias AttachmentReader = @Sendable (String) async throws -> JSONValue

    /// The chat's in the page (`ChatPageHost.attach`), none while no chat is in it.
    var readAttachment: AttachmentReader?
    /// Tasks answered later (an attachment) that WebKit has not stopped.
    private var pending: Set<ObjectIdentifier> = []

    init(readAttachment: AttachmentReader? = nil) {
        self.readAttachment = readAttachment
        super.init()
    }

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

    /// The attachment id an image URL names: `cascade-chat://page/attachments/<id>`, one path
    /// component of letters, digits, `-`, `_` and `.`, not starting with a dot. Anything else, an
    /// encoded slash or `..` included, names none.
    nonisolated static func attachmentID(for url: URL) -> String? {
        let prefix = "/attachments/"
        let path = url.path(percentEncoded: true)
        guard url.scheme == scheme, url.host == "page", path.hasPrefix(prefix),
              let id = String(path.dropFirst(prefix.count)).removingPercentEncoding,
              !id.isEmpty, id.count <= 256, !id.hasPrefix("."), !id.contains(".."),
              id.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        return id
    }

    /// The bytes and type of an `attachments.read` result, when it is an image.
    nonisolated static func image(from reply: JSONValue) -> (Data, String)? {
        guard let type = reply["mimeType"]?.string?.lowercased(), type.hasPrefix("image/"),
              type.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != ";" }),
              let text = reply["dataBase64"]?.string,
              let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return nil }
        return (data, type)
    }

    /// What `url` is answered with: a page file, an attachment's image, or nothing.
    func response(for url: URL) async -> (Data, String)? {
        if let file = Self.data(for: url) { return (file.0, "\(file.1); charset=utf-8") }
        guard let id = Self.attachmentID(for: url), let readAttachment,
              let reply = try? await readAttachment(id) else { return nil }
        return Self.image(from: reply)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if let (data, type) = Self.data(for: url) {
            Self.answer(task, url: url, data: data, type: "\(type); charset=utf-8")
            return
        }
        guard Self.attachmentID(for: url) != nil, readAttachment != nil else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let key = ObjectIdentifier(task)
        pending.insert(key)
        Task { [weak self] in
            let found = await self?.response(for: url)
            // A task WebKit stopped must not be answered.
            guard let self, pending.remove(key) != nil else { return }
            guard let (data, type) = found else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            Self.answer(task, url: url, data: data, type: type)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        pending.remove(ObjectIdentifier(task))
    }

    private static func answer(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String) {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
}
