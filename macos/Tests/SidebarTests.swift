import AppKit
import Testing

private let sidebarProject = Project(id: "p1", name: "Project", repo: "o/r", color: nil, workspace: "/tmp")
private func workspaceSession(_ id: String, created: String?, pinned: Bool = false, project: String = "p1", url: String = "") -> WorkspaceSession {
    .init(id: id, projectId: project, workspace: "/tmp", worktree: "/tmp/\(id)", title: id,
          branch: id, url: url, createdAt: created, pinned: pinned)
}

@Test func sidebarPinsAreMirrorsAndTaskTabsAreNotDuplicated() {
    let sessions = [workspaceSession("new", created: "2026-02", pinned: true, url: "https://example.com/task"),
                    workspaceSession("old", created: nil),
                    workspaceSession("orphan", created: "2026-01", project: "deleted")]
    let tabs = [SavedTab(kind: "web", title: "Task context", url: "https://example.com/task"),
                SavedTab(kind: "web", title: "Docs", url: "https://example.com/docs")]
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: sessions, tabs: tabs)
    // Web sidebar order: Dashboard, Pinned, Projects (sessions nested), orphans, Tabs.
    #expect(entries.map(\.id) == ["overview", "label:pinned", "pin:new", "label:projects", "project:p1",
                                   "session:orphan", "label:tabs", "tab:https://example.com/docs"])
    let project = entries.first { $0.id == "project:p1" }
    #expect(project?.children.map(\.id) == ["session:old", "session:new"])
    #expect(entries.flatMap(\.descendants).filter { $0.destination == .session("new") }.count == 2)
    #expect(entries.filter { $0.role == .label }.allSatisfy { $0.destination == nil && $0.children.isEmpty })
    #expect(Set(entries.flatMap(\.descendants).map(\.id)).count == entries.flatMap(\.descendants).count)
}

@MainActor @Test func cocoaOutlineRetainsNodesSelectionAndExpansionAcrossRefresh() throws {
    _ = NSApplication.shared
    let suite = "craft-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var selected: SidebarDestination = .overview
    func sidebar(_ sessions: [WorkspaceSession], selection: SidebarDestination) -> CocoaSidebar {
        .init(entries: SidebarEntry.make(projects: [sidebarProject], sessions: sessions, tabs: []),
              selection: selection, pinnedIDs: Set(sessions.filter(\.pinned).map(\.id)),
              onSelect: { selected = $0 }, onTogglePin: { _ in })
    }
    let first = workspaceSession("first", created: "2026-01")
    let value = sidebar([first], selection: .overview)
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(value)
    func node(_ id: String) throws -> CocoaSidebar.Node {
        try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id })
    }
    let original = try node("session:first")
    outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: original)), byExtendingSelection: false)
    #expect(selected == .session("first"))
    var pinned = first; pinned.pinned = true
    coordinator.update(sidebar([pinned, workspaceSession("second", created: "2026-02")], selection: selected))
    #expect(try node("session:first") === original)
    #expect(outline.item(atRow: outline.selectedRow) as? CocoaSidebar.Node === original)
    let project = try node("project:p1")
    outline.collapseItem(project)
    coordinator.update(sidebar([pinned], selection: .project("p1")))
    #expect(!outline.isItemExpanded(project))
    #expect(preferences.stringArray(forKey: "sidebar.collapsed")?.contains("project:p1") == true)
}

@Test func sidebarSessionRowsCarryAgentStatusAndTabIcons() {
    let sessions = [workspaceSession("busy", created: "2026-01"), workspaceSession("stopped", created: "2026-02")]
    let tabs = [SavedTab(kind: "github", title: "PR", url: "https://github.com/o/r/pull/1", login: "octocat")]
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: sessions, tabs: tabs,
                                    status: ["busy": .init(live: true, busy: true, cli: "claude")])
    let rows = entries.flatMap(\.descendants)
    #expect(rows.first { $0.id == "session:busy" }?.role == .session(.init(live: true, busy: true, cli: "claude"), pinned: false))
    #expect(rows.first { $0.id == "session:stopped" }?.role == .session(.init(), pinned: false))
    #expect(rows.first { $0.id == "session:stopped" }?.tooltip?.contains("Stopped") == true)
    #expect(rows.first { $0.id == "tab:https://github.com/o/r/pull/1" }?.role == .tab(.init(kind: "github", login: "octocat", url: "https://github.com/o/r/pull/1")))
    #expect(rows.first { $0.id == "project:p1" }?.role == .project(canCreateSession: true))
}

