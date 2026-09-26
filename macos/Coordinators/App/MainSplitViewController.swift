import AppKit
import Observation
import SwiftUI

/// The main window's columns, as AppKit lays out Xcode's: the sidebar, the screen
/// (`AppCoordinatorView`), and the shown workspace's context pane as the inspector. The toolbar tracks
/// both dividers, so each column has its own section of it (`MainToolbarController`). AppKit keeps
/// each column to its minimum width, so no drag or window resize can squeeze one to nothing.
///
/// The pane column follows the workspace on show: open while its pane is (`showsInspector`), and
/// the other way round, a pane the user collapses or opens from the divider or a menu is told to
/// its workspace.
@MainActor final class MainSplitViewController: NSSplitViewController {
    private let coordinator: AppCoordinator
    private let sidebarItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem
    private let paneItem: NSSplitViewItem
    /// The pane state last asked of the column; a collapse that differs came from the user.
    private var expectedCollapsed = true
    /// The workspace on show when the pane was last set, to tell a toggle from a switch.
    private var shownWorkspace: ObjectIdentifier?
    private var collapseObservation: NSKeyValueObservation?
    /// No widths saved yet: the first time the window shows, the sidebar opens at its ideal width.
    private var needsInitialWidths = false
    private static let autosaveName = "CascadeMainColumns"

    init(model: AppViewModel) {
        let coordinator = model.coordinator
        self.coordinator = coordinator
        let sidebar = NSHostingController(rootView: MainSidebarColumn(coordinator: coordinator))
        let content = NSHostingController(rootView: MainContentColumn(model: model))
        let pane = NSHostingController(rootView: MainPaneColumn(coordinator: coordinator))
        // The columns' widths are the split view's to decide, not their content's.
        sidebar.sizingOptions = []
        content.sizingOptions = []
        pane.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = MainWindowMetrics.sidebarMin
        sidebarItem.maximumThickness = MainWindowMetrics.sidebarMax
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = MainWindowMetrics.contentMin
        paneItem = NSSplitViewItem(inspectorWithViewController: pane)
        paneItem.minimumThickness = MainWindowMetrics.paneMin
        paneItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        paneItem.canCollapse = true
        // An inspector is a glass panel, full height by default: its section of the toolbar would be
        // that glass, with the pane's page showing through it. Below the toolbar, the section is the
        // window's own toolbar background, as the screen's is.
        paneItem.allowsFullHeightLayout = false
        // Equal holding priorities: a window resize is shared between the screen and the pane in
        // proportion, as it was between the terminal and the pane before.
        paneItem.holdingPriority = contentItem.holdingPriority
        paneItem.isCollapsed = true
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(paneItem)
        needsInitialWidths = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.autosaveName)") == nil
        splitView.autosaveName = Self.autosaveName
        // AppKit changes the column on the main thread: from the divider, a menu, or `observePane`.
        collapseObservation = paneItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.paneCollapsedChanged(self.paneItem.isCollapsed)
            }
        }
        observePane()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyTitlebar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard needsInitialWidths else { return }
        needsInitialWidths = false
        splitView.setPosition(MainWindowMetrics.sidebarIdeal, ofDividerAt: 0)
    }

    private func observePane() {
        let target = withObservationTracking {
            _ = coordinator.shownDeckWorkspace?.model.showsTerminal
            return coordinator.inspectorWorkspace
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePane() }
        }
        applyTitlebar()
        // Shown or hidden in its own workspace, the pane slides, as an inspector does. Anything
        // else — another workspace, a screen with no pane — switches at once, as the toolbar does.
        let shown = coordinator.shownDeckWorkspace.map(ObjectIdentifier.init)
        let animated = shown != nil && shown == shownWorkspace && view.window?.isVisible == true
        shownWorkspace = shown
        let collapsed = target == nil
        expectedCollapsed = collapsed
        guard paneItem.isCollapsed != collapsed else { return }
        if animated { paneItem.animator().isCollapsed = collapsed } else { paneItem.isCollapsed = collapsed }
    }

    /// The toolbar over a terminal and its pane is the window's own backdrop in both sections. AppKit
    /// gives the screen's section a scroll-edge effect that the pane's section cannot have, so the
    /// two would not match; a workspace scrolls nothing under the toolbar — the terminal and the pane
    /// both start below it — so it has no use for the effect. Every other screen keeps it.
    private func applyTitlebar() {
        view.window?.titlebarAppearsTransparent = coordinator.shownDeckWorkspace?.model.showsTerminal == true
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
    static let sidebarMin: CGFloat = 170
    static let sidebarMax: CGFloat = 420
    static let sidebarIdeal: CGFloat = 250
    /// The least a screen, and the terminal beside an open pane, can be and still be used.
    static let contentMin: CGFloat = 360
    /// The least the context pane can be.
    static let paneMin: CGFloat = 320
}

/// The screen's column, with the activity toasts over its trailing corner.
private struct MainContentColumn: View {
    let model: AppViewModel

    var body: some View {
        AppCoordinatorView(coordinator: model.coordinator)
            .overlay(alignment: .topTrailing) {
                ActivityToastView(notifications: model.shell.notifications)
                    .padding(.top, 6).padding(.trailing, 20)
            }
            .modifier(SettingsWindowOpener(model: model))
    }
}

/// Hands the environment's `openSettings` to the app model, for opens that do not start in a
/// view: the sidebar gear's command, and the workflow hooks' jump to CLIs.
private struct SettingsWindowOpener: ViewModifier {
    let model: AppViewModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { model.openSettingsWindow = { openSettings() } }
    }
}

/// The sidebar's column, once the root model exists.
private struct MainSidebarColumn: View {
    let coordinator: AppCoordinator

    var body: some View {
        if let viewModel = coordinator.rootModel { SidebarView(viewModel: viewModel) }
    }
}

/// The context pane's column: a deck of every workspace's pane, the one on show on top, so a switch
/// between sessions rebuilds no pane and takes no web view out of the window, as the screen's deck
/// does for their terminals. The pane stays while the column slides shut, so what closes is the
/// pane that was open, not an empty one. The column is opaque: AppKit backs an inspector with glass, which would show through wherever the
/// pane is not drawn — between one panel and the next, or while a page loads. It draws its own
/// edge: beside a glass column the divider is zero-width and AppKit draws no line, though it can
/// still be dragged.
private struct MainPaneColumn: View {
    let coordinator: AppCoordinator

    var body: some View {
        SessionWorkspaceDeck(workspaces: coordinator.deckWorkspaces, shown: coordinator.shownDeckWorkspace, part: .pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: Theme.Size.hairline).accessibilityHidden(true)
        }
    }
}
