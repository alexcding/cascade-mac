import AppKit
import Foundation
import Testing

/// An outline in a short scroll view, driven by the sidebar's coordinator as the app drives it.
@MainActor private struct SidebarHarness {
    let coordinator: CocoaSidebar.Coordinator
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
    let window: NSWindow

    init(_ value: CocoaSidebar, preferences: UserDefaults) {
        _ = NSApplication.shared
        coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = coordinator; outline.delegate = coordinator
        coordinator.outline = outline
        scroll.documentView = outline
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.update(value)
        window.layoutIfNeeded()
    }

    var offset: CGFloat { scroll.contentView.bounds.origin.y }
    func scroll(to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func node(_ id: String) -> CocoaSidebar.Node? {
        (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id }
    }
}

private let modeProject = Project(id: "p1", name: "Project", repo: "o/r", color: nil, workspace: "/tmp")
private func modeEntries() -> [SidebarEntry] {
    let sessions = (0..<40).map { index in
        WorkspaceSession(id: "s\(index)", projectId: "p1", workspace: "/tmp", worktree: "/tmp/s\(index)", title: "s\(index)",
                         branch: "s\(index)", url: "", createdAt: nil, pinned: false)
    }
    let tabs = (0..<40).map { SavedTab(id: "t\($0)", kind: "web", title: "t\($0)", url: "https://t\($0).example") }
    return SidebarEntry.make(projects: [modeProject], sessions: sessions, tabs: tabs)
}
@MainActor private func modeSidebar(_ mode: SidebarMode, selection: SidebarDestination = .overview) -> CocoaSidebar {
    .init(entries: modeEntries().filter { $0.mode == mode }, list: mode.rawValue, selection: selection,
          pinnedIDs: [], onSelect: { _ in }, onTogglePin: { _ in })
}

@MainActor @Test func eachSidebarListKeepsItsOwnScrollPosition() throws {
    let suite = "cascade-sidebar-mode-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let harness = SidebarHarness(modeSidebar(.home), preferences: preferences)
    defer { harness.window.close() }
    harness.scroll(to: 300)
    #expect(harness.offset == 300)
    // Browser does not open where Home was scrolled to: its first rows would be off screen.
    harness.coordinator.update(modeSidebar(.browser))
    #expect(harness.offset == 0)
    harness.scroll(to: 120)
    // Each list comes back where it was left, not scrolled to the row that was already selected.
    harness.coordinator.update(modeSidebar(.home))
    #expect(harness.offset == 300)
    harness.coordinator.update(modeSidebar(.browser))
    #expect(harness.offset == 120)
}

@MainActor @Test func aHeadingThatOpensItsListIsAsTallAsARow() throws {
    let suite = "cascade-sidebar-mode-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    // Nothing is pinned, so "Tabs" is Browser's first row: its title sits on a row's line.
    let harness = SidebarHarness(modeSidebar(.browser), preferences: preferences)
    defer { harness.window.close() }
    func height(_ id: String) throws -> CGFloat {
        harness.coordinator.outlineView(harness.outline, heightOfRowByItem: try #require(harness.node(id)))
    }
    #expect(try height("label:tabs") == SidebarMetrics.rowHeight)
    // A heading further down keeps a heading's height.
    harness.coordinator.update(modeSidebar(.home))
    #expect(try height("label:projects") == SidebarMetrics.labelHeight)
}

@MainActor @Test func aSelectedSessionsFolderIsOpenAgainWhenItsListComesBack() throws {
    let suite = "cascade-sidebar-mode-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let harness = SidebarHarness(modeSidebar(.home), preferences: preferences)
    defer { harness.window.close() }
    let project = try #require(harness.node("project:p1"))
    // Collapsed by hand, then a shortcut lands on a session inside: the folder opens for it.
    harness.outline.collapseItem(project)
    harness.coordinator.update(modeSidebar(.home, selection: .session("s3")))
    #expect(harness.outline.isItemExpanded(project))
    harness.coordinator.update(modeSidebar(.browser, selection: .session("s3")))
    #expect(harness.outline.selectedRow == -1)
    harness.coordinator.update(modeSidebar(.home, selection: .session("s3")))
    // The list was rebuilt, so the folder is a new row for the same project.
    #expect(harness.outline.isItemExpanded(try #require(harness.node("project:p1"))))
    #expect((harness.outline.item(atRow: harness.outline.selectedRow) as? CocoaSidebar.Node)?.entry.id == "session:s3")
}

@Test func everySidebarRowBelongsToOneModeAndTabsAreOnlyBrowsers() {
    let project = modeProject
    let tabs = [SavedTab(id: "a", kind: "web", title: "Docs", url: "https://docs.example", pinned: true),
                SavedTab(id: "b", kind: "web", title: "Plain", url: "https://plain.example")]
    let entries = SidebarEntry.make(projects: [project], sessions: [], tabs: tabs)
    #expect(entries.filter { $0.mode == .home }.map(\.id) == ["overview", "automation", "label:projects", "project:p1"])
    #expect(entries.filter { $0.mode == .browser }.map(\.id) == ["pinned-tabs", "label:tabs", "tab:b"])
    // With no tab saved, Browser still has its heading: the "+" that makes the first one.
    let empty = SidebarEntry.make(projects: [project], sessions: [], tabs: [])
    #expect(empty.filter { $0.mode == .browser }.map(\.id) == ["label:tabs"])
}

@Test func onlyATabIsShownByTheBrowserList() {
    #expect(SidebarDestination.tab("a").sidebarMode == .browser)
    for destination in [SidebarDestination.overview, .automation, .terminal, .project("p"), .session("s")] {
        #expect(destination.sidebarMode == .home, "\(destination)")
    }
    // The rail's first icons are the modes, in this order.
    #expect(SidebarMode.allCases == [.home, .browser])
}

@MainActor @Test func theRailPicksTheListAndANavigationBringsItsOwn() {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    #expect(coordinator.sidebarMode == .home)
    // Before anything is listed, a Browser with no tab to go to shows its list and leaves the window.
    coordinator.showSidebar(.browser)
    #expect(coordinator.sidebarMode == .browser)
    #expect(coordinator.selection == .overview)
    // Landing where the window already is leaves the list the rail picked.
    coordinator.showSidebar(.home)
    #expect(coordinator.selection == .overview)
    coordinator.navigate(to: .overview)
    #expect(coordinator.sidebarMode == .home)
    // Going somewhere shows the list that has its row.
    coordinator.navigate(to: .automation)
    #expect(coordinator.sidebarMode == .home)
    coordinator.navigate(to: .tab("a"))
    #expect(coordinator.sidebarMode == .browser)
}

// Switching lists shows that list's selection, not the other list's page: where the window last
// was from it, both ways.
@MainActor @Test func theRailShowsTheSelectionOfTheListItPicks() {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.navigate(to: .automation)
    coordinator.navigate(to: .tab("a"))
    coordinator.showSidebar(.home)
    #expect(coordinator.sidebarMode == .home)
    #expect(coordinator.selection == .automation)
    coordinator.showSidebar(.browser)
    #expect(coordinator.sidebarMode == .browser)
    #expect(coordinator.selection == .tab("a"))
    // Picking the list already on show changes nothing.
    coordinator.showSidebar(.browser)
    #expect(coordinator.selection == .tab("a"))
}

// Home with nothing remembered from it opens on the Dashboard.
@MainActor @Test func homeFirstOpensOnTheDashboard() {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }),
                                     selectionStore: TransientSidebarSelectionStore(.tab("a")))
    coordinator.showSidebar(.home)
    #expect(coordinator.selection == .overview)
    #expect(coordinator.sidebarMode == .home)
}

