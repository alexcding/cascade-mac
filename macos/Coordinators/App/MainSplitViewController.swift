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
        // The line under the screen's toolbar is the column's own (`MainContentColumn`), so it is
        // always there. AppKit's comes and goes with what has scrolled under the toolbar, and
        // asking it for `.line` does not keep it: a page at its top still has none.
        contentItem.titlebarSeparatorStyle = .none
        paneItem = NSSplitViewItem(inspectorWithViewController: pane)
        paneItem.minimumThickness = MainWindowMetrics.paneMin
        paneItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        paneItem.canCollapse = true
        // Full height, as Xcode's inspector is: the column reaches the window's top and draws its
        // own bar in the title-bar zone (`SessionWorkspacePane`), so the toolbar's pane section is
        // its toggle alone, and showing or hiding the pane changes no toolbar item — the tracking
        // separator carries the screen's trailing items along with the divider, and the bar slides
        // with the column it is part of.
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
    /// The rail at the sidebar column's leading edge (`SidebarRail`): one icon wide, with the
    /// air a plate needs on each side. The column's widths are its list's plus this.
    static let railWidth: CGFloat = 57
    static let sidebarMin: CGFloat = 170 + railWidth
    static let sidebarMax: CGFloat = 420 + railWidth
    static let sidebarIdeal: CGFloat = 250 + railWidth
    /// The least a screen, and the terminal beside an open pane, can be and still be used.
    static let contentMin: CGFloat = 360
    /// The least the context pane can be.
    static let paneMin: CGFloat = 320
    /// The width of the lines the columns draw between themselves — the list's edge and the line
    /// under the toolbar: one pixel of the display, thinner than the theme's one-point hairline.
    static func rule(_ displayScale: CGFloat) -> CGFloat { 1 / max(displayScale, 1) }
}

/// The screen's column, with the activity toasts over its trailing corner.
private struct MainContentColumn: View {
    let model: AppViewModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        AppCoordinatorView(coordinator: model.coordinator)
            // The toolbar's edge, whatever the screen has scrolled to: the sidebar list's top edge
            // runs into it, and would otherwise end at nothing. A terminal has no edge here — its
            // toolbar is the window's own backdrop (`applyTitlebar`).
            .overlay(alignment: .top) {
                if model.coordinator.shownDeckWorkspace?.model.showsTerminal != true {
                    Rectangle().fill(Color(nsColor: SidebarPalette.rule)).frame(height: MainWindowMetrics.rule(displayScale))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
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

/// The sidebar's column, once the root model exists: the rail, then the list it picked. The rail
/// is in the column, not beside it, because only the column has the sidebar's glass. AppKit makes
/// that glass itself, and nothing public matches it — a glass view or any window material beside
/// the split view comes out a different colour, and a sidebar item of its own takes the toolbar's
/// sidebar separator from the list. So the rail goes where the sidebar goes, collapse included.
private struct MainSidebarColumn: View {
    let coordinator: AppCoordinator
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let viewModel = coordinator.rootModel {
            HStack(spacing: 0) {
                SidebarRail(mode: coordinator.sidebarMode, onSelect: coordinator.showSidebar, onSettings: viewModel.openSettings)
                    .frame(width: MainWindowMetrics.railWidth)
                // The list is edged like a panel set into the column: up its side against the rail,
                // round the corner under the title bar, and along its top to the screen, where the
                // toolbar's own edge goes on. The rail has no line over it. The window's buttons
                // sit across the rail's edge above this, which is why the line starts below them.
                SidebarView(viewModel: viewModel, mode: coordinator.sidebarMode)
                    .overlay {
                        SidebarListEdge(radius: 10, lineWidth: MainWindowMetrics.rule(displayScale))
                            .stroke(Color(nsColor: SidebarPalette.rule), lineWidth: MainWindowMetrics.rule(displayScale))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        }
    }
}

/// The leading and top edges of the sidebar's list, joined by a rounded corner: one line from the
/// column's bottom, up, round, and across to its trailing edge.
private struct SidebarListEdge: Shape {
    let radius: CGFloat
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        // Half a line in, so the stroke lands on whole pixels from the list's edge.
        let inset = lineWidth / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset + radius))
        path.addArc(center: CGPoint(x: rect.minX + inset + radius, y: rect.minY + inset + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
        return path
    }
}

/// The context pane's column: a deck of every workspace's pane, the one the column is open for on
/// top, so a switch between sessions rebuilds no pane and takes no web view out of the window, as the
/// screen's deck does for their terminals. The pane stays while the column shuts, so what closes is
/// the pane that was open: not an empty one, nor the hidden pane of the session switched to. The column reaches the window's top: each pane draws its
/// bar in the title-bar zone, which AppKit reports to it as the safe area. It is opaque: AppKit
/// backs an inspector with glass, which would show through wherever the pane is not drawn —
/// between one panel and the next, or while a page loads. It draws its own edge: beside a glass
/// column the divider is zero-width and AppKit draws no line, though it can still be dragged.
private struct MainPaneColumn: View {
    let coordinator: AppCoordinator
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        SessionWorkspaceDeck(workspaces: coordinator.deckWorkspaces, shown: coordinator.inspectorWorkspace, part: .pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: SidebarPalette.rule)).frame(width: MainWindowMetrics.rule(displayScale)).accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
