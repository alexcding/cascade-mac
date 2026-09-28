import AppKit
import SwiftUI

/// Every open session workspace, each in its own hosting controller, with only the selected one
/// shown. One that is not selected is hidden rather than taken down: switching sessions flips
/// visibility instead of rebuilding the terminal or the pane beside it, and terminals
/// and web views never leave the window, which would blank them until they drew again. A workspace
/// is built the first time it is shown and released when its coordinator goes.
///
/// The window keeps two decks of the same workspaces: the screen's column holds each workspace, and
/// the inspector column each one's context pane (`MainSplitViewController`), so a switch rebuilds
/// neither.
struct SessionWorkspaceDeck: NSViewControllerRepresentable {
    /// What of a workspace a deck's pages show.
    enum Part {
        /// The workspace: its terminal, or its page when it has none.
        case workspace
        /// The context pane beside its terminal: the one the column is open for. With none, the deck
        /// keeps the pane it has, so a column that closes, or has closed, shows the pane that was
        /// open — never the hidden pane of a session just switched to, drawn until the column shuts.
        case pane
    }

    let workspaces: [SessionWorkspaceCoordinator]
    let shown: SessionWorkspaceCoordinator?
    var part: Part = .workspace

    /// A hosting controller starts a new SwiftUI hierarchy, which would otherwise begin with a
    /// blank environment. Each page carries the surrounding one across.
    @Environment(\.self) private var environment
    /// `\.self` only re-runs the update for the keys read here, and handing the environment on reads
    /// none, so a system light/dark switch would never reach the pages. Depend on it by name.
    @Environment(\.colorScheme) private var colorScheme

    struct Page: View {
        let environment: EnvironmentValues
        let coordinator: SessionWorkspaceCoordinator
        let part: Part

        var body: some View {
            Group {
                switch part {
                case .workspace:
                    coordinator.root.view()
                case .pane:
                    if coordinator.model.showsTerminal {
                        SessionWorkspacePane(context: coordinator.context, model: coordinator.model)
                    }
                }
            }
            .environment(\.self, environment)
        }
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
        /// A pane deck's pane on screen, kept while no pane is open (`Part.pane`). Always nil in the
        /// screen's deck.
        private weak var keptPane: SessionWorkspaceCoordinator?
        private let container = Container()
        private let part: Part

        init(part: Part = .workspace) {
            self.part = part
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The page on screen, for tests.
        var shownPage: NSView? { shownID.flatMap { pages[$0]?.view } }
        var pageCount: Int { pages.count }

        override func loadView() { view = container }

        func update(workspaces: [SessionWorkspaceCoordinator], shown: SessionWorkspaceCoordinator?, environment: EnvironmentValues) {
            let live = Set(workspaces.map(ObjectIdentifier.init))
            for (id, page) in pages where !live.contains(id) {
                release(page); pages[id] = nil
                if shownID == id { shownID = nil; keptPane = nil }
            }
            let shown = shown ?? keptPane
            let nextID = shown.map(ObjectIdentifier.init).flatMap { live.contains($0) ? $0 : nil }
            if let shown, let nextID {
                // Only the page on screen follows the environment; a hidden one catches up when shown.
                if let page = pages[nextID] { page.rootView = Page(environment: environment, coordinator: shown, part: part) }
                else { add(shown, id: nextID, environment: environment) }
            }
            guard nextID != shownID else { return }
            if let previous = shownID.flatMap({ pages[$0] }) { hide(previous) }
            if let nextID, let page = pages[nextID] {
                // A page shown before keeps its last size: the column may be about to change width
                // for it, as the context pane opens or closes for this session, and sized now it would
                // take the last session's width for a moment. A web page lays itself out for every
                // width it is given and paints each a frame late, so the chat would jump sideways.
                // The column's resize sizes it; anything still off once it has settled is set then.
                if page.view.frame.isEmpty { page.view.frame = container.bounds } else { settle(page) }
                page.view.isHidden = false
                WorkspaceSwitchSignpost.endAfterCommit()
            }
            container.shown = nextID.flatMap { pages[$0]?.view }
            shownID = nextID
            keptPane = part == .pane && nextID != nil ? shown : nil
        }

        /// A page shown again, sized to the column once the column has settled: after the context
        /// pane, which follows the same switch a main-queue turn later (`MainSplitViewController`).
        /// Only a window resized while it was hidden leaves it off by then.
        private func settle(_ page: NSHostingController<Page>) {
            DispatchQueue.main.async { [weak self, weak page] in
                guard let self, let page, container.shown === page.view, page.view.frame != container.bounds else { return }
                page.view.frame = container.bounds
            }
        }

        /// Added hidden; `update` sizes and shows it in the same pass.
        private func add(_ coordinator: SessionWorkspaceCoordinator, id: ObjectIdentifier, environment: EnvironmentValues) {
            let page = NSHostingController(rootView: Page(environment: environment, coordinator: coordinator, part: part))
            page.sizingOptions = []
            // A workspace deck already sits inside the screen's safe area. A pane deck reaches the
            // window's top, and its pages draw their bar in the title-bar zone the safe area marks.
            if part == .workspace { page.safeAreaRegions = [] }
            addChild(page)
            page.view.isHidden = true
            view.addSubview(page.view)
            pages[id] = page
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

    func makeNSViewController(context: Context) -> Controller { Controller(part: part) }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(workspaces: workspaces, shown: shown, environment: environment)
    }
}
