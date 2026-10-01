import AppKit
import SwiftUI

/// The main window's content: AppKit's own sidebar, the rail down its leading edge and the list the
/// rail picks beside it, and the card column, the card (`MainSplitViewController`'s screen and pane).
/// The sidebar is a real one, so AppKit slides it in and out and answers Toggle Sidebar for the View
/// menu and the toolbar's toggle.
/// Shut, it takes the rail with it.
///
/// Both columns draw the same backdrop over AppKit's sidebar material (`MainBackdrop`), so the
/// window reads as one surface: the rail on it, the list on a lighter wash of its own, and the card,
/// opaque. Open, the list's wash and the card meet square at the divider, which is not drawn and
/// takes no width, so the two read as one container with rounded outer corners.
@MainActor final class MainWindowViewController: NSSplitViewController {
    let columns: MainSplitViewController
    private let sidebarItem: NSSplitViewItem
    private let cardItem: NSSplitViewItem
    private let cardColumn: MainCardColumn
    private var collapseObservation: NSKeyValueObservation?

    /// No widths saved yet: the first time the window shows, the list opens at its ideal width.
    private var needsInitialWidths = false
    private static let autosaveName = "CascadeSidebarColumns"

    init(model: AppViewModel) {
        let columns = MainSplitViewController(model: model)
        self.columns = columns
        sidebarItem = NSSplitViewItem(sidebarWithViewController: MainSidebarColumn(coordinator: model.coordinator))
        sidebarItem.minimumThickness = MainWindowMetrics.railWidth + MainWindowMetrics.sidebarMin
        sidebarItem.maximumThickness = MainWindowMetrics.railWidth + MainWindowMetrics.sidebarMax
        cardColumn = MainCardColumn(columns: columns)
        cardItem = NSSplitViewItem(viewController: cardColumn)
        cardItem.minimumThickness = Self.cardMinimum(paneOpen: false)
        // A window too narrow for the sidebar beside the card, and the pane in it, shuts the sidebar.
        sidebarItem.canCollapseFromWindowResize = true
        super.init(nibName: nil, bundle: nil)
        columns.onPaneCollapsed = { [weak self] collapsed in
            self?.cardItem.minimumThickness = Self.cardMinimum(paneOpen: !collapsed)
        }
        let split = MainSidebarSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The least the card's column can be: the screen, the pane beside it when it is open, and the
    /// card's insets — one beside the open sidebar, two with it shut, so the larger is asked for.
    private static func cardMinimum(paneOpen: Bool) -> CGFloat {
        MainWindowMetrics.contentMin + (paneOpen ? MainWindowMetrics.paneMin : 0) + 2 * MainWindowMetrics.cardInset
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(cardItem)
        needsInitialWidths = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.autosaveName)") == nil
        splitView.autosaveName = Self.autosaveName
        cardColumn.sidebarShut = sidebarItem.isCollapsed
        // AppKit changes the column on the main thread: from the toggle, the View menu or a drag.
        collapseObservation = sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cardColumn.sidebarShut = self.sidebarItem.isCollapsed
            }
        }
    }

    /// The divider takes no width, so its handle is the last few points of the sidebar: none of it
    /// over the card, where it would take the screen's first points of clicks.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        NSRect(x: drawnRect.minX - Self.dividerHandle, y: drawnRect.minY, width: Self.dividerHandle, height: drawnRect.height)
    }

    private static let dividerHandle: CGFloat = 6

    override func viewDidAppear() {
        super.viewDidAppear()
        // The sidebar as the saved frames left it, which AppKit may restore without saying so.
        cardColumn.sidebarShut = sidebarItem.isCollapsed
        guard needsInitialWidths else { return }
        needsInitialWidths = false
        splitView.setPosition(MainWindowMetrics.railWidth + MainWindowMetrics.sidebarIdeal, ofDividerAt: 0)
    }
}

/// The sidebar's split view: the divider between the list and the card is not drawn and takes no
/// width, the card's edge being the line between them.
private final class MainSidebarSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
}

