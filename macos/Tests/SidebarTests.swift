import AppKit
import SwiftUI
import Testing

private let sidebarProject = Project(id: "p1", name: "Project", repo: "o/r", color: nil, workspace: "/tmp")
private func workspaceSession(_ id: String, created: String?, pinned: Bool = false, project: String = "p1", url: String = "") -> WorkspaceSession {
    .init(id: id, projectId: project, workspace: "/tmp", worktree: "/tmp/\(id)", title: id,
          branch: id, url: url, createdAt: created, pinned: pinned)
}

@Test func sidebarPinsLeaveProjectsAndOrphans() {
    let sessions = [workspaceSession("new", created: "2026-02", pinned: true, url: "https://example.com/task"),
                    workspaceSession("old", created: nil),
                    workspaceSession("orphan", created: "2026-01", project: "deleted"),
                    workspaceSession("pinned-orphan", created: "2026-03", pinned: true, project: "deleted")]
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: sessions)
    // Sidebar order: Dashboard, Pinned, Projects (sessions nested), orphans.
    #expect(entries.map(\.id) == ["new-session", "overview", "automation", "label:pinned", "pin:new", "pin:pinned-orphan", "label:projects", "project:p1",
                                   "session:orphan"])
    let project = entries.first { $0.id == "project:p1" }
    #expect(project?.children.map(\.id) == ["session:old"])
    for session in sessions {
        #expect(entries.flatMap(\.descendants).filter { $0.destination == .session(session.id) }.count == 1)
    }
    #expect(entries.filter { $0.role == .label }.allSatisfy { $0.destination == nil && $0.children.isEmpty })
    #expect(Set(entries.flatMap(\.descendants).map(\.id)).count == entries.flatMap(\.descendants).count)
    let unpinned = sessions.map { session in var value = session; value.pinned = false; return value }
    let restored = SidebarEntry.make(projects: [sidebarProject], sessions: unpinned)
    #expect(!restored.contains { $0.id == "label:pinned" })
    #expect(restored.first { $0.id == "project:p1" }?.children.map(\.id) == ["session:old", "session:new"])
    #expect(restored.contains { $0.id == "session:pinned-orphan" })
}

@MainActor @Test func cocoaOutlineRetainsNodesSelectionAndExpansionAcrossRefresh() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var selected: SidebarDestination = .overview
    func sidebar(_ sessions: [WorkspaceSession], selection: SidebarDestination) -> CocoaSidebar {
        .init(entries: SidebarEntry.make(projects: [sidebarProject], sessions: sessions),
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
    let second = workspaceSession("second", created: "2026-02")
    coordinator.update(sidebar([first, second], selection: selected))
    #expect(try node("session:first") === original)
    #expect(outline.item(atRow: outline.selectedRow) as? CocoaSidebar.Node === original)
    var pinned = first; pinned.pinned = true
    coordinator.update(sidebar([pinned, second], selection: selected))
    let pin = try node("pin:first")
    #expect(outline.item(atRow: outline.selectedRow) as? CocoaSidebar.Node === pin)
    let project = try node("project:p1")
    #expect(project.children.map(\.entry.id) == ["session:second"])
    outline.collapseItem(project)
    coordinator.update(sidebar([first, second], selection: selected))
    #expect(outline.isItemExpanded(project))
    #expect((outline.item(atRow: outline.selectedRow) as? CocoaSidebar.Node)?.entry.id == "session:first")
    outline.collapseItem(project)
    coordinator.update(sidebar([first], selection: .project("p1")))
    #expect(!outline.isItemExpanded(project))
    #expect(preferences.stringArray(forKey: "sidebar.collapsed")?.contains("project:p1") == true)
}

@Test func sidebarSessionRowsCarryAgentStatus() {
    let sessions = [workspaceSession("busy", created: "2026-01"), workspaceSession("stopped", created: "2026-02")]
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: sessions,
                                    status: ["busy": .init(live: true, busy: true, cli: "claude")])
    let rows = entries.flatMap(\.descendants)
    #expect(rows.first { $0.id == "session:busy" }?.role == .session(.init(live: true, busy: true, cli: "claude"), pinned: false))
    #expect(rows.first { $0.id == "session:stopped" }?.role == .session(.init(), pinned: false))
    #expect(rows.first { $0.id == "session:stopped" }?.tooltip?.contains("Stopped") == true)
    #expect(rows.first { $0.id == "project:p1" }?.role == .project)
}

