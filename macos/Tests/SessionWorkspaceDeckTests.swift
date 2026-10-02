import AppKit
import SwiftUI
import Testing
import WebKit

@MainActor private final class DeckRuntimeFixture: WorkspaceCoordinating {
    var state = SessionWorkspaceState()
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { state }
    func ownsWorkspace(_ context: WorkspaceContext) -> Bool { true }
    func performWorkspaceOperation(_ operation: WorkspaceOperation, in context: WorkspaceContext) {}
    func makeWorkspaceBuild(in context: WorkspaceContext) -> BuildWorkspaceViewModel? { nil }
    func makeWorkspaceRemoval(in context: WorkspaceContext) -> SessionRemovalViewModel? { nil }
    func restartWorkspaceSession(_ id: String, in context: WorkspaceContext) {}
}

@MainActor private func deckCoordinator(id: String, title: String, runtime: DeckRuntimeFixture) -> SessionWorkspaceCoordinator {
    let context = WorkspaceContext(id: id, sourceURL: "", title: title)
    let model = SessionWorkspaceViewModel(context: context, service: runtime)
    return SessionWorkspaceCoordinator(model: model, context: context)
}

@MainActor @Test func deckFirstShowBuildsOneVisiblePage() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    controller.update(workspaces: [a], shown: a, environment: EnvironmentValues())
    #expect(controller.pageCount == 1)
    let page = controller.shownPage
    #expect(page != nil)
    #expect(page?.isHidden == false)
    #expect(page?.superview === controller.view)
}

@MainActor @Test func deckSwitchingBackAndForthReusesThePageAndHidesTheOther() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let pageA = controller.shownPage
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    #expect(controller.pageCount == 2)
    #expect(pageA?.isHidden == true)
    let pageB = controller.shownPage
    #expect(pageB != nil && pageB !== pageA)
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    #expect(controller.shownPage === pageA)
    #expect(pageB?.isHidden == true)
}

// The inspector column's deck holds each workspace's pane the same way: coming back to a session
// finds its pane as it was left, not built again.
@MainActor @Test func paneDeckSwitchingBackReusesThePane() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller(part: .pane)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let paneA = controller.shownPage
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    #expect(paneA?.isHidden == true)
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    #expect(controller.shownPage === paneA && controller.pageCount == 2)
}

// A pane deck told no pane is open keeps the one it has: switching to a session whose pane is hidden
// leaves the last pane in the column while it shuts, rather than showing the hidden one.
@MainActor @Test func paneDeckWithNoPaneKeepsTheLastOne() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller(part: .pane)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let paneA = controller.shownPage
    controller.update(workspaces: [a, b], shown: nil, environment: environment)
    #expect(controller.shownPage === paneA && paneA?.isHidden == false && controller.pageCount == 1)
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    #expect(paneA?.isHidden == true && controller.pageCount == 2)
    controller.update(workspaces: [b], shown: nil, environment: environment)
    #expect(controller.pageCount == 1 && controller.shownPage != nil, "Still the pane it had")
    controller.update(workspaces: [a], shown: nil, environment: environment)
    #expect(controller.shownPage == nil, "A dropped workspace's pane goes with it")
}

// A dropped workspace's pane is not kept: back in the deck with no pane open, it is not shown.
@MainActor @Test func paneDeckForgetsADroppedWorkspacesPane() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller(part: .pane)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a], shown: a, environment: environment)
    controller.update(workspaces: [], shown: nil, environment: environment)
    controller.update(workspaces: [a], shown: nil, environment: environment)
    #expect(controller.shownPage == nil && controller.pageCount == 0)
}

// The pane deck sizes as the screen's does: a pane shown again keeps its size until the column has
// settled, then takes the column's.
@MainActor @Test func paneDeckSizesAPaneShownAgainOnceTheColumnSettles() async throws {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller(part: .pane)
    controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let paneA = try #require(controller.shownPage)
    #expect(paneA.frame.size == NSSize(width: 320, height: 600))
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    controller.view.setFrameSize(NSSize(width: 400, height: 600))
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    #expect(paneA.frame.size == NSSize(width: 320, height: 600) && !paneA.isHidden, "Not the column's size before it settles")
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    #expect(paneA.frame.size == NSSize(width: 400, height: 600))
}

