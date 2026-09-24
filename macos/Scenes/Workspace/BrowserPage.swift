import AppKit
import Observation
import WebKit

struct WebPageRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var url: String
    var title: String
}

/// Whether a menu is tracking, or has just closed. WebKit shows a page's own context menu with
/// `popUpMenuPositioningItem:`, which never reaches the view's menu chain, so `NSView.willOpenMenu`
/// never fires for it and Open Link in New Window arrives at the delegate looking exactly like a
/// scripted `window.open`. The menu's own tracking notifications are the one public signal that
/// does fire, and they tell the two apart.
@MainActor enum PageMenuTracking {
    private(set) static var active = false
    private static var observers: [any NSObjectProtocol] = []

    static func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { active = true }
            },
            // The chosen item's action runs once tracking has ended, so the flag outlives this
            // turn and is dropped on the next one.
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Task { @MainActor in active = false } }
            },
        ]
    }
}

/// The browser's own web view. ⌘R belongs to Run Project in the menu bar; while a page has the
/// keyboard, it reloads that page instead, as it would in Safari. Handled here, ahead of the menu,
/// because a menu item cannot tell which view has focus.
final class BrowserWebView: WKWebView {
    var onReload: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let onReload,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "r",
              (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        else { return super.performKeyEquivalent(with: event) }
        onReload()
        return true
    }
}

/// One file a page is saving to Downloads: progress while it transfers, then a way to find it.
@MainActor @Observable final class BrowserDownload: Identifiable {
    let id = UUID()
    private(set) var filename: String
    private(set) var destination: URL?
    private(set) var fraction: Double = 0
    private(set) var finished = false
    private(set) var error: String?
    @ObservationIgnored fileprivate weak var download: WKDownload?
    @ObservationIgnored fileprivate var observation: NSKeyValueObservation?

    init(filename: String) { self.filename = filename }

    var running: Bool { !finished && error == nil }

