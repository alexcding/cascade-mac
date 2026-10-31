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
///
/// And it serves the documents of the page's inline visuals (Synara's `synara_show_visual`) at
/// `cascade-chat://visual/<id>.html`, each the document the page built and handed over in a
/// `visualDocument` event (`registerVisual`). Synara writes it into its frame as `srcdoc`, but
/// WebKit gives a srcdoc frame the page's own content security policy, under which none of the
/// visual's inline script runs; a document loaded from here keeps only its own policy. The frame is
/// sandboxed without `allow-same-origin`, so its origin is opaque either way, and the host's
/// navigation delegate lets a frame load nothing but a registered visual (`isVisualDocument`).
@MainActor final class ChatPageAssets: NSObject, WKURLSchemeHandler {
    /// Reads one saved attachment: `attachments.read`'s `{mimeType, dataBase64}`.
    typealias AttachmentReader = @Sendable (String) async throws -> JSONValue

    /// The chat's in the page (`ChatPageHost.attach`), none while no chat is in it.
    var readAttachment: AttachmentReader?
    /// Tasks answered later (an attachment) that WebKit has not stopped.
    private var pending: Set<ObjectIdentifier> = []
    /// The page's inline visual documents, by id, oldest first. A frame the transcript re-inserts
    /// loads its document again, so one stays until it is among the oldest past `visualLimit`.
    private var visuals: [(id: String, document: Data)] = []
    nonisolated static let visualLimit = 64
    /// Synara's limit on a visual's HTML (256 KiB) with room for the frame's own bootstrap.
    nonisolated static let visualDocumentLimit = 1024 * 1024
    /// Synara's `INLINE_VISUAL_CONTENT_SECURITY_POLICY`, which the document also carries as its
    /// first element: sent with it too, so it holds even for a document that lost its own.
    nonisolated static let visualPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        + "img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; "
        + "child-src 'none'; worker-src 'none'; object-src 'none'; manifest-src 'none'; base-uri 'none'; form-action 'none'"
    /// The response's own `sandbox` as well, beside the frame's attribute: a document loaded any
    /// other way still runs in an opaque origin. A header alone, as a meta tag cannot carry it.
    nonisolated static let visualResponsePolicy = visualPolicy + "; sandbox allow-scripts allow-forms"

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

    /// The visual id a frame URL names: `cascade-chat://visual/<id>.html`, the id letters, digits
    /// and `-` (the page's `<load token>-<n>`).
    nonisolated static func visualID(for url: URL) -> String? {
        let path = url.path(percentEncoded: true)
        guard url.scheme == scheme, url.host == "visual", url.query == nil, url.fragment == nil,
              path.hasPrefix("/"), path.hasSuffix(".html") else { return nil }
        let id = String(path.dropFirst().dropLast(".html".count))
        return Self.isVisualID(id) ? id : nil
    }

    nonisolated private static func isVisualID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Keeps a visual's document for its frame to load (the page's `visualDocument` event).
    func registerVisual(id: String, html: String) {
        guard Self.isVisualID(id) else { return }
        let document = Data(html.utf8)
        guard document.count <= Self.visualDocumentLimit else { return }
        visuals.removeAll { $0.id == id }
        visuals.append((id, document))
        if visuals.count > Self.visualLimit { visuals.removeFirst(visuals.count - Self.visualLimit) }
    }

    /// Forgets the documents of a page that is loaded again.
    func forgetVisuals() { visuals.removeAll() }

    /// Whether `url` is a registered visual's document: the one thing a frame may load.
    func isVisualDocument(_ url: URL) -> Bool {
        guard let id = Self.visualID(for: url) else { return false }
        return visuals.contains { $0.id == id }
    }

    private func visualDocument(for url: URL) -> Data? {
        guard let id = Self.visualID(for: url) else { return nil }
        return visuals.last { $0.id == id }?.document
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
        if Self.visualID(for: url) != nil {
            guard let document = visualDocument(for: url) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            Self.answer(task, url: url, data: document, type: "text/html; charset=utf-8",
                        extra: ["Content-Security-Policy": Self.visualResponsePolicy])
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

    private static func answer(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String, extra: [String: String] = [:]) {
        let headers = [
            "Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ].merging(extra) { _, new in new }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
        else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
}