@MainActor @Test func deckDroppingAWorkspaceRemovesItsPage() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let pageA = controller.shownPage
    controller.update(workspaces: [b], shown: b, environment: environment)
    #expect(controller.pageCount == 1)
    #expect(pageA?.superview == nil)
    #expect(controller.children.count == 1)
}

@MainActor @Test func deckShownNilHidesThePage() {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    let environment = EnvironmentValues()
    controller.update(workspaces: [a], shown: a, environment: environment)
    let page = controller.shownPage
    controller.update(workspaces: [a], shown: nil, environment: environment)
    #expect(controller.shownPage == nil)
    #expect(page?.isHidden == true)
}

private final class ProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// The deck in a real window, which a first responder needs.
@MainActor private func windowed(_ controller: SessionWorkspaceDeck.Controller) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 400, height: 300))
    window.layoutIfNeeded()
    return window
}

// This and the web view case below pin where the keyboard goes when its page is hidden: back to
// the window. AppKit already does that for a hidden ancestor, so they hold the outcome, not the
// deck's own hand-off.
@MainActor @Test func deckHidingAPageReturnsFirstResponderToTheWindow() throws {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    let window = windowed(controller)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let pageA = try #require(controller.shownPage)
    let probe = ProbeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    pageA.addSubview(probe)
    window.makeFirstResponder(probe)
    #expect(window.firstResponder === probe)
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    // Where taking the workspace down used to leave it: with the window.
    #expect(window.firstResponder === window)
    window.close()
}

@MainActor @Test func deckWorkspacesListEveryWorkspaceAndShownDeckWorkspaceFollowsRoot() {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = DeckRuntimeFixture()
    let taskContext = WorkspaceContext(id: "task:a", sourceURL: "", title: "A")
    let scratchContext = WorkspaceContext(id: "scratch", sourceURL: "", title: "Terminal")
    let taskModel = SessionWorkspaceViewModel(context: taskContext, service: runtime)
    let scratchModel = SessionWorkspaceViewModel(context: scratchContext, service: runtime)
    let taskChild = coordinator.bindWorkspace(taskModel, context: taskContext, runtime: runtime)
    let scratchChild = coordinator.bindWorkspace(scratchModel, context: scratchContext, runtime: runtime)
    #expect(coordinator.deckWorkspaces.map(ObjectIdentifier.init) == [ObjectIdentifier(taskChild), ObjectIdentifier(scratchChild)])
    #expect(coordinator.shownDeckWorkspace == nil)
    coordinator.root = .sessionWorkspaceCoordinator(taskChild)
    #expect(coordinator.shownDeckWorkspace === taskChild)
    coordinator.root = .sessionWorkspaceCoordinator(scratchChild)
    #expect(coordinator.shownDeckWorkspace === scratchChild)
    coordinator.root = .none
    #expect(coordinator.shownDeckWorkspace == nil)
}

// The browser pane's page holds the keyboard while its session is on screen; switching sessions must
// take it away, or keys typed next reach a page nobody can see.
@MainActor @Test func deckHidingAPageTakesTheKeyboardFromAWebViewInIt() throws {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    let window = windowed(controller)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let pageA = try #require(controller.shownPage)
    let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    pageA.addSubview(page)
    window.makeFirstResponder(page)
    let focused = window.firstResponder as? NSView
    #expect(focused === page || focused?.isDescendant(of: page) == true)
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    // Where taking the workspace down used to leave it: with the window.
    #expect(window.firstResponder === window)
    window.close()
}

