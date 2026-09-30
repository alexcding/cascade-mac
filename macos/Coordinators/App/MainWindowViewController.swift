import AppKit
import SwiftUI

/// The main window's content: one backdrop across the whole window, and on it the rail down the
/// leading edge and the card that holds the columns (`MainSplitViewController`). The window's
/// toolbar (`MainToolbarController`) is transparent, so the backdrop runs under it too: a
/// translucent outline round the card, along the top, down the rail, and a thin margin at the
/// trailing and bottom edges.
///
/// The backdrop is a material of this view's own rather than a sidebar column's glass: AppKit makes
/// that glass itself and nothing public matches it, so a strip or a rail beside such a column comes
/// out a different colour. With one material behind everything there is nothing to match.
///
/// The material is the title bar's, which lets the desktop's own colour through: over a blue sky
/// it is a pale blue. The sidebar's material lets as much light through but greys it, so the same
/// sky comes out a grey-green. Over the material is a wash (`SidebarPalette.backdrop`), which makes
/// the backdrop solid: in light a pale grey as light as the material, so the tint stays; in dark
/// the page's own colour, where the material alone is too light a grey.
@MainActor final class MainWindowViewController: NSViewController {
    let columns: MainSplitViewController
    private let rail: NSHostingView<MainRail>
    private let wash = MainBackdropWash()
    private let card = MainCardView()

    init(model: AppViewModel) {
        let columns = MainSplitViewController(model: model)
        self.columns = columns
        rail = NSHostingView(rootView: MainRail(coordinator: model.coordinator) { [weak columns] in columns?.revealList() })
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let backdrop = NSVisualEffectView()
        backdrop.material = .titlebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        view = backdrop
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The rail's width is this view's to decide, not its content's.
        rail.sizingOptions = []
        addChild(columns)
        card.addSubview(columns.view)
        // Under everything, and under the strip too: the content view reaches the window's top.
        wash.frame = view.bounds
        wash.autoresizingMask = [.width, .height]
        view.addSubview(wash)
        view.addSubview(rail)
        view.addSubview(card)
        for subview in [rail, card, columns.view] { subview.translatesAutoresizingMaskIntoConstraints = false }
        // Under the toolbar: the safe area's top is the window's title bar, in a window or full screen.
        let top = view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.widthAnchor.constraint(equalToConstant: MainWindowMetrics.railWidth),
            rail.topAnchor.constraint(equalTo: top),
            rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            card.topAnchor.constraint(equalTo: top),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -MainWindowMetrics.cardInset),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -MainWindowMetrics.cardInset),
            columns.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            columns.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            columns.view.topAnchor.constraint(equalTo: card.topAnchor),
            columns.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
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

    /// Run under the view's own appearance, so the colour is the one for it.
    override func updateLayer() {
        layer?.backgroundColor = SidebarPalette.backdrop.cgColor
    }
}

/// The card: the columns, clipped to its rounded corners, with the window's rule round its edge.
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

/// The rail, once the root model exists. Picking a list also opens the list's column if it is shut.
private struct MainRail: View {
    let coordinator: AppCoordinator
    let revealList: () -> Void

    var body: some View {
        if let viewModel = coordinator.rootModel {
            SidebarRail(mode: coordinator.sidebarMode, onSelect: { mode in
                coordinator.showSidebar(mode)
                revealList()
            }, onSettings: viewModel.openSettings)
        }
    }
}
