import AppKit
import SwiftUI

// AppKit owns row reuse, keyboard navigation, selection, and menus. SwiftUI only supplies
// snapshots and receives semantic selection/actions. The look is the system's: a source list
// over the sidebar material, with its selection, its section headers and its label colours.
// What is ours sits inside that: no disclosure triangles (a click on the already-selected
// folder collapses it), sessions nested under their project, hover-only pin / "+" / close
// accessories, and the session status dot.
struct CocoaSidebar: NSViewRepresentable {
    let entries: [SidebarEntry]
    let selection: SidebarDestination
    let pinnedIDs: Set<String>
    /// The sessions whose menu offers Fork Session.
    var forkableIDs: Set<String> = []
    /// Shown in each session's status slot, at its trailing edge, while ⌘ alone is held, then gone once it is let go.
    var sessionShortcuts: [String: String] = [:]
    let onSelect: (SidebarDestination) -> Void
    let onTogglePin: (String) -> Void
    var onNewProject: () -> Void = {}
    var onMoveProject: (String, String?) -> Void = { _, _ in }
    var onMoveSession: (String, String?) -> Void = { _, _ in }
    var onMovePinned: (String, String?) -> Void = { _, _ in }
    var onRemoveSession: (String) -> Void = { _ in }
    var onRenameSession: (String, String) -> Void = { _, _ in }
    var onForkSession: (String) -> Void = { _ in }
    var onReattachSession: (String) -> Void = { _ in }
    /// A session clicked in the sidebar hands the keyboard to its agent; the arrow keys leave it here.
    var onFocusSession: (String) -> Void = { _ in }
    var gitClientLabel: String?
    var onOpenGitClient: (String) -> Void = { _ in }
    static let dragType = NSPasteboard.PasteboardType("com.cascade.sidebar-row")

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.identifier = .init("workspace-sidebar")
        outline.setAccessibilityIdentifier("workspace-sidebar")
        outline.setAccessibilityLabel(String(localized: "Workspace sidebar"))
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.floatsGroupRows = false
        // Nesting is laid out by the cell, so a session's name lines up under its project's.
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        // Typing a letter here must not jump to the row it starts: "a" landed on Automation.
        outline.allowsTypeSelect = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap
        outline.contextMenu = { [weak coordinator = context.coordinator] item in coordinator?.menu(for: item) }
        outline.onReselect = { [weak coordinator = context.coordinator] item in coordinator?.reselected(item) }
        outline.onClick = { [weak coordinator = context.coordinator] item in coordinator?.clicked(item) }
        outline.canDrag = { [weak coordinator = context.coordinator] item in coordinator?.canDrag(item) ?? false }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopShortcutHints()
    }

    @MainActor final class Node: NSObject {
        var entry: SidebarEntry
        var children: [Node] = []
        init(_ entry: SidebarEntry) { self.entry = entry }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: CocoaSidebar
        weak var outline: NSOutlineView?
        private var roots: [Node] = []
        private var nodes: [String: Node] = [:]
        /// Each nested row's folder, so a drag — which asks on every mouse move — never searches for it.
        private var homes: [ObjectIdentifier: Node] = [:]
        private var snapshot: [SidebarEntry] = []
        private var updating = false
        private var selectedPlacement: String?
        private var collapsed: Set<String>
        private let preferences: UserDefaults
        private var flagsMonitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var holdingCommand = false { didSet { if oldValue != holdingCommand { refreshVisibleCells() } } }

        init(parent: CocoaSidebar, preferences: UserDefaults = .standard) {
            self.parent = parent
            self.preferences = preferences
            collapsed = Set(preferences.stringArray(forKey: "sidebar.collapsed") ?? [])
            super.init()
            // ⌘ alone, in this sidebar's window. Any other modifier with it is a different shortcut,
            // and a window that loses the keyboard never hears ⌘ let go.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.outline?.window else { return }
                    self.holdingCommand = event.window === window
                        && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
                }
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                let resigned = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window = self.outline?.window, resigned == ObjectIdentifier(window) else { return }
                    self.holdingCommand = false
                }
            }
        }

        func stopShortcutHints() {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
        }

        func update(_ value: CocoaSidebar) {
            let changedSelection = parent.selection != value.selection
            parent = value
            guard let outline else { return }
            updating = true
            defer { updating = false }
            if snapshot != value.entries {
                if Self.shape(snapshot) == Self.shape(value.entries) {
                    // Same rows, new state (a busy edge, a title, a pin): update in place, so the
                    // hover state survives and nothing reloads under the pointer.
                    func apply(_ entry: SidebarEntry) {
                        if let node = nodes[entry.id], node.entry != entry {
                            node.entry = entry
                            let row = outline.row(forItem: node)
                            if row >= 0 { configureCell(atRow: row, node: node) }
                        }
                        entry.children.forEach(apply)
                    }
                    value.entries.forEach(apply)
                    snapshot = value.entries
                } else {
                    let scrollPosition = outline.enclosingScrollView?.contentView.bounds.origin
                    var retained: [String: Node] = [:]
                    func reconcile(_ entry: SidebarEntry) -> Node {
                        let node = nodes[entry.id] ?? Node(entry)
                        node.entry = entry
                        node.children = entry.children.map(reconcile)
                        retained[entry.id] = node
                        return node
                    }
                    roots = value.entries.map(reconcile)
                    nodes = retained
                    homes = Dictionary(roots.flatMap { folder in folder.children.map { (ObjectIdentifier($0), folder) } },
                                       uniquingKeysWith: { first, _ in first })
                    snapshot = value.entries
                    outline.reloadData()
                    for node in roots where !node.children.isEmpty && !collapsed.contains(node.entry.id) {
                        outline.expandItem(node)
                    }
                    if let scrollPosition { outline.enclosingScrollView?.contentView.scroll(to: scrollPosition) }
                }
            }
            let placed = selectedPlacement.flatMap { nodes[$0] }
            let selected = placed?.entry.destination == value.selection ? placed
                : roots.flatMap(flatten).first { $0.entry.destination == value.selection }
            guard let selected else { outline.deselectAll(nil); return }
            let changedPlacement = selectedPlacement != selected.entry.id
            selectedPlacement = selected.entry.id
            if changedSelection || changedPlacement {
                // A newly unpinned child may not be known to the outline while its
                // folder is collapsed. Use the snapshot's parent map to reveal it.
                if let folder = homes[ObjectIdentifier(selected)] { outline.expandItem(folder) }
            }
            let row = outline.row(forItem: selected)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if changedSelection || changedPlacement { outline.scrollRowToVisible(row) }
            } else { outline.deselectAll(nil) }
        }

        private struct Shape: Equatable { let id: String; let children: [Shape] }
        private static func shape(_ entries: [SidebarEntry]) -> [Shape] {
            entries.map { Shape(id: $0.id, children: shape($0.children)) }
        }

        private func flatten(_ node: Node) -> [Node] { [node] + node.children.flatMap(flatten) }
        private func children(_ item: Any?) -> [Node] { (item as? Node)?.children ?? roots }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(item)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.children.isEmpty == false }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.entry.destination != nil }
        /// Headings are the source list's own section headers, so they take its typography.
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.entry.isHeading == true }

        // Drag to reorder, always among siblings: a project within Projects, a session within its
        // own project, a pinned session within Pinned. The pasteboard carries the row's placement id.
        private enum Drag: Equatable { case project, session, pinned }
        private func drag(for node: Node) -> Drag? {
            switch node.entry.destination {
            case .project: return .project
            case .session(let id):
                // A pinned session moves within Pinned, a project's row within its project; an orphan stays put.
                if node.entry.id == "pin:\(id)" { return .pinned }
                return home(of: node) != nil ? .session : nil
            default: return nil
            }
        }
        private func home(of node: Node) -> Node? { homes[ObjectIdentifier(node)] }
        func canDrag(_ node: Node) -> Bool { drag(for: node) != nil }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node, canDrag(node) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(node.entry.id, forType: CocoaSidebar.dragType)
            return pasteboardItem
        }
        /// Where a drop would put `dragged`: a gap among its own siblings.
        private struct Drop {
            let dragged: Node, parent: Node?, from: Int, gap: Int
            /// The sibling the row lands before; nil for the end of its list.
            let before: Node?
            /// The row's index once it has left `from`.
            var to: Int { gap > from ? gap - 1 : gap }
        }
        /// Nil when the pointer is outside the row's own list, or the drop would not move it.
        private func drop(_ info: NSDraggingInfo, item: Any?, index: Int) -> Drop? {
            guard let placement = info.draggingPasteboard.string(forType: CocoaSidebar.dragType),
                  let dragged = nodes[placement], let kind = drag(for: dragged) else { return nil }
            let target = item as? Node
            let parent = kind == .session ? home(of: dragged) : nil
            let siblings = parent?.children ?? roots
            guard let from = siblings.firstIndex(of: dragged) else { return nil }
            // The rows that may trade places: contiguous, since each kind has its own section.
            guard let first = siblings.firstIndex(where: { drag(for: $0) == kind }),
                  let last = siblings.lastIndex(where: { drag(for: $0) == kind }) else { return nil }
            // The table mostly proposes a drop ON a row — a folder's whole height is one target, and
            // the slivers between rows are hard to hit. So a row dropped on another takes its
            // place: before it when dragging up, after it when dragging down. Landing before it
            // either way would make the most common drag, one step down, a drop onto itself.
            let gap: Int
            if kind == .session {
                // The folder's own row sits above its sessions, so a drop on it is the top of the list.
                if target === parent { gap = index < 0 ? first : index }
                else if let target, let position = siblings.firstIndex(of: target) { gap = position < from ? position : position + 1 }
                else { return nil }
            } else if let target {
                // On a row, or anywhere among a project's sessions, counts as that root row.
                guard let top = roots.firstIndex(where: { $0 === target || $0.children.contains(target) }) else { return nil }
                gap = top < from ? top : top + 1
            } else if index < 0 {
                return nil
            } else { gap = index }
            guard gap >= first, gap <= last + 1, gap != from, gap != from + 1 else { return nil }
            return Drop(dragged: dragged, parent: parent, from: from, gap: gap, before: gap <= last ? siblings[gap] : nil)
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let drop = drop(info, item: item, index: index) else { return [] }
            // Retarget to the gap so the feedback shows where the row will land.
            outlineView.setDropItem(drop.parent, dropChildIndex: drop.gap)
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            func id(_ node: Node?) -> String? {
                switch node?.entry.destination {
                case .project(let id), .session(let id): id
                default: nil
                }
            }
            // Everything that can refuse the drop is settled before a row moves.
            guard let drop = drop(info, item: item, index: index), let kind = drag(for: drop.dragged),
                  let moving = id(drop.dragged) else { return false }
            // Move the row here and now. The gap style hides the dragged row until the table is
            // told where it went, and the model's answer arrives later — as the same shape, so
            // it updates in place instead of reloading under the pointer.
            updating = true
            defer { updating = false }
            func move<Row>(_ rows: inout [Row]) { rows.insert(rows.remove(at: drop.from), at: drop.to) }
            if let folder = drop.parent {
                move(&folder.children)
                move(&folder.entry.children)
                if let index = snapshot.firstIndex(where: { $0.id == folder.entry.id }) { move(&snapshot[index].children) }
            } else {
                move(&roots)
                move(&snapshot)
            }
            outlineView.beginUpdates()
            outlineView.moveItem(at: drop.from, inParent: drop.parent, to: drop.to, inParent: drop.parent)
            outlineView.endUpdates()
            switch kind {
            case .project: parent.onMoveProject(moving, id(drop.before))
            case .session: parent.onMoveSession(moving, id(drop.before))
            case .pinned: parent.onMovePinned(moving, id(drop.before))
            }
            return true
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let entry = (item as? Node)?.entry else { return SidebarMetrics.rowHeight }
            return entry.isHeading ? SidebarMetrics.labelHeight : SidebarMetrics.rowHeight
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = SidebarRowView()
            row.hoverable = (item as? Node).map { $0.entry.hoverable } ?? false
            return row
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            // Headings never share a cell with rows: each kind sets its own font and colour, and a
            // cell reused from the other kind would start from the wrong one.
            let identifier = NSUserInterfaceItemIdentifier(node.entry.isHeading ? "sidebar-heading" : "sidebar-cell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView ?? {
                let cell = SidebarCellView()
                cell.identifier = identifier
                return cell
            }()
            configure(cell, node: node, row: outlineView.row(forItem: node))
            return cell
        }

        /// Reconfigures the row's cell.
        private func configureCell(atRow row: Int, node: Node) {
            guard let outline, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { return }
            configure(cell, node: node, row: row)
        }

        private func configure(_ cell: SidebarCellView, node: Node, row: Int) {
            guard let outline else { return }
            let nested = outline.parent(forItem: node) != nil
            cell.onTogglePin = { [weak self] id in self?.parent.onTogglePin(id) }
            cell.onNewProject = { [weak self] in self?.parent.onNewProject() }
            cell.configure(node.entry, nested: nested,
                           shortcut: holdingCommand ? node.entry.sessionID.flatMap { parent.sessionShortcuts[$0] } : nil)
            if row >= 0, let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView {
                rowView.hoverable = node.entry.hoverable
                cell.hovered = rowView.hovered
            }
        }

        private func refreshVisibleCells() {
            guard let outline else { return }
            outline.enumerateAvailableRowViews { _, row in
                guard let node = outline.item(atRow: row) as? Node else { return }
                configureCell(atRow: row, node: node)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, let node = outline.item(atRow: outline.selectedRow) as? Node,
                  let destination = node.entry.destination else { return }
            selectedPlacement = node.entry.id
            parent.onSelect(destination)
        }

        /// After the selection it made has been shown, so the keyboard goes to the session on screen.
        func clicked(_ node: Node) {
            if let id = node.entry.sessionID { parent.onFocusSession(id) }
        }

        // A click on the folder that is already in view collapses / expands its sessions — the
        // web sidebar's projectClick; there is no disclosure caret.
        func reselected(_ node: Node) {
            guard let outline, node.entry.projectID != nil, !node.children.isEmpty else { return }
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) }
            else { outline.animator().expandItem(node) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, collapsed: true) }
        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, collapsed: false) }
        private func expansionChanged(_ notification: Notification, collapsed isCollapsed: Bool) {
            guard let outline, let node = notification.userInfo?["NSObject"] as? Node else { return }
            let row = outline.row(forItem: node)
            if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView {
                configure(cell, node: node, row: row)
            }
            guard !updating else { return }
            if isCollapsed { collapsed.insert(node.entry.id) } else { collapsed.remove(node.entry.id) }
            preferences.set(Array(collapsed).sorted(), forKey: "sidebar.collapsed")
        }

        func menu(for node: Node) -> NSMenu? {
            guard let destination = node.entry.destination else { return nil }
            let menu = NSMenu()
            func add(_ title: String, action: Selector) {
                let item = NSMenuItem(title: Bundle.main.localizedString(forKey: title, value: title, table: nil), action: action, keyEquivalent: "")
                item.target = self; item.representedObject = node
                menu.addItem(item)
            }
            if node.entry.detail.hasPrefix("/") {
                if case .session = destination, let title = parent.gitClientLabel {
                    add(title, action: #selector(openGitClient(_:)))
                }
                add("Reveal in Finder", action: #selector(reveal(_:)))
            }
            // The session and its worktree go together (one unit); the sheet spells out what is
            // stopped and removed, so the menu item only asks for it.
            if case .session(let id) = destination {
                menu.addItem(.separator())
                // Only on a stopped row, the grey one: its terminal is what there is to bring back.
                if case .session(let status, _) = node.entry.role, !status.live, !status.busy {
                    add("Reattach Session", action: #selector(reattachSession(_:)))
                }
                add("Rename Session…", action: #selector(renameSession(_:)))
                add(parent.pinnedIDs.contains(id) ? "Unpin Session" : "Pin Session", action: #selector(togglePin(_:)))
                add("Remove Session…", action: #selector(removeSession(_:)))
                if parent.forkableIDs.contains(id) {
                    menu.addItem(.separator())
                    add("Fork Session", action: #selector(forkSession(_:)))
                }
            }
            return menu.items.isEmpty ? nil : menu
        }

        @objc private func togglePin(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onTogglePin(id)
        }
        /// The system's own text prompt, as a sheet on the sidebar's window. An empty name puts
        /// the worktree folder back; whether anything changed is the app's to decide.
        @objc private func renameSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            let alert = NSAlert()
            alert.window.setAccessibilityIdentifier("rename-session-dialog")
            alert.messageText = String(localized: "Rename Session")
            alert.informativeText = String(localized: "Leave it empty to show the worktree folder's name.")
            alert.addButton(withTitle: String(localized: "Rename"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let field = NSTextField(string: node.entry.title)
            field.placeholderString = String(localized: "Session name")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            field.setAccessibilityIdentifier("rename-session-input")
            field.setAccessibilityLabel(String(localized: "Session name"))
            alert.accessoryView = field
            let rename = { [weak self] (response: NSApplication.ModalResponse) in
                guard response == .alertFirstButtonReturn else { return }
                self?.parent.onRenameSession(id, field.stringValue)
            }
            // NSAlert focuses its default button on show, so the field is focused after it.
            if let window = outline?.window {
                alert.beginSheetModal(for: window, completionHandler: rename)
                alert.window.makeFirstResponder(field)
            } else {
                alert.window.initialFirstResponder = field
                rename(alert.runModal())
            }
        }
        /// No prompt: the fork is named after this session with the next number, and opens at once.
        @objc private func forkSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onForkSession(id)
        }
        @objc private func reattachSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onReattachSession(id)
        }
        @objc private func removeSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onRemoveSession(id)
        }
        @objc private func openGitClient(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onOpenGitClient(id)
        }
        @objc private func reveal(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.entry.detail)])
        }
    }
}

