import AppKit
import Observation
import WebKit

struct WebPageRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var url: String
    var title: String
}

@MainActor @Observable final class BrowserPage: NSObject, Identifiable, BrowserControlling, WKNavigationDelegate, WKUIDelegate {
    let id: String
    private(set) var url: String { didSet { if oldValue != url { controls.synchronizeAddress() } } }
    private(set) var title: String
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var error: String?
    private(set) var webView: WKWebView?
    private(set) var found: Bool?
    /// Set while the start page is shown over a loaded site: Back from the first real page. The
    /// site stays loaded behind it so Forward can return. WebKit never sees this entry.
    @ObservationIgnored private var parkedURL: URL?
    /// Set when the web view came from a popup configuration: its about:blank has a live document.
    private(set) var hasPopupDocument = false
    let dialogs = BrowserDialogViewModel()
    @ObservationIgnored var isOwned: () -> Bool = { false }
    @ObservationIgnored var changed: () -> Void = {}
    /// `linkActivated` is true for a plain user click on a target=_blank link; false for a
    /// scripted `window.open` or a popup that asked for window features.
    @ObservationIgnored var openPopup: ((URL, WKWebViewConfiguration, _ linkActivated: Bool) -> WKWebView?)?
    /// Set by the page factory: attaches the shared web-extension controller (ad blocking).
    @ObservationIgnored var configureWebView: (WKWebViewConfiguration) -> Void = { _ in }
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored lazy var controls = BrowserControlsViewModel(page: self)

    init(_ record: WebPageRecord) {
        id = record.id; url = record.url; title = record.title; super.init()
    }
    /// The parked site is what gets saved, so a tab left on its start page is not lost as blank.
    var record: WebPageRecord { .init(id: id, url: parkedURL?.absoluteString ?? url, title: title) }

