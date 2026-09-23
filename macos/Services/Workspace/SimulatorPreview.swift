import Foundation
import Observation
import WebKit

// The Simulator panel: Expo's `serve-sim` streams a booted simulator to a loopback page, which
// the workspace shows beside the session. The backend starts and stops the stream; this file
// only knows which device a session last ran on and what the panel should show for it.

protocol SimulatorPreviewing: Sendable {
    /// The loopback page streaming `udid`, starting its stream when there is none yet.
    func start(udid: String) async throws -> URL
    /// Stops every stream, as explicit Quit does for the session shells.
    func stopAll() async
}

struct APISimulatorPreviewService: SimulatorPreviewing {
    let api: APIClient
    private struct Started: Decodable, Sendable { let udid: String; let url: String }

    func start(udid: String) async throws -> URL {
        let started: Started = try await api.request(Routes.SIM_PREVIEW, method: "POST", body: ["udid": udid], timeout: 120)
        guard let url = Self.loopback(started.url) else {
            throw BackendError.operation("serve-sim answered with an address that is not on this Mac.")
        }
        return url
    }

    func stopAll() async {
        let _: OperationOK? = try? await api.request(Routes.SIM_PREVIEW, method: "DELETE", body: [String: String](), timeout: 20)
    }

    /// The panel has no address bar, so it only ever loads a page served from this Mac.
    static func loopback(_ value: String) -> URL? {
        guard let url = safeWebURL(value), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { return nil }
        return url
    }
}

@MainActor @Observable final class SimulatorPreviewModel {
    enum State: Equatable {
        /// Nothing has run on a simulator in this session yet.
        case idle
        case starting
        case live(URL)
        /// No Node.js 20 or later to run serve-sim on: the panel sends the user to Settings.
        case unavailable
        case failed(String)
    }
    private(set) var state: State = .idle {
        // A page is only good for the stream it was loaded from: once the panel leaves live, the next
        // live state loads afresh, even at the same address — a new helper can take the old port.
        didSet {
            guard pageURL != nil else { return }
            if case .live = state {} else { pageURL = nil; pageLoad = nil; webView?.stopLoading() }
        }
    }
    private(set) var udid: String?
    private let service: any SimulatorPreviewing
    private var generation = UUID()
    private var retired = false

    init(service: any SimulatorPreviewing) { self.service = service }

    /// Shows `udid`'s stream, starting it when needed. A later call wins over one still starting.
    /// Asked again while live, it still asks the backend: the helper may have gone since (killed
    /// from a terminal, the device shut down), and a live one answers at once with the same page.
    func show(udid: String) {
        guard !retired, !udid.isEmpty else { return }
        let refreshing = self.udid == udid && { if case .live = state { true } else { false } }()
        self.udid = udid
        start(quietly: refreshing)
    }

    func retry() {
        guard !retired, udid != nil else { return }
        start(quietly: false)
    }

    /// Craft came back to the front, perhaps from a terminal that just installed Node: a preview
    /// that was not set up asks again. Quietly, so a check that still finds nothing leaves the
    /// panel as it was; one that gets further than that check shows that it is starting.
    func applicationBecameActive() {
        // Not while a check is still out: that one answers for this activation too.
        guard !retired, udid != nil, state == .unavailable, answered == generation else { return }
        start(quietly: true, revealAfter: .milliseconds(400))
    }

    /// The page itself failed to load or went away: the stream is gone, so offer Try Again.
    func pageFailed(_ message: String) {
        guard !retired, case .live = state else { return }
        generation = UUID(); state = .failed(message)
    }

    /// The stream's page, made the first time the panel draws it live and kept here rather than in
    /// the panel's view: the panel is taken down and put back as the pane and the session change,
    /// and a new web view is a new content process and a new connection to the helper. The page is
    /// serve-sim's own and drives the device itself, so it gets no bridge, no file access and no
    /// data that outlives it. Not observed: the panel asks for it while drawing.
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var pageURL: URL?
    /// The load the page is on: only its failure says the stream is gone, not a stale one's.
    @ObservationIgnored private var pageLoad: WKNavigation?
    @ObservationIgnored private var navigation: PageNavigation?

    /// The live stream's page, loading `url` when it is another helper's (another device streams
    /// on its own port) or the panel was not live since the last load.
    func page(for url: URL) -> WKWebView {
        let view = webView ?? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: config)
            let navigation = PageNavigation(owner: self)
            view.navigationDelegate = navigation
            self.navigation = navigation
            view.setValue(false, forKey: "drawsBackground")
            view.setAccessibilityIdentifier("simulator-preview-webview")
            webView = view
            return view
        }()
        if pageURL?.host != url.host || pageURL?.port != url.port {
            pageURL = url
            pageLoad = view.load(URLRequest(url: url))
        }
        return view
    }

    /// Terminal: the session's build model went away, and this panel with it. The stream itself
    /// is left running, since another session may be showing the same device.
    func retire() {
        retired = true; generation = UUID(); state = .idle
        webView?.stopLoading(); webView?.navigationDelegate = nil
        webView?.removeFromSuperview(); webView = nil; navigation = nil; pageLoad = nil
    }

    /// A helper that is gone refuses the connection; the panel then offers Try Again. A load that
    /// a newer one replaced, or one from before the panel last left live, is not a failure.
    @MainActor private final class PageNavigation: NSObject, WKNavigationDelegate {
        weak var owner: SimulatorPreviewModel?
        init(owner: SimulatorPreviewModel) { self.owner = owner }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(navigation, error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(navigation, error)
        }
        private func failed(_ navigation: WKNavigation?, _ error: Error) {
            guard let owner, navigation === owner.pageLoad, (error as NSError).code != NSURLErrorCancelled else { return }
            owner.pageFailed(error.localizedDescription)
        }
    }

    /// `quietly` keeps what is on screen while the backend answers: a live page it confirms, or
    /// a "not set up" it may only confirm again. `revealAfter` shows the spinner after all when
    /// the answer takes that long, since then something is really starting.
    private func start(quietly: Bool, revealAfter delay: Duration? = nil) {
        guard let udid else { return }
        let generation = UUID(); self.generation = generation
        if !quietly { state = .starting }
        if let delay {
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !self.retired, self.generation == generation, self.answered != generation else { return }
                self.state = .starting
            }
        }
        Task { [weak self, service] in
            let result: State
            do { result = .live(try await service.start(udid: udid)) }
            catch { result = Self.state(for: error) }
            guard let self, !self.retired, self.generation == generation else { return }
            self.answered = generation
            self.state = result
        }
    }
    /// The start the backend has answered, so a late spinner does not cover its answer.
    private var answered: UUID?

    /// The backend reports a missing Node with this wording (`sim_preview.rs`, `MISSING`).
    nonisolated static func state(for error: Error) -> State {
        let message = error.localizedDescription
        return message.contains("needs Node.js 20 or later") ? .unavailable : .failed(message)
    }
}
