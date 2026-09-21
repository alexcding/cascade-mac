import AppKit
import SwiftUI

// AppKit owns row reuse, keyboard navigation, selection, and menus. SwiftUI only supplies
// snapshots and receives semantic selection/actions. The look is the system's: a source list
// over the sidebar material, with its selection, its section headers and its label colours.
// What is ours sits inside that: no disclosure triangles (a click on the already-selected
// folder collapses it), sessions nested under their project, hover-only pin / "+" / close
// accessories, and the session status glyph.
struct CocoaSidebar: NSViewRepresentable {
    let entries: [SidebarEntry]
    let selection: SidebarDestination
    let pinnedIDs: Set<String>
    let onSelect: (SidebarDestination) -> Void
    let onTogglePin: (String) -> Void
    var onNewSession: (String) -> Void = { _ in }
    var onCloseTab: (String) -> Void = { _ in }
    var onNewTab: () -> Void = {}
    var onMoveTab: (String, String?) -> Void = { _, _ in }
    var onMoveProject: (String, String?) -> Void = { _, _ in }
    var onMoveSession: (String, String?) -> Void = { _, _ in }
    var onMovePinned: (String, String?) -> Void = { _, _ in }
    var onTogglePinTab: (String) -> Void = { _ in }
    var onRemoveSession: (String) -> Void = { _ in }
    var gitClientLabel: String?
    var onOpenGitClient: (String) -> Void = { _ in }
    static let dragType = NSPasteboard.PasteboardType("com.craft.sidebar-row")

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.identifier = .init("workspace-sidebar")
        outline.setAccessibilityIdentifier("workspace-sidebar")
        outline.setAccessibilityLabel("Workspace sidebar")
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.floatsGroupRows = false
        // Nesting is laid out by the cell, so a session's glyph lines up under its project's title.
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap
        outline.contextMenu = { [weak coordinator = context.coordinator] item in coordinator?.menu(for: item) }
        outline.onReselect = { [weak coordinator = context.coordinator] item in coordinator?.reselected(item) }
        outline.onMiddleClick = { [weak coordinator = context.coordinator] item in coordinator?.middleClicked(item) }
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

    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.stopSpinner() }

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
        private var spinTimer: Timer?
        private var spinFrame = 0
        private var avatarObserver: NSObjectProtocol?

        init(parent: CocoaSidebar, preferences: UserDefaults = .standard) {
            self.parent = parent
            self.preferences = preferences
            collapsed = Set(preferences.stringArray(forKey: "sidebar.collapsed") ?? [])
            super.init()
            avatarObserver = NotificationCenter.default.addObserver(forName: SidebarAvatars.loaded, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleCells() }
            }
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
                    // spinner and hover state survive and nothing reloads under the pointer.
                    func apply(_ entry: SidebarEntry) {
                        if let node = nodes[entry.id], node.entry != entry {
                            let grewOrShrank = Self.pinnedTabsHeight(node.entry) != Self.pinnedTabsHeight(entry)
                            node.entry = entry
                            let row = outline.row(forItem: node)
                            if row >= 0 {
                                if grewOrShrank { outline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
                                configureCell(atRow: row, node: node)
                            }
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
                syncSpinner()
            }
            // The grid's tiles draw their own selection, so they follow a selection change too.
            if changedSelection, let node = nodes["pinned-tabs"] {
                let row = outline.row(forItem: node)
                if row >= 0 { configureCell(atRow: row, node: node) }
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

        private static func pinnedTabsHeight(_ entry: SidebarEntry) -> CGFloat? {
            if case .pinnedTabs(let tabs) = entry.role { SidebarPinnedTabsGrid.height(count: tabs.count) } else { nil }
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

        // Drag to reorder, always among siblings: a tab within the Tabs section, a project within
        // Projects, a session within its own project, a pinned session within Pinned. The
        // pasteboard carries the row's placement id.
        private enum Drag: Equatable { case tab, project, session, pinned }
        private func drag(for node: Node) -> Drag? {
            switch node.entry.destination {
            case .tab: return .tab
            case .project: return .project
            case .session(let id):
                // A pinned session moves within Pinned, a project's row within its project; an orphan stays put.
                if node.entry.id == "pin:\(id)" { return .pinned }
                return home(of: node) != nil ? .session : nil
            default: return nil
            }
        }
        private func home(of node: Node) -> Node? { homes[ObjectIdentifier(node)] }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node, drag(for: node) != nil else { return nil }
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
                guard kind == .tab else { return nil } // below the last row: the end of Tabs
                gap = last + 1
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
                case .tab(let id), .project(let id), .session(let id): id
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
            case .tab: parent.onMoveTab(moving, id(drop.before))
            case .project: parent.onMoveProject(moving, id(drop.before))
            case .session: parent.onMoveSession(moving, id(drop.before))
            case .pinned: parent.onMovePinned(moving, id(drop.before))
            }
            return true
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let entry = (item as? Node)?.entry else { return SidebarMetrics.rowHeight }
            if let height = Self.pinnedTabsHeight(entry) { return height }
            return entry.isHeading ? SidebarMetrics.labelHeight : SidebarMetrics.rowHeight
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = SidebarRowView()
            row.hoverable = (item as? Node).map { $0.entry.destination != nil || $0.entry.role == .tabsHeader } ?? false
            return row
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if case .pinnedTabs = node.entry.role {
                let cell = outlineView.makeView(withIdentifier: SidebarPinnedTabsCell.identifier, owner: self) as? SidebarPinnedTabsCell ?? {
                    let cell = SidebarPinnedTabsCell()
                    cell.identifier = SidebarPinnedTabsCell.identifier
                    return cell
                }()
                configure(cell, node: node)
                return cell
            }
            // Headings never share a cell with rows: the table sets a group row's font when the
            // cell goes in, and a cell reused from a row would keep the row's.
            let identifier = NSUserInterfaceItemIdentifier(node.entry.isHeading ? "sidebar-heading" : "sidebar-cell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView ?? {
                let cell = SidebarCellView()
                cell.identifier = identifier
                return cell
            }()
            configure(cell, node: node, row: outlineView.row(forItem: node))
            return cell
        }

        /// Reconfigures whichever cell class the row holds.
        private func configureCell(atRow row: Int, node: Node) {
            guard let outline else { return }
            switch outline.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarPinnedTabsCell: configure(cell, node: node)
            case let cell as SidebarCellView: configure(cell, node: node, row: row)
            default: break
            }
        }

        private func configure(_ cell: SidebarPinnedTabsCell, node: Node) {
            guard case .pinnedTabs(let tabs) = node.entry.role else { return }
            cell.configure(SidebarPinnedTabsGrid(
                tabs: tabs, selectedID: parent.selection.tabID,
                onSelect: { [weak self] id in self?.parent.onSelect(.tab(id)) },
                onUnpin: { [weak self] id in self?.parent.onTogglePinTab(id) },
                onClose: { [weak self] id in self?.parent.onCloseTab(id) }))
        }

        private func configure(_ cell: SidebarCellView, node: Node, row: Int) {
            guard let outline else { return }
            let nested = outline.parent(forItem: node) != nil
            cell.onTogglePin = { [weak self] id in self?.parent.onTogglePin(id) }
            cell.onNewSession = { [weak self] id in self?.parent.onNewSession(id) }
            cell.onCloseTab = { [weak self] url in self?.parent.onCloseTab(url) }
        cell.onNewTab = { [weak self] in self?.parent.onNewTab() }
            cell.configure(node.entry, nested: nested, spinFrame: spinFrame)
            if row >= 0, let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView {
                rowView.hoverable = node.entry.destination != nil || node.entry.role == .tabsHeader
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

        // One shared 180ms ticker advances every visible busy row in lockstep, and runs only
        // while at least one session is busy (sidebar.js syncSpinner).
        private func syncSpinner() {
            let anyBusy = snapshot.flatMap(\.descendants).contains {
                if case .session(let status, _) = $0.role { status.busy } else { false }
            }
            if anyBusy, spinTimer == nil {
                let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                spinTimer = timer
            } else if !anyBusy { stopSpinner() }
        }

        func stopSpinner() { spinTimer?.invalidate(); spinTimer = nil }

        private func tick() {
            spinFrame = (spinFrame + 1) % SidebarGlyphs.frameCount
            outline?.enumerateAvailableRowViews { rowView, _ in
                (rowView.view(atColumn: 0) as? SidebarCellView)?.advanceSpinner(to: spinFrame)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, let node = outline.item(atRow: outline.selectedRow) as? Node,
                  let destination = node.entry.destination else { return }
            selectedPlacement = node.entry.id
            parent.onSelect(destination)
        }

        // A click on the folder that is already in view collapses / expands its sessions — the
        // web sidebar's projectClick; there is no disclosure caret.
        func reselected(_ node: Node) {
            guard let outline, node.entry.projectID != nil, !node.children.isEmpty else { return }
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) }
            else { outline.animator().expandItem(node) }
        }

        // A middle-click closes a tab row, as in a browser (sidebar.js onauxclick).
        func middleClicked(_ node: Node) {
            if case .tab(let url) = node.entry.destination { parent.onCloseTab(url) }
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
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = node
                menu.addItem(item)
            }
            if node.entry.detail.hasPrefix("/") {
                if case .session = destination, let title = parent.gitClientLabel {
                    add(title, action: #selector(openGitClient(_:)))
                }
                add("Reveal in Finder", action: #selector(reveal(_:)))
            } else if case .tab = destination {
                add("Pin Tab", action: #selector(pinTab(_:)))
                add("Close Tab", action: #selector(closeTab(_:)))
            }
            // The session and its worktree go together (one unit); the sheet spells out what is
            // stopped and removed, so the menu item only asks for it.
            if case .session(let id) = destination {
                menu.addItem(.separator())
                add(parent.pinnedIDs.contains(id) ? "Unpin Session" : "Pin Session", action: #selector(togglePin(_:)))
                add("Remove Session…", action: #selector(removeSession(_:)))
            }
            return menu.items.isEmpty ? nil : menu
        }

        @objc private func togglePin(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onTogglePin(id)
        }
        @objc private func removeSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onRemoveSession(id)
        }
        @objc private func openGitClient(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .session(let id) = node.entry.destination else { return }
            parent.onOpenGitClient(id)
        }
        @objc private func pinTab(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .tab(let id) = node.entry.destination else { return }
            parent.onTogglePinTab(id)
        }
        @objc private func closeTab(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, case .tab(let url) = node.entry.destination else { return }
            parent.onCloseTab(url)
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
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
    }
    static let navText = dynamic(0x3b3d3f, 0xc9cbce)   // --nav-text
    static let text = dynamic(0x16181d, 0xe8e8e8)      // --text
    static let text2 = dynamic(0x565d68, 0xa2a2a2)     // --text-2
    static let text3 = dynamic(0x9298a3, 0x6e6e6e)     // --text-3
    /// A row's symbol, sampled from Finder's own sidebar in each appearance. No one system colour is
    /// both: `systemGray` is this in light mode, but resolves well dimmer than Finder in dark.
    static let icon = dynamic(0x8d8d92, 0xc1c4cb)
    /// Each CLI's own brand colour, matching `Theme.agentTint`: one agent reads the same in the
    /// sidebar spinner, on the Dashboard and in its context ring.
    static let spinClaude = dynamic(0xd97757, 0xd97757)
    static let spinCodex = dynamic(0x707af0, 0x707af0)
    static let success = dynamic(0x16a34a, 0x4ade80)
    static let warn = dynamic(0xd97706, 0xfbbf24)
    static let danger = dynamic(0xdc2626, 0xf87171)
    // The pinned tiles draw their own plates: the list's selection colour, and a fainter hover.
    static let hover = dynamic(0x16181d, 0xe8e8e8, alpha: 0.08)
    static let selected = NSColor.unemphasizedSelectedContentBackgroundColor
}

/// A medium source list's own measures, and the few the cell adds inside it.
enum SidebarMetrics {
    static let rowHeight: CGFloat = 32       // what `.medium` rows measure
    static let labelHeight: CGFloat = 19     // what a section header measures; the list adds the air above it
    static let iconSlot: CGFloat = 24        // a row's leading icon; a session's glyph has its own narrower slot
    static let symbolSize: CGFloat = 17      // a row symbol's point size, a step up from the list's 13
    static let brandSize: CGFloat = 20       // favicons, brand art and avatars, centred in the slot
    static let leading: CGFloat = 2          // cell edge to the icon slot
    static let gap: CGFloat = 6              // icon to title, title to accessory
    static let trailing: CGFloat = 4         // accessory to the cell edge
    static let nestedIndent: CGFloat = 16    // a session under its project
    /// How far the selection plate reaches past a cell on each side. The pinned tiles are plates
    /// of their own, so they are laid out to the plate's edges rather than the cell's.
    static let plateOutset: CGFloat = 6
    static let radius: CGFloat = 8
}

/// Busy-spinner frames per CLI (sidebar.js SPIN_FRAMES): Claude Code's blooming asterisk for
/// Claude, a braille cycle otherwise; the resting glyph is the full-bloom frame held still.
enum SidebarGlyphs {
    static let frameCount = 10
    static func frames(_ cli: String?) -> [String] {
        cli == "claude" ? ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
            : ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    }
    static func resting(_ cli: String?) -> String { cli == "claude" ? "✻" : "⠿" }
    static func tint(_ cli: String?) -> NSColor {
        switch cli {
        case "claude": SidebarPalette.spinClaude
        case "codex": SidebarPalette.spinCodex
        default: SidebarPalette.text3
        }
    }
}

// MARK: - Views

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
    var onNewSession: (String) -> Void = { _ in }
    var onCloseTab: (String) -> Void = { _ in }
    var onNewTab: () -> Void = {}
    var hovered = false { didSet { if oldValue != hovered { applyState() } } }

    private let icon = NSImageView()
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let accessory = SidebarAccessoryButton()
    private var entry = SidebarEntry(id: "", title: "", symbol: "")
    private var nested = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.maximumNumberOfLines = 1
        glyph.alignment = .center
        glyph.font = Self.glyphFont
        // Down only: a symbol is already the size its font makes it, and must not be stretched to the slot.
        icon.imageScaling = .scaleProportionallyDown
        icon.wantsLayer = true
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3.5
        badge.layer?.borderWidth = 1.5
        accessory.target = self
        accessory.action = #selector(accessoryPressed)
        [icon, glyph, title, badge, accessory].forEach(addSubview)
        imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The table builds a drag image from `imageView` and `textField`. This cell has no
    // `textField` and a session hides its icon behind the glyph, so the default image is
    // empty — and the gap style hides the row itself, so a dragged row would simply vanish
    // until it was dropped. Drag a picture of the whole cell instead, minus the hover button.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard bounds.width > 0, bounds.height > 0, let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return super.draggingImageComponents
        }
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

    func configure(_ entry: SidebarEntry, nested: Bool, spinFrame: Int) {
        self.entry = entry
        self.nested = nested
        title.stringValue = entry.title
        // Only a heading's label is the table's to style. On macOS 27 the table also turns a selected
        // row's label semibold, which makes the title jump as the selection moves; a row keeps its
        // label to itself and sets the row size's font, so it reads the same selected or not.
        textField = entry.isHeading ? title : nil
        if !entry.isHeading { title.font = .systemFont(ofSize: NSFont.systemFontSize) }
        setAccessibilityLabel(entry.title)
        toolTip = entry.tooltip ?? (entry.detail.isEmpty ? entry.title : entry.detail)
        setAccessibilityIdentifier(entry.id)
        icon.isHidden = false; glyph.isHidden = true; badge.isHidden = true; accessory.isHidden = true
        icon.layer?.cornerRadius = 0
        alphaValue = 1
        switch entry.role {
        case .label:
            icon.isHidden = true
        case .tabsHeader:
            icon.isHidden = true
            accessory.image = SidebarIcons.addSymbol
            accessory.toolTip = "New tab"
            accessory.setAccessibilityLabel("New tab")
        case .nav:
            icon.image = SidebarIcons.rowSymbol(entry.symbol)
        case .project(let canCreate):
            icon.image = SidebarIcons.rowSymbol("folder")
            if canCreate {
                accessory.image = SidebarIcons.addSymbol
                accessory.toolTip = "New session on a new worktree"
                accessory.setAccessibilityLabel("New session")
            }
        case .session(let status, let pinned):
            icon.isHidden = true
            glyph.isHidden = !status.live && !status.busy
            glyph.stringValue = status.busy ? SidebarGlyphs.frames(status.cli)[spinFrame % SidebarGlyphs.frameCount]
                : SidebarGlyphs.resting(status.cli)
            glyph.textColor = status.busy ? SidebarGlyphs.tint(status.cli) : SidebarPalette.text3
            alphaValue = status.live || status.busy ? 1 : 0.82
            accessory.image = SidebarIcons.symbol(pinned ? "pinFilled" : "pin")
            accessory.toolTip = pinned ? "Unpin session" : "Pin session to the top"
            accessory.setAccessibilityLabel(accessory.toolTip)
        case .tab(let tab):
            configureTabIcon(tab)
            accessory.image = SidebarIcons.closeSymbol
            accessory.toolTip = "Close tab"
            accessory.setAccessibilityLabel("Close tab")
        case .pinnedTabs:
            break // Hosted by SidebarPinnedTabsCell, never this cell.
        }
        applyState()
    }

    /// Shared by the glyph label and the slot measured for it, so the two cannot drift apart.
    private static let glyphFont = NSFont.monospacedSystemFont(ofSize: 14.7, weight: .bold)
    /// The status glyph's slot: the widest glyph either CLI shows, fixed so a spinner frame of another
    /// width cannot nudge the title.
    private static let glyphSlot: CGFloat = {
        let font = glyphFont
        let glyphs = ["claude", "codex"].flatMap { SidebarGlyphs.frames($0) + [SidebarGlyphs.resting($0)] }
        return (glyphs.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 10).rounded(.up)
    }()
    /// What a label insets its text by on each side; the glyph's frame is widened by it so nothing clips.
    private static let labelInset: CGFloat = 2

    /// A tab row's leading image size: favicons, brand art and avatars sit inside the slot; the globe fills it.
    private var iconSize = SidebarMetrics.iconSlot

    private func configureTabIcon(_ tab: SidebarTabIcon) {
        iconSize = SidebarMetrics.brandSize
        switch tab.kind {
        case "github":
            if let avatar = SidebarAvatars.image(login: tab.login, frozen: tab.avatar) {
                icon.image = avatar
                icon.layer?.cornerRadius = SidebarMetrics.brandSize / 2
                icon.layer?.masksToBounds = true
            } else {
                icon.image = SidebarIcons.brand("github", size: SidebarMetrics.brandSize)
            }
            let color: NSColor? = switch tab.ci {
            case .none: nil
            case .running: SidebarPalette.warn
            case .success: SidebarPalette.success
            case .failure: SidebarPalette.danger
            }
            if let color {
                badge.isHidden = false
                badge.layer?.backgroundColor = color.cgColor
                badge.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            }
        case "jira": icon.image = SidebarIcons.brand("jira", size: SidebarMetrics.brandSize)
        default:
            if let url = tab.url, let favicon = FaviconStore.shared.image(forURL: url) {
                icon.image = favicon
                icon.layer?.cornerRadius = 3
                icon.layer?.masksToBounds = true
            } else {
                icon.image = SidebarIcons.rowSymbol("globe")
                iconSize = SidebarMetrics.iconSlot
            }
        }
    }

    func advanceSpinner(to frame: Int) {
        guard case .session(let status, _) = entry.role, status.busy else { return }
        glyph.stringValue = SidebarGlyphs.frames(status.cli)[frame % SidebarGlyphs.frameCount]
    }

    private var stopped: Bool {
        if case .session(let status, _) = entry.role { return !status.live && !status.busy }
        return false
    }

    private func applyState() {
        // The table never sets a colour, not even for the headings whose font it does set.
        // These are system label colours, which follow the appearance and the selection by themselves.
        title.textColor = entry.isHeading ? .secondaryLabelColor : stopped ? .tertiaryLabelColor : .labelColor
        // Finder's grey, lighter than the title in light mode and dimmer than it in dark. No system
        // label colour lands on both: secondary label is too dim in dark, --nav-text too dark in light.
        icon.contentTintColor = SidebarPalette.icon
        switch entry.role {
        case .project(let canCreate): accessory.isHidden = !(hovered && canCreate)
        case .session, .tab, .tabsHeader: accessory.isHidden = !hovered
        default: accessory.isHidden = true
        }
        needsLayout = true
    }

    @objc private func accessoryPressed() {
        if entry.role == .tabsHeader { onNewTab() }
        else if let id = entry.sessionID { onTogglePin(id) }
        else if let id = entry.projectID { onNewSession(id) }
        else if let id = entry.destination?.tabID { onCloseTab(id) }
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
        let left = SidebarMetrics.leading + (nested ? SidebarMetrics.nestedIndent : 0)
        let right = bounds.width - SidebarMetrics.trailing
        func centered(_ x: CGFloat, _ size: CGFloat) -> NSRect {
            NSRect(x: x, y: ((height - size) / 2).rounded(), width: size, height: size)
        }
        switch entry.role {
        case .label, .tabsHeader:
            title.sizeToFit()
            let titleHeight = title.frame.height
            // The heading's "+" sits in the same trailing slot as a project row's, centred on the title.
            // Same slot on screen, not the same offset in the cell: a source list frames a heading's
            // cell differently from an item's, so the item's edge is read off an item.
            let right = itemTrailingEdge ?? right
            let titleY = ((height - titleHeight) / 2).rounded()
            accessory.frame = NSRect(x: right - 18, y: (titleY + (titleHeight - 18) / 2).rounded(), width: 18, height: 18)
            let titleRight = accessory.isHidden ? right : right - 18 - SidebarMetrics.gap
            title.frame = NSRect(x: 0, y: titleY, width: max(0, titleRight), height: titleHeight)
            return
        case .nav, .project:
            icon.frame = centered(left, slot)
        case .session:
            glyph.sizeToFit()
            let glyphHeight = glyph.frame.height
            glyph.frame = NSRect(x: left - Self.labelInset, y: ((height - glyphHeight) / 2).rounded(),
                                 width: Self.glyphSlot + Self.labelInset * 2, height: glyphHeight)
        case .tab:
            icon.frame = centered(left + (slot - iconSize) / 2, iconSize)
            badge.frame = NSRect(x: icon.frame.maxX - 5, y: icon.frame.maxY - 6, width: 7, height: 7)
        case .pinnedTabs:
            return
        }
        // An icon fills its slot, so the gap is what separates it from the title. A status glyph is far
        // narrower than the slot: it gets a slot of its own width, or the same gap would read twice as wide.
        let leadingSlot = if case .session = entry.role { Self.glyphSlot } else { slot }
        let titleX = left + leadingSlot + SidebarMetrics.gap
        let accessorySlot: CGFloat = 18
        let slotX = right - accessorySlot
        accessory.frame = centered(slotX, accessorySlot)
        let titleRight = accessory.isHidden ? right : slotX - SidebarMetrics.gap
        title.sizeToFit()
        let titleHeight = title.frame.height
        title.frame = NSRect(x: titleX, y: ((height - titleHeight) / 2).rounded(), width: max(0, titleRight - titleX), height: titleHeight)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); needsLayout = true }
    override var isFlipped: Bool { true }
}

/// The hover pin / "+": invisible until the row is hovered (the cell hides it), a muted glyph
/// that darkens under the pointer — no plate of its own inside the row's highlight.
@MainActor final class SidebarAccessoryButton: NSButton {
    private var tracking: NSTrackingArea?
    private var pointed = false { didSet { contentTintColor = pointed ? SidebarPalette.text : SidebarPalette.text3.withAlphaComponent(0.8) } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        contentTintColor = SidebarPalette.text3.withAlphaComponent(0.8)
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
    var onMiddleClick: ((CocoaSidebar.Node) -> Void)?

    // No disclosure triangles: a project folder collapses by clicking it again.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let reselected = row >= 0 && row == selectedRow ? item(atRow: row) as? CocoaSidebar.Node : nil
        super.mouseDown(with: event)
        // `super` returns once the mouse is up, which may be the end of a drag: that is a
        // reorder (or an abandoned one), not a click, and must not collapse the folder.
        guard let reselected, event.clickCount == 1, let released = window?.mouseLocationOutsideOfEventStream,
              hypot(released.x - event.locationInWindow.x, released.y - event.locationInWindow.y) < 4 else { return }
        onReselect?(reselected)
    }

    override func otherMouseUp(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard event.buttonNumber == 2, row >= 0, let node = item(atRow: row) as? CocoaSidebar.Node else {
            super.otherMouseUp(with: event); return
        }
        onMiddleClick?(node)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? CocoaSidebar.Node else { return nil }
        return contextMenu?(node)
    }
}

/// GitHub avatars for PR tab rows: the data URI frozen onto the tab when there is one, else
/// github.com/<login>.png fetched once and kept for the process. A finished fetch posts
/// `loaded` so visible rows swap the octicon for the face.
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
              let url = URL(string: "https://github.com/\(encoded).png?size=40"),
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