@MainActor @Test func faviconFallbackIsLimitedToPublicHosts() {
    #expect(FaviconStore.isPublicHost("github.com") && FaviconStore.isPublicHost("issues.apache.org"))
    for host in ["localhost", "jira", "jira.internal", "build.corp", "printer.local", "nas.lan", "10.0.0.4", "::1", "app.test"] {
        #expect(!FaviconStore.isPublicHost(host), "\(host) should stay private")
    }
}

/// The "+" on the Projects heading and a session's pin sit in the same place. A source list frames a heading's cell differently from an item's, so they only line up
/// on screen if the heading reads the item's edge rather than reusing its own offset.
@MainActor @Test func projectsHeadingAddButtonLinesUpWithASessionsPin() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-align-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let value = CocoaSidebar(entries: SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("s", created: nil)], canCreateProject: true),
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
    let heading = try accessoryEdge { if case .projectsHeader = $0 { true } else { false } }
    let pin = try accessoryEdge { if case .session = $0 { true } else { false } }
    #expect(abs(heading - pin) < 0.5, "heading + ends at \(heading), a session's pin at \(pin)")
    window.close()
}

/// A section heading is set in the sidebar's own heading font, not the source list's group font:
/// the list styles a cell's `textField` as it displays a group row, so a heading keeps none.
@MainActor @Test func sectionHeadingKeepsTheSidebarsHeadingFont() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-heading-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let value = CocoaSidebar(entries: SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("pinned", created: nil, pinned: true)]),
                             selection: .overview, pinnedIDs: ["pinned"], onSelect: { _ in }, onTogglePin: { _ in })
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.headerView = nil
    outline.style = .sourceList
    outline.rowSizeStyle = .medium
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    scroll.documentView = outline
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    coordinator.update(value)
    outline.expandItem(nil, expandChildren: true)
    window.layoutIfNeeded(); outline.displayIfNeeded()
    let expected = SidebarMetrics.headingFont
    var headings = 0
    for row in 0..<outline.numberOfRows {
        guard let node = outline.item(atRow: row) as? CocoaSidebar.Node, node.entry.isHeading,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else { continue }
        let title = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == node.entry.title })
        #expect(title.font == expected, "\(node.entry.title) is set in \(String(describing: title.font))")
        headings += 1
    }
    #expect(headings >= 2)
    window.close()
}