// MARK: - Look

/// css/tokens.css, as dynamic colours: the dark theme is the same palette swap.
enum SidebarPalette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: alpha)
        }
    }
    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    static let navText = dynamic(0x3b3d3f, 0xc9cbce)   // --nav-text
    static let text = dynamic(0x16181d, 0xe8e8e8)      // --text
    static let text2 = dynamic(0x565d68, 0xa2a2a2)     // --text-2
    static let text3 = dynamic(0x9298a3, 0x6e6e6e)     // --text-3
    /// A hover "+" at rest; the section headings and project folders share it.
    static let accessory = text3.withAlphaComponent(0.8)
    /// A row's symbol: in light mode the idle status dot's grey (`text3`), rgb(146, 152, 163); in dark
    /// rgb(180, 184, 191). No one system colour is both: secondary label resolves well dimmer than Finder in dark.
    static let icon = dynamic(0x9298a3, 0xb4b8bf)
    /// An idle session's dot. A solid dot reads darker than a line icon of the same colour, whose thin
    /// strokes blend into the sidebar, so in light mode it is a step lighter than `icon`, to look the folder's grey.
    static let idle = dynamic(0xb3b7bf, 0x6e6e6e)
    static let success = dynamic(0x16a34a, 0x4ade80)
    static let warn = dynamic(0xd97706, 0xfbbf24)
    /// A session waiting on a person: yellow, well clear of Claude's terracotta beside it.
    static let waiting = dynamic(0xeab308, 0xfacc15)
    static let danger = dynamic(0xdc2626, 0xf87171)
}

