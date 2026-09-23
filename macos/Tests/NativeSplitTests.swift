import AppKit
import SwiftUI
import Testing

/// The split stores a fraction; these tests think in points at the fixture's 1200pt window.
@MainActor private func fraction<L: View, T: View>(_ width: CGFloat, in controller: NativeSplitView<L, T>.Controller) -> CGFloat {
    width / (1200 - controller.splitView.dividerThickness)
}

@MainActor private func splitFixture(width: CGFloat = 560)
    -> (NativeSplitView<Text, Text>.Controller, NSWindow) {
    let controller = NativeSplitView<Text, Text>.Controller(
        leading: .init(environment: EnvironmentValues(), content: Text("Leading")),
        trailing: .init(environment: EnvironmentValues(), content: Text("Trailing")))
    controller.show(true, fraction: fraction(width, in: controller))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
    // Programmatic windows release themselves on close, which would over-release the strong
    // reference this fixture hands back.
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    // Adopting the controller shrinks the window to the panes' minimums, so size it afterwards.
    window.setContentSize(NSSize(width: 1200, height: 800))
    window.layoutIfNeeded()
    return (controller, window)
}

/// Laying the split out drives `viewDidLayout` into `setPosition`, which calls back into the
/// `NSSplitViewDelegate` methods this controller overrides. Overriding one of those and calling
/// `super` on it crashed the app at launch with an unrecognized selector, because
/// `NSSplitViewController` only conforms to the protocol, it does not implement every method.
@MainActor @Test(.timeLimit(.minutes(1))) func nativeSplitLaysOutAtTheStoredWidthWithoutCallingAbsentSuperclassMethods() {
    let (controller, window) = splitFixture(width: 560)
    #expect(controller.splitViewItems.count == 2)
    #expect(!controller.splitViewItems[1].isCollapsed)
    #expect(controller.splitView.bounds.width == 1200)
    #expect(abs(controller.trailingHost.view.frame.width - 560) < 1)
    // Wider than the window allows: the pane is clamped, and the leading minimum is honoured.
    controller.show(true, fraction: fraction(5000, in: controller))
    window.layoutIfNeeded()
    #expect(controller.leadingHost.view.frame.width >= 360)
    #expect(controller.trailingHost.view.frame.width >= 320)
    window.close()
}

/// A width the controller asked for itself must not be written back as if the user chose it,
/// or a clamped width overwrites the stored one and ratchets it down.
@MainActor @Test(.timeLimit(.minutes(1))) func nativeSplitDoesNotReportBackTheWidthItAppliedItself() async {
    let (controller, window) = splitFixture(width: 560)
    var reported: [CGFloat] = []
    controller.onFractionChange = { reported.append($0) }
    controller.show(true, fraction: fraction(400, in: controller))
    window.layoutIfNeeded()
    // Past the debounce, and a sleep rather than a yield loop so the main queue actually drains.
    try? await Task.sleep(for: .milliseconds(400))
    #expect(reported.isEmpty)
    #expect(abs(controller.trailingHost.view.frame.width - 400) < 1)
    window.close()
}

/// A drag must not be able to collapse the pane. Collapsing leaves an empty column behind with no
/// obvious way back, so it stays the toolbar toggle's job. While the pane is up the item refuses to
/// collapse; once the toggle has hidden it, nothing offers a grab band over the space it left.
@MainActor @Test(.timeLimit(.minutes(1))) func nativeSplitLetsOnlyTheToggleCollapseThePane() async {
    let (controller, window) = splitFixture(width: 560)
    let pane = controller.splitViewItems[1]
    #expect(!pane.canCollapse)
    #expect(controller.splitView(controller.splitView, additionalEffectiveRectOfDividerAt: 0).width > 1)
    // Hiding and showing are animated; wait for the pane to settle rather than for a fixed time,
    // which a busy parallel test run can outlast.
    controller.show(false, fraction: fraction(560, in: controller))
    await settle(window) { pane.isCollapsed }
    #expect(pane.isCollapsed)
    #expect(controller.splitView(controller.splitView, additionalEffectiveRectOfDividerAt: 0) == .zero)
    // Reopening restores the pane, its width, its grab band and its refusal to be dragged shut.
    controller.show(true, fraction: fraction(560, in: controller))
    await settle(window) { !pane.isCollapsed && !pane.canCollapse && abs(controller.trailingHost.view.frame.width - 560) < 1 }
    #expect(!pane.isCollapsed)
    #expect(!pane.canCollapse)
    #expect(abs(controller.trailingHost.view.frame.width - 560) < 1)
    #expect(controller.splitView(controller.splitView, additionalEffectiveRectOfDividerAt: 0).width > 1)
    // And it survives the round trip a second time, from a width the user dragged to.
    controller.show(false, fraction: fraction(560, in: controller))
    await settle(window) { pane.isCollapsed }
    controller.show(true, fraction: fraction(420, in: controller))
    await settle(window) { !pane.isCollapsed && !pane.canCollapse && abs(controller.trailingHost.view.frame.width - 420) < 1 }
    #expect(!pane.isCollapsed)
    #expect(abs(controller.trailingHost.view.frame.width - 420) < 1, "pane \(controller.trailingHost.view.frame.width) of \(controller.splitView.frame.width)")
    window.close()
}

