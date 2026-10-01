import AppKit
import Foundation
import Testing
@testable import Cascade

/// The main window as it is really built: its toolbar, the sidebar, and the card beside it, whose
/// columns the toolbar's sections track.
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

    @Test(.timeLimit(.minutes(1))) func toolbarSectionsTrackTheWindowsColumns() async throws {
        _ = NSApplication.shared
        let suite = "main-window-layout-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        // The columns remember their widths, and whether the sidebar was shut: this test shuts it,
        // and would otherwise start the next run from there.
        let saved = ["CascadeSidebarColumns", MainSplitViewController.autosaveName].map { "NSSplitView Subview Frames \($0)" }
        for key in saved { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in saved { UserDefaults.standard.removeObject(forKey: key) } }
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
        let content = try #require(window.contentViewController as? MainWindowViewController)
        let sidebarItem = try #require(content.splitViewItems.first)
        let sidebar = sidebarItem.viewController.view
        let columns = content.columns.splitView
        let card = try #require(view(named: "MainCardView", in: root))
        try await settle { inWindow(card).width > 100 && inWindow(sidebar).width > 100 }

        // The rail and the list are in AppKit's own sidebar, which opens at the list's ideal width
        // beside the rail.
        #expect(sidebarItem.behavior == .sidebar)
        #expect(abs(inWindow(sidebar).width - (MainWindowMetrics.railWidth + MainWindowMetrics.sidebarIdeal)) < 0.5)
        let rail = try #require(view(named: "SidebarRail", in: sidebar) ?? sidebar.subviews.first)
        #expect(inWindow(rail).maxX <= inWindow(sidebar).maxX)

        // A transparent unified toolbar; the card starts under it, inset from the window's edges. It
        // meets the sidebar square, at a divider that takes no width: only its trailing corners are
        // rounded, continuous as its clip is.
        #expect(window.toolbarStyle == .unified)
        #expect(window.titlebarAppearsTransparent)
        let titleBar = window.frame.height - window.contentLayoutRect.height
        #expect(titleBar == 52)
        let inset = MainWindowMetrics.cardInset
        #expect(abs(window.frame.height - inWindow(card).maxY - titleBar) < 0.5)
        #expect(abs(inWindow(card).minY - inset) < 0.5)
        #expect(abs(inWindow(card).minX - inWindow(sidebar).maxX) < 0.5)
        #expect(abs(inWindow(card).maxX - (window.frame.width - inset)) < 0.5)
        #expect(card.layer?.cornerRadius == MainWindowMetrics.cardRadius)
        #expect(card.layer?.cornerCurve == .continuous)
        #expect(card.layer?.maskedCorners == [.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
        let screen = try #require(view(named: "MainContentColumn", in: root))
        // The divider's handle is the sidebar's last points, none of it over the screen's first.
        let edge = inWindow(sidebar).maxX
        let handle = content.splitView(content.splitView, effectiveRect: .zero,
                                       forDrawnRect: NSRect(x: edge, y: 0, width: 0, height: 700), ofDividerAt: 0)
        #expect(handle.maxX <= edge && handle.width > 0)
        #expect(abs(inWindow(screen).minX - inWindow(card).minX) < 0.5)

        // The toolbar's first section is the sidebar's, with its toggle in it, clear of the window's
        // buttons; the dashboard's items come after it, over the screen.
        let items = window.toolbar?.items ?? []
        let toggleIndex = try #require(items.firstIndex { $0.itemIdentifier == .toggleSidebar })
        #expect(items[toggleIndex + 2].itemIdentifier == .sidebarTrackingSeparator)
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let toggle = try #require(items[toggleIndex].view)
        #expect(inWindow(toggle).minX > inWindow(zoom).maxX)
        #expect(inWindow(toggle).maxX <= inWindow(sidebar).maxX)
        // The activity bell leads the sidebar's section, beside the window's buttons, and the
        // toggle follows it.
        let bellIndex = try #require(items.firstIndex { $0.itemIdentifier.rawValue == "today-activity" })
        #expect(bellIndex < toggleIndex)
        let bell = try #require(items[bellIndex].view)
        try await settle { inWindow(bell).width > 0 }
        #expect(inWindow(bell).minX > inWindow(zoom).maxX)
        #expect(inWindow(bell).minX - inWindow(zoom).maxX < 30)
        #expect(inWindow(bell).maxX <= inWindow(toggle).minX)
        #expect(inWindow(toggle).minX - inWindow(bell).maxX < 30)
        let tabs = try #require(items.first { $0.itemIdentifier.rawValue == "dashboard-tabs" }?.view)
        try await settle { inWindow(tabs).minX >= inWindow(screen).minX }
        #expect(inWindow(tabs).minX >= inWindow(screen).minX)
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(abs(inWindow(tabs).midY - inWindow(close).midY) < 1)

        // A terminal's toolbar has a pane section, tracking the card's divider, with its toggle.
        model.select(.terminal)
        model.openTerminal()
        try await settle { window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "pane-toggle" } == true }
        let pane = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "pane-separator" } as? NSTrackingSeparatorToolbarItem)
        #expect(pane.splitView === columns)
        #expect(pane.dividerIndex == 0)
        // The card's column is held wide enough for the screen, the pane beside it when it is open,
        // and its insets.
        let paneOpen = !content.columns.splitViewItems[1].isCollapsed
        let cardMinimum = MainWindowMetrics.contentMin + (paneOpen ? MainWindowMetrics.paneMin : 0) + 2 * inset
        try await settle { content.splitViewItems[1].minimumThickness == cardMinimum }
        #expect(content.splitViewItems[1].minimumThickness == cardMinimum)
        // The bell is there over a terminal too, before the toggle.
        let terminalItems = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        let terminalBell = try #require(terminalItems.firstIndex(of: "today-activity"))
        #expect(terminalBell < (terminalItems.firstIndex(of: NSToolbarItem.Identifier.toggleSidebar.rawValue) ?? 0))

        // Toggle Sidebar, as the View menu sends it to the window, shuts the sidebar, rail and all:
        // the card then starts at the window's edge, less its inset, rounded there too.
        #expect(window.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil))
        try await settle { sidebarItem.isCollapsed && abs(inWindow(card).minX - inset) < 0.5 }
        #expect(sidebarItem.isCollapsed)
        #expect(abs(inWindow(card).minX - inset) < 0.5)
        #expect(card.layer?.maskedCorners.contains(.layerMinXMaxYCorner) == true)
        // The toggle stays beside the window's buttons. The terminal's is a new toolbar, so its
        // toggle is too.
        let shutToggle = try #require(window.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }?.view)
        try await settle { shutToggle.window === window && inWindow(shutToggle).maxX < inWindow(card).minX + 200 }
        #expect(shutToggle.window === window)
        #expect(inWindow(shutToggle).minX > inWindow(zoom).maxX)

        // And opens it again, once it has finished shutting: AppKit hides the column when its slide
        // completes, and a toggle before then is undone by it.
        try await settle { sidebar.isHiddenOrHasHiddenAncestor }
        #expect(window.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil))
        try await settle { !sidebarItem.isCollapsed && inWindow(card).minX > 200 }
        #expect(!sidebarItem.isCollapsed)

        await model.stop()
    }
}