/// A medium source list's own measures, and the few the cell adds inside it.
enum SidebarMetrics {
    static let rowHeight: CGFloat = 32       // what `.medium` rows measure
    static let labelHeight: CGFloat = 23     // a section header, at `headingFont`; the list adds the air above it
    // A point above the rows, and on the system font's weight axis between light (300) and
    // regular (400), in the "+"'s grey. A `weight:` between two named weights snaps to one of them.
    nonisolated(unsafe) static let headingFont: NSFont = {
        let size = NSFont.systemFontSize + 1
        let weight = NSFont.systemFont(ofSize: size).fontDescriptor.addingAttributes([.variation: [0x7767_6874 /* 'wght' */: 350]])
        return NSFont(descriptor: weight, size: size) ?? .systemFont(ofSize: size, weight: .regular)
    }()
    /// A session's name: the rows' size, light (300) on the weight axis, so the many sessions under a
    /// project read lighter than the project itself.
    nonisolated(unsafe) static let sessionFont = rowFont(weight: 300)
    private static func rowFont(weight: Int) -> NSFont {
        let size = NSFont.systemFontSize
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.addingAttributes([.variation: [0x7767_6874 /* 'wght' */: weight]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: .light)
    }
    static let iconSlot: CGFloat = 24        // a row's leading icon
    static let symbolSize: CGFloat = 17      // a row symbol's point size: a glyph a little under what the list drew at 14
    static let glyphSide: CGFloat = 15.5     // a row glyph covers this square's area: the Dashboard grid's glyph at `symbolSize`
    static let brandSize: CGFloat = 20       // favicons, brand art and avatars, centred in the slot
    static let leading: CGFloat = 2          // cell edge to the icon slot
    static let gap: CGFloat = 6              // title to accessory
    static let iconGap: CGFloat = 3          // icon slot to title: the glyph sits inside its slot, so less reads as close
    static let trailing: CGFloat = 4         // accessory to the cell edge
    static let radius: CGFloat = 8
}

// MARK: - Views

/// A session's status, a small solid dot leading the row, always there: grey while nothing
/// is happening, in the agent's own colour while it works (Claude's orange, Codex's purple), yellow
/// while it waits on a person, green when a turn finished that nobody has looked at. Working, the dot
/// blinks softly, dimming and coming back; it never changes size, and it holds steady when the
/// system asks for reduced motion. Every other state is steady.
@MainActor final class SidebarStatusDot: NSView {
    enum State: Equatable {
        case idle, done, needsInput
        case working(cli: String?)
    }
    static let size: CGFloat = 8
    private let dot = CALayer()
    private(set) var state = State.idle
    /// The system's Reduce Motion setting; a test answers it for itself.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } {
        didSet { animate() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.cornerRadius = Self.size / 2
        layer?.addSublayer(dot)
        // Reduce Motion turned on or off while a session works takes effect at once.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ status: SidebarSessionStatus) {
        let next: State = status.needsInput ? .needsInput : status.busy ? .working(cli: status.cli)
            : status.done ? .done : .idle
        guard next != state || dot.backgroundColor == nil else { return }
        state = next
        paint()
        animate()
    }

