import AppKit
import Observation
import SwiftUI

/// The columns inside the main window's card (`MainWindowViewController`): the screen
/// (`AppCoordinatorView`) and the shown workspace's context pane. They are plain columns — the pane
/// is not AppKit's inspector, which reaches the window's top — so both start at the card's top,
/// under the toolbar, whose pane section tracks their divider (`MainToolbarController`,
/// `splitView`). AppKit keeps each column to its minimum width, so no drag or window resize can
/// squeeze one to nothing.
///
/// The pane column follows the workspace on show: open while its pane is (`showsInspector`), and
/// the other way round, a pane the user collapses or opens from the divider or a menu is told to
/// its workspace.
@MainActor final class MainSplitViewController: NSSplitViewController {
    private let coordinator: AppCoordinator
    private let contentItem: NSSplitViewItem
    private let paneItem: NSSplitViewItem
    /// The pane state last asked of the column; a collapse that differs came from the user.
    private var expectedCollapsed = true
    /// The workspace on show when the pane was last set, to tell a toggle from a switch.
    private var shownWorkspace: ObjectIdentifier?
    private var collapseObservation: NSKeyValueObservation?
    /// Told whenever the pane's column opens or shuts, however it was asked to: the window holds
    /// the card's column wide enough for it.
    var onPaneCollapsed: (Bool) -> Void = { _ in }

    /// Not the old `CascadeCardColumns`: its first column was the list, which is now the window's
    /// sidebar, so a saved screen would open at the list's width.
    static let autosaveName = "CascadeCardPane"

    init(model: AppViewModel) {
        let coordinator = model.coordinator
        self.coordinator = coordinator
        let content = NSHostingController(rootView: MainContentColumn(model: model))
        let pane = NSHostingController(rootView: MainPaneColumn(coordinator: coordinator))
        // The columns' widths are the split view's to decide, not their content's.
        content.sizingOptions = []
        pane.sizingOptions = []
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = MainWindowMetrics.contentMin
        paneItem = NSSplitViewItem(viewController: pane)
        paneItem.minimumThickness = MainWindowMetrics.paneMin
        paneItem.canCollapse = true
        // Equal holding priorities: a window resize is shared between the screen and the pane in
        // proportion, as it was between the terminal and the pane before.
        paneItem.holdingPriority = contentItem.holdingPriority
        paneItem.isCollapsed = true
        super.init(nibName: nil, bundle: nil)
        // The line between the columns is the split view's own divider, one display pixel wide.
        splitView = RuleSplitView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addSplitViewItem(contentItem)
        addSplitViewItem(paneItem)
        splitView.autosaveName = Self.autosaveName
        // AppKit changes the column on the main thread: from the divider, a menu, or `observePane`.
        collapseObservation = paneItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onPaneCollapsed(self.paneItem.isCollapsed)
                self.paneCollapsedChanged(self.paneItem.isCollapsed)
            }
        }
        observePane()
    }

    /// The screen's column, the card's first: the section of the toolbar its middle is centred in.
    var screenColumn: NSView { contentItem.viewController.view }

    // MARK: The pane

    private func observePane() {
        let target = withObservationTracking {
            coordinator.inspectorWorkspace
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePane() }
        }
        // Shown or hidden in its own workspace, the pane slides, as an inspector does. Anything
        // else — another workspace, a screen with no pane — switches at once, as the screen's bar does.
        let shown = coordinator.shownDeckWorkspace.map(ObjectIdentifier.init)
        let animated = shown != nil && shown == shownWorkspace && view.window?.isVisible == true
        shownWorkspace = shown
        let collapsed = target == nil
        expectedCollapsed = collapsed
        guard paneItem.isCollapsed != collapsed else { return }
        if animated {
            paneItem.animator().isCollapsed = collapsed
        } else {
            paneItem.isCollapsed = collapsed
            // The deck has already sized the workspace it just showed to the column as it was, and
            // AppKit lays the columns out again only on its next pass: a frame of the new session at
            // the last one's width, which its chat visibly jumps from. Lay them out before it draws.
            if view.window?.isVisible == true { splitView.layoutSubtreeIfNeeded() }
        }
    }

    /// A collapse the column was not asked for came from the divider or a menu: the workspace hears
    /// of it, and its model then asks for the state the column is already in.
    private func paneCollapsedChanged(_ collapsed: Bool) {
        guard collapsed != expectedCollapsed else { return }
        expectedCollapsed = collapsed
        guard let workspace = coordinator.shownDeckWorkspace, workspace.model.canToggleContext else {
            // Nothing to show: the column goes back.
            paneItem.isCollapsed = true
            expectedCollapsed = true
            return
        }
        workspace.model.setContextPresented(!collapsed)
    }
}

enum MainWindowMetrics {
    /// The rail down the sidebar's leading edge (`SidebarRail`): ChatGPT's and Codex's, measured at
    /// 56 points, one plate wide with a little air either side.
    static let railWidth: CGFloat = 56
    /// The card's edges to the sidebar's and the window's.
    static let cardInset: CGFloat = 4
    /// The card's corners: the window's own corner, less the inset, so the two curve together.
    static let cardRadius: CGFloat = 12
    /// The list's widths, beside the rail; the sidebar's column is the two together.
    static let sidebarMin: CGFloat = 170
    static let sidebarMax: CGFloat = 420
    static let sidebarIdeal: CGFloat = 250
    /// The least a screen, and the terminal beside an open pane, can be and still be used.
    static let contentMin: CGFloat = 360
    /// The least the context pane can be.
    static let paneMin: CGFloat = 320
    /// The width of the lines the window draws — the card's edge and the columns' dividers: one
    /// pixel of the display, thinner than the theme's one-point hairline.
    /// Before the view is in a window, the main screen's pixel.
    static func rule(in view: NSView) -> CGFloat {
        1 / max(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
    }
}

/// The screen's column, with the activity toasts over its trailing corner. Its bar is the window's
/// toolbar, over the card (`MainToolbarController`).
private struct MainContentColumn: View {
    let model: AppViewModel

    var body: some View {
        AppCoordinatorView(coordinator: model.coordinator)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                ActivityToastView(notifications: model.shell.notifications)
                    .padding(.top, 6).padding(.trailing, 20)
            }
            .background(Theme.paneBackground)
            .modifier(SettingsWindowOpener(model: model))
    }
}

/// Hands the environment's `openSettings` to the app model, for opens that do not start in a
/// view: the rail gear's command, and the workflow hooks' jump to CLIs.
private struct SettingsWindowOpener: ViewModifier {
    let model: AppViewModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { model.openSettingsWindow = { openSettings() } }
    }
}

/// The context pane's column: a deck of every workspace's pane, the one the column is open for on
/// top, so a switch between sessions rebuilds no pane and takes no web view out of the window, as the
/// screen's deck does for their terminals. The pane stays while the column shuts, so what closes is
/// the pane that was open: not an empty one, nor the hidden pane of the session switched to. It is
/// opaque: the window's backdrop would show through wherever the pane is not drawn — between one
/// panel and the next, or while a page loads.
private struct MainPaneColumn: View {
    let coordinator: AppCoordinator

    var body: some View {
        SessionWorkspaceDeck(workspaces: coordinator.deckWorkspaces, shown: coordinator.inspectorWorkspace, part: .pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paneBackground)
    }
}