/// A pinned session sits at the top level, with no project before it: its dot's slot ends where a
/// folder's glyph does, so its name starts where a project's does, a slot short of a nested session's.
@MainActor @Test func aPinnedSessionsNameStartsWhereAProjectsDoes() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-pinned-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let value = CocoaSidebar(entries: SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("pinned", created: nil, pinned: true),
                                                                                               workspaceSession("nested", created: nil)]),
                             selection: .overview, pinnedIDs: ["pinned"], onSelect: { _ in }, onTogglePin: { _ in })
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    let column = NSTableColumn(identifier: .init("name"))
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
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    coordinator.update(value)
    outline.expandItem(nil, expandChildren: true)
    window.layoutIfNeeded(); outline.displayIfNeeded()
    var titleX: [String: CGFloat] = [:], dotX: [String: CGFloat] = [:]
    var folderRight: CGFloat = 0
    for row in 0..<outline.numberOfRows {
        guard let node = outline.item(atRow: row) as? CocoaSidebar.Node,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else { continue }
        cell.needsLayout = true; cell.layoutSubtreeIfNeeded()
        let title = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == node.entry.title })
        titleX[node.entry.id] = cell.convert(title.frame, to: outline).minX
        if let dot = cell.subviews.compactMap({ $0 as? SidebarStatusDot }).first, !dot.isHidden {
            dotX[node.entry.id] = cell.convert(dot.frame, to: outline).midX
        }
        if node.entry.id.hasPrefix("project:"), let glyph = cell.icon.image {
            folderRight = cell.convert(cell.icon.frame, to: outline).midX + glyph.size.width / 2
        }
    }
    window.close()
    let pinned = try #require(titleX["pin:pinned"])
    let project = try #require(titleX["project:p1"]), nested = try #require(titleX["session:nested"])
    #expect(pinned == project, "a pinned session's name where a project's is")
    #expect(nested > project, "further in, after its dot")
    let pinnedDot = try #require(dotX["pin:pinned"])
    #expect(abs(pinnedDot - (folderRight - SidebarCellView.statusSlot / 2)) <= 0.5, "the dot's slot ends where the folder's glyph does")
    #expect(abs(try #require(dotX["session:nested"]) - (folderRight + project) / 2) <= 0.5, "a nested dot sits between the folder's glyph and the project's name")
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
    let entries = SidebarEntry.make(projects: projects, sessions: sessions, order: .init(projects: ["p2"], sessions: dragged))
    #expect(entries.filter { $0.projectID != nil }.map(\.id) == ["project:p2", "project:p1", "project:p3"])
    #expect(entries.first { $0.id == "project:p1" }?.children.map(\.id) == ["session:c", "session:a", "session:b"])
    // Pinned mirrors span projects and keep an order of their own, whatever was dragged inside one.
    let everyPinned = sessions.map { session in var pinned = session; pinned.pinned = true; return pinned }
    func pins(_ order: SidebarOrder) -> [String] {
        SidebarEntry.make(projects: projects, sessions: everyPinned, order: order).filter { $0.id.hasPrefix("pin:") }.map(\.id)
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
    let suite = "cascade-sidebar-order-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    #expect(UserDefaultsSidebarOrderStore(preferences: preferences).load() == SidebarOrder())
    UserDefaultsSidebarOrderStore(preferences: preferences).save(.init(projects: ["p2"], sessions: dragged, pinned: ["x"]))
    #expect(UserDefaultsSidebarOrderStore(preferences: preferences).load() == .init(projects: ["p2"], sessions: dragged, pinned: ["x"]))
}

/// A project row is a folder until an icon is chosen for it in the project's forms, and the
/// draft those forms edit sends the icon to the backend, storing nothing for the folder.
@MainActor @Test func projectRowsDrawTheIconChosenForThem() throws {
    #expect(SidebarEntry.make(projects: [sidebarProject], sessions: []).first { $0.id == "project:p1" }?.symbol == "folder")
    let iconed = Project(id: "p1", name: "Project", repo: "o/r", color: nil, workspace: "/tmp", icon: "hammer")
    #expect(SidebarEntry.make(projects: [iconed], sessions: []).first { $0.id == "project:p1" }?.symbol == "hammer")
    #expect(Project(id: "p1", name: "Project", repo: "o/r", color: nil, workspace: "/tmp", icon: "").symbol == "folder")
    #expect(SidebarIcons.rowSymbol("hammer") != nil)

    #expect(ProjectDraft(iconed).icon == "hammer")
    #expect(ProjectDraft(sidebarProject).icon.isEmpty)
    let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectDraft(iconed))) as? [String: Any]
    #expect(body?["icon"] as? String == "hammer")
}

