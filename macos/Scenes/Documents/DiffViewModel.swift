import Foundation
import Observation
import WebKit

struct DiffSnapshot: Codable, Equatable, Sendable {
    let diff: String
    let untracked: [String]
    let branch: String?
    var fileLinks = true
    var revision: String? = nil
    var ahead: Int? = nil
    var behind: Int? = nil
}

protocol DiffService: Sendable { func load(worktree: String) async throws -> DiffSnapshot }

struct APIDiffService: DiffService {
    let api: APIClient
    func load(worktree: String) async throws -> DiffSnapshot {
        struct Response: Decodable, Sendable {
            let diff: String?, untracked: [String]?, branch: String?, revision: String?
            let ahead: Int?, behind: Int?, error: String?
        }
        let result: Response = try await api.get(APIClient.query(Routes.DIFF, ["path": worktree]), timeout: 30)
        if let error = result.error { throw BackendError.operation(error) }
        guard let diff = result.diff else { throw BackendError.operation("The backend returned no diff.") }
        return .init(diff: diff, untracked: result.untracked ?? [], branch: result.branch,
                     revision: result.revision, ahead: result.ahead, behind: result.behind)
    }
}

/// The working-changes diff is the app's one embedded page of our own (`Resources/DiffPage`).
/// The page is push-only: this model loads the snapshot through `APIClient` and hands it to
/// `window.nativeDiff.render`; the page has no network access and reports back `ready`,
/// `open` and `discard` through a single message handler.
@MainActor @Observable final class DiffViewModel: NSObject, WKNavigationDelegate {
    enum Action { case showActions, openFile(DocumentLocation), hide }
    let coordinator: DiffCoordinator
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    var presentation = DocumentPresentation() {
        didSet {
            guard oldValue != presentation else { return }
            if oldValue.appearance != presentation.appearance { setAppearance(presentation.appearance) }
            if oldValue.font != presentation.font { setFont(presentation.font) }
            if oldValue.active != presentation.active {
                if presentation.active { show(appearance: presentation.appearance) } else { hide() }
            }
        }
    }
    let worktree: String
    private(set) var snapshot: DiffSnapshot?
    private(set) var loading = false
    private var loadError: String?
    private var documentError: String?
    var error: String? { documentError ?? loadError ?? actions?.error }
    var showsActions: Bool { get { coordinator.showsActions } set { newValue ? requestActions() : coordinator.dismissActions() } }
    var isActive: Bool { active }
    /// True once the page's module has posted `ready`; rendering before that is dropped.
    var isPageReady: Bool { loaded }
    private(set) var actions: GitChangesActions?
    private(set) var webView: WKWebView?
    @ObservationIgnored private var service: (any DiffService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var documentScript: String?
    @ObservationIgnored private var loaded = false
    /// The page's content process ended while it was hidden: `show` loads it again.
    @ObservationIgnored private var contentProcessEnded = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var appearance = AppAppearance.system
    @ObservationIgnored private var font = CodeFont(size: 12)
    @ObservationIgnored private let allowsFileOpening: Bool

    init(worktree: String, baseURL: URL, service: (any DiffService)? = nil,
         actionsService: (any GitChangesService)? = nil, allowsFileOpening: Bool = true,
         factory: any DocumentFeatureFactory = NativeDocumentFeatureFactory(),
         openFile: @escaping (DocumentLocation) -> Void = { _ in }) {
        self.allowsFileOpening = allowsFileOpening; coordinator = factory.diffCoordinator()
        self.worktree = worktree; self.service = service
        super.init()
        if let actionsService {
            actions = factory.changes(worktree: worktree, service: actionsService, didChange: { [weak self] in
                guard let self, active else { return }
                task?.cancel(); task = nil; generation = UUID(); refresh()
            })
        }
        coordinator.bind(self, openFile: openFile)
    }
    func requestActions() { onAction(.showActions) }
    func connect(baseURL: URL, service: any DiffService) {
        task?.cancel(); task = nil; generation = UUID(); loading = false; self.service = service
        if active { refresh() }
    }
    func show(appearance: AppAppearance) {
        active = true; self.appearance = appearance
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(DiffPageAssets(), forURLScheme: DiffPageAssets.scheme)
            config.userContentController.add(DiffMessageReceiver(owner: self), name: "diff")
            config.userContentController.addUserScript(WKUserScript(source: #"window.addEventListener('error', e => window.webkit.messageHandlers.diff.postMessage({type:'error', message:e.message || 'A changes-view asset failed to load.'}), true);"#,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = self
            // The page paints its own themed ground; a white flash before it loads is not ours.
            view.setValue(false, forKey: "drawsBackground")
            view.setAccessibilityIdentifier("working-diff-webview")
            webView = view
            view.load(URLRequest(url: DiffPageAssets.pageURL))
        } else if contentProcessEnded || documentError != nil {
            // macOS reclaimed the page while it was hidden, or it broke: showing it again starts it
            // afresh, as it did when every show built a new page.
            contentProcessEnded = false
            reload(); return
        }
        refresh()
    }
    func refresh() {
        guard task == nil else { return }
        guard let service else { loadError = "Connect to the backend to load changes."; return }
        loading = true; loadError = nil
        let generation = generation
        task = Task {
            defer { if self.generation == generation { loading = false; task = nil } }
            do {
                let value = try await service.load(worktree: worktree)
                try Task.checkCancellation()
                // A large patch is encoded once on a worker, never per frame or on
                // appearance changes. The page also caps the rows it renders.
                let script = try await Task.detached(priority: .userInitiated) {
                    guard value.diff.utf8.count <= 8 * 1024 * 1024, value.untracked.count <= 100_000 else {
                        throw BackendError.operation("Diff too large to display.")
                    }
                    let data = try JSONEncoder().encode(value)
                    guard data.count <= 16 * 1024 * 1024 else { throw BackendError.operation("Diff too large to display.") }
                    return "window.nativeDiff.render(\(String(decoding: data, as: UTF8.self)))"
                }.value
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                if snapshot != value { snapshot = value; documentScript = script; render() }
            } catch { if !Task.isCancelled, self.generation == generation { self.loadError = error.localizedDescription } }
        }
    }
    func waitForRefresh() async { await task?.value }
    func setAppearance(_ value: AppAppearance) {
        appearance = value
        if loaded { webView?.evaluateJavaScript("window.nativeDiff.setTheme('\(value == .system ? "system" : value.rawValue)')", completionHandler: nil) }
    }
    func setFont(_ value: CodeFont) {
        font = value
        if loaded { webView?.evaluateJavaScript("window.nativeDiff.setFont(\(value.json))", completionHandler: nil) }
    }
    func reload() { documentError = nil; loadError = nil; loaded = false; webView?.reload(); refresh() }
    private func render() {
        guard loaded, let documentScript else { return }
        let generation = generation
        webView?.evaluateJavaScript(documentScript) { [weak self] _, error in
            guard let self, self.generation == generation, let error else { return }
            let details = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            self.documentError = "Could not render changes: \(details)"
        }
    }
    /// Off screen: stop asking for changes, but keep the page and its last render, so showing it
    /// again — this pane or its session — is immediate. `show` then looks for newer changes.
    func hide() {
        active = false; onAction(.hide); actions?.cancelDiscard(); task?.cancel(); task = nil
        generation = UUID(); loading = false
    }
    /// The model is going away, and its page and content process with it.
    func disconnect() {
        presentation.active = false; hide(); service = nil; showsActions = false
        webView?.stopLoading(); webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "diff")
        webView?.removeFromSuperview(); webView = nil
        loaded = false; contentProcessEnded = false
        snapshot = nil; documentScript = nil; documentError = nil; loadError = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == DiffPageAssets.pageURL ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        // A hidden page is loaded again when it comes back; only one on screen has to say so.
        if active { documentError = "The changes view stopped. Reload to restore it." } else { contentProcessEnded = true }
    }
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { documentError = error.localizedDescription }
    }
    // A finished navigation is not readiness: the module posts `ready` once its imports
    // and event wiring are done, and only then is the snapshot rendered.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame, message.frameInfo.request.url == DiffPageAssets.pageURL,
              let body = message.body as? [String: Any], body.count <= 3 else { return }
        if body["type"] as? String == "ready" {
            loaded = true; documentError = nil; setAppearance(appearance); setFont(font); render()
        } else if body["type"] as? String == "error", let text = body["message"] as? String, text.utf8.count <= 4096 {
            documentError = "Could not load changes: \(text)"
        } else if let request = DiscardSelectionMessage.decode(body, revision: snapshot?.revision), active, loaded, !loading, let actions {
            let generation = generation
            Task {
                guard self.generation == generation, active else { return }
                await actions.prepareDiscard(revision: request.revision, selection: request.selection)
            }
        } else if body["type"] as? String == "open", let path = body["path"] as? String,
                  let line = body["line"] as? Int, active, loaded, allowsFileOpening {
            let generation = generation, root = worktree
            Task {
                do {
                    let location = try await Task.detached(priority: .userInitiated) {
                        try WorkingFileLocation.resolve(path, line: line, root: root)
                    }.value
                    guard self.generation == generation, active else { return }
                    onAction(.openFile(location))
                } catch { if self.generation == generation { loadError = error.localizedDescription } }
            }
        }
    }
}

@MainActor private final class DiffMessageReceiver: NSObject, WKScriptMessageHandler {
    weak var owner: DiffViewModel?
    init(owner: DiffViewModel) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
