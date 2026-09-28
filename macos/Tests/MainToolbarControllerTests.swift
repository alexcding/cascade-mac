import AppKit
import Observation
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
}
