import AppKit
import Foundation
import Testing
@testable import Cascade

/// The main window as it is really built: its toolbar, and the card under it whose columns the
/// toolbar's sections track.
@MainActor struct MainWindowLayoutTests {
    private func settle(until done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func view(named name: String, in root: NSView) -> NSView? {
        if String(describing: type(of: root)).contains(name) { return root }
        return root.subviews.lazy.compactMap { view(named: name, in: $0) }.first
    }

    private func split(in root: NSView) -> NSSplitView? {
        if let split = root as? NSSplitView { return split }
        return root.subviews.lazy.compactMap { split(in: $0) }.first
    }

    private func inWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    @Test(.timeLimit(.minutes(1))) func toolbarSectionsTrackTheCardsColumns() async throws {
        _ = NSApplication.shared
        let suite = "main-window-layout-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        // The columns remember their widths, and whether the list was shut: this test shuts it, and
        // would otherwise start the next run from there.
        let saved = "NSSplitView Subview Frames CascadeCardColumns"
        UserDefaults.standard.removeObject(forKey: saved)
        defer { UserDefaults.standard.removeObject(forKey: saved) }
        let model = AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }),
            shellFactory: NativeShellFeatureFactory(preferences: preferences, fileIcons: nil),
            platformFactory: NativeAppPlatformFactory(homeDirectory: "/tmp/cascade-layout-home",
                configuration: { throw BackendError.configuration("No test terminal") }),
            welcomeStore: TransientWelcomeStore(shown: true),
            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
        let controller = MainWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
        window.orderFront(nil)
        let root = try #require(window.contentView)
        let card = try #require(view(named: "MainCardView", in: root))
        let columns = try #require(split(in: root))
        try await settle { inWindow(card).width > 100 }

        // A transparent unified toolbar over the backdrop; the card and the rail start under it.
        #expect(window.toolbarStyle == .unified)
        #expect(window.titlebarAppearsTransparent)
        let titleBar = window.frame.height - window.contentLayoutRect.height
        #expect(titleBar == 52)
        #expect(abs(window.frame.height - inWindow(card).maxY - titleBar) < 0.5)
        #expect(abs(inWindow(card).minY - MainWindowMetrics.cardInset) < 0.5)
        let rail = try #require(view(named: "MainRail", in: root))
        #expect(abs(inWindow(rail).maxY - inWindow(card).maxY) < 0.5)

        // The toolbar's first section is the list's, tracking the card's first divider, with nothing
        // in it; the dashboard's items come after it, over the screen's column.
        let items = window.toolbar?.items ?? []
        let separator = try #require(items.first as? NSTrackingSeparatorToolbarItem)
        #expect(separator.splitView === columns)
        #expect(separator.dividerIndex == 0)
        // The screen's column is the one the columns' owner names, found by its content.
        let screen = try #require(view(named: "MainContentColumn", in: root))
        try await settle { inWindow(screen).minX > 200 }
        let tabs = try #require(items.first { $0.itemIdentifier.rawValue == "dashboard-tabs" }?.view)
        try await settle { inWindow(tabs).minX >= inWindow(screen).minX }
        #expect(inWindow(tabs).minX >= inWindow(screen).minX)
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(abs(inWindow(tabs).midY - inWindow(close).midY) < 1)

        // The card's edge starts at the screen's column, not the list's: the list is on the wash
        // beside it. Its corners are continuous, as the clips under it are.
        let outline = try #require(view(named: "MainCardOutline", in: root))
        #expect(abs(inWindow(outline).minX - inWindow(screen).minX) < 0.5)
        #expect(abs(inWindow(outline).maxX - inWindow(card).maxX) < 0.5)
        #expect(outline.layer?.cornerCurve == .continuous)
        #expect(screen.layer?.maskedCorners == [.layerMinXMinYCorner, .layerMinXMaxYCorner])

        // A terminal's toolbar has a pane section, tracking the card's second divider, with its toggle.
        model.select(.terminal)
        model.openTerminal()
        try await settle { window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "pane-toggle" } == true }
        let pane = try #require(window.toolbar?.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.first { $0.dividerIndex == 1 })
        #expect(pane.splitView === columns)

        // Toggle Sidebar, as the View menu sends it to the window, shuts the list: the screen's column
        // then starts at the card's edge.
        #expect(window.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil))
        try await settle { columns.isSubviewCollapsed(columns.arrangedSubviews[0]) && abs(inWindow(screen).minX - inWindow(card).minX) < 0.5 }
        #expect(columns.isSubviewCollapsed(columns.arrangedSubviews[0]))
        #expect(abs(inWindow(screen).minX - inWindow(card).minX) < 0.5)
        // With the list shut the card's edge comes back to the card's own.
        try await settle { abs(inWindow(outline).minX - inWindow(card).minX) < 0.5 }
        #expect(abs(inWindow(outline).minX - inWindow(card).minX) < 0.5)

        await model.stop()
    }
}
