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

@MainActor @Test func deckWorkspacesExcludesTabContextsAndShownDeckWorkspaceFollowsRoot() {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = DeckRuntimeFixture()
    let taskContext = WorkspaceContext(id: "task:a", sourceURL: "", title: "A")
    let tabContext = WorkspaceContext(id: "tab:b", sourceURL: "", title: "B")
    let taskModel = SessionWorkspaceViewModel(context: taskContext, service: runtime)
    let tabModel = SessionWorkspaceViewModel(context: tabContext, service: runtime)
    let taskChild = coordinator.bindWorkspace(taskModel, context: taskContext, runtime: runtime)
    let tabChild = coordinator.bindWorkspace(tabModel, context: tabContext, runtime: runtime)
    #expect(coordinator.deckWorkspaces.map(ObjectIdentifier.init) == [ObjectIdentifier(taskChild)])
    #expect(coordinator.shownDeckWorkspace == nil)
    coordinator.root = .sessionWorkspaceCoordinator(taskChild)
    #expect(coordinator.shownDeckWorkspace === taskChild)
    coordinator.root = .sessionWorkspaceCoordinator(tabChild)
    #expect(coordinator.shownDeckWorkspace == nil)
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

// A hidden page keeps its size through a window resize and takes the deck's size when shown again:
// resizing it while hidden would lay out a page nobody sees and resize the terminal in it.
@MainActor @Test func deckSizesOnlyThePageOnScreen() throws {
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
    #expect(pageA.frame.size == NSSize(width: 600, height: 500) && !pageA.isHidden)
    controller.view.setFrameSize(NSSize(width: 500, height: 400))
    #expect(pageA.frame.size == NSSize(width: 500, height: 400))
    #expect(pageB.frame.size == NSSize(width: 600, height: 500) && pageB.isHidden)
}
