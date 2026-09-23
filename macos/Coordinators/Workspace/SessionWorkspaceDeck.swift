import AppKit
import SwiftUI

/// Every open session workspace, each in its own hosting controller, with only the selected one
/// shown. One that is not selected is hidden rather than taken down: switching sessions flips
/// visibility instead of rebuilding the terminal, the split and the pane beside it, and terminals
/// and web views never leave the window, which would blank them until they drew again. A workspace
/// is built the first time it is shown and released when its coordinator goes.
struct SessionWorkspaceDeck: NSViewControllerRepresentable {
    let workspaces: [SessionWorkspaceCoordinator]
    let shown: SessionWorkspaceCoordinator?

    /// A hosting controller starts a new SwiftUI hierarchy, which would otherwise begin with a
    /// blank environment. Each page carries the surrounding one across, as `NativeSplitView` does.
    @Environment(\.self) private var environment

    struct Page: View {
        let environment: EnvironmentValues
        let coordinator: SessionWorkspaceCoordinator
        var body: some View { coordinator.root.view().environment(\.self, environment) }
    }

    /// Sizes only the page on screen. A hidden one keeps its last size until it is shown again:
    /// resizing it would lay out a page nobody sees and resize its terminal, making the agent in it
    /// redraw, on every step of a window resize.
    final class Container: NSView {
        weak var shown: NSView?
        override func resizeSubviews(withOldSize oldSize: NSSize) { shown?.frame = bounds }
    }

    final class Controller: NSViewController {
        private var pages: [ObjectIdentifier: NSHostingController<Page>] = [:]
        private var shownID: ObjectIdentifier?
        private let container = Container()

        /// The page on screen, for tests.
        var shownPage: NSView? { shownID.flatMap { pages[$0]?.view } }
        var pageCount: Int { pages.count }

        override func loadView() { view = container }

        func update(workspaces: [SessionWorkspaceCoordinator], shown: SessionWorkspaceCoordinator?, environment: EnvironmentValues) {
            let live = Set(workspaces.map(ObjectIdentifier.init))
            for (id, page) in pages where !live.contains(id) {
                release(page); pages[id] = nil
                if shownID == id { shownID = nil }
            }
            let nextID = shown.map(ObjectIdentifier.init).flatMap { live.contains($0) ? $0 : nil }
            if let shown, let nextID {
                let page = pages[nextID] ?? add(shown, id: nextID, environment: environment)
                // Only the page on screen follows the environment; a hidden one catches up when shown.
                page.rootView = Page(environment: environment, coordinator: shown)
            }
            guard nextID != shownID else { return }
            if let previous = shownID.flatMap({ pages[$0] }) { hide(previous) }
            if let nextID, let page = pages[nextID] {
                page.view.frame = container.bounds
                page.view.isHidden = false
                WorkspaceSwitchSignpost.endAfterCommit()
            }
            container.shown = nextID.flatMap { pages[$0]?.view }
            shownID = nextID
        }

        private func add(_ coordinator: SessionWorkspaceCoordinator, id: ObjectIdentifier,
                         environment: EnvironmentValues) -> NSHostingController<Page> {
            let page = NSHostingController(rootView: Page(environment: environment, coordinator: coordinator))
            page.sizingOptions = []
            // The deck already sits inside the detail column's safe area.
            page.safeAreaRegions = []
            addChild(page)
            page.view.frame = view.bounds
            page.view.isHidden = true
            view.addSubview(page.view)
            pages[id] = page
            return page
        }

        /// Keys must not reach a session nobody can see: the keyboard goes back to the window, as it
        /// did when the workspace was taken down. AppKit does the same for a hidden ancestor today;
        /// saying it here keeps it the deck's rule rather than a side effect.
        private func hide(_ page: NSHostingController<Page>) {
            if let window = view.window, let responder = window.firstResponder as? NSView,
               responder.isDescendant(of: page.view) {
                window.makeFirstResponder(nil)
            }
            page.view.isHidden = true
        }

        private func release(_ page: NSHostingController<Page>) {
            hide(page)
            page.view.removeFromSuperview()
            page.removeFromParent()
        }
    }

    func makeNSViewController(context: Context) -> Controller { Controller() }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(workspaces: workspaces, shown: shown, environment: environment)
    }
}
