import AppKit
import Foundation
import Observation
import OSLog
import WebKit

/// What the chat page shows and how it resolves file references: `ChatContext` in
/// `macos/web/chat/src/bridge.ts`. A new `threadId` replaces the conversation.
struct ChatPageContext: Encodable, Equatable, Sendable {
    enum Appearance: String, Encodable, Sendable { case light, dark }
    var threadId: String
    var projectId: String
    var cwd: String
    var projectName: String
    var appearance: Appearance = .light
    /// BCP 47, as `Intl` requires.
    var locale = Locale.current.identifier(.bcp47)
    /// Hides the composer: a terminal session's transcript, to read rather than continue.
    var readOnly = false
    var chatFontSizePx: Int? = nil
    var homeDir: String? = FileManager.default.homeDirectoryForCurrentUser.path
}

/// Where a chat page's requests go, and where its snapshot and providers come from. A live chat
/// forwards every request to the chat backend (`ChatServiceBackend`); a terminal session's
/// read-only transcript answers them its own way (`TranscriptPageBackend`), through the same model.
protocol ChatPageBackend: Sendable {
    /// One of the page's RPCs (`SYNARA.md`, "RPC methods the app serves").
    func call(_ method: String, params: JSONValue) async throws -> JSONValue
    /// `ServerProviderStatus[]`, pushed on the `providers` channel.
    func providers() async throws -> JSONValue
    /// `{snapshotSequence, thread}`, or null for a thread the backend does not have.
    func snapshot(threadID: String) async throws -> JSONValue
}

/// A live chat: everything to the chat backend, as it is. The service is looked up for each call,
/// so a page outlives a reconnect without being rebuilt.
struct ChatServiceBackend: ChatPageBackend {
    let service: @Sendable @MainActor () -> (any ChatServing)?

    private func resolve() async throws -> any ChatServing {
        guard let service = await service() else { throw ChatRPCError(message: String(localized: "Not connected to the backend.")) }
        return service
    }
    func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        try await resolve().rpc(method, params: params)
    }
    func providers() async throws -> JSONValue { try await resolve().providerStatuses() }
    func snapshot(threadID: String) async throws -> JSONValue {
        try await resolve().rpc("orchestration.getThreadDetailSnapshot", params: ["threadId": .string(threadID)])
    }
}

/// What the page tells the app that is not a request: each handled by whoever shows the page.
enum ChatPageEvent: Equatable {
    case openLink(URL)
    case openFile(path: String, line: Int?)
    case revealFile(String)
    case openTurnDiff(threadID: String, turnID: String, filePath: String?)
    case openSettings(String)
    /// Another chat to show: a fork or a review thread the page made.
    case openThread(String)
}

/// What the model sends the page: a reply to one of its requests, or a push on a channel.
enum ChatPageOutput: Equatable {
    case reply(id: String, JSONValue)
    case push(channel: String, JSONValue)

    /// The script that delivers it, through `window.nativeChat`.
    var script: String {
        switch self {
        case .reply(let id, let value):
            "window.nativeChat.reply(\(JSONValue.string(id).jsonText), \(value.jsonText))"
        case .push(let channel, let value):
            "window.nativeChat.push(\(JSONValue.string(channel).jsonText), \(value.jsonText))"
        }
    }
}

/// The chat page (`Resources/ChatPage`, Synara's client) for one thread, and the native half of its
/// bridge (`macos/web/chat/SYNARA.md`). It owns its web view; a view only attaches it.
///
/// The page asks, the model forwards to its backend and answers with the same id. On `ready` it is
/// handed its context, the providers and the thread's snapshot, in that order; the thread's live
/// events go after the snapshot, and the ones that arrive before it are held and sent once it is
/// in, so the page never sees an event it has no conversation for. Retired is terminal: a retired
/// model sends nothing and answers nothing.
@MainActor @Observable final class ChatPageModel {
    /// The chat pages' own persistent website data store (`ChatPageHost.dataStore`).
    nonisolated static let dataStoreIdentifier = UUID(uuidString: "6A1C3E52-7F0B-4C1D-9E7A-3B2D5C8F4A10")!
    private(set) var context: ChatPageContext
    /// The last error the page reported, or a failure to reach it.
    private(set) var failure: String?
    private(set) var retired = false
    /// What the page asked of the app beyond requests.
    @ObservationIgnored var onEvent: (ChatPageEvent) -> Void = { _ in }
    /// The page's web view; nil when a test takes the output instead.
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private let backend: any ChatPageBackend
    @ObservationIgnored private let copy: (String) -> Void
    @ObservationIgnored private var output: (ChatPageOutput) -> Void = { _ in }
    @ObservationIgnored private var host: ChatPageHost?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private static let log = Logger(subsystem: "com.cascade.app", category: "chat-page")