    private static let blinkKey = "blink"
    /// Whether the working blink is running.
    var isBlinking: Bool { dot.animation(forKey: Self.blinkKey) != nil }

    /// Starts or stops the working blink: only while the dot is in a window and shown, and Reduce
    /// Motion is off. A layer's animation does not survive the view leaving its
    /// window, so it is started again on the way back in.
    private func animate() {
        guard case .working = state, window != nil, !isHiddenOrHasHiddenAncestor, !reducesMotion() else {
            dot.removeAnimation(forKey: Self.blinkKey)
            return
        }
        guard !isBlinking else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.6
        blink.duration = 1.2
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(blink, forKey: Self.blinkKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    override func viewDidHide() {
        super.viewDidHide()
        animate()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        animate()
    }

    @objc private func displayOptionsChanged() { animate() }

    /// The state in words. The dot is not an accessibility element; its row reads this after its title.
    var statusLabel: String {
        switch state {
        case .idle: String(localized: "Idle")
        case .done: String(localized: "Done")
        case .needsInput: String(localized: "Needs input")
        case .working: String(localized: "Working")
        }
    }

    var color: NSColor {
        switch state {
        case .idle: SidebarPalette.idle
        case .done: SidebarPalette.success
        case .needsInput: SidebarPalette.waiting
        // An agent with no driver has no colour of its own: a darker grey than idle's, so it still
        // reads as working when Reduce Motion holds the blink.
        case .working(let cli): AgentDrivers.of(cli)?.sidebarTint ?? SidebarPalette.text2
        }
    }

    /// A layer takes a resolved colour, so it is resolved again when the appearance changes.
    private func paint() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let box = NSRect(x: ((bounds.width - Self.size) / 2 * 2).rounded() / 2, y: ((bounds.height - Self.size) / 2 * 2).rounded() / 2,
                         width: Self.size, height: Self.size)
        dot.frame = box
        CATransaction.commit()
    }
}

/// The system draws the selection. The row only tracks the pointer, for the cell's hover accessory.
@MainActor final class SidebarRowView: NSTableRowView {
    /// Rows that react to the pointer: anything selectable, and headings with a hover accessory.
    var hoverable = true
    private(set) var hovered = false {
        didSet {
            guard oldValue != hovered else { return }
            (numberOfColumns > 0 ? view(atColumn: 0) as? SidebarCellView : nil)?.hovered = hovered
        }
    }
    private var tracking: NSTrackingArea?