@MainActor @Test func theSidebarOpensOnTheListOfTheRestoredSelection() {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }),
                                     selectionStore: TransientSidebarSelectionStore(.tab("a")))
    #expect(coordinator.selection == .tab("a"))
    #expect(coordinator.sidebarMode == .browser)
}

/// The root state a test's sidebar lists.
@MainActor private final class ListedRoot: RootServing {
    var state = RootState()
    func rootState() -> RootState { state }
}

@MainActor private func coordinator(listing root: ListedRoot) -> AppCoordinator {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = RootViewModel(service: root, shell: ShellStore(), viewer: ViewerStore())
    model.onAction = { [weak coordinator] in coordinator?.handle($0) }
    coordinator.rootModel = model
    return coordinator
}

// A tab closed since it was last shown is gone: with no tab left, Browser opens a new one, not
// the closed tab again and not the page from Home.
@MainActor @Test func theRailDoesNotBringBackAClosedTab() throws {
    let root = ListedRoot()
    root.state.entries = SidebarEntry.make(projects: [modeProject], sessions: [], tabs: [])
    let coordinator = coordinator(listing: root)
    coordinator.navigate(to: .tab("a"))
    coordinator.navigate(to: .overview)
    let model = try #require(coordinator.rootModel)
    var actions: [RootViewModel.Action] = []
    let forward = model.onAction
    model.onAction = { actions.append($0); forward($0) }
    coordinator.showSidebar(.browser)
    #expect(coordinator.sidebarMode == .browser)
    #expect(actions == [.newTab])
    #expect(coordinator.selection == .overview)

    // Once there is a tab, Browser shows it.
    root.state.entries = SidebarEntry.make(projects: [modeProject], sessions: [],
                                           tabs: [SavedTab(id: "b", kind: "web", title: "Docs", url: "https://docs.example")])
    coordinator.showSidebar(.home)
    coordinator.showSidebar(.browser)
    #expect(coordinator.selection == .tab("b"))
    // And a tab still listed is brought back as it was left.
    coordinator.showSidebar(.home)
    coordinator.showSidebar(.browser)
    #expect(coordinator.selection == .tab("b"))
}

// Terminal has no sidebar row and never goes stale: Home brings it back.
@MainActor @Test func theRailBringsBackTheTerminal() {
    let root = ListedRoot()
    root.state.entries = SidebarEntry.make(projects: [modeProject], sessions: [], tabs: [])
    let coordinator = coordinator(listing: root)
    coordinator.navigate(to: .terminal)
    coordinator.navigate(to: .tab("a"))
    coordinator.showSidebar(.home)
    #expect(coordinator.selection == .terminal)
}