/// Lays the window out until `condition` holds or five seconds pass; the caller's expectations
/// then report what it settled on.
@MainActor private func settle(_ window: NSWindow, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    repeat {
        try? await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
    } while !condition() && Date() < deadline
}

/// The other half of the write-back: a width the controller did not ask for is the user's, and it
/// is reported once, after the drag settles.
@MainActor @Test(.timeLimit(.minutes(1))) func nativeSplitReportsAWidthItDidNotApplyItself() async {
    let (controller, window) = splitFixture(width: 560)
    var reported: [CGFloat] = []
    controller.onFractionChange = { reported.append($0) }
    // Let the width the fixture applied stop counting as the controller's own doing.
    try? await Task.sleep(for: .milliseconds(150))
    // What a drag leaves behind: a divider somewhere the controller never put it.
    let total = controller.splitView.bounds.width
    controller.splitView.setPosition(total - controller.splitView.dividerThickness - 700, ofDividerAt: 0)
    window.layoutIfNeeded()
    try? await Task.sleep(for: .milliseconds(400))
    #expect(reported.count == 1)
    #expect(abs((reported.first ?? 0) - fraction(700, in: controller)) < 0.002)
    window.close()
}

/// The split is a ratio: a window resize scales both panes, and is not the user choosing
/// a new share, so nothing is written back.
@MainActor @Test(.timeLimit(.minutes(1))) func nativeSplitKeepsItsFractionWhenTheWindowResizes() async {
    let (controller, window) = splitFixture(width: 720)
    var reported: [CGFloat] = []
    controller.onFractionChange = { reported.append($0) }
    #expect(abs(controller.trailingHost.view.frame.width - 720) < 1)
    window.setContentSize(NSSize(width: 1600, height: 800))
    window.layoutIfNeeded()
    try? await Task.sleep(for: .milliseconds(400))
    let share = controller.trailingHost.view.frame.width / (1600 - controller.splitView.dividerThickness)
    #expect(abs(share - fraction(720, in: controller)) < 0.01)
    #expect(reported.isEmpty)
    window.close()
}

/// SwiftUI re-runs `show` with the stored fraction on any update, and the stored fraction lags a
/// drag by the write-back debounce. An update landing inside that window must neither snap the
/// divider back nor lose the report of where the user left it.
@MainActor @Test(.timeLimit(.minutes(1))) func nativeSplitKeepsADragWhenAnUpdateLandsBeforeItIsReported() async {
    let (controller, window) = splitFixture(width: 560)
    var reported: [CGFloat] = []
    controller.onFractionChange = { reported.append($0) }
    try? await Task.sleep(for: .milliseconds(150))
    let total = controller.splitView.bounds.width
    controller.splitView.setPosition(total - controller.splitView.dividerThickness - 700, ofDividerAt: 0)
    window.layoutIfNeeded()
    // Inside the debounce: an unrelated update hands the old stored fraction in again.
    try? await Task.sleep(for: .milliseconds(40))
    controller.show(true, fraction: fraction(560, in: controller))
    window.layoutIfNeeded()
    try? await Task.sleep(for: .milliseconds(400))
    #expect(abs(controller.trailingHost.view.frame.width - 700) < 1)
    #expect(reported.count == 1)
    #expect(abs((reported.first ?? 0) - fraction(700, in: controller)) < 0.002)
    // A fraction that really is new still applies.
    controller.show(true, fraction: fraction(420, in: controller))
    window.layoutIfNeeded()
    #expect(abs(controller.trailingHost.view.frame.width - 420) < 1)
    window.close()
}