@Test func pinnedTabsFormOneGridRowUnderDashboardAndLeaveTheTabsList() {
    let tabs = [SavedTab(id: "a", kind: "web", title: "Docs", url: "https://docs.example", pinned: true),
                SavedTab(id: "b", kind: "github", title: "PR", url: "https://github.com/o/r/pull/1", login: "octocat", pinned: true),
                SavedTab(id: "c", kind: "web", title: "", url: "https://plain.example")]
    let entries = SidebarEntry.make(projects: [], sessions: [], tabs: tabs)
    #expect(entries.map(\.id) == ["overview", "pinned-tabs", "label:projects", "label:tabs", "tab:c"])
    let grid = entries.first { $0.id == "pinned-tabs" }
    #expect(grid?.destination == nil)
    #expect(grid?.role == .pinnedTabs([
        .init(id: "a", title: "Docs", url: "https://docs.example", icon: .init(kind: "web", url: "https://docs.example")),
        .init(id: "b", title: "PR", url: "https://github.com/o/r/pull/1", icon: .init(kind: "github", login: "octocat", url: "https://github.com/o/r/pull/1")),
    ]))
    // A pinned tab that belongs to a session stays hidden, like any task tab.
    let owned = SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("s", created: nil, url: "https://docs.example")], tabs: tabs)
    if case .pinnedTabs(let shown)? = owned.first(where: { $0.id == "pinned-tabs" })?.role { #expect(shown.map(\.id) == ["b"]) } else { Issue.record("grid missing") }
    // One tile is a full row; more wrap four to a row.
    #expect(SidebarPinnedTabsGrid.height(count: 1) == SidebarPinnedTabsGrid.height(count: 4))
    #expect(SidebarPinnedTabsGrid.height(count: 4) == SidebarPinnedTabsGrid.height(count: 2))
    #expect(SidebarPinnedTabsGrid.height(count: 5) > SidebarPinnedTabsGrid.height(count: 4))
}

private func savedTab(_ id: String) -> SavedTab { SavedTab(id: id, kind: "web", title: id, url: "https://\(id).example") }

@MainActor @Test func tabReorderMovesBeforeTargetOrToEndAndKeepsDraftsAfterSavedTabs() throws {
    let shown = ["a", "b", "c", "d1", "d2"].map(savedTab)
    let drafts: Set<String> = ["d1", "d2"]
    func split(_ list: [SavedTab]) -> ([String], [String]) {
        (list.filter { !drafts.contains($0.id) }.map(\.id), list.filter { drafts.contains($0.id) }.map(\.id))
    }
    #expect(try #require(AppViewModel.reordered(shown, moving: "c", before: "a")).map(\.id) == ["c", "a", "b", "d1", "d2"])
    #expect(try #require(AppViewModel.reordered(shown, moving: "a", before: nil)).map(\.id) == ["b", "c", "d1", "d2", "a"])
    #expect(try #require(AppViewModel.reordered(shown, moving: "a", before: "missing")).map(\.id) == ["b", "c", "d1", "d2", "a"])
    #expect(AppViewModel.reordered(shown, moving: "missing", before: "a") == nil)
    // A saved tab dropped among drafts still lands in the saved list; a draft dropped among
    // saved tabs stays a draft and follows them, each list keeping its relative order.
    let mixed = try #require(AppViewModel.reordered(shown, moving: "a", before: "d2"))
    #expect(split(mixed) == (["b", "c", "a"], ["d1", "d2"]))
    let draftFirst = try #require(AppViewModel.reordered(shown, moving: "d2", before: "a"))
    #expect(split(draftFirst) == (["a", "b", "c"], ["d2", "d1"]))
}

@MainActor @Test func tabOrderRollbackRestoresRelativeOrderAndKeepsUnknownTabsAtTheEnd() {
    let current = ["c", "new", "a", "b"].map(savedTab)
    #expect(AppViewModel.ordered(current, by: ["a", "b", "c", "gone"]).map(\.id) == ["a", "b", "c", "new"])
    #expect(AppViewModel.ordered([], by: ["a"]).isEmpty)
}

@MainActor @Test func faviconFallbackIsLimitedToPublicHosts() {
    #expect(FaviconStore.isPublicHost("github.com") && FaviconStore.isPublicHost("issues.apache.org"))
    for host in ["localhost", "jira", "jira.internal", "build.corp", "printer.local", "nas.lan", "10.0.0.4", "::1", "app.test"] {
        #expect(!FaviconStore.isPublicHost(host), "\(host) should stay private")
    }
}