// A hidden page keeps its size through a window resize: resizing it while hidden would lay out a page
// nobody sees and resize the terminal in it. Shown again, it keeps it until the column has settled,
// so a web page in it never lays out for a width it is not given to keep.
@MainActor @Test func deckSizesOnlyThePageOnScreen() async throws {
    let runtime = DeckRuntimeFixture()
    let a = deckCoordinator(id: "task:a", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "task:b", title: "B", runtime: runtime)
    let controller = SessionWorkspaceDeck.Controller()
    controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let environment = EnvironmentValues()
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    let pageA = try #require(controller.shownPage)
    #expect(pageA.frame.size == NSSize(width: 400, height: 300))
    controller.update(workspaces: [a, b], shown: b, environment: environment)
    let pageB = try #require(controller.shownPage)
    controller.view.setFrameSize(NSSize(width: 600, height: 500))
    #expect(pageB.frame.size == NSSize(width: 600, height: 500))
    #expect(pageA.frame.size == NSSize(width: 400, height: 300))
    controller.update(workspaces: [a, b], shown: a, environment: environment)
    #expect(pageA.frame.size == NSSize(width: 400, height: 300) && !pageA.isHidden, "Not the column's size before it settles")
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    #expect(pageA.frame.size == NSSize(width: 600, height: 500))
    controller.view.setFrameSize(NSSize(width: 500, height: 400))
    #expect(pageA.frame.size == NSSize(width: 500, height: 400))
    #expect(pageB.frame.size == NSSize(width: 600, height: 500) && pageB.isHidden)
}

/// Every appearance SwiftUI pinned on a view in this subtree, leaving out hidden pages when asked.
@MainActor private func pinnedAppearances(in view: NSView, shownOnly: Bool = false) -> [NSAppearance.Name] {
    guard !(shownOnly && view.isHidden) else { return [] }
    return (view.appearance.map { [$0.name] } ?? []) + view.subviews.flatMap { pinnedAppearances(in: $0, shownOnly: shownOnly) }
}

// A system light/dark switch reaches a session's page: the terminal and the chat take their
// appearance from the deck page's host, which SwiftUI pins. The deck hands its environment on
// without reading the colour scheme, and `\.self` alone never re-ran it for it, so every pin stayed
// in the appearance the session was built in. A page hidden through the switch catches up when it
// is shown.
@MainActor @Test func deckPagesFollowTheAppAppearance() async throws {
    _ = NSApplication.shared
    let saved = NSApp.appearance
    defer { NSApp.appearance = saved }
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let runtime = DeckRuntimeFixture()
    // A scratch workspace shows a terminal without a session behind it.
    let a = deckCoordinator(id: "scratch", title: "A", runtime: runtime)
    let b = deckCoordinator(id: "scratch", title: "B", runtime: runtime)
    let hosting = NSHostingView(rootView: SessionWorkspaceDeck(workspaces: [a, b], shown: b))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.contentView = nil; window.close() }
    func settle(until done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }
    try await settle { !pinnedAppearances(in: hosting).isEmpty }
    hosting.rootView = SessionWorkspaceDeck(workspaces: [a, b], shown: a)
    try await settle { !pinnedAppearances(in: hosting, shownOnly: true).isEmpty }
    let dark = pinnedAppearances(in: hosting, shownOnly: true)
    #expect(!dark.isEmpty && dark.allSatisfy { $0 == .darkAqua }, "\(dark)")

    NSApp.appearance = NSAppearance(named: .aqua)
    try await settle { pinnedAppearances(in: hosting, shownOnly: true).allSatisfy { $0 == .aqua } }
    let shown = pinnedAppearances(in: hosting, shownOnly: true)
    #expect(shown.allSatisfy { $0 == .aqua }, "\(shown)")

    hosting.rootView = SessionWorkspaceDeck(workspaces: [a, b], shown: b)
    try await settle { pinnedAppearances(in: hosting, shownOnly: true).allSatisfy { $0 == .aqua } }
    let revealed = pinnedAppearances(in: hosting, shownOnly: true)
    #expect(!revealed.isEmpty && revealed.allSatisfy { $0 == .aqua }, "\(revealed)")
}