    @discardableResult func materialize(configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> WKWebView {
        if let webView { return webView }
        hasPopupDocument = configuration != nil
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // WebKit's bare default UA has no "Version/x Safari/x" suffix, so sites such as Google
        // treat it as an unknown browser and serve their legacy layout. Present as Safari.
        configuration.applicationNameForUserAgent = Self.safariApplicationName
        configureWebView(configuration)
        // Remote pages never receive a document bridge, local file read access,
        // terminal handlers, or injected app scripts.
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setAccessibilityIdentifier("context-webview")
        webView = view
        observations = [view.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }, view.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }, view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }]
        if load, let address = safeWebURL(url) { view.load(URLRequest(url: address)) }
        return view
    }

    /// The Safari suffix WebKit appends to its default user agent: the latest Safari, or this
    /// OS's version when it is newer still.
    static let safariApplicationName: String = {
        let major = max(26, ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        return "Version/\(major).0 Safari/605.1.15"
    }()

    func evict() {
        dialogs.cancel()
        update()
        observations.removeAll()
        if let webView {
            // Dropping the view does not stop a playing page: its web process keeps the
            // audio going until WebKit tears it down. End playback and unload the document
            // first, so closing a tab is silent immediately.
            webView.stopLoading()
            webView.pauseAllMediaPlayback()
            webView.closeAllMediaPresentations()
            webView.navigationDelegate = nil; webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            webView.removeFromSuperview()
            Self.releaseWebContentProcess(of: webView)
        }
        webView = nil
        loading = false
        canGoBack = false; canGoForward = false
    }

    /// WebKit keeps a closed page's web content process in a cache for reuse, so its memory
    /// survives the view. Terminating the process returns it now. The selector is private, so
    /// it is looked up at runtime and skipped when absent; the view is released either way.
    private static func releaseWebContentProcess(of webView: WKWebView) {
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        if webView.responds(to: kill) { _ = webView.perform(kill) }
    }

    func navigate(_ address: String) {
        guard let destination = webAddress(address) else { error = "Enter a web address, like example.com."; return }
        error = nil; parkedURL = nil
        materialize().load(URLRequest(url: destination))
    }

    /// Any site can go back: through WebKit's history first, then to the start page. Consistent
    /// for tabs that began blank and tabs restored straight onto a site.
    func back() {
        guard let webView, parkedURL == nil else { return }
        // WebKit entries that would not visibly change the page (about:blank, or the same address
        // left by a redirect) are skipped, so Back does not appear to do nothing.
        if webView.canGoBack, let item = webView.backForwardList.backItem,
           !Self.isInvisibleStep(item.url, from: webView.url) { webView.goBack(); return }
        guard let current = webView.url, safeWebURL(current.absoluteString) != nil else { return }
        // The site leaves the view tree while parked; nothing of it may keep running unseen.
        webView.pauseAllMediaPlayback(); webView.closeAllMediaPresentations()
        dialogs.cancel()
        parkedURL = current
        url = WorkspaceContext.blankPageURL
        update()
    }
    private static func isInvisibleStep(_ target: URL, from current: URL?) -> Bool {
        if WorkspaceContext.isBlankAddress(target.absoluteString) || safeWebURL(target.absoluteString) == nil { return true }
        guard let current else { return false }
        return target.host == current.host && target.path == current.path && target.query == current.query
    }
    func forward() {
        if let parked = parkedURL {
            parkedURL = nil
            url = parked.absoluteString
            update()
        } else { webView?.goForward() }
    }
    func reload() { error = nil; materialize().reload() }
    func stop() { webView?.stopLoading() }
    func zoom(_ delta: Double?) {
        guard let webView else { return }
        webView.pageZoom = delta.map { min(3, max(0.5, webView.pageZoom + $0)) } ?? 1
    }
    func find(_ text: String, backwards: Bool = false) {
        guard let webView, !text.isEmpty else { found = nil; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in self?.found = result.matchFound }
    }

    private func update() {
        guard let webView else { return }
        let previous = record
        if let address = webView.url, safeWebURL(address.absoluteString) != nil {
            // Parked on the start page: the site behind may redirect; remember where it went.
            if parkedURL != nil { parkedURL = address } else { url = address.absoluteString }
        }
        if let text = webView.title, !text.isEmpty { title = text }
        loading = webView.isLoading
        let onSite = parkedURL == nil && webView.url.map { safeWebURL($0.absoluteString) != nil } == true
        canGoBack = onSite
        canGoForward = parkedURL != nil || webView.canGoForward
        if record != previous { changed() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        dialogs.cancel(); error = nil; update()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { error = nil; update() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
        update()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        dialogs.cancel()
        error = "This page stopped responding. Reload to recover it."
        loading = false
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let raw = action.request.url?.absoluteString ?? ""
        // about:blank is needed by login popups. Subframes can render data/blob
        // content, but may never navigate into the host filesystem.
        let subframe = action.targetFrame?.isMainFrame == false
        let scheme = action.request.url?.scheme ?? ""
        let allowed = safeWebURL(raw) != nil || raw == "about:blank"
            || (subframe && ["about", "data", "blob"].contains(scheme))
        if !allowed { error = "This page tried to open an unsupported address." }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url,
              safeWebURL(url.absoluteString) != nil || url.absoluteString == "about:blank" else { return nil }
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.x != nil || windowFeatures.y != nil
        return openPopup?(url, configuration, action.navigationType == .linkActivated && !sized)
    }
    private func requestDialog(_ kind: BrowserDialogViewModel.Kind, from webView: WKWebView, frame: WKFrameInfo,
                               completion: @escaping (BrowserDialogViewModel.Response) -> Void) {
        guard self.webView === webView, isOwned() else { completion(.cancel); return }
        dialogs.begin(kind, origin: frame.request.url?.host ?? "Web page", completion: completion)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        requestDialog(.alert(message), from: webView, frame: frame) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        requestDialog(.confirm(message), from: webView, frame: frame) { result in
            if case .confirm(let accepted) = result { completionHandler(accepted) } else { completionHandler(false) }
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        requestDialog(.prompt(prompt, defaultText: defaultText ?? ""), from: webView, frame: frame) { result in
            if case .text(let text) = result { completionHandler(text) } else { completionHandler(nil) }
        }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        requestDialog(.files(multiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories),
                      from: webView, frame: frame) { result in
            if case .files(let urls) = result { completionHandler(urls) } else { completionHandler(nil) }
        }
    }
}
