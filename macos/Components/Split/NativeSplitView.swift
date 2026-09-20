import AppKit
import SwiftUI

private enum SplitMetrics {
    static let minLeading: CGFloat = 360
    static let minTrailing: CGFloat = 320
    /// How wide the divider is to the pointer, as opposed to the hairline it is drawn as.
    static let grabWidth: CGFloat = 16
}

/// Two panes side by side, with AppKit owning the divider. `NSSplitView` runs the drag loop,
/// the collapse animation and the pane geometry; the hosting controllers only render into the
/// bounds they are handed. The trailing pane is sized as a fraction of the split:
/// both panes scale with the window, and a drag sets a new fraction.
struct NativeSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    let showsTrailing: Bool
    @Binding var trailingFraction: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    /// A hosting controller starts a new SwiftUI hierarchy, which would otherwise begin with a
    /// blank environment. Carry the surrounding one across by hand.
    @Environment(\.self) private var environment

    struct Hosted<Content: View>: View {
        let environment: EnvironmentValues
        let content: Content
        var body: some View { content.environment(\.self, environment) }
    }

    final class Controller: NSSplitViewController {
        let leadingHost: NSHostingController<Hosted<Leading>>
        let trailingHost: NSHostingController<Hosted<Trailing>>
        var onFractionChange: (CGFloat) -> Void = { _ in }

        private var shown: Bool?
        private var desiredFraction: CGFloat = 0.6
        /// The fraction `show` was last handed, as opposed to the one the divider is at.
        private var givenFraction: CGFloat?
        private var needsWidth = false
        private var suppression = 0
        /// The width we last asked for. A width that is not this one was put there by the user.
        private var commandedWidth: CGFloat = -1
        private var lastTotalWidth: CGFloat = 0
        private var writeBack: DispatchWorkItem?
        private var cursorArea: NSTrackingArea?

        init(leading: Hosted<Leading>, trailing: Hosted<Trailing>) {
            leadingHost = NSHostingController(rootView: leading)
            trailingHost = NSHostingController(rootView: trailing)
            super.init(nibName: nil, bundle: nil)
            leadingHost.sizingOptions = []
            trailingHost.sizingOptions = []
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            let lead = NSSplitViewItem(viewController: leadingHost)
            lead.canCollapse = false
            lead.minimumThickness = SplitMetrics.minLeading
            // Equal holding priorities: a window resize is shared in proportion, so the fraction holds.
            lead.holdingPriority = NSLayoutConstraint.Priority(250)
            addSplitViewItem(lead)
            let trail = NSSplitViewItem(viewController: trailingHost)
            trail.canCollapse = true
            trail.minimumThickness = SplitMetrics.minTrailing
            trail.holdingPriority = NSLayoutConstraint.Priority(250)
            // Collapsing gives the space to the sibling instead of resizing the window.
            trail.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            addSplitViewItem(trail)
            trail.isCollapsed = !(shown ?? false)
            needsWidth = shown ?? false
            updateCollapsePolicy()
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            if needsWidth { needsWidth = false; applyWidth() }
            updateCursorArea()
        }

        func show(_ value: Bool, fraction: CGFloat) {
            // SwiftUI calls this on every update with the *stored* fraction, which lags a drag by the
            // write-back debounce. Only a fraction that differs from the last one handed in is news;
            // the same one again must not overwrite, or snap the divider back over, a width the user
            // has just dragged to.
            let given = givenFraction.map { abs($0 - fraction) > 0.001 } ?? true
            givenFraction = fraction
            if given { desiredFraction = fraction }
            // The first call sets the starting state, so it must not animate: the pane is either
            // already there when the session opens or it is not.
            let animated = shown != nil
            let changed = shown != value
            shown = value
            guard isViewLoaded else { _ = view; return }
            guard changed else {
                if value, given { applyWidth() }
                return
            }
            let item = splitViewItems[1]
            item.canCollapse = true
            guard animated else {
                item.isCollapsed = !value
                needsWidth = value
                updateCollapsePolicy()
                updateCursorArea()
                return
            }
            suppression += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                item.animator().isCollapsed = !value
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if value { self.applyWidth() }
                    self.updateCollapsePolicy()
                    self.updateCursorArea()
                    self.endSuppression()
                }
            }
        }

        /// Ends a suppression on the next runloop turn. The split view is autolayout driven, so the
        /// frames a change produces, and the resize notification that follows them, land on a later
        /// pass, and the guard has to outlive the call that set it.
        private func endSuppression() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.suppression > 0 else { return }
                    self.suppression -= 1
                }
            }
        }

        /// What the two panes share: the split less its divider.
        private var usableWidth: CGFloat { max(1, splitView.bounds.width - splitView.dividerThickness) }

        private func applyWidth() {
            guard isViewLoaded, splitViewItems.count == 2, !splitViewItems[1].isCollapsed else { return }
            let total = splitView.bounds.width
            guard total > 1 else { needsWidth = true; return }
            let room = max(SplitMetrics.minTrailing, total - splitView.dividerThickness - SplitMetrics.minLeading)
            let target = min(max(desiredFraction * usableWidth, SplitMetrics.minTrailing), room)
            commandedWidth = target
            guard abs(trailingHost.view.frame.width - target) > 0.5 else { return }
            suppression += 1
            splitView.setPosition(total - splitView.dividerThickness - target, ofDividerAt: 0)
            endSuppression()
        }

        override func splitViewDidResizeSubviews(_ notification: Notification) {
            super.splitViewDidResizeSubviews(notification)
            guard isViewLoaded, splitViewItems.count == 2, !splitViewItems[1].isCollapsed else { return }
            let total = splitView.bounds.width
            let windowResized = total != lastTotalWidth
            lastTotalWidth = total
            // A window resize can squeeze this pane past the width the user chose, and must not be
            // mistaken for the user choosing a new one. Neither may the frame the pane is born with,
            // before the stored width has been applied to it. None of these may cancel a report
            // that is already pending either: that report is the user's drag.
            guard suppression == 0, !needsWidth, !windowResized else { return }
            writeBack?.cancel()
            // A width the user put there is the one to keep, so stop trying to restore the old one.
            let current = trailingHost.view.frame.width
            if current > 1, abs(current - commandedWidth) > 0.5 { desiredFraction = current / usableWidth }
            // Report the width once the drag settles. Reporting every frame would write
            // UserDefaults and invalidate the whole workspace subtree on each one. The width is
            // read when the timer fires, not now: a notification can carry a frame that layout
            // has not finished with, and only the settled one is worth keeping.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.splitViewItems.count == 2,
                          !self.splitViewItems[1].isCollapsed else { return }
                    let settled = self.trailingHost.view.frame.width
                    // Our own setPosition reports back here too, so a width we asked for is not news.
                    guard settled > 1, abs(settled - self.commandedWidth) > 0.5 else { return }
                    self.desiredFraction = settled / self.usableWidth
                    self.onFractionChange(self.desiredFraction)
                }
            }
            writeBack = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Dragging the divider to the edge would collapse the pane, leaving an empty column with
        /// no obvious way back. Hiding the pane is the toolbar toggle's job, so the item may only
        /// collapse while it is already collapsed, which is what a drag cannot reach.
        private func updateCollapsePolicy() {
            guard splitViewItems.count == 2 else { return }
            splitViewItems[1].canCollapse = splitViewItems[1].isCollapsed
        }

        /// The band the divider can be grabbed by, wider than the divider it is drawn as.
        private func grabRect() -> NSRect {
            guard isViewLoaded, splitViewItems.count == 2, !splitViewItems[1].isCollapsed else { return .zero }
            let thickness = splitView.dividerThickness
            let extra = max(0, (SplitMetrics.grabWidth - thickness) / 2)
            return NSRect(x: leadingHost.view.frame.maxX - extra, y: 0,
                          width: thickness + extra * 2, height: splitView.bounds.height)
        }

        override func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
            // No super call. NSSplitViewController conforms to NSSplitViewDelegate, so every method
            // of that protocol can be overridden here whether or not the class implements it, and
            // calling super on one it does not implement is an unrecognized selector at runtime.
            // `constrainSplitPosition` is one such method, and calling super on it crashed this app
            // at launch. This one is implemented, so omitting super is a choice, not a necessity.
            guard dividerIndex == 0 else { return .zero }
            return grabRect()
        }

        /// `additionalEffectiveRectOfDividerAt` widens where a drag may start, and nothing else.
        /// The resize cursor needs its own tracking area over the same band.
        private func updateCursorArea() {
            let rect = grabRect()
            if let existing = cursorArea {
                guard existing.rect != rect else { return }
                splitView.removeTrackingArea(existing)
                cursorArea = nil
            }
            guard !rect.isEmpty else { return }
            let area = NSTrackingArea(rect: rect, options: [.activeInKeyWindow, .cursorUpdate],
                                      owner: self, userInfo: nil)
            splitView.addTrackingArea(area)
            cursorArea = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    }

    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller(leading: hosted(leading()), trailing: hosted(trailing()))
        configure(controller)
        return controller
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.leadingHost.rootView = hosted(leading())
        controller.trailingHost.rootView = hosted(trailing())
        configure(controller)
    }

    private func hosted<Content: View>(_ content: Content) -> Hosted<Content> {
        Hosted(environment: environment, content: content)
    }

    private func configure(_ controller: Controller) {
        let fraction = $trailingFraction
        controller.onFractionChange = { value in
            if abs(fraction.wrappedValue - value) > 0.001 { fraction.wrappedValue = value }
        }
        controller.show(showsTrailing, fraction: trailingFraction)
    }
}