    /// A sidebar selection says where the detail pane is, not where the keyboard is: it stays the
    /// quiet grey plate whether or not the list has focus, as in Finder's sidebar.
    override var isEmphasized: Bool { get { false } set {} }
    /// A selected row's icons take its title's colour.
    override var isSelected: Bool {
        didSet { (numberOfColumns > 0 ? view(atColumn: 0) as? SidebarCellView : nil)?.selected = isSelected }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = hoverable }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func prepareForReuse() { super.prepareForReuse(); hovered = false }
}

@MainActor final class SidebarCellView: NSTableCellView {
    var onTogglePin: (String) -> Void = { _ in }
    var onNewProject: () -> Void = {}
    var hovered = false { didSet { if oldValue != hovered { applyState() } } }
    /// Told by its row, and read off a row it is put into.
    var selected = false { didSet { if oldValue != selected { applyState() } } }

    /// The row's leading icon. Not the cell's `imageView`: the source list restyles that one, at its own
    /// point size and in its own grey whatever its tint, so the icon would match neither the cell's size nor its title.
    let icon = NSImageView()
    private let dot = SidebarStatusDot()
    /// The ⌘-held hint, in the status dot's trailing slot.
    private let shortcut = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    /// After a forked session's name.
    private let forkMark = NSImageView()
    private let accessory = SidebarAccessoryButton()
    private var entry = SidebarEntry(id: "", title: "", symbol: "")
    private var nested = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.maximumNumberOfLines = 1
        shortcut.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        // Down only: a symbol is already the size its font makes it, and must not be stretched to the slot.
        icon.imageScaling = .scaleProportionallyDown
        icon.wantsLayer = true
        accessory.target = self
        accessory.action = #selector(accessoryPressed)
        forkMark.image = SidebarIcons.mark("fork", size: Self.forkMarkSize)
        forkMark.setAccessibilityLabel(String(localized: "Forked session"))
        [icon, dot, title, forkMark, accessory, shortcut].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Taken out of a row, it keeps what it was told until it is put into another.
        guard let row = superview as? NSTableRowView else { return }
        selected = row.isSelected
    }