    private enum Stream: Equatable {
        /// The page is not up: nothing goes to it.
        case down
        /// The page is up and the snapshot is on its way: events wait.
        case loading
        /// The snapshot is in; events go straight through.
        case live
    }
    @ObservationIgnored private var stream = Stream.down
    @ObservationIgnored private var held: [JSONValue] = []
    /// A `ready` (or a reload) starts a new delivery; one started earlier stops where it is.
    @ObservationIgnored private var delivery = UUID()
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]

    /// `output` takes what would go to a web view, and no web view is made: for tests.
    init(context: ChatPageContext, backend: any ChatPageBackend, copy: @escaping (String) -> Void = { NativeClipboard.copy($0) },
         output: ((ChatPageOutput) -> Void)? = nil) {
        self.context = context
        self.backend = backend
        self.copy = copy
        if let output {
            // A test's output takes every value, as a page that ran it would.
            self.output = { [weak self] value in
                output(value)
                self?.delivered(value)
            }
        } else {
            // The page's attachment images are read through the same backend as its requests.
            let host = ChatPageHost(readAttachment: { id in
                try await backend.call("attachments.read", params: ["attachmentId": .string(id)])
            })
            self.host = host
            webView = host.webView
            host.owner = self
            self.output = { [weak host] value in host?.send(value) }
            // AppKit changes a view's appearance on the main thread.
            appearanceObservation = host.webView.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    self?.setAppearance(dark ? .dark : .light)
                }
            }
            host.load()
        }
    }

    // MARK: Page → native

    /// A message the page posted to `webkit.messageHandlers.chat`.
    func receive(_ body: Any) {
        guard !retired, let message = JSONValue(foundation: body) else { return }
        receive(message: message)
    }

    func receive(message: JSONValue) {
        guard !retired else { return }
        switch message["kind"]?.string {
        case "request":
            guard let id = message["id"]?.string, let method = message["method"]?.string else { return }
            request(id: id, method: method, params: message["params"] ?? [:])
        case "event":
            guard let name = message["name"]?.string else { return }
            event(name, payload: message["payload"] ?? [:])
        default: break
        }
    }

    private func request(id: String, method: String, params: JSONValue) {
        let backend = backend
        var params = params
        // Read inside the chat's own folder, whatever `cwd` the page sent.
        if ChatFileAccess.folderMethods.contains(method), case .object(var object) = params {
            object["threadId"] = .string(context.threadId)
            params = .object(object)
        }
        requests[id]?.cancel()
        requests[id] = Task { [weak self] in
            let reply: JSONValue
            do {
                let result = try await backend.call(method, params: params)
                reply = ["ok": true, "result": result]
            } catch let error as ChatRPCError {
                reply = error.reply
            } catch {
                reply = ChatRPCError(message: error.localizedDescription).reply
            }
            guard let self, !retired, !Task.isCancelled else { return }
            requests[id] = nil
            send(.reply(id: id, reply))
        }
    }

    private func event(_ name: String, payload: JSONValue) {
        switch name {
        case "ready":
            ready()
        case "openLink":
            guard let text = payload["url"]?.string, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            onEvent(.openLink(url))
        case "openFile":
            guard let path = payload["path"]?.string, let file = confined(path) else { return }
            onEvent(.openFile(path: file, line: payload["line"]?.number.map { Int($0) }))
        case "revealFile":
            guard let path = payload["path"]?.string, let file = confined(path) else { return }
            onEvent(.revealFile(file))
        case "openTurnDiff":
            guard let turn = payload["turnId"]?.string else { return }
            onEvent(.openTurnDiff(threadID: payload["threadId"]?.string ?? context.threadId, turnID: turn,
                                  filePath: payload["filePath"]?.string.map(resolve)))
        case "openSettings":
            onEvent(.openSettings(payload["path"]?.string ?? ""))
        case "openThread":
            guard let thread = payload["threadId"]?.string, !thread.isEmpty, thread.count <= 256,
                  thread != context.threadId else { return }
            onEvent(.openThread(thread))
        case "copy":
            guard let text = payload["text"]?.string, text.utf8.count <= 16 << 20 else { return }
            copy(text)
        case "error":
            let message = String((payload["message"]?.string ?? "").prefix(4096))
            failure = message
            Self.log.error("chat page error: \(message, privacy: .public)")
        case "log":
            let message = String((payload["message"]?.string ?? "").prefix(4096))
            Self.log.notice("chat page \(payload["level"]?.string ?? "info", privacy: .public): \(message, privacy: .public)")
        default: break
        }
    }

    /// A workspace-relative reference is resolved against the chat's folder.
    private func resolve(_ path: String) -> String {
        if path.hasPrefix("/") || context.cwd.isEmpty { return path }
        return ((context.cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// A file the page asks to open or reveal, as the real file it names, only when that is inside
    /// the chat's folder (`ChatFileAccess`): the page draws what the agent wrote.
    private func confined(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let file = ChatFileAccess.confined(path, to: context.cwd) else {
            Self.log.notice("chat page asked for a file outside its folder, or a missing one; ignored")
            return nil
        }
        return file
    }

    // MARK: Native → page

    /// The page is up, for the first time or again after a reload: it is told everything afresh.
    private func ready() {
        let delivery = UUID()
        self.delivery = delivery
        stream = .loading
        failure = nil
        send(.push(channel: "context", try! JSONValue.from(context)))
        let backend = backend, threadID = context.threadId
        Task { [weak self] in
            if let providers = try? await backend.providers() {
                guard let self, self.delivery == delivery, !retired else { return }
                send(.push(channel: "providers", providers))
            }
            let snapshot: JSONValue?
            do { snapshot = try await backend.snapshot(threadID: threadID) }
            catch {
                guard let self, self.delivery == delivery, !retired else { return }
                snapshotFailed(error)
                return
            }
            guard let self, self.delivery == delivery, !retired else { return }
            deliver(snapshot: snapshot ?? .null)
        }
    }

    /// The snapshot, then whatever the page has not seen of what was held.
    private func deliver(snapshot: JSONValue) {
        let after = snapshot["snapshotSequence"]?.number ?? 0
        if snapshot["thread"] != nil {
            send(.push(channel: "thread", ["kind": "snapshot", "snapshot": snapshot]))
        }
        stream = .live
        let pending = held
        held = []
        for event in pending where (event["sequence"]?.number ?? .infinity) > after {
            send(.push(channel: "thread", ["kind": "event", "event": event]))
        }
    }

    /// The thread's events from a `chat-thread` event: through at once once the snapshot is in,
    /// held until then.
    func receiveThreadEvents(_ events: [JSONValue]) {
        guard !retired else { return }
        switch stream {
        case .live:
            for event in events { send(.push(channel: "thread", ["kind": "event", "event": event])) }
        case .loading, .down:
            // Before the page is up there is nothing to send to, but the next `ready` reads a
            // snapshot that may predate them: keep them until then.
            held.append(contentsOf: events)
            if held.count > 2000 { held.removeFirst(held.count - 2000) }
        }
    }

    /// A newer snapshot from whoever polls the thread instead of streaming its events (a terminal
    /// session's transcript): through to a page that is up, whose stream it replaces. False when
    /// the page is not up, and its next `ready` reads one itself.
    @discardableResult func receiveSnapshot(_ snapshot: JSONValue) -> Bool {
        guard !retired, stream != .down else { return false }
        deliver(snapshot: snapshot)
        return true
    }

    /// The page reads the thread again: after a reconnect, when events may have been missed.
    func resync() {
        guard !retired, stream != .down else { return }
        let delivery = UUID()
        self.delivery = delivery
        stream = .loading
        let backend = backend, threadID = context.threadId
        Task { [weak self] in
            let snapshot: JSONValue
            do { snapshot = try await backend.snapshot(threadID: threadID) }
            catch {
                guard let self, self.delivery == delivery, !retired else { return }
                snapshotFailed(error)
                return
            }
            guard let self, self.delivery == delivery, !retired else { return }
            deliver(snapshot: snapshot)
        }
    }

    /// No snapshot came. Events are not held for one that may never come: the stream goes live and
    /// what was held goes through, and the page, finding a gap or no conversation, reads the thread
    /// itself.
    private func snapshotFailed(_ error: any Error) {
        Self.log.error("chat snapshot failed: \(error.localizedDescription, privacy: .public)")
        deliver(snapshot: .null)
    }

    /// The providers changed (one was installed or signed in): the page is told again.
    func refreshProviders() {
        guard !retired, stream != .down else { return }
        let backend = backend
        Task { [weak self] in
            guard let providers = try? await backend.providers(), let self, !retired, stream != .down else { return }
            send(.push(channel: "providers", providers))
        }
    }

    func setAppearance(_ appearance: ChatPageContext.Appearance) {
        guard !retired, context.appearance != appearance else { return }
        context.appearance = appearance
        if stream != .down { send(.push(channel: "context", try! JSONValue.from(context))) }
    }

    /// The chat's folder or project name changed under it.
    func update(projectName: String? = nil, cwd: String? = nil) {
        guard !retired else { return }
        var next = context
        if let projectName { next.projectName = projectName }
        if let cwd, !cwd.isEmpty { next.cwd = cwd }
        guard next != context else { return }
        context = next
        if stream != .down { send(.push(channel: "context", try! JSONValue.from(context))) }
    }

    /// The page's content process ended; it reloads and says `ready` again.
    fileprivate func pageWentAway() {
        guard !retired else { return }
        stream = .down
        delivery = UUID()
    }

    fileprivate func pageFailed(_ message: String) {
        guard !retired else { return }
        failure = message
    }

    /// The page took a push: a failure shown before is over.
    fileprivate func delivered(_ value: ChatPageOutput) {
        guard !retired, case .push = value, failure != nil else { return }
        failure = nil
    }

    private func send(_ value: ChatPageOutput) {
        guard !retired else { return }
        output(value)
    }

    var hasFocus: Bool {
        guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: webView)
    }

    func retire() {
        guard !retired else { return }
        retired = true
        delivery = UUID()
        stream = .down
        held = []
        for task in requests.values { task.cancel() }
        requests = [:]
        onEvent = { _ in }
        output = { _ in }
        appearanceObservation?.invalidate(); appearanceObservation = nil
        host?.close(); host = nil
        webView = nil
    }
}

/// The WebKit side of a chat page: the web view, its scheme, its navigation policy and its message
/// handler. Held by its `ChatPageModel`, never by a view.
@MainActor private final class ChatPageHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    weak var owner: ChatPageModel?

    /// One persistent store for every chat page, a chat's and a terminal transcript's alike: the
    /// page keeps each thread's composer draft and queued follow-ups in its localStorage, and they
    /// must outlive the page, which goes when its screen does. Not `.default()`, which the browser
    /// pane's sites share and Settings clears: the chat page's origin has nothing to do with
    /// them. Pages open at once share its localStorage; the page merges its writes
    /// (`macos/web/chat/src/storage.ts`).
    static let dataStore = WKWebsiteDataStore(forIdentifier: ChatPageModel.dataStoreIdentifier)

    init(readAttachment: @escaping ChatPageAssets.AttachmentReader) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore
        config.setURLSchemeHandler(ChatPageAssets(readAttachment: readAttachment), forURLScheme: ChatPageAssets.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        // Through a weak proxy: the controller holds its handlers strongly.
        config.userContentController.add(ChatPageMessageProxy(host: self), name: "chat")
        webView.navigationDelegate = self
        // The page paints its own ground.
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityIdentifier("chat-page")
    }

    func load() { webView.load(URLRequest(url: ChatPageAssets.pageURL)) }

    func send(_ value: ChatPageOutput) {
        webView.evaluateJavaScript(value.script) { [weak self] _, error in
            guard let self else { return }
            guard let error else { owner?.delivered(value); return }
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            owner?.pageFailed(message)
        }
    }

    func close() {
        // Synara writes drafts on a debounce; have it write them now, before the page goes. The
        // completion holds the web view until the page has.
        let webView = webView
        webView.evaluateJavaScript("window.nativeChat?.flush?.()") { _, _ in _ = webView }
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == ChatPageAssets.pageURL ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.pageWentAway()
        load()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url == ChatPageAssets.pageURL else { return }
        owner?.receive(message.body)
    }
}

@MainActor private final class ChatPageMessageProxy: NSObject, WKScriptMessageHandler {
    weak var host: ChatPageHost?
    init(host: ChatPageHost) { self.host = host }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.userContentController(userContentController, didReceive: message)
    }
}
