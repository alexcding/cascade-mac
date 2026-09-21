import Foundation
import Observation
import Testing

@MainActor @Observable private final class ControlledBrowser: BrowserControlling {
    var url = "https://example.test/original"
    var loading = false
    var canGoBack = false
    var canGoForward = false
    var error: String?
    var found: Bool?
    var navigations: [String] = []
    var actions: [String] = []
    func navigate(_ address: String) { navigations.append(address) }
    func back() { actions.append("back") }
    func forward() { actions.append("forward") }
    func reload() { actions.append("reload") }
    func stop() { actions.append("stop") }
    func zoom(_ delta: Double?) { actions.append("zoom:\(delta.map { String($0) } ?? "reset")") }
    func find(_ text: String, backwards: Bool) { actions.append("find:\(backwards):\(text)") }
    var muted = false
    var playingAudio = false
    func toggleMute() { muted.toggle(); actions.append("mute:\(muted)") }
}

/// Mute is the one control that works on a tab that is not selected: sound comes from it either
/// way. It is still gated on the page being owned, and the other controls still need selection.
@MainActor @Test func browserControlsMuteBackgroundTabsButNothingElse() {
    let page = ControlledBrowser()
    let model = BrowserControlsViewModel(page: page)
    var owned = true
    let coordinator = BrowserControlsCoordinator(canPerform: { false })
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.bind(model, page: page, isOwned: { owned })
    model.active = false
    model.reload()
    #expect(page.actions.isEmpty)
    model.toggleMute()
    #expect(page.muted && model.muted && page.actions == ["mute:true"])
    page.playingAudio = true
    #expect(model.playingAudio)
    owned = false
    model.toggleMute()
    #expect(page.muted && page.actions == ["mute:true"])
}

@MainActor @Test func browserControlsPreserveAddressEditsAndValidateNavigation() {
    let page = ControlledBrowser()
    let model = BrowserControlsViewModel(page: page)
    let coordinator = BrowserControlsCoordinator()
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.bind(model, page: page, isOwned: { true })
    model.active = true
    model.setEditingAddress(true)
    model.address = "  https://example.test/draft  "
    page.url = "https://example.test/redirect"
    model.synchronizeAddress()
    #expect(model.address == "  https://example.test/draft  ")
    for invalid in ["file:///tmp/private", "javascript:alert(1)", "https://user:password@example.test", "mailto:a@b.c"] {
        model.address = invalid
        #expect(!model.submitAddress() && model.error == "Enter a web address, like example.com.")
        #expect(model.address == invalid && page.navigations.isEmpty)
    }
    model.address = "  https://example.test/accepted\n"
    model.retry()
    #expect(page.navigations == ["https://example.test/accepted"] && model.error == nil)
    #expect(model.address == "https://example.test/accepted")
    model.setEditingAddress(false)
    #expect(model.address == page.url && page.actions.isEmpty)
    // Words that are not an address search Google instead of failing.
    model.address = "not a URL"
    #expect(model.submitAddress() && model.error == nil)
    #expect(page.navigations.last == "https://www.google.com/search?q=not%20a%20URL")
    #expect(model.address == "https://www.google.com/search?q=not%20a%20URL")
    model.address = "C++ tutorial"
    #expect(model.submitAddress() && page.navigations.last == "https://www.google.com/search?q=C%2B%2B%20tutorial")
}

@MainActor @Test func browserControlsForwardLoadingFindAndNavigationWithoutRetainingClosedPage() {
    var page: ControlledBrowser? = ControlledBrowser()
    weak var released = page
    let model = BrowserControlsViewModel(page: page!)
    let coordinator = BrowserControlsCoordinator()
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.bind(model, page: page!, isOwned: { true })
    model.active = true
    page?.loading = true
    model.toggleLoading()
    page?.loading = false
    model.toggleLoading()
    model.back(); model.forward(); model.zoom(0.1); model.zoom(nil)
    model.find("quokka"); model.find("quokka", backwards: true)
    page?.error = "Network unavailable"
    #expect(model.error == "Network unavailable")
    model.retry()
    #expect(page?.actions == ["stop", "reload", "back", "forward", "zoom:0.1", "zoom:reset", "find:false:quokka", "find:true:quokka", "reload"])
    page?.canGoBack = true; page?.canGoForward = true; page?.found = false
    #expect(model.canGoBack && model.canGoForward && model.found == false)
    page = nil
    #expect(released == nil && !model.canGoBack && !model.canGoForward)
    #expect(!model.submitAddress())
    model.toggleLoading(); model.reload() // A retained UI action cannot revive the page.
}