    // The table builds a drag image from `imageView` and `textField`. This cell has neither,
    // so the default image would be empty — and the gap style hides the row
    // itself, so a dragged row would all but vanish until it was dropped. Drag a picture of the whole cell instead, minus the hover button.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard bounds.width > 0, bounds.height > 0, let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return super.draggingImageComponents
        }
        // A dragged row is under the pointer, where a session shows its pin: the picture leaves it out.
        let accessoryWasHidden = accessory.isHidden
        accessory.isHidden = true
        cacheDisplay(in: bounds, to: bitmap)
        accessory.isHidden = accessoryWasHidden
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = bounds
        return [component]
    }

    func configure(_ entry: SidebarEntry, nested: Bool, shortcut hint: String? = nil) {
        self.entry = entry
        shortcut.stringValue = hint ?? ""
        shortcut.isHidden = hint == nil
        self.nested = nested
        title.stringValue = entry.title
        // Every label is the cell's own to style. On macOS 27 the table turns a selected row's label
        // semibold, which makes the title jump as the selection moves, and would set a heading in its
        // small group font; a heading reads a point larger than the rows, a touch heavier.
        textField = nil
        title.font = if entry.isHeading { SidebarMetrics.headingFont }
            else if case .session = entry.role { SidebarMetrics.sessionFont }
            else { .systemFont(ofSize: NSFont.systemFontSize) }
        setAccessibilityLabel(entry.title)
        toolTip = entry.tooltip ?? (entry.detail.isEmpty ? entry.title : entry.detail)
        setAccessibilityIdentifier(entry.id)
        // The dot is shown or hidden once, in `applyState`: hiding it here and showing it again there
        // would restart a working dot's blink on every refresh.
        icon.isHidden = false; accessory.isHidden = true
        forkMark.isHidden = !entry.forked
        icon.layer?.cornerRadius = 0
        alphaValue = 1
        switch entry.role {
        case .label:
            icon.isHidden = true
        case .projectsHeader(let canCreate):
            icon.isHidden = true
            if canCreate {
                accessory.image = SidebarIcons.addSymbol
                accessory.toolTip = String(localized: "New Project")
                accessory.setAccessibilityLabel(String(localized: "New Project"))
            }
        case .nav:
            icon.image = SidebarIcons.rowSymbol(entry.symbol)
        case .project:
            // A project's sessions start from its page's composer, so its row has no "+".
            icon.image = SidebarIcons.rowSymbol(entry.symbol) ?? SidebarIcons.rowSymbol("folder")
        case .session(let status, let pinned):
            // A session has no icon: its status dot stands where one would be.
            icon.isHidden = true
            dot.set(status)
            setAccessibilityLabel("\(entry.title), \(dot.statusLabel)")
            alphaValue = status.live || status.busy ? 1 : 0.82
            accessory.image = SidebarIcons.pinSymbol(pinned ? "pinFilled" : "pin")
            accessory.toolTip = pinned ? String(localized: "Unpin session") : String(localized: "Pin session to the top")
            accessory.setAccessibilityLabel(accessory.toolTip)
        }
        applyState()
    }

    private static let forkMarkSize: CGFloat = 12
    /// The box a session's status dot is centred in, before its name: about as wide as a row symbol's glyph.
    static let statusSlot: CGFloat = 15

    private var stopped: Bool {
        if case .session(let status, _) = entry.role { return !status.live && !status.busy }
        return false
    }

    private func applyState() {
        // A heading is in the "+"'s resting grey. Any other title is a system label colour, which
        // follows the appearance and the selection by itself. Every icon in the row, a session's fork
        // included, is the sidebar's icon grey (`SidebarPalette.icon`), and its title's colour when the row is selected.
        title.textColor = entry.isHeading ? SidebarPalette.accessory : stopped ? .tertiaryLabelColor : .labelColor
        let iconColor = selected ? title.textColor : SidebarPalette.icon
        icon.contentTintColor = iconColor
        forkMark.contentTintColor = iconColor
        switch entry.role {
        case .projectsHeader(let canCreate): accessory.isHidden = !(hovered && canCreate); dot.isHidden = true
        // The pin shows in the trailing slot under the pointer, and the ⌘-held hint takes it. The status
        // dot leads the row, always shown.
        case .session:
            accessory.isHidden = !hovered || !shortcut.isHidden
            dot.isHidden = false
        default: accessory.isHidden = true; dot.isHidden = true
        }
        needsLayout = true
    }

    @objc private func accessoryPressed() {
        if case .projectsHeader = entry.role { onNewProject() }
        else if let id = entry.sessionID { onTogglePin(id) }
    }

    /// Where an item row's accessory slot ends, in this cell's coordinates: the trailing edge of
    /// any item cell on screen, less the same margin. Nil until one is on screen.
    private var itemTrailingEdge: CGFloat? {
        var ancestor = superview
        while let view = ancestor, !(view is NSOutlineView) { ancestor = view.superview }
        guard let outline = ancestor as? NSOutlineView else { return nil }
        let rows = outline.rows(in: outline.visibleRect)
        for row in rows.location..<(rows.location + rows.length) {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView,
                  cell !== self, !cell.entry.isHeading else { continue }
            let edge = cell.convert(NSPoint(x: cell.bounds.maxX, y: 0), to: self).x
            return edge - SidebarMetrics.trailing
        }
        return nil
    }

    override func layout() {
        super.layout()
        // The source list has already inset the cell from the sidebar's edge and its selection plate.
        let height = bounds.height
        let slot = SidebarMetrics.iconSlot
        let left = SidebarMetrics.leading
        let right = bounds.width - SidebarMetrics.trailing
        func centered(_ x: CGFloat, _ size: CGFloat) -> NSRect {
            NSRect(x: x, y: ((height - size) / 2).rounded(), width: size, height: size)
        }
        switch entry.role {
        case .label, .projectsHeader:
            title.sizeToFit()
            let titleHeight = title.frame.height
            // The heading's "+" sits in the same trailing slot as a session's pin, ending at the item
            // cell's own edge, centred on the title. Same slot on screen, not the same offset in the
            // cell: a source list frames a heading's cell differently from an item's, so the item's
            // edge is read off an item.
            let edge = itemTrailingEdge.map { $0 + SidebarMetrics.trailing } ?? bounds.width
            let titleY = ((height - titleHeight) / 2).rounded()
            accessory.frame = NSRect(x: edge - 18, y: (titleY + (titleHeight - 18) / 2).rounded(), width: 18, height: 18)
            let titleRight = accessory.isHidden ? right : edge - 18 - SidebarMetrics.gap
            title.frame = NSRect(x: 0, y: titleY, width: max(0, titleRight), height: titleHeight)
            return
        case .nav, .project, .session:
            break
        }
        let session = if case .session = entry.role { true } else { false }
        var titleX = left + slot + SidebarMetrics.iconGap
        var dotCenterX: CGFloat = 0
        if session {
            // The dot is centred in a box about a glyph wide, and the name is as far from that box as a
            // project's name is from its folder. Under its project the dot sits on the edge between the
            // folder's glyph and the project's name; at the top level (Pinned, or a project that is gone)
            // its box ends where a folder does.
            let folder = SidebarIcons.rowSymbol("folder")?.size.width ?? slot
            let folderRight = left + ((slot + folder) / 2 * 2).rounded() / 2
            let toName = titleX - folderRight
            let width = Self.statusSlot
            let x = nested ? (folderRight + titleX) / 2 - width / 2 : folderRight - width
            titleX = x + width + toName
            dotCenterX = x + width / 2
        } else {
            icon.frame = centered(left, slot)
        }
        let accessorySlot: CGFloat = 18
        // A session's pin sits nearer the edge than a heading's "+", as it is smaller: its slot ends at the cell's own edge, where the pin can still be clicked.
        let slotX = (session ? bounds.width : right) - accessorySlot
        accessory.frame = centered(slotX, accessorySlot)
        // A session's name runs to a gap before the pin's glyph whether or not the pin shows, so it never
        // shifts, not before the slot: the glyph is far narrower than the slot it is centred in.
        var titleRight = session ? slotX + (accessorySlot - SidebarIcons.pinSize) / 2 - SidebarMetrics.gap
            : accessory.isHidden ? right : slotX - SidebarMetrics.gap
        title.sizeToFit()
        let titleHeight = title.frame.height
        let titleY = ((height - titleHeight) / 2).rounded()
        if session {
            let font = title.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let baseline = titleY + font.ascender
            // On the letters' own middle, not the label's frame, whose descender space sets the dot
            // low: halfway between a lowercase letter's middle and a capital's, as a name is mostly
            // lowercase under a capital. Placed to the half point, which a whole-point round misses
            // by enough to see on a dot this small.
            let middle = baseline - (font.capHeight + font.xHeight) / 4
            let size = SidebarStatusDot.size
            dot.frame = NSRect(x: ((dotCenterX - size / 2) * 2).rounded() / 2, y: ((middle - size / 2) * 2).rounded() / 2,
                               width: size, height: size)
            // In the pin's place, ending where its slot does, on the name's baseline: the same place on
            // every row, nested or not.
            shortcut.sizeToFit()
            let hint = shortcut.frame.size
            let hintAscender = shortcut.font?.ascender ?? font.ascender
            shortcut.frame = NSRect(x: slotX + accessorySlot - hint.width, y: (baseline - hintAscender).rounded(),
                                    width: hint.width, height: hint.height)
            // The hint is wider than the pin: while it shows, a long name ends a gap before it.
            if !shortcut.isHidden { titleRight = min(titleRight, shortcut.frame.minX - SidebarMetrics.gap) }
        }
        var titleWidth = max(0, titleRight - titleX)
        // The mark follows the name, and a long name gives way to it rather than hide it.
        if !forkMark.isHidden {
            let size = Self.forkMarkSize, gap: CGFloat = 4
            // The text's own width, not whatever frame the label was last given.
            titleWidth = min(title.intrinsicContentSize.width.rounded(.up), max(0, titleWidth - size - gap))
            forkMark.frame = centered(titleX + titleWidth + gap, size)
        }
        title.frame = NSRect(x: titleX, y: titleY, width: titleWidth, height: titleHeight)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); needsLayout = true }
    override var isFlipped: Bool { true }
}