@MainActor private final class SidebarDropInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: .init("cascade-sidebar-test-\(UUID().uuidString)"))
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
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let projects = [sidebarProject, Project(id: "p2", name: "Second", repo: "o/s", color: nil, workspace: "/tmp"),
                    Project(id: "p3", name: "Third", repo: "o/t", color: nil, workspace: "/tmp")]
    let sessions = [workspaceSession("a", created: "2026-01"), workspaceSession("b", created: "2026-02"),
                    workspaceSession("c", created: "2026-03"), workspaceSession("x", created: "2026-04", project: "p2"),
                    workspaceSession("pa", created: "2026-01", pinned: true),
                    workspaceSession("px", created: "2026-04", pinned: true, project: "p2"),
                    workspaceSession("orphan", created: "2026-05", project: "deleted")]
    var moves: [String] = []
    var value = CocoaSidebar(entries: SidebarEntry.make(projects: projects, sessions: sessions),
                             selection: .overview, pinnedIDs: ["pa", "px"], onSelect: { _ in }, onTogglePin: { _ in })
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
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("pin:pa")) != nil)
    #expect(!drop("pin:pa", on: nil, at: try root("project:p2")))
    #expect(!drop("pin:pa", on: try node("project:p1"), at: 0))
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("session:orphan")) == nil)
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("label:projects")) == nil)
    #expect(coordinator.outlineView(outline, pasteboardWriterForItem: try node("session:b")) != nil)
    #expect(!drop("session:a", on: try node("project:p2"), at: 0))
    #expect(!drop("session:a", on: nil, at: try root("project:p2")))
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

    // Every row is still listed, and the model's answer in the new order is not a reload.
    #expect(rows().sorted() == before.sorted())
    let kept = try node("session:b")
    let answer = ["p3", "p2", "p1"]
    value = CocoaSidebar(entries: SidebarEntry.make(projects: projects, sessions: sessions,
                                                    order: .init(projects: answer, sessions: ["a", "c", "b"])),
                         selection: .overview, pinnedIDs: ["pa", "px"], onSelect: { _ in }, onTogglePin: { _ in })
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
    // A session dropped on its own folder's row goes to the top; the top one stays put.
    #expect(!drop("session:c", on: try node("project:p1"), at: -1))
    #expect(drop("session:b", on: try node("project:p1"), at: -1))
    #expect(drop("session:b", on: try node("project:p1"), at: 3))
    // Pinned sessions reorder independently of the unpinned project sessions.
    #expect(drop("pin:pa", on: try node("pin:px"), at: -1))
    #expect(drop("pin:pa", on: nil, at: try root("pin:px")))
    #expect(moves == ["project p3 before p1", "project p1 before p2", "project p1 before p3",
                      "session a before b", "session b before c", "session b before end",
                      "pinned pa before end", "pinned pa before px"])
    #expect(try node("project:p1").children.map(\.entry.id) == ["session:c", "session:a", "session:b"])
    #expect(rows().sorted() == before.sorted())
}

/// The gap style hides the pressed row before any pasteboard writer is asked for, so a row with
/// nothing to drag has to refuse the drag itself, or a wobbly click leaves its slot empty.
@MainActor @Test func aRowThatCannotMoveRefusesTheDragBeforeTheTableHidesIt() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let sessions = [workspaceSession("a", created: "2026-01"), workspaceSession("pa", created: "2026-02", pinned: true),
                    workspaceSession("orphan", created: "2026-05", project: "deleted")]
    let value = CocoaSidebar(entries: SidebarEntry.make(projects: [sidebarProject], sessions: sessions),
                             selection: .overview, pinnedIDs: ["pa"], onSelect: { _ in }, onTogglePin: { _ in })
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = SidebarOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    outline.canDrag = { coordinator.canDrag($0) }
    // In a window, as on screen: out of one the table refuses every drag by itself.
    let window = NSWindow(contentRect: outline.frame, styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = outline
    coordinator.outline = outline
    coordinator.update(value)
    outline.layoutSubtreeIfNeeded()
    func canDrag(_ id: String) throws -> Bool {
        let row = try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? CocoaSidebar.Node)?.entry.id == id })
        return outline.canDragRows(with: [row], at: NSPoint(x: 40, y: outline.rect(ofRow: row).midY))
    }

    for id in ["new-session", "overview", "automation", "label:pinned", "label:projects", "session:orphan"] {
        #expect(try !canDrag(id), "\(id)")
    }
    for id in ["pin:pa", "project:p1", "session:a"] { #expect(try canDrag(id), "\(id)") }
    window.close()
}