/// The window's backdrop, made for each column: the title bar's material, which lets the desktop's
/// own colour through — over a blue sky it is a pale blue, where the sidebar's material greys it —
/// and over it a wash (`SidebarPalette.backdrop`), which makes it solid: in light a pale grey as
/// light as the material, so the tint stays; in dark the page's own colour, where the material alone
/// is too light a grey. The material blends with what is behind the window, so drawn in the sidebar
/// it covers AppKit's own sidebar material, and the two columns match.
private enum MainBackdrop {
    static func make() -> NSVisualEffectView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .titlebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        let wash = MainBackdropWash()
        wash.frame = backdrop.bounds
        wash.autoresizingMask = [.width, .height]
        backdrop.addSubview(wash)
        return backdrop
    }
}

/// The sidebar's column: the rail and the list on the backdrop, which runs under the toolbar too.
private final class MainSidebarColumn: NSViewController {
    private let content: NSHostingView<MainSidebarContent>

    init(coordinator: AppCoordinator) {
        content = NSHostingView(rootView: MainSidebarContent(coordinator: coordinator))
        // The column's width is the split view's to decide, not its content's.
        content.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let backdrop = MainBackdrop.make()
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)
        view = backdrop
    }
}

/// The card's column: the card under the toolbar, on the backdrop. Beside the open sidebar it meets
/// the list's wash square; with the sidebar shut it is inset from the window's edge and rounded there
/// too.
private final class MainCardColumn: NSViewController {
    private let columns: MainSplitViewController
    private let card = MainCardView()
    private var leading: NSLayoutConstraint?

    var sidebarShut = false {
        didSet { updateLeadingEdge() }
    }

    init(columns: MainSplitViewController) {
        self.columns = columns
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = MainBackdrop.make()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(columns)
        card.addSubview(columns.view)
        view.addSubview(card)
        for subview in [card, columns.view] { subview.translatesAutoresizingMaskIntoConstraints = false }
        let inset = MainWindowMetrics.cardInset
        let leading = card.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            // Under the toolbar: the safe area's top is the window's title bar, in a window or full screen.
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),
            columns.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            columns.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            columns.view.topAnchor.constraint(equalTo: card.topAnchor),
            columns.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        updateLeadingEdge()
    }

    private func updateLeadingEdge() {
        leading?.constant = sidebarShut ? MainWindowMetrics.cardInset : 0
        card.layer?.maskedCorners = sidebarShut
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }
}

/// The wash over the backdrop's material, in the appearance's own colour.
private final class MainBackdropWash: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SidebarPalette.backdrop.cgColor
    }
}

/// The card: the screen and the pane, clipped to its rounded corners, and round them the window's
/// rule. The rule is the layer's border, which is drawn over what the card holds and follows the
/// same continuous corners as the clip; a stroked path's circular corners would drift from them by
/// about a point.
private final class MainCardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MainWindowMetrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    /// Run under the view's own appearance, so the rule is the one for it.
    override func updateLayer() {
        layer?.borderColor = SidebarPalette.rule.cgColor
        layer?.borderWidth = MainWindowMetrics.rule(window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// The sidebar's content, once the root model exists: the rail, and beside it the rows of the list
/// it picked on the list's wash, under the toolbar and down to the card's bottom edge, its leading
/// corners rounded as the card's trailing ones are.
private struct MainSidebarContent: View {
    let coordinator: AppCoordinator

    private var listShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: MainWindowMetrics.cardRadius,
                               bottomLeadingRadius: MainWindowMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let viewModel = coordinator.rootModel {
                SidebarRail(mode: coordinator.sidebarMode, onSelect: coordinator.showSidebar,
                            onSettings: viewModel.openSettings)
                    .frame(width: MainWindowMetrics.railWidth)
                SidebarView(viewModel: viewModel, mode: coordinator.sidebarMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { listShape.fill(Color(nsColor: SidebarPalette.list)) }
                    .clipShape(listShape)
                    .padding(.bottom, MainWindowMetrics.cardInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