/// The hover pin / "+": invisible until the row is hovered (the cell hides it), a muted glyph
/// that darkens under the pointer — no plate of its own inside the row's highlight.
@MainActor final class SidebarAccessoryButton: NSButton {
    private var tracking: NSTrackingArea?
    private var pointed = false { didSet { contentTintColor = pointed ? SidebarPalette.text : SidebarPalette.icon } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        contentTintColor = SidebarPalette.icon
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointed = true }
    override func mouseExited(with event: NSEvent) { pointed = false }
    override var isHidden: Bool { didSet { if isHidden { pointed = false } } }
}

@MainActor final class SidebarOutlineView: NSOutlineView {
    var contextMenu: ((CocoaSidebar.Node) -> NSMenu?)?
    var onReselect: ((CocoaSidebar.Node) -> Void)?
    /// A click that left its row selected, as opposed to a drag or the arrow keys.
    var onClick: ((CocoaSidebar.Node) -> Void)?
    var canDrag: ((CocoaSidebar.Node) -> Bool)?

    // No disclosure triangles: a project folder collapses by clicking it again.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    // The gap style hides the pressed row as soon as the pointer moves 4pt, before it asks for a
    // pasteboard writer. For a row with none, no drag begins, so nothing ever shows the row again:
    // a click that wobbled on Automation left an empty slot. Refuse those rows up front.
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        rowIndexes.allSatisfy { (item(atRow: $0) as? CocoaSidebar.Node).map { canDrag?($0) == true } ?? false }
            && super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let pressed = row >= 0 ? item(atRow: row) as? CocoaSidebar.Node : nil
        let reselected = row == selectedRow ? pressed : nil
        super.mouseDown(with: event)
        // `super` returns once the mouse is up, which may be the end of a drag: that is a
        // reorder (or an abandoned one), not a click, and must not collapse the folder.
        guard let pressed, let released = window?.mouseLocationOutsideOfEventStream else { return }
        let travel = hypot(released.x - event.locationInWindow.x, released.y - event.locationInWindow.y)
        if let reselected, event.clickCount == 1, travel < 4 { onReselect?(reselected) }
        if Self.chooses(row: row, selectedRow: selectedRow, clickCount: event.clickCount,
                        flags: event.modifierFlags, travel: travel) { onClick?(pressed) }
    }

    /// Whether a finished press chose its row: one click that left the row selected and moved
    /// under 4pt. A drag is a reorder, a control-click opened the row's menu, and a double-click's
    /// second press has already been counted by its first.
    static func chooses(row: Int, selectedRow: Int, clickCount: Int, flags: NSEvent.ModifierFlags, travel: CGFloat) -> Bool {
        row >= 0 && row == selectedRow && clickCount == 1 && !flags.contains(.control) && travel < 4
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? CocoaSidebar.Node else { return nil }
        return contextMenu?(node)
    }
}