@MainActor @Test func aDraggedSidebarRowCarriesAPictureOfItself() throws {
    _ = NSApplication.shared
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("a", created: "2026-01")])
    let session = try #require(entries.flatMap(\.descendants).first { $0.id == "session:a" })
    let cell = SidebarCellView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarMetrics.rowHeight))
    cell.configure(session, nested: true)
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

/// A session has no icon: its status dot leads the row, centred where an icon would be, starting under
/// its project's name, in every state and under the pointer. The pin takes the trailing slot under the
/// pointer, and the key that selects the session takes it while ⌘ is held, with no plate; the name does not move.
@MainActor @Test func aSessionLeadsWithItsStatusDot() throws {
    _ = NSApplication.shared
    let entries = SidebarEntry.make(projects: [sidebarProject], sessions: [workspaceSession("a", created: "2026-01")],
                                    status: ["a": SidebarSessionStatus(live: true, cli: "claude")])
    let project = try #require(entries.flatMap(\.descendants).first { $0.id.hasPrefix("project:") })
    let idle = try #require(entries.flatMap(\.descendants).first { $0.id == "session:a" })
    var working = idle
    working.role = .session(SidebarSessionStatus(live: true, busy: true, cli: "claude"), pinned: false)
    let folder = SidebarCellView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarMetrics.rowHeight))
    folder.configure(project, nested: false)
    folder.needsLayout = true; folder.layoutSubtreeIfNeeded()
    let folderTitle = try #require(folder.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == project.title }).frame
    let cell = SidebarCellView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarMetrics.rowHeight))
    func label(_ text: String) -> NSTextField? {
        cell.needsLayout = true; cell.layoutSubtreeIfNeeded()
        return cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == text && !$0.isHidden }
    }
    // An icon is the sidebar's grey, and its title's colour once its row is selected.
    #expect(folder.icon.contentTintColor == SidebarPalette.icon)
    folder.selected = true
    #expect(folder.icon.contentTintColor == NSColor.labelColor, "a selected row's icon is its title's colour")
    folder.selected = false
    let row = SidebarRowView(frame: folder.frame)
    row.isSelected = true
    let reused = SidebarCellView(frame: folder.frame)
    reused.configure(project, nested: false)
    row.addSubview(reused)
    #expect(reused.icon.contentTintColor == NSColor.labelColor, "a cell put into a selected row takes its colour")
    let dot = try #require(cell.subviews.compactMap { $0 as? SidebarStatusDot }.first)
    cell.configure(idle, nested: true)
    #expect(cell.accessibilityLabel() == "\(idle.title), Idle", "the row reads its status after its title")
    let title = try #require(label(idle.title)).frame
    #expect(cell.icon.isHidden, "a session has no icon")
    #expect(!dot.isHidden, "an idle session shows its dot")
    let slot = SidebarCellView.statusSlot
    let folderIcon = folder.icon, folderImage = try #require(folderIcon.image)
    let folderRight = folderIcon.frame.midX + folderImage.size.width / 2
    #expect(abs(dot.frame.midX - (folderRight + folderTitle.minX) / 2) <= 0.5, "the dot sits between the folder's glyph and the project's name")
    let font = try #require(label(idle.title)?.font)
    let middle = title.minY + font.ascender - (font.capHeight + font.xHeight) / 4
    #expect(abs(dot.frame.midY - middle) <= 0.5, "the dot is on the letters' middle, not the label frame's")
    let folderToName = folderTitle.minX - folderRight
    #expect(abs((title.minX - (dot.frame.midX + slot / 2)) - folderToName) <= 0.5, "as far from its name as the folder is from the project's")

    cell.configure(working, nested: true)
    _ = label(working.title)
    #expect(!dot.isHidden && dot.state == .working(cli: "claude"))
    #expect(label("⌘1") == nil)
    let pin = try #require(cell.subviews.compactMap { $0 as? SidebarAccessoryButton }.first)
    cell.hovered = true
    let hoveredTitle = try #require(label(working.title)).frame
    #expect(!dot.isHidden && !pin.isHidden, "the pin shows trailing, the dot stays")
    #expect(hoveredTitle.origin == title.origin && hoveredTitle.maxX < title.maxX, "the name keeps its place and gives way to the pin")
    cell.hovered = false
    cell.configure(working, nested: true, shortcut: "⌘1")
    let hint = try #require(label("⌘1"))
    let hinted = try #require(label(working.title)).frame
    #expect(hinted.minX == title.minX && hinted.minY == title.minY, "the name does not move")
    #expect(hint.frame.minX > hinted.maxX && abs(hint.frame.maxX - cell.bounds.width) <= 0.5, "the hint ends where the slot does, clear of the name")
    #expect(!hint.drawsBackground && hint.layer?.backgroundColor == nil)
    cell.hovered = true
    #expect(pin.isHidden && !dot.isHidden, "the hint keeps the slot under the pointer")
    cell.hovered = false
}