/// The "+" on the Tabs heading and the "+" on a project row are the same control in the same
/// place. A source list frames a heading's cell differently from an item's, so they only line up
/// on screen if the heading reads the item's edge rather than reusing its own offset.
@MainActor @Test func tabsHeadingAddButtonLinesUpWithAProjectRows() throws {
    _ = NSApplication.shared
    let suite = "craft-sidebar-align-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let value = CocoaSidebar(entries: SidebarEntry.make(projects: [sidebarProject], sessions: [], tabs: []),
                             selection: .overview, pinnedIDs: [], onSelect: { _ in }, onTogglePin: { _ in })
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    let column = NSTableColumn(identifier: .init("name"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.headerView = nil
    outline.style = .sourceList
    outline.rowSizeStyle = .medium
    outline.indentationPerLevel = 0
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    scroll.documentView = outline
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // ARC owns this window. AppKit's default would release it again on close.
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    coordinator.update(value)
    outline.expandItem(nil, expandChildren: true)
    window.layoutIfNeeded()

    func accessoryEdge(_ role: (SidebarEntry.Role) -> Bool) throws -> CGFloat {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? CocoaSidebar.Node, role(node.entry.role),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else { continue }
            cell.needsLayout = true; cell.layoutSubtreeIfNeeded()
            let button = try #require(cell.subviews.first { $0 is SidebarAccessoryButton })
            return button.convert(NSPoint(x: button.bounds.maxX, y: 0), to: outline).x
        }
        throw BackendError.operation("no such row")
    }
    let heading = try accessoryEdge { if case .tabsHeader = $0 { true } else { false } }
    let project = try accessoryEdge { if case .project = $0 { true } else { false } }
    #expect(abs(heading - project) < 0.5, "heading + ends at \(heading), project + at \(project)")
    window.close()
}

@MainActor @Test func sessionReorderStaysInsideItsProjectAndTheDraggedOrderIsTheApps() throws {
    let sessions = [workspaceSession("a", created: "2026-01"), workspaceSession("x", created: "2026-02", project: "p2"),
                    workspaceSession("b", created: "2026-03"), workspaceSession("c", created: "2026-04")]
    let moved = try #require(AppViewModel.reordered(sessions, movingSession: "c", before: "a"))
    // Siblings trade their own slots; the other project's session keeps its place.
    #expect(moved.map(\.id) == ["c", "x", "a", "b"])
    #expect(try #require(AppViewModel.reordered(moved, movingSession: "c", before: nil)).map(\.id) == ["a", "x", "b", "c"])
    #expect(AppViewModel.reordered(sessions, movingSession: "a", before: "x") == nil)
    #expect(AppViewModel.reordered(sessions, movingSession: "a", before: "b") == nil)
    #expect(AppViewModel.reordered(sessions, movingSession: "missing", before: nil) == nil)

    // The dragged order wins over creation order; ids it does not know come last, ids that are gone are ignored.
    let dragged = ["gone", "c", "x", "a", "b"]
    #expect(SidebarEntry.displayOrder(sessions.shuffled(), dragged: dragged).map(\.id) == ["c", "x", "a", "b"])
    #expect(SidebarEntry.displayOrder(sessions + [workspaceSession("new", created: "2025-01")], dragged: dragged).last?.id == "new")
    let projects = [sidebarProject, Project(id: "p2", name: "Second", repo: "o/s", color: nil, workspace: "/tmp"),
                    Project(id: "p3", name: "Third", repo: "o/t", color: nil, workspace: "/tmp")]
    #expect(SidebarEntry.displayOrder(projects, dragged: ["p3", "gone", "p1"]).map(\.id) == ["p3", "p1", "p2"])
    let entries = SidebarEntry.make(projects: projects, sessions: sessions, tabs: [], order: .init(projects: ["p2"], sessions: dragged))
    #expect(entries.filter { $0.projectID != nil }.map(\.id) == ["project:p2", "project:p1", "project:p3"])
    #expect(entries.first { $0.id == "project:p1" }?.children.map(\.id) == ["session:c", "session:a", "session:b"])
    // Pinned mirrors span projects and keep an order of their own, whatever was dragged inside one.
    let everyPinned = sessions.map { session in var pinned = session; pinned.pinned = true; return pinned }
    func pins(_ order: SidebarOrder) -> [String] {
        SidebarEntry.make(projects: projects, sessions: everyPinned, tabs: [], order: order).filter { $0.id.hasPrefix("pin:") }.map(\.id)
    }
    #expect(pins(.init(sessions: dragged)) == ["pin:a", "pin:x", "pin:b", "pin:c"])
    #expect(pins(.init(sessions: dragged, pinned: ["c", "a"])) == ["pin:c", "pin:a", "pin:x", "pin:b"])
    // Unpinning forgets the place; pinning again joins the end.
    let arranged = SidebarOrder(pinned: ["c", "a", "x", "b"])
    let unpinned = arranged.pinning("c", pinned: false, shown: arranged.pinned)
    #expect(unpinned.pinned == ["a", "x", "b"])
    #expect(unpinned.pinning("c", pinned: true, shown: unpinned.pinned).pinned == ["a", "x", "b", "c"])
    #expect(SidebarOrder().pinning("b", pinned: true, shown: ["a", "x"]).pinned == ["a", "x", "b"])

    // It survives a relaunch through the app's own preferences.
    let suite = "craft-sidebar-order-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    #expect(UserDefaultsSidebarOrderStore(preferences: preferences).load() == SidebarOrder())
    UserDefaultsSidebarOrderStore(preferences: preferences).save(.init(projects: ["p2"], sessions: dragged, pinned: ["x"]))
    #expect(UserDefaultsSidebarOrderStore(preferences: preferences).load() == .init(projects: ["p2"], sessions: dragged, pinned: ["x"]))
}

