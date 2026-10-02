import AppKit
import Observation
import SwiftUI
import Testing
@testable import Cascade

@MainActor @Observable private final class PickerFixture {
    var choices: [WindowToolbarItem.Choice] = [
        .init(title: "Tabs", symbol: "rectangle.stack"),
        .init(title: "Diff", symbol: "plus.forwardslash.minus"),
    ]
    var selected = 0
    var label = "Panel"
}

@MainActor @Observable private final class PaneFixture {
    var open = false
}

@MainActor struct MainToolbarControllerTests {
    private let fixture = PickerFixture()
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
    private let controller: MainToolbarController

    init() {
        let fixture = fixture
        controller = MainToolbarController {
            WindowToolbar(trailing: [.picker("mode-picker", label: fixture.label, choices: fixture.choices,
                                             selected: fixture.selected) { fixture.selected = $0 }])
        }
        window.isReleasedWhenClosed = false
        controller.window = window
    }

    private var group: NSToolbarItemGroup? {
        window.toolbar?.items.lazy.compactMap { $0 as? NSToolbarItemGroup }.first
    }

    private func settle(until done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    // Enabling a choice keeps the toolbar; offering another is a new one, since a group's choices
    // are fixed once it is made.
    @Test(.timeLimit(.minutes(1))) func pickerRebuildsOnlyForNewChoices() async throws {
        defer { window.close() }
        #expect(group?.subitems.map(\.label) == ["Tabs", "Diff"])
        let first = window.toolbar

        fixture.choices[1].enabled = false
        try await settle { group?.subitems[1].isEnabled == false }
        #expect(group?.subitems[1].isEnabled == false)
        #expect(window.toolbar === first)

        fixture.choices.append(.init(title: "Simulator", symbol: "iphone"))
        try await settle { window.toolbar !== first }
        #expect(window.toolbar !== first)
        #expect(group?.subitems.map(\.label) == ["Tabs", "Diff", "Simulator"])
        #expect(group?.subitems[1].isEnabled == false)
    }

    @Test(.timeLimit(.minutes(1))) func pickerSelectionFlowsBothWays() async throws {
        defer { window.close() }
        let group = try #require(group)
        #expect(group.selectedIndex == 0)

        group.selectedIndex = 1
        NSApp.sendAction(try #require(group.action), to: group.target, from: group)
        #expect(fixture.selected == 1)

        fixture.selected = 0
        try await settle { group.selectedIndex == 0 }
        #expect(group.selectedIndex == 0)
    }

    // A toggling picker is the system's segmented control: it can have nothing selected, a click
    // reports the segment clicked while the selection stays the description's, so clicking the
    // selected one turns it off, and new choices change it in place rather than the toolbar.
    @Test(.timeLimit(.minutes(1))) func aTogglingPickerReportsClicksAndCanSelectNone() async throws {
        let fixture = PickerFixture()
        fixture.selected = -1
        var clicks: [Int] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = MainToolbarController {
            WindowToolbar(trailing: [.picker("pane-picker", label: fixture.label, choices: fixture.choices,
                                             selected: fixture.selected, toggles: true) { clicks.append($0) }])
        }
        controller.window = window
        let control = try #require(Self.view("pane-picker", in: window) as? NSSegmentedControl)
        let toolbar = window.toolbar
        #expect(control.trackingMode == .selectOne && control.segmentCount == 2 && control.selectedSegment == -1)
        func click(_ segment: Int) throws {
            control.selectedSegment = segment
            NSApp.sendAction(try #require(control.action), to: control.target, from: control)
        }

        try click(1)
        #expect(clicks == [1] && control.selectedSegment == -1, "the description decides what is selected")
        fixture.selected = 1
        try await settle { control.selectedSegment == 1 }
        #expect(control.selectedSegment == 1)

        try click(1)
        #expect(clicks == [1, 1] && control.selectedSegment == 1)
        fixture.selected = -1
        try await settle { control.selectedSegment == -1 }
        #expect(control.selectedSegment == -1)

        fixture.choices.append(.init(title: "Simulator", symbol: "iphone"))
        try await settle { control.segmentCount == 3 }
        #expect(control.segmentCount == 3 && control.toolTip(forSegment: 2) == "Simulator")
        #expect(window.toolbar === toolbar && Self.view("pane-picker", in: window) === control, "changed in place")
    }

    // The pane picker is the pane section alone, pane open or shut, so a toggle changes no item:
    // the same control, at the window's edge, with the column open, shut and collapsed.
    @Test(.timeLimit(.minutes(1))) func thePanePickerStaysAtTheWindowsEdge() async throws {
        // The pane at its narrowest, `MainWindowMetrics.paneMin`.
        let window = Self.splitWindow(inspector: true, paneWidth: MainWindowMetrics.paneMin)
        defer { window.close() }
        let pane = PaneFixture()
        let fixture = PickerFixture()
        fixture.choices.append(.init(title: "Simulator", symbol: "iphone"))
        let controller = MainToolbarController {
            WindowToolbar(leading: [WindowToolbarItem("title", style: .plain) { Color.clear.frame(width: 100, height: 20) }],
                          pane: [.picker("pane-picker", label: fixture.label, choices: fixture.choices,
                                         selected: pane.open ? 0 : -1, toggles: true) { _ in }])
        }
        controller.window = window
        // Measured before AppKit has placed the picker, it must not read as the whole window: the
        // pane's bar would leave itself no width, and show no tabs.
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.room.paneTrailing < 200, "before layout: \(controller.room.paneTrailing)")
        window.orderFront(nil)
        let control = try #require(Self.view("pane-picker", in: window) as? NSSegmentedControl)
        let items = window.toolbar?.items.map(\.itemIdentifier)
        func edge() -> CGFloat {
            window.layoutIfNeeded()
            return window.frame.width - control.convert(control.bounds, to: nil).maxX
        }
        let shut = edge()
        #expect(shut >= 0 && shut < 24, "at the window's edge: \(shut) pt from it")
        // What the pane's own bar keeps clear of is the picker as laid out, edge gap included.
        let taken = window.frame.width - control.convert(control.bounds, to: nil).minX
        try await settle { abs(controller.room.paneTrailing - taken) < 1 }
        #expect(abs(controller.room.paneTrailing - taken) < 1, "measured \(controller.room.paneTrailing) against \(taken)")

        pane.open = true
        try await settle { control.selectedSegment == 0 }
        #expect(window.toolbar?.items.map(\.itemIdentifier) == items, "opening the pane changes no item")
        #expect(abs(edge() - shut) < 0.5, "open: \(edge()) against \(shut)")
        let split = try #require(window.contentViewController as? NSSplitViewController)
        split.splitViewItems.last?.isCollapsed = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(edge() - shut) < 0.5, "column collapsed: \(edge()) against \(shut)")
        #expect(Self.view("pane-picker", in: window) === control)
    }

    // A pane item the toolbar cannot measure leaves the pane's width unmeasured, never short.
    @Test(.timeLimit(.minutes(1))) func aPaneItemWithNoViewLeavesThePaneUnmeasured() async throws {
        let window = Self.splitWindow(inspector: true, paneWidth: 600)
        defer { window.close() }
        let fixture = PickerFixture()
        let controller = MainToolbarController {
            WindowToolbar(pane: [.picker("pane-group", label: fixture.label, choices: fixture.choices, selected: 0) { _ in },
                                 .picker("pane-picker", label: fixture.label, choices: fixture.choices, selected: 0, toggles: true) { _ in }])
        }
        controller.window = window
        window.orderFront(nil)
        let control = try #require(Self.view("pane-picker", in: window) as? NSSegmentedControl)
        try await settle { control.frame.width > 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.room.paneTrailing == 0, "measured \(controller.room.paneTrailing) with a group picker it cannot see")
    }

    // A new label is not new choices: the group keeps its toolbar and takes the label.
    @Test(.timeLimit(.minutes(1))) func pickerTakesANewLabelInPlace() async throws {
        defer { window.close() }
        let group = try #require(group)
        let first = window.toolbar
        #expect(group.label == "Panel")

        fixture.label = "Shown"
        try await settle { group.label == "Shown" }
        #expect(group.label == "Shown")
        #expect(window.toolbar === first)
    }

    // A wide title before the middle and a narrow control after it: the middle still sits at the
    // centre of the screen's column, not pushed right by half the difference.
    @Test(.timeLimit(.minutes(1))) func middleIsCentredInTheScreenColumn() async throws {
        let window = Self.splitWindow()
        defer { window.close() }
        let controller = MainToolbarController {
            WindowToolbar(leading: [WindowToolbarItem("title", style: .plain) { Color.clear.frame(width: 300, height: 20) }],
                          center: [WindowToolbarItem("agent") { Color.clear.frame(width: 120, height: 20) }],
                          trailing: [WindowToolbarItem("mode") { Color.clear.frame(width: 40, height: 20) }])
        }
        controller.window = window
        window.orderFront(nil)
        let column = try #require(Self.column(of: window))
        func offset() -> CGFloat? {
            guard let agent = Self.view("agent", in: window), agent.frame.width > 0 else { return nil }
            return agent.convert(agent.bounds, to: nil).midX - column.convert(column.bounds, to: nil).midX
        }
        try await settle { offset().map { abs($0) < 2 } ?? false }
        #expect(try abs(#require(offset())) < 2)

        // The title is told of the free width up to the middle, less a gap, to draw into.
        let title = try #require(Self.view("title", in: window))
        let agent = try #require(Self.view("agent", in: window))
        let free = agent.convert(agent.bounds, to: nil).minX - title.convert(title.bounds, to: nil).maxX
        try await settle { controller.room.afterLeading > 0 }
        #expect(abs(controller.room.afterLeading - (free - 20)) < 2)

        // A wider window moves the column's centre; the middle follows it.
        window.setContentSize(NSSize(width: 1500, height: 300))
        try await settle { offset().map { abs($0) < 2 } ?? false }
        #expect(try abs(#require(offset())) < 2)
    }

    // With no middle, and a picker after the title that hosts no view of its own, the title is
    // still told of the free width up to the picker.
    @Test(.timeLimit(.minutes(1))) func roomReachesAPickerWithNoMiddle() async throws {
        let window = Self.splitWindow()
        defer { window.close() }
        let fixture = fixture
        let controller = MainToolbarController {
            WindowToolbar(leading: [WindowToolbarItem("title", style: .plain) { Color.clear.frame(width: 100, height: 20) }],
                          trailing: [.picker("mode-picker", label: fixture.label, choices: fixture.choices,
                                             selected: fixture.selected) { fixture.selected = $0 }])
        }
        controller.window = window
        window.orderFront(nil)
        try await settle { controller.room.afterLeading > 0 }
        // The column is 1000 wide; the title and the picker take a few hundred of it at most.
        #expect(controller.room.afterLeading > 500)
    }

    // The pane opening adds its tabs to the toolbar and shutting takes them out. The toolbar is
    // edited in place: the same toolbar, the title's item and view untouched, so nothing but the
    // pane's section moves.
    @Test(.timeLimit(.minutes(1))) func paneTabsComeAndGoInPlace() async throws {
        let window = Self.splitWindow(inspector: true)
        defer { window.close() }
        let pane = PaneFixture()
        let controller = MainToolbarController {
            WindowToolbar(leading: [WindowToolbarItem("title", style: .plain) { Color.clear.frame(width: 100, height: 20) }],
                          pane: pane.open
                            ? [WindowToolbarItem("pane-bar", style: .fill) { Color.clear }, WindowToolbarItem("pane-toggle") { Color.clear.frame(width: 20, height: 20) }]
                            : [WindowToolbarItem("pane-toggle") { Color.clear.frame(width: 20, height: 20) }])
        }
        controller.window = window
        window.orderFront(nil)
        let toolbar = try #require(window.toolbar)
        let title = try #require(Self.view("title", in: window))
        func ids() -> [String] { window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [] }
        #expect(!ids().contains("pane-bar"))

        pane.open = true
        try await settle { ids().contains("pane-bar") }
        #expect(ids().suffix(2) == ["pane-bar", "pane-toggle"])
        #expect(window.toolbar === toolbar)
        #expect(Self.view("title", in: window) === title)

        pane.open = false
        try await settle { !ids().contains("pane-bar") }
        #expect(ids().last == "pane-toggle")
        #expect(window.toolbar === toolbar)
        #expect(Self.view("title", in: window) === title)
    }

    private static func splitWindow(inspector: Bool = false, paneWidth: CGFloat = 300) -> NSWindow {
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: NSViewController.sized(width: 200)))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController.sized(width: 1000)))
        if inspector {
            let pane = NSSplitViewItem(inspectorWithViewController: NSViewController.sized(width: paneWidth))
            pane.minimumThickness = paneWidth
            split.addSplitViewItem(pane)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 300),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 300))
        return window
    }

    private static func column(of window: NSWindow) -> NSView? {
        (window.contentViewController as? NSSplitViewController)?.splitViewItems.last?.viewController.view
    }

    private static func view(_ id: String, in window: NSWindow) -> NSView? {
        window.toolbar?.items.first { $0.itemIdentifier.rawValue == id }?.view.flatMap { $0.window === window ? $0 : nil }
    }
}

private extension NSViewController {
    static func sized(width: CGFloat) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        return controller
    }
}