/// A session running an agent offers Fork Session, which names the session and asks nothing.
@MainActor @Test func onlyAnAgentsSessionOffersForkSession() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let projects = [Project(id: "p1", name: "First", repo: "o/f", color: nil, workspace: "/tmp")]
    var child = workspaceSession("agent (2)", created: "2026-03"); child.forkedFrom = "agent"
    let sessions = [workspaceSession("agent", created: "2026-01"), workspaceSession("shell", created: "2026-02"), child]
    // A fork is marked after its name; the rest are not.
    let marked = SidebarEntry.make(projects: projects, sessions: sessions).flatMap(\.descendants).filter(\.forked).map(\.id)
    #expect(marked == ["session:agent (2)"])
    var forked: [String] = []
    var value = CocoaSidebar(entries: SidebarEntry.make(projects: projects, sessions: sessions),
                             selection: .overview, pinnedIDs: [], onSelect: { _ in }, onTogglePin: { _ in })
    value.forkableIDs = ["agent"]
    value.onForkSession = { forked.append($0) }
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(value)
    func node(_ id: String) throws -> CocoaSidebar.Node {
        try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id })
    }
    let titles = coordinator.menu(for: try node("session:agent"))?.items.map(\.title) ?? []
    #expect(Array(titles.suffix(5)) == ["Rename Session…", "Pin Session", "Remove Session…", "", "Fork Session"], "\(titles)")
    let fork = try #require(coordinator.menu(for: try node("session:agent"))?.items.first { $0.title == "Fork Session" })
    #expect(coordinator.menu(for: try node("session:shell"))?.items.contains { $0.title == "Fork Session" } == false)
    _ = (fork.target as? NSObject)?.perform(try #require(fork.action), with: fork)
    #expect(forked == ["agent"])
}