@MainActor private final class SidebarDropInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: .init("craft-sidebar-test-\(UUID().uuidString)"))
    init(placement: String) {
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.setString(placement, forType: CocoaSidebar.dragType)
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor @Test func draggingASidebarRowMovesItAmongItsSiblingsAndKeepsItListed() throws {
    _ = NSApplication.shared
    let suite = "craft-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let projects = [sidebarProject, Project(id: "p2", name: "Second", repo: "o/s", color: nil, workspace: "/tmp"),
                    Project(id: "p3", name: "Third", repo: "o/t", color: nil, workspace: "/tmp")]
    let sessions = [workspaceSession("a", created: "2026-01", pinned: true), workspaceSession("b", created: "2026-02"),
                    workspaceSession("c", created: "2026-03"), workspaceSession("x", created: "2026-04", pinned: true, project: "p2"),
                    workspaceSession("orphan", created: "2026-05", project: "deleted")]
    let tabs = [SavedTab(id: "t1", kind: "web", title: "One", url: "https://example.com/1"),
                SavedTab(id: "t2", kind: "web", title: "Two", url: "https://example.com/2")]
    var moves: [String] = []
    var value = CocoaSidebar(entries: SidebarEntry.make(projects: projects, sessions: sessions, tabs: tabs),
                             selection: .overview, pinnedIDs: ["a", "x"], onSelect: { _ in }, onTogglePin: { _ in })
    value.onMoveTab = { moves.append("tab \($0) before \($1 ?? "end")") }
    value.onMoveProject = { moves.append("project \($0) before \($1 ?? "end")") }
    value.onMoveSession = { moves.append("session \($0) before \($1 ?? "end")") }
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(value)
    func rows() -> [String] { (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? CocoaSidebar.Node)?.entry.id } }
    func node(_ id: String) throws -> CocoaSidebar.Node {
        try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id })
    }
    func root(_ id: String) throws -> Int { outline.childIndex(forItem: try node(id)) }
    func drop(_ placement: String, on item: CocoaSidebar.Node?, at index: Int) -> Bool {
        let info = SidebarDropInfo(placement: placement)
        defer { info.draggingPasteboard.releaseGlobally() }
        guard coordinator.outlineView(outline, validateDrop: info, proposedItem: item, proposedChildIndex: index) == .move else { return false }
        return coordinator.outlineView(outline, acceptDrop: info, item: item, childIndex: index)
    }
    let before = rows()

    // Rows that must not move, and drops that leave a row's own list.
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("pin:a")) != nil)
    #expect(!drop("pin:a", on: nil, at: try root("project:p2")))
    #expect(!drop("pin:a", on: try node("project:p1"), at: 0))
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("session:orphan")) == nil)
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("label:projects")) == nil)
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("session:b")) != nil)
    #expect(!drop("session:a", on: try node("project:p2"), at: 0))
    #expect(!drop("session:a", on: nil, at: try root("project:p2")))
    #expect(!drop("project:p1", on: nil, at: try root("label:tabs") + 1))
    #expect(!drop("tab:t2", on: nil, at: try root("project:p1")))
    // Dropping a row where it already is moves nothing.
    #expect(!drop("session:a", on: try node("project:p1"), at: 0))
    #expect(!drop("session:a", on: try node("project:p1"), at: 1))
    #expect(rows() == before && moves.isEmpty)

    // A session moves among its project's sessions, by gap or by landing on a sibling.
    #expect(drop("session:c", on: try node("project:p1"), at: 0))
    #expect(drop("session:a", on: try node("project:p1"), at: 3))
    #expect(drop("session:a", on: try node("session:c"), at: -1))
    #expect(moves == ["session c before a", "session a before end", "session a before c"])
    #expect(try node("project:p1").children.map(\.entry.id) == ["session:a", "session:c", "session:b"])

    // A project moves within Projects, carrying its sessions; among another project's sessions lands after it.
    moves = []
    #expect(drop("project:p3", on: try node("project:p1"), at: -1))
    #expect(drop("project:p3", on: try node("project:p1"), at: 1))
    #expect(drop("project:p1", on: nil, at: try root("project:p2") + 1))
    #expect(moves == ["project p3 before p1", "project p3 before p2", "project p1 before end"])
    #expect(drop("tab:t2", on: try node("tab:t1"), at: -1))
    #expect(drop("tab:t2", on: nil, at: -1))

    // Every row is still listed, and the model's answer in the new order is not a reload.
    #expect(rows().sorted() == before.sorted())
    let kept = try node("session:b")
    let answer = ["p3", "p2", "p1"]
    value = CocoaSidebar(entries: SidebarEntry.make(projects: projects, sessions: sessions, tabs: tabs,
                                                    order: .init(projects: answer, sessions: ["a", "c", "b"])),
                         selection: .overview, pinnedIDs: ["a", "x"], onSelect: { _ in }, onTogglePin: { _ in })
    value.onMoveTab = { moves.append("tab \($0) before \($1 ?? "end")") }
    value.onMoveProject = { moves.append("project \($0) before \($1 ?? "end")") }
    value.onMoveSession = { moves.append("session \($0) before \($1 ?? "end")") }
    value.onMovePinned = { moves.append("pinned \($0) before \($1 ?? "end")") }
    let shown = rows()
    coordinator.update(value)
    #expect(rows() == shown)
    #expect(try node("session:b") === kept)

    // Dropped ON a row, the dragged row takes its place — so one step down is a real move,
    // and a project's open sessions count as the project.
    moves = []
    #expect(drop("project:p3", on: try node("project:p2"), at: -1))
    #expect(drop("project:p1", on: try node("project:p2"), at: 0))
    #expect(drop("project:p1", on: try node("session:x"), at: -1))
    #expect(drop("session:a", on: try node("session:c"), at: -1))
    #expect(drop("tab:t1", on: try node("tab:t2"), at: -1))
    // A session dropped on its own folder's row goes to the top; the top one stays put.
    #expect(!drop("session:c", on: try node("project:p1"), at: -1))
    #expect(drop("session:b", on: try node("project:p1"), at: -1))
    #expect(drop("session:b", on: try node("project:p1"), at: 3))
    // A pinned mirror moves within Pinned only, and its project's row stays where it was.
    #expect(drop("pin:a", on: try node("pin:x"), at: -1))
    #expect(drop("pin:a", on: nil, at: try root("pin:x")))
    #expect(moves == ["project p3 before p1", "project p1 before p2", "project p1 before p3",
                      "session a before b", "tab t1 before end", "session b before c", "session b before end",
                      "pinned a before end", "pinned a before x"])
    #expect(try node("project:p1").children.map(\.entry.id) == ["session:c", "session:a", "session:b"])
    #expect(rows().sorted() == before.sorted())
}

@MainActor @Test func aDraggedSidebarRowCarriesAPictureOfItself() throws {
    _ = NSApplication.shared
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("a", created: "2026-01")], tabs: [])
    let session = try #require(entries.flatMap(\.descendants).first { $0.id == "session:a" })
    let cell = SidebarCellView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarMetrics.rowHeight))
    cell.configure(session, nested: true, spinFrame: 0)
    cell.layoutSubtreeIfNeeded()
    let component = try #require(cell.draggingImageComponents.first)
    #expect(cell.draggingImageComponents.count == 1)
    #expect(component.frame == cell.bounds)
    // The title is drawn: some pixel of the picture is not transparent.
    let image = try #require(component.contents as? NSImage)
    let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
    let inked = (0..<bitmap.pixelsWide).contains { x in (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 } }
    #expect(inked)
}