@MainActor @Test func browserFactoryBindsControlsAcrossNewAndRestoredContexts() throws {
    let factory = BrowserPageFactory()
    var context: WorkspaceContext? = WorkspaceContext(id: "context", sourceURL: "https://example.test/root", title: "Root", pageFactory: factory)
    var page = try #require(context?.activePage)
    let controls = page.controls
    #expect(page.controls === controls)
    controls.active = true
    _ = context?.open("https://example.test/second")
    let snapshot = try #require(context?.snapshot)
    context?.apply(snapshot)
    controls.reload()
    #expect(page.webView == nil, "Retained controls cannot revive a replaced page")
    let restored = WorkspaceContext(id: "restored", sourceURL: "", title: "", snapshot: snapshot, pageFactory: factory)
    #expect(restored.pages.allSatisfy { $0.webView == nil })
    // Controls survive eviction but do not retain a page removed from its context.
    weak var removed = page
    page = try #require(restored.activePage)
    context = nil
    #expect(removed == nil && !controls.canGoBack)
}

@MainActor @Test func browserControlsCoordinatorRejectsHiddenRemovedReboundAndOrphanedActions() {
    let page = ControlledBrowser()
    let model = BrowserControlsViewModel(page: page)
    var owned = true, allowed = true
    let coordinator = BrowserControlsCoordinator(canPerform: { allowed })
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.bind(model, page: page, isOwned: { owned })
    model.onAction?(.reload)
    #expect(page.actions.isEmpty)
    model.active = true
    model.reload()
    #expect(page.actions == ["reload"])
    allowed = false
    model.reload(); model.back()
    #expect(page.actions == ["reload"])
    allowed = true; owned = false
    model.reload(); model.onAction?(.navigate(URL(string: "https://example.test/removed")!))
    #expect(page.actions == ["reload"] && page.navigations.isEmpty)
    owned = true
    let oldAction = model.onAction
    var replacement: BrowserControlsCoordinator? = BrowserControlsCoordinator()
    replacement?.bind(model, page: page, isOwned: { owned })
    oldAction?(.reload)
    model.reload()
    #expect(page.actions == ["reload", "reload"], "Only the rebound coordinator acts")
    model.onAction?(.navigate(URL(fileURLWithPath: "/tmp/private")))
    #expect(page.navigations.isEmpty)
    model.setEditingAddress(true); model.address = "https://example.test/draft"
    model.active = false
    #expect(!model.editingAddress && model.address == page.url && !model.canGoBack)
    model.onAction?(.reload)
    #expect(page.actions == ["reload", "reload"])
    model.active = true; replacement = nil
    model.reload()
    #expect(page.actions == ["reload", "reload"])
}

@Test func typedAddressesBecomeWebURLs() {
    let cases: [(String, String?)] = [
        ("https://example.test/a", "https://example.test/a"),
        ("  http://example.test\n", "http://example.test"),
        ("example.com", "https://example.com"),
        ("www.google.com", "https://www.google.com"),
        ("github.com/org/repo?tab=1#top", "https://github.com/org/repo?tab=1#top"),
        ("localhost:3000/path", "http://localhost:3000/path"),
        ("app.localhost", "http://app.localhost"),
        ("printer.local", "http://printer.local"),
        ("192.168.1.5:8080", "http://192.168.1.5:8080"),
        ("[::1]:8080", "http://[::1]:8080"),
        ("notes", nil), ("not a URL", nil), ("", nil), ("https://", nil),
        ("file:///tmp/private", nil), ("javascript:alert(1)", nil), ("mailto:someone@example.test", nil),
        ("data:text/html,hi", nil), ("https://user:password@example.test", nil), ("ftp://example.test", nil),
    ]
    for (input, expected) in cases {
        #expect(webAddress(input)?.absoluteString == expected, "\(input)")
    }
}