/// A stopped session offers Reattach Session, first among its session items; a live or busy one does not.
@MainActor @Test func onlyAStoppedSessionOffersReattachSession() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let projects = [Project(id: "p1", name: "First", repo: "o/f", color: nil, workspace: "/tmp")]
    let sessions = [workspaceSession("stopped", created: "2026-01"), workspaceSession("live", created: "2026-02"),
                    workspaceSession("busy", created: "2026-03")]
    let entries = SidebarEntry.make(projects: projects, sessions: sessions,
                                    status: ["live": SidebarSessionStatus(live: true), "busy": SidebarSessionStatus(busy: true)])
    var reattached: [String] = []
    var value = CocoaSidebar(entries: entries, selection: .overview, pinnedIDs: [], onSelect: { _ in }, onTogglePin: { _ in })
    value.onReattachSession = { reattached.append($0) }
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(value)
    func node(_ id: String) throws -> CocoaSidebar.Node {
        try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id })
    }
    let titles = coordinator.menu(for: try node("session:stopped"))?.items.map(\.title) ?? []
    #expect(Array(titles.suffix(4)) == ["Reattach Session", "Rename Session…", "Pin Session", "Remove Session…"], "\(titles)")
    #expect(coordinator.menu(for: try node("session:live"))?.items.contains { $0.title == "Reattach Session" } == false)
    #expect(coordinator.menu(for: try node("session:busy"))?.items.contains { $0.title == "Reattach Session" } == false)
    let reattach = try #require(coordinator.menu(for: try node("session:stopped"))?.items.first { $0.title == "Reattach Session" })
    _ = (reattach.target as? NSObject)?.perform(try #require(reattach.action), with: reattach)
    #expect(reattached == ["stopped"])
}

/// A click that leaves a session selected hands it the keyboard; a click on a project does not.
@MainActor @Test func clickingASessionRowFocusesItsSession() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let projects = [Project(id: "p1", name: "First", repo: "o/f", color: nil, workspace: "/tmp")]
    let sessions = [workspaceSession("agent", created: "2026-01")]
    var focused: [String] = []
    var value = CocoaSidebar(entries: SidebarEntry.make(projects: projects, sessions: sessions),
                             selection: .overview, pinnedIDs: [], onSelect: { _ in }, onTogglePin: { _ in })
    value.onFocusSession = { focused.append($0) }
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(value)
    func node(_ id: String) throws -> CocoaSidebar.Node {
        try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id })
    }
    coordinator.clicked(try node("project:p1"))
    coordinator.clicked(try node("session:agent"))
    #expect(focused == ["agent"])
}

/// Only a plain single click that left its row selected hands the session the keyboard.
@MainActor @Test func onlyAPlainClickOnTheSelectedRowChoosesIt() {
    func chooses(row: Int = 3, selected: Int = 3, clicks: Int = 1, flags: NSEvent.ModifierFlags = [], travel: CGFloat = 0) -> Bool {
        SidebarOutlineView.chooses(row: row, selectedRow: selected, clickCount: clicks, flags: flags, travel: travel)
    }
    #expect(chooses())
    #expect(chooses(travel: 3.9))
    #expect(!chooses(travel: 4), "a drag is a reorder")
    #expect(!chooses(flags: .control), "a control-click opens the menu")
    #expect(!chooses(clicks: 2), "a double-click's second press")
    #expect(!chooses(selected: 5), "a Command-click that deselected, or a refused selection")
    #expect(!chooses(row: -1, selected: -1), "a click below the rows")
}

