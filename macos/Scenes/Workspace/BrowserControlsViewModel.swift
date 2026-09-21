import Foundation
import Observation

@MainActor protocol BrowserControlling: AnyObject {
    var url: String { get }
    /// A scripted popup whose document lives at about:blank: blank by address, not a blank tab.
    var hasPopupDocument: Bool { get }
    var loading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var error: String? { get }
    var found: Bool? { get }
    var muted: Bool { get }
    var playingAudio: Bool { get }
    func navigate(_ address: String)
    func back()
    func forward()
    func reload()
    func stop()
    func zoom(_ delta: Double?)
    func find(_ text: String, backwards: Bool)
    func toggleMute()
}

extension BrowserControlling {
    var hasPopupDocument: Bool { false }
    var muted: Bool { false }
    var playingAudio: Bool { false }
    func toggleMute() {}
}

@MainActor @Observable final class BrowserControlsViewModel {
    enum Action {
        case navigate(URL), back, forward, reload, stop, zoom(Double?), find(String, backwards: Bool), toggleMute
    }
    enum ActionError {
        case invalidAddress
        var message: String {
            switch self {
            case .invalidAddress: "Enter a web address, like example.com."
            }
        }
    }
    var address: String
    var active = false {
        didSet { if oldValue != active && !active { editingAddress = false } }
    }
    private(set) var editingAddress = false {
        didSet { if oldValue != editingAddress && !editingAddress { synchronizeAddress() } }
    }
    private(set) var actionError: ActionError?
    // The page owns its controls. Controls must not keep a closed page alive.
    @ObservationIgnored private weak var page: (any BrowserControlling)?
    @ObservationIgnored var onAction: ((Action) -> Void)?
    @ObservationIgnored var bindingID = UUID()

    init(page: any BrowserControlling) {
        self.page = page; address = Self.displayAddress(page.url)
    }

    /// A blank tab has no address to show.
    var isBlank: Bool { page.map { WorkspaceContext.isBlankAddress($0.url) && !$0.hasPopupDocument } == true }
    private static func displayAddress(_ url: String) -> String { WorkspaceContext.isBlankAddress(url) ? "" : url }

    var loading: Bool { page?.loading == true }
    var canGoBack: Bool { active && page?.canGoBack == true }
    var canGoForward: Bool { active && page?.canGoForward == true }
    var found: Bool? { page?.found }
    var muted: Bool { page?.muted == true }
    var playingAudio: Bool { page?.playingAudio == true }
    var error: String? { actionError?.message ?? page?.error }

    /// Whether the field holds something the user typed, rather than the page's own address that
    /// focusing the field merely selected.
    var addressEdited: Bool { address != page.map { Self.displayAddress($0.url) } }
    func setEditingAddress(_ value: Bool) { editingAddress = value }
    func synchronizeAddress() {
        guard !editingAddress, let page else { return }
        address = Self.displayAddress(page.url)
    }

    @discardableResult func submitAddress() -> Bool {
        guard active, page != nil, onAction != nil else { return false }
        guard let url = webAddress(address) ?? Self.searchURL(for: address) else {
            actionError = .invalidAddress
            return false
        }
        actionError = nil
        address = url.absoluteString
        perform(.navigate(url))
        return true
    }

    /// Text that is not an address becomes a Google search, as in Safari's field. Anything shaped
    /// like a URL attempt (a scheme, or `://`) is not searched: it was meant as an address and failed.
    static func searchURL(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("://") else { return nil }
        if !text.contains(where: \.isWhitespace), let colon = text.firstIndex(of: ":"),
           text[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) { return nil }
        // `URLQueryItem` leaves "+" bare, which Google reads as a space; encode it ourselves.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=" + query)
    }

    func back() { perform(.back) }
    func forward() { perform(.forward) }
    func reload() { perform(.reload) }
    func zoom(_ delta: Double?) { perform(.zoom(delta)) }
    func retry() {
        switch actionError {
        case .invalidAddress: submitAddress()
        case nil: reload()
        }
    }
    func toggleLoading() {
        perform(loading ? .stop : .reload)
    }
    func find(_ text: String, backwards: Bool = false) { perform(.find(text, backwards: backwards)) }
    /// Any tab can be silenced, selected or not: the sound is coming from it either way.
    func toggleMute() {
        guard page != nil else { return }
        onAction?(.toggleMute)
    }
    private func perform(_ action: Action) {
        guard active, page != nil else { return }
        actionError = nil
        onAction?(action)
    }
}

@MainActor struct BrowserPageFactory {
    let controls: BrowserControlsCoordinator
    let dialogs: BrowserDialogCoordinator
    /// Nil leaves pages without the extension controller, which is what tests want.
    let adBlocker: BrowserAdBlocker?
    init(dialogs: BrowserDialogCoordinator = BrowserDialogCoordinator(), adBlocker: BrowserAdBlocker? = nil) {
        self.dialogs = dialogs; self.adBlocker = adBlocker
        controls = BrowserControlsCoordinator(canPerform: {
            dialogs.enabled && !dialogs.isPresenting && dialogs.canPresent()
        })
    }
    func make(_ record: WebPageRecord) -> BrowserPage {
        let page = BrowserPage(record)
        if let adBlocker { page.configureWebView = { adBlocker.attach(to: $0) } }
        controls.bind(page.controls, page: page, isOwned: { [weak page] in page?.isOwned() == true })
        dialogs.bind(page.dialogs, isOwned: { [weak page] in page?.isOwned() == true },
                     window: { [weak page] in page?.webView?.window })
        return page
    }
}
