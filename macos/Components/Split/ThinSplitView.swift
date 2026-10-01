import AppKit
import SwiftUI

/// Two panes side by side with a divider AppKit owns, as `HSplitView`'s is — a drag resizes the
/// panes without SwiftUI re-rendering either per frame — but one pixel of the display wide and in
/// the colour of the lines the window's columns draw (`SidebarPalette.rule`). `HSplitView` offers
/// neither: its divider is AppKit's thin style, a point wide in the separator colour.
///
/// Each pane is a hosting root of its own. Pass views that read their models in their own `body`:
/// a condition written in the builder here is evaluated when the split is updated, not when the
/// model it reads changes.
struct ThinSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    typealias Pane = ThinSplitPane

    let leading: Pane
    let trailing: Pane
    @ViewBuilder let leadingContent: () -> Leading
    @ViewBuilder let trailingContent: () -> Trailing

    func makeNSViewController(context: Context) -> ThinSplitViewController {
        let controller = ThinSplitViewController(leading: leading, trailing: trailing)
        update(controller, context: context)
        return controller
    }

    func updateNSViewController(_ controller: ThinSplitViewController, context: Context) {
        update(controller, context: context)
    }

    /// The panes are outside the view tree this split is in, so they are handed its environment.
    private func update(_ controller: ThinSplitViewController, context: Context) {
        controller.leadingHost.rootView = AnyView(leadingContent().environment(\.self, context.environment))
        controller.trailingHost.rootView = AnyView(trailingContent().environment(\.self, context.environment))
    }
}

/// A pane's widths. The pane with an `ideal` opens at it and keeps its width when the split is
/// resized; the other takes what is left.
struct ThinSplitPane {
    var min: CGFloat
    var ideal: CGFloat?
    var max: CGFloat?
}

@MainActor final class ThinSplitViewController: NSSplitViewController {
    let leadingHost = NSHostingController(rootView: AnyView(EmptyView()))
    let trailingHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let leading: ThinSplitPane
    private let trailing: ThinSplitPane
    /// The divider is put at the ideal width once, when the split first has a width.
    private var placed = false

    init(leading: ThinSplitPane, trailing: ThinSplitPane) {
        self.leading = leading
        self.trailing = trailing
        super.init(nibName: nil, bundle: nil)
        splitView = RuleSplitView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addSplitViewItem(item(leadingHost, leading))
        addSplitViewItem(item(trailingHost, trailing))
    }

    private func item(_ host: NSHostingController<AnyView>, _ widths: ThinSplitPane) -> NSSplitViewItem {
        // The panes' widths are the split's to decide, not their content's.
        host.sizingOptions = []
        let item = NSSplitViewItem(viewController: host)
        item.minimumThickness = widths.min
        item.maximumThickness = widths.max ?? NSSplitViewItem.unspecifiedDimension
        item.canCollapse = false
        item.holdingPriority = widths.ideal == nil ? .defaultLow : .defaultLow + 1
        return item
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placed, view.bounds.width > 0 else { return }
        placed = true
        if let ideal = leading.ideal {
            splitView.setPosition(ideal, ofDividerAt: 0)
        } else if let ideal = trailing.ideal {
            splitView.setPosition(view.bounds.width - ideal - splitView.dividerThickness, ofDividerAt: 0)
        }
    }
}

/// A side-by-side split view whose divider is one pixel of the display, in the columns' rule colour.
class RuleSplitView: NSSplitView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var dividerThickness: CGFloat { MainWindowMetrics.rule(in: self) }

    override var dividerColor: NSColor { SidebarPalette.rule }

    /// Another display has another pixel: the panes are laid out again around the new divider.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        adjustSubviews()
        needsDisplay = true
    }
}