/// A session's dot: waiting on a person outranks working, working outranks a finished turn, and
/// only working blinks — once the dot is in a window and shown, again after it leaves and comes
/// back, and never while Reduce Motion is on.
@MainActor @Test func aSessionDotShowsTheAgentsState() {
    let dot = SidebarStatusDot()
    dot.reducesMotion = { false }
    let blinking = { dot.isBlinking }
    dot.set(SidebarSessionStatus(live: true, cli: "claude"))
    #expect(dot.state == .idle)
    #expect(dot.color == SidebarPalette.idle, "an idle session keeps a grey dot")
    #expect(dot.layer?.sublayers?.contains { !$0.isHidden && $0.backgroundColor != nil } == true, "drawn, not hidden")
    dot.set(SidebarSessionStatus(live: true, busy: true, cli: "unknown-cli"))
    #expect(dot.color != SidebarPalette.idle, "an agent with no colour of its own still differs from idle")
    dot.set(SidebarSessionStatus(live: true, done: true, cli: "claude"))
    #expect(dot.state == .done)
    dot.set(SidebarSessionStatus(live: true, busy: true, done: true, cli: "codex"))
    #expect(dot.state == .working(cli: "codex"))
    #expect(!blinking(), "out of a window")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [], backing: .buffered, defer: true)
    window.contentView?.addSubview(dot)
    #expect(blinking(), "working, in a window")
    dot.removeFromSuperview()
    window.contentView?.addSubview(dot)
    #expect(blinking(), "back in a window")
    dot.isHidden = true
    #expect(!blinking(), "hidden behind the hover pin")
    dot.isHidden = false
    #expect(blinking(), "shown again")
    var reduced = true
    dot.reducesMotion = { reduced }
    #expect(!blinking(), "Reduce Motion on")
    reduced = false
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    #expect(blinking(), "Reduce Motion turned off while working")
    dot.set(SidebarSessionStatus(live: true, busy: true, needsInput: true, cli: "claude"))
    #expect(dot.state == .needsInput && dot.statusLabel == "Needs input")
    #expect(!blinking(), "waiting is steady")
}

/// The icon picker's categories come from the system's tables in their own order, All first with
/// no list of its own, each category's symbols in the system's symbol order; with no tables there
/// are none.
@Test func symbolCategoriesReadTheSystemTables() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-glyphs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func write(_ value: Any, _ name: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent(name))
    }
    #expect(SymbolCategories(resources: folder).categories.isEmpty)
    try write([["key": "all", "icon": "square.grid.2x2"], ["key": "objectsandtools", "icon": "folder"],
               ["key": "empty", "icon": "xmark"], ["key": "arrows", "icon": "arrow.forward"]], "categories.plist")
    try write(["hammer": ["objectsandtools"], "folder": ["objectsandtools"], "arrow.up": ["arrows"]], "symbol_categories.plist")
    try write(["folder", "hammer", "arrow.up"], "symbol_order.plist")
    let read = SymbolCategories(resources: folder).categories
    #expect(read.map(\.id) == ["all", "objectsandtools", "arrows"])
    #expect(read[0].symbols == nil)
    #expect(read[1].symbols == ["folder", "hammer"])
    #expect(read[1].title == "Objects & Tools")
}

/// Every row's icon covers about the same area, however its glyph is shaped, but none is wider than
/// the cap: the folder, a quarter wider than the grid at one point size, is drawn smaller rather than
/// reading bigger, and the Pull Requests list, flat, does not stretch past the others to make up its area.
@MainActor @Test func rowSymbolsCoverTheSameArea() throws {
    func glyph(_ name: String) throws -> CGSize {
        let image = try #require(SidebarIcons.rowSymbol(name))
        return try #require(SidebarIcons.glyphSize(image))
    }
    let target = SidebarMetrics.glyphSide * SidebarMetrics.glyphSide
    for name in ["automation", "hammer", "newSession"] {
        let covered = try glyph(name)
        #expect(abs(covered.width * covered.height - target) / target < 0.12, "\(name) covers \(covered), not about \(target)pt²")
    }
    for name in ["pullRequests", "folder", "automation", "hammer", "newSession"] {
        let width = try glyph(name).width
        #expect(width <= SidebarMetrics.glyphMaxWidth, "\(name) is \(width)pt wide")
    }
    #expect(try glyph("pullRequests").width > SidebarMetrics.glyphMaxWidth - 1, "the list is held at the cap, not shrunk past it")
    let wide = try #require(SidebarIcons.symbol("folder")?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.symbolSize, weight: .regular)))
    let folder = try #require(SidebarIcons.rowSymbol("folder"))
    #expect(folder.size.width < wide.size.width, "the folder is drawn smaller than the rows' point size")
}