/// GitHub avatars for the Dashboard's review tiles and the menu-bar tray: a frozen data URI when
/// one is given, else github.com/<login>.png fetched once and kept for the process. A finished
/// fetch posts `loaded` so those surfaces swap the octicon for the face.
@MainActor enum SidebarAvatars {
    static let loaded = Notification.Name("SidebarAvatars.loaded")
    private static var images: [String: NSImage] = [:]
    private static var pending: Set<String> = []
    private static var failures: [String: Date] = [:]

    static func image(login: String?, frozen: String?) -> NSImage? {
        if let frozen, !frozen.isEmpty {
            if let hit = images[frozen] { return hit }
            if let comma = frozen.firstIndex(of: ","), frozen.hasPrefix("data:"),
               let data = Data(base64Encoded: String(frozen[frozen.index(after: comma)...])), let image = NSImage(data: data) {
                images[frozen] = image
                return image
            }
        }
        guard let login, !login.isEmpty else { return nil }
        if let hit = images[login] { return hit }
        // A failed fetch may retry after a minute — not on every row refresh (a busy edge
        // reconfigures the row), and not never (a transient error must not stick for the process).
        if let failed = failures[login], Date().timeIntervalSince(failed) < 60 { return nil }
        guard let encoded = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              // 80px: sharp for the sidebar's 20pt rows and the dashboard's 30pt faces on Retina.
              let url = URL(string: "https://github.com/\(encoded).png?size=80"),
              pending.insert(login).inserted else { return nil }
        Task {
            defer { pending.remove(login) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else {
                failures[login] = Date()
                return
            }
            failures[login] = nil
            images[login] = image
            NotificationCenter.default.post(name: loaded, object: nil)
        }
        return nil
    }
}
