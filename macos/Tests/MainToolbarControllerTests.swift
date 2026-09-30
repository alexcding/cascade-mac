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
        controller.splitView = Self.split(of: window)
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
        controller.splitView = Self.split(of: window)
        controller.window = window
        window.orderFront(nil)
        try await settle { controller.room.afterLeading > 0 }
        // The column is 1000 wide; the title and the picker take a few hundred of it at most.
        #expect(controller.room.afterLeading > 500)
    }

    /// A list column and a screen column, as plain items, as the card's are.
    private static func splitWindow() -> NSWindow {
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController.sized(width: 200)))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController.sized(width: 1000)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 300),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 300))
        return window
    }

    private static func split(of window: NSWindow) -> NSSplitView? {
        (window.contentViewController as? NSSplitViewController)?.splitView
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