    fileprivate func begin(_ download: WKDownload, at destination: URL) {
        self.download = download
        self.destination = destination
        filename = destination.lastPathComponent
        observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.fraction = value }
        }
    }
    fileprivate func finish() { fraction = 1; finished = true; observation = nil }
    fileprivate func fail(_ message: String) { error = message; observation = nil }

    func cancel() { download?.cancel() }
    func reveal() {
        guard finished, let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

@MainActor @Observable final class BrowserPage: NSObject, Identifiable, BrowserControlling, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let id: String
    private(set) var url: String { didSet { if oldValue != url { controls.synchronizeAddress() } } }
    private(set) var title: String
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var error: String?
    private(set) var webView: WKWebView?
    private(set) var found: Bool?
    /// Mute is a property of the tab, not the document: it outlives navigation and suspension.
    private(set) var muted = false
    /// WebKit's word on whether the page is producing sound right now.
    private(set) var playingAudio = false
    private(set) var downloads: [BrowserDownload] = []
    @ObservationIgnored private var observingAudio = false
    /// Set while the start page is shown over a loaded site: Back from the first real page. The
    /// site stays loaded behind it so Forward can return. WebKit never sees this entry.
    @ObservationIgnored private var parkedURL: URL?
    /// What the page was showing when it was suspended, as WebKit saves it: its history, and where
    /// each entry was scrolled to. Handed back when it next loads.
    @ObservationIgnored private var suspendedState: Any?
    /// Set when the web view came from a popup configuration: its about:blank has a live document.
    private(set) var hasPopupDocument = false
    /// The page whose script opened this one as a popup. An opener handshake, such as an OAuth or
    /// payment flow, needs both documents alive while the popup is open.
    @ObservationIgnored weak var opener: BrowserPage?
    let dialogs = BrowserDialogViewModel()
    @ObservationIgnored var isOwned: () -> Bool = { false }
    @ObservationIgnored var changed: () -> Void = {}
    /// Called when this page creates its web view, and with it a content process.
    @ObservationIgnored var materialized: () -> Void = {}
    /// `openedLink` is true where the user opened a link — a click on a target=_blank link, or the
    /// page menu's Open Link in New Window — and false for a scripted `window.open` or a popup that
    /// asked for window features, both of which need the child web view back for their opener.
    @ObservationIgnored var openPopup: ((URL, WKWebViewConfiguration, _ openedLink: Bool) -> WKWebView?)?
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
        PageMenuTracking.observe()
        let view = BrowserWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setAccessibilityIdentifier("context-webview")
        view.onReload = { [weak self] in self?.reload() }
        webView = view
        if muted { applyMute(to: view) }
        observeAudio(on: view)
        observations = [view.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }, view.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }, view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }]
        // A suspended page gets its history back, and WebKit loads the entry it was on. One that
        // had not yet arrived where it was going, or never loaded at all, goes there now.
        if let state = suspendedState { suspendedState = nil; view.interactionState = state }
        if load, view.backForwardList.currentItem?.url.absoluteString != url, let address = safeWebURL(url) {
            view.load(URLRequest(url: address))
        }
        materialized()
        return view
    }

    /// Suspending it would lose nothing it cannot get back: it is not making sound, recording or
    /// downloading, it is not a popup whose opener is waiting on it, and it is not parked on its
    /// start page, where Forward returns to the site behind it as it was. A dialog needs no check:
    /// only the page on screen can hold one, and that page is never suspended.
    var canSuspend: Bool {
        guard let webView, !hasPopupDocument, parkedURL == nil, !playingAudio,
              !downloads.contains(where: \.running) else { return false }
        return webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
    }

    /// The Safari suffix WebKit appends to its default user agent: the latest Safari, or this
    /// OS's version when it is newer still.
    static let safariApplicationName: String = {
        let major = max(26, ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        return "Version/\(major).0 Safari/605.1.15"
    }()

    /// Closes the page's web view for good: nothing it was showing is kept.
    func evict() {
        suspendedState = nil
        closeWebView()
    }

    /// Ends the page's content process to free its memory. Its history, with where each entry was
    /// scrolled to, is kept: shown again, it loads back where it was.
    func suspend() {
        let state = webView?.interactionState
        closeWebView()
        suspendedState = state
    }

    private func closeWebView() {
        dialogs.cancel()
        // The download delegate is weak: a transfer outliving its page would finish unseen.
        for download in downloads { download.cancel() }
        downloads.removeAll()
        update()
        observations.removeAll()
        if let webView {
            stopObservingAudio(on: webView)
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
        loading = false; playingAudio = false
        canGoBack = false; canGoForward = false
    }

    // MARK: Sound

    /// WebKit mutes at the page level through a private setter; where it is missing, the media
    /// elements in the document are muted instead, which covers everything but Web Audio.
    private static let setPageMuted = NSSelectorFromString("_setPageMuted:")
    private static let isPlayingAudio = "_isPlayingAudio"

    func toggleMute() {
        muted.toggle()
        if let webView { applyMute(to: webView) }
    }
    private func applyMute(to view: WKWebView) {
        if view.responds(to: Self.setPageMuted), let method = view.method(for: Self.setPageMuted) {
            typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(method, to: Setter.self)(view, Self.setPageMuted, muted ? 1 : 0)
        } else {
            view.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m => { m.muted = \(muted) })")
        }
    }
    private func observeAudio(on view: WKWebView) {
        guard view.responds(to: NSSelectorFromString(Self.isPlayingAudio)) else { return }
        view.addObserver(self, forKeyPath: Self.isPlayingAudio, options: [.initial, .new], context: nil)
        observingAudio = true
    }
    private func stopObservingAudio(on view: WKWebView) {
        guard observingAudio else { return }
        view.removeObserver(self, forKeyPath: Self.isPlayingAudio)
        observingAudio = false
    }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.isPlayingAudio else {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        let playing = (change?[.newKey] as? Bool) ?? false
        Task { @MainActor in self.playingAudio = playing }
    }

    // MARK: Downloads

    func dismiss(_ download: BrowserDownload) {
        download.cancel()
        downloads.removeAll { $0 === download }
    }
    private func track(_ download: WKDownload) {
        download.delegate = self
        let item = BrowserDownload(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.download = download
        downloads.append(item)
    }
    private func item(for download: WKDownload) -> BrowserDownload? { downloads.first { $0.download === download } }

    /// The next free name in Downloads, numbered the way Finder numbers a duplicate.
    private static func downloadDestination(for filename: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name = filename.isEmpty ? "Download" : filename
        var candidate = folder.appendingPathComponent(name)
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        // The name is claimed by creating the file exclusively: WebKit writes only after this
        // returns, so two downloads deciding at once would otherwise settle on the same free name.
        while true {
            let fd = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 { close(fd); return candidate }
            if errno != EEXIST { return candidate }
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { track(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { track(download) }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let destination = Self.downloadDestination(for: suggestedFilename)
        item(for: download)?.begin(download, at: destination)
        completionHandler(destination)
    }
    func downloadDidFinish(_ download: WKDownload) { item(for: download)?.finish() }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        if (error as NSError).code == NSURLErrorCancelled { downloads.removeAll { $0 === item } } else { item.fail(error.localizedDescription) }
    }

    /// WebKit keeps a closed page's web content process in a cache for reuse, so its memory
    /// survives the view. Terminating the process returns it now. The selector is private, so
    /// it is looked up at runtime and skipped when absent; the view is released either way.
    private static func releaseWebContentProcess(of webView: WKWebView) {
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        if webView.responds(to: kill) { _ = webView.perform(kill) }
    }

    /// The content process the page runs in. WebKit names it only through a private property,
    /// looked up at runtime: nil without a web view, before its first load, or where it is absent.
    var contentProcess: Int32? {
        guard let webView, webView.responds(to: Self.webProcessIdentifier),
              let method = webView.method(for: Self.webProcessIdentifier) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let process = unsafeBitCast(method, to: Getter.self)(webView, Self.webProcessIdentifier)
        return process > 0 ? process : nil
    }
    private static let webProcessIdentifier = NSSelectorFromString("_webProcessIdentifier")

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
        let failure = error as NSError
        // 102 is WebKit's "frame load interrupted": what a navigation that became a download
        // reports. Nothing went wrong for the user.
        let interrupted = failure.domain == "WebKitErrorDomain" && failure.code == 102
        if failure.code != NSURLErrorCancelled && !interrupted { self.error = error.localizedDescription }
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
        // A link marked for download saves its target rather than showing it. blob: and data:
        // targets are fine to save; the host filesystem is never read through one.
        if action.shouldPerformDownload, let target = action.request.url,
           safeWebURL(raw) != nil || ["blob", "data"].contains(target.scheme ?? "") { decisionHandler(.download); return }
        // about:blank is needed by login popups. Subframes can render data/blob
        // content, but may never navigate into the host filesystem.
        let subframe = action.targetFrame?.isMainFrame == false
        let scheme = action.request.url?.scheme ?? ""
        let allowed = safeWebURL(raw) != nil || raw == "about:blank"
            || (subframe && ["about", "data", "blob"].contains(scheme))
        if !allowed { error = "This page tried to open an unsupported address." }
        decisionHandler(allowed ? .allow : .cancel)
    }
    /// A response the page cannot display, or one the server marked as an attachment, is saved.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let attachment = disposition.trimmingCharacters(in: .whitespaces).hasPrefix("attachment")
        // A frame the page embedded may not drop files on the user unless the server asked for it.
        let download = attachment || (response.isForMainFrame && !response.canShowMIMEType)
        decisionHandler(download ? .download : .allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url,
              safeWebURL(url.absoluteString) != nil || url.absoluteString == "about:blank" else { return nil }
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.x != nil || windowFeatures.y != nil
        let openedLink = action.navigationType == .linkActivated || PageMenuTracking.active
        return openPopup?(url, configuration, openedLink && !sized)
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
