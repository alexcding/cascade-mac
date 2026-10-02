import AppKit
import Observation
import SwiftUI

/// Draws the main window's toolbar from the description the screen on show gives
/// (`AppCoordinator.windowToolbar`). The toolbar is split where the window is: the sidebar's
/// section, the screen's, and beside a terminal the context pane's, each tracking its divider in
/// `MainSplitViewController`. Every item hosts its SwiftUI content; the description is read under
/// observation, so anything it reads redraws the toolbar, and an item's content is handed over
/// again on every pass rather than only when the set of items changes.
///
/// A changed set of items is edited in place (`edit(to:)`): only the run of items that changed is
/// taken out and put in, so the rest — the title, the agent's controls — keep their places as the
/// pane's section adds or drops its tabs. A new toolbar is made only when the window holds another
/// or a picker is offered other choices. Items whose set stays the same are updated in place,
/// never rebuilt, so the state inside them (a focused field, an open menu) survives.
@MainActor final class MainToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    /// The window the toolbar is installed in; each new toolbar replaces the last in it.
    weak var window: NSWindow? {
        didSet { window?.toolbar = toolbar }
    }
    private(set) var toolbar = NSToolbar()
    private let describe: () -> WindowToolbar
    private var current = WindowToolbar.empty
    private var identifiers: [NSToolbarItem.Identifier] = []
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var searchTexts: [String: Binding<String>] = [:]
    private var searchItems: [String: NSSearchToolbarItem] = [:]
    private var segmentControls: [String: NSSegmentedControl] = [:]
    private var pickers: [String: (group: NSToolbarItemGroup, choices: [WindowToolbarItem.Choice])] = [:]
    /// Toggling pickers: a segmented control of this controller's, which can have no segment
    /// selected and whose choices can change in place. `selected` is the one last described.
    private var toggles: [String: (control: NSSegmentedControl, selected: Int)] = [:]
    private var segmentActions: [String: (Int) -> Void] = [:]
    /// The widths of the spacers either side of the middle items, which keep them centred in the
    /// screen's section however wide its leading and trailing items are.
    private var balances: [NSToolbarItem.Identifier: NSLayoutConstraint] = [:]
    private var balancePending = false
    /// Where the free width after the leading items ends when there is no middle: the flexible space
    /// after them, as a view of our own, so its edge is where the next item begins whatever it is.
    private var roomSpacer: NSView?
    /// The free width after the leading items, which their content may draw into but not claim.
    let room = ToolbarRoom()

    init(describe: @escaping () -> WindowToolbar) {
        self.describe = describe
        super.init()
        // A column's divider dragged or the window resized moves the section the middle is centred
        // in; `layoutChanged` ignores every other split view's.
        for name in [NSSplitView.didResizeSubviewsNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged(_:)), name: name, object: nil)
        }
        observe()
    }

    private func observe() {
        let next = withObservationTracking { describe() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(next)
    }

    private func apply(_ next: WindowToolbar) {
        current = next
        // A picker offered more or fewer choices is another width: read once AppKit has laid it out.
        defer { DispatchQueue.main.async { [weak self] in self?.measurePane() } }
        let identifiers = Self.identifiers(for: next)
        // A group's choices are fixed once it is made, so a picker offering others is a new toolbar too.
        if allItems(next).contains(where: reshapesPicker) || (identifiers != self.identifiers && !canEdit) {
            self.identifiers = identifiers
            install()
            return
        }
        if identifiers != self.identifiers { edit(to: identifiers) }
        for item in allItems(next) { refresh(item) }
    }

    /// Whether the toolbar on the window holds the items this controller last described, so a
    /// change can be made to it in place.
    private var canEdit: Bool { window?.toolbar === toolbar && toolbar.items.map(\.itemIdentifier) == identifiers }

    /// Takes out and puts in only the run of items that changed, keeping every item either side.
    /// A new toolbar re-lays out every item: the pane opening or shutting, which adds or drops its
    /// tabs, jolted the whole bar, title and agent controls included.
    private func edit(to next: [NSToolbarItem.Identifier]) {
        let old = identifiers
        var prefix = 0
        while prefix < min(old.count, next.count), old[prefix] == next[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, next.count) - prefix, old[old.count - 1 - suffix] == next[next.count - 1 - suffix] { suffix += 1 }
        // Allowed before they are asked for: the toolbar only inserts what its delegate allows.
        identifiers = next
        for index in stride(from: old.count - suffix - 1, through: prefix, by: -1) {
            forget(toolbar.items[index].itemIdentifier)
            toolbar.removeItem(at: index)
        }
        for index in prefix..<(next.count - suffix) { toolbar.insertItem(withItemIdentifier: next[index], at: index) }
    }

    /// Drops what this controller kept for an item taken out of the toolbar.
    private func forget(_ identifier: NSToolbarItem.Identifier) {
        let id = identifier.rawValue
        if let host = hosts.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: host)
        }
        if identifier == .roomSpacer, let view = roomSpacer {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
            roomSpacer = nil
        }
        searchTexts[id] = nil
        searchItems[id] = nil
        segmentControls[id] = nil
        pickers[id] = nil
        if let control = toggles.removeValue(forKey: id)?.control {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: control)
        }
        segmentActions[id] = nil
        balances[identifier] = nil
    }

    /// A fresh toolbar with the current items, made by the delegate from `current`.
    private func install() {
        for view in hosts.values.map({ $0 as NSView }) + [roomSpacer].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
        }
        hosts = [:]
        roomSpacer = nil
        searchTexts = [:]
        searchItems = [:]
        segmentControls = [:]
        pickers = [:]
        for control in toggles.values.map(\.control) {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: control)
        }
        toggles = [:]
        segmentActions = [:]
        balances = [:]
        // Its own identifier: toolbars sharing one keep their items in step, and the old one may
        // not be gone yet.
        let toolbar = NSToolbar(identifier: "CascadeMain.\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        window?.toolbar = toolbar
    }

    /// The sidebar's section, then the screen's — its leading items, a flexible space, its middle
    /// items and another flexible space, its trailing items — then the pane's. Two glass items side
    /// by side get a space between them, or AppKit would draw them in one capsule; anything else
    /// sits at the toolbar's own spacing. A fill item takes its section's slack itself.
    private static func identifiers(for toolbar: WindowToolbar) -> [NSToolbarItem.Identifier] {
        func run(_ items: [WindowToolbarItem]) -> [NSToolbarItem.Identifier] {
            items.enumerated().flatMap { index, item in
                (index > 0 && item.glass && items[index - 1].glass ? [.space] : []) + [NSToolbarItem.Identifier(item.id)]
            }
        }
        // The sidebar's section holds its toggle alone, against the divider, the same over every screen.
        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]
        identifiers += run(toolbar.leading)
        // Beside a bar that fills there is no slack to centre the middle in.
        let balanced = !toolbar.center.isEmpty && !toolbar.leading.contains(where: \.fills)
        if balanced { identifiers.append(.leadingBalance) }
        // With no middle, the space after the leading items is our own, to measure where the
        // trailing ones begin: a picker has no view to measure. Beside a middle, the system's, so the
        // two share the slack evenly and the balance works out.
        if !toolbar.leading.contains(where: \.fills) { identifiers.append(toolbar.center.isEmpty ? .roomSpacer : .flexibleSpace) }
        if !toolbar.center.isEmpty { identifiers += run(toolbar.center) + [.flexibleSpace] }
        if balanced { identifiers.append(.trailingBalance) }
        identifiers += run(toolbar.trailing)
        if let pane = toolbar.pane {
            identifiers.append(.inspectorTrackingSeparator)
            if !pane.contains(where: \.fills) { identifiers.append(.flexibleSpace) }
            identifiers += run(pane)
        }
        return identifiers
    }

    private func allItems(_ toolbar: WindowToolbar) -> [WindowToolbarItem] {
        toolbar.leading + toolbar.center + toolbar.trailing + (toolbar.pane ?? [])
    }

    /// A picker whose choices are no longer the ones its group was made with; which are enabled
    /// is updated in place.
    private func reshapesPicker(_ item: WindowToolbarItem) -> Bool {
        guard case .picker(_, let choices, _, _, _) = item.style, let built = pickers[item.id]?.choices else { return false }
        return built.map(\.title) != choices.map(\.title) || built.map(\.symbol) != choices.map(\.symbol)
    }

    private func refresh(_ item: WindowToolbarItem) {
        switch item.style {
        case .search(_, let value, let text):
            searchTexts[item.id] = text
            if let field = searchItems[item.id]?.searchField, field.stringValue != value {
                field.stringValue = value
            }
        case .segments(_, let selected, let select):
            segmentActions[item.id] = select
            if let control = segmentControls[item.id], control.selectedSegment != selected { control.selectedSegment = selected }
        case .picker(let label, let choices, let selected, let toggling, let select):
            segmentActions[item.id] = select
            if toggling, let control = toggles[item.id]?.control {
                toggles[item.id]?.selected = selected
                Self.configure(control, choices: choices)
                if control.selectedSegment != selected { control.selectedSegment = selected }
                break
            }
            guard let group = pickers[item.id]?.group else { break }
            if group.label != label { group.label = label }
            if group.selectedIndex != selected { group.selectedIndex = selected }
            for (subitem, choice) in zip(group.subitems, choices) where subitem.isEnabled != choice.enabled {
                subitem.isEnabled = choice.enabled
            }
        case .glass, .plain, .fill:
            hosts[item.id]?.rootView = AnyView(item.content.environment(room))
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .leadingBalance || identifier == .trailingBalance { return balanceItem(identifier) }
        if identifier == .roomSpacer { return roomSpacerItem() }
        guard let spec = allItems(current).first(where: { $0.id == identifier.rawValue }) else { return nil }
        let item: NSToolbarItem
        switch spec.style {
        case .search(let prompt, let value, let text):
            let search = NSSearchToolbarItem(itemIdentifier: identifier)
            search.searchField.placeholderString = prompt
            search.searchField.stringValue = value
            search.searchField.delegate = self
            // Typing arrives as text changes; the clear button and Escape arrive as the action.
            search.searchField.target = self
            search.searchField.action = #selector(searchFieldChanged(_:))
            search.searchField.identifier = NSUserInterfaceItemIdentifier(spec.id)
            searchItems[spec.id] = search
            searchTexts[spec.id] = text
            item = search
        case .segments(let titles, let selected, let select):
            // The system control, made here rather than by NSToolbarItemGroup, which builds its own
            // privately: this one carries the item's id for accessibility, and AppKit still sizes it.
            let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
            control.selectedSegment = selected
            control.identifier = NSUserInterfaceItemIdentifier(spec.id)
            control.setAccessibilityIdentifier(spec.id)
            item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            segmentControls[spec.id] = control
            segmentActions[spec.id] = select
        case .picker(let label, let choices, let selected, true, let select):
            // The system's segmented control, of this controller's: in one-of mode it draws the
            // toolbar's own selection, and unlike a group it can have none selected and take new
            // choices without a new toolbar. It never collapses to a pop-up button: the shown
            // section stays in sight, and it is how the pane is hidden.
            let control = NSSegmentedControl()
            control.trackingMode = .selectOne
            control.target = self
            control.action = #selector(toggleChanged(_:))
            control.identifier = NSUserInterfaceItemIdentifier(spec.id)
            control.setAccessibilityIdentifier(spec.id)
            control.setAccessibilityLabel(label)
            Self.configure(control, choices: choices)
            control.selectedSegment = selected
            item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.view = control
            toggles[spec.id] = (control, selected)
            control.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(paneItemResized(_:)),
                                                   name: NSView.frameDidChangeNotification, object: control)
            segmentActions[spec.id] = select
        case .picker(let label, let choices, let selected, _, let select):
            // AppKit's own group, not a control made here: only the group collapses to one pop-up
            // button when its section is short of room, rather than leaving for the overflow menu.
            // It builds that control privately, so it carries no identifier for accessibility and
            // none can be set on it: it is a radio group whose buttons are named by the images'
            // descriptions, each choice's title.
            let group = NSToolbarItemGroup(itemIdentifier: identifier,
                                           images: choices.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage() },
                                           selectionMode: .selectOne, labels: choices.map(\.title),
                                           target: self, action: #selector(pickerChanged(_:)))
            group.label = label
            group.controlRepresentation = .automatic
            group.selectedIndex = selected
            // Validation would enable every choice again: the description says which are.
            group.autovalidates = false
            for (subitem, choice) in zip(group.subitems, choices) {
                subitem.autovalidates = false
                subitem.isEnabled = choice.enabled
                subitem.toolTip = choice.title
            }
            item = group
            pickers[spec.id] = (group, choices)
            segmentActions[spec.id] = select
        case .glass, .plain, .fill:
            item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(rootView: AnyView(spec.content.environment(room)))
            // Content may draw past its measured width, into the room `ToolbarRoom` reports.
            host.clipsToBounds = false
            if spec.fills {
                // Between a floor and a ceiling, hugging loosely: the toolbar hands a flexible item
                // whatever its section has left, as it did Safari's address field.
                host.sizingOptions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    host.widthAnchor.constraint(greaterThanOrEqualToConstant: CompactTabMetrics.minToolbarBarWidth),
                    host.widthAnchor.constraint(lessThanOrEqualToConstant: CompactTabMetrics.maxToolbarBarWidth),
                    host.heightAnchor.constraint(equalToConstant: CompactTabMetrics.pillHeight),
                ])
                host.setContentHuggingPriority(.init(1), for: .horizontal)
            }
            item.view = host
            // A middle item's content changing width, or the items either side of it, re-centres it.
            host.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged(_:)),
                                                   name: NSView.frameDidChangeNotification, object: host)
            // Glass is the toolbar's own capsule; a plain item or a bar draws its own shapes.
            if case .glass = spec.style {} else { item.isBordered = false }
            hosts[spec.id] = host
        }
        item.visibilityPriority = spec.priority
        return item
    }

    // MARK: Centring the middle

    /// An empty spacer whose width `balanceMiddle` sets; the first to go when the toolbar is short.
    private func balanceItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let width = view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([width, view.heightAnchor.constraint(equalToConstant: 1)])
        balances[identifier] = width
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        item.isBordered = false
        item.visibilityPriority = .low
        return item
    }

    /// A flexible space the toolbar sizes as it does its own: empty, and taking what slack it is given.
    /// It needs some width of its own, or the toolbar leaves it at none.
    private func roomSpacerItem() -> NSToolbarItem {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
            view.heightAnchor.constraint(equalToConstant: 1),
        ])
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: view)
        roomSpacer = view
        let item = NSToolbarItem(itemIdentifier: .roomSpacer)
        item.view = view
        item.isBordered = false
        return item
    }

    @objc private func layoutChanged(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window !== self.window { return }
        if let split = notification.object as? NSSplitView {
            guard let window, split === (window.contentViewController as? NSSplitViewController)?.splitView else { return }
        } else if let view = notification.object as? NSView, view !== roomSpacer, !hosts.values.contains(where: { $0 === view }) {
            return
        }
        guard !balancePending else { return }
        // After the toolbar has laid out what changed.
        balancePending = true
        DispatchQueue.main.async { [weak self] in
            self?.balancePending = false
            self?.balanceMiddle()
            self?.measureRoom()
        }
    }

    /// The two flexible spaces share the slack, so the middle sits off centre by about half the
    /// difference between what precedes it and what follows it in the section; the spacers make up
    /// that difference. Widening one side's spacer moves the middle half as far the other way, which
    /// is corrected from where the middle lands until it stops moving, laid out between passes so
    /// each pass reads the toolbar as the last one left it. They never take more than the slack.
    private func balanceMiddle() {
        guard let window, let lead = balances[.leadingBalance], let trail = balances[.trailingBalance],
              let leadView = lead.firstItem as? NSView, let trailView = trail.firstItem as? NSView,
              let section = Self.screenColumn(in: window) else { return }
        // A spacer squeezed into the overflow menu, by a column that shrank at once, comes back at
        // no width; the pass its return sets off balances from there.
        let visible = Set(toolbar.visibleItems?.map(\.itemIdentifier) ?? [])
        guard visible.contains(.leadingBalance), visible.contains(.trailingBalance) else {
            lead.constant = 0
            trail.constant = 0
            return
        }
        let middle = current.center.compactMap { hosts[$0.id] }.filter { $0.window != nil }
        guard !middle.isEmpty else { return }
        for _ in 0..<3 {
            layOut(window, middle[0])
            let sectionFrame = Self.screenFrame(section)
            let middleFrame = middle.map(Self.screenFrame).reduce(NSRect.null) { $0.union($1) }
            let leadFrame = Self.screenFrame(leadView)
            let trailFrame = Self.screenFrame(trailView)
            let slack = max(0, (middleFrame.minX - leadFrame.maxX) + (trailFrame.minX - middleFrame.maxX)
                + lead.constant + trail.constant - 2 * Self.minimumGap)
            let balance = trail.constant - lead.constant
            let target = min(max(balance + 2 * (middleFrame.midX - sectionFrame.midX), -slack), slack).rounded()
            if abs(target - balance) < 1 { return }
            lead.constant = max(0, -target)
            trail.constant = max(0, target)
        }
    }

    /// The free width between the last leading item and whatever follows it: up to the middle, or
    /// with none to the end of the space after them. Read once the middle is balanced, since that
    /// moves it.
    private func measureRoom() {
        // After the layout below, which it reads without forcing another.
        defer { measurePane() }
        guard let window, let last = current.leading.last.flatMap({ hosts[$0.id] }), last.window != nil else {
            if room.afterLeading != 0 { room.afterLeading = 0 }
            return
        }
        layOut(window, last)
        let middle = current.center.compactMap { hosts[$0.id] }.filter { $0.window != nil }
        let end = middle.isEmpty
            ? roomSpacer.flatMap { $0.window != nil ? Self.screenFrame($0).maxX : nil }
            : middle.map { Self.screenFrame($0).minX }.min()
        let free = end.map { max(0, $0 - Self.screenFrame(last).maxX - Self.minimumGap / 2) } ?? 0
        if abs(room.afterLeading - free) >= 1 { room.afterLeading = free.rounded() }
    }

    /// The pane section's items as AppKit sized them, the toolbar's spacing between them, and its
    /// inset at the window's edge: their width depends on the system and on how many choices a
    /// picker offers. Widths, never positions: an item not laid out yet sits at the toolbar's origin,
    /// and its position would read as the whole window. Zero until every item has a width; an
    /// item's width changing measures again (`paneItemResized`). Only an item with a view of this
    /// controller's — a toggling picker or a hosted item — can be measured; with any other kind in
    /// the section (a group picker, a search field) it is not measured at all, rather than measured
    /// short, and the pane keeps clear of its own estimate.
    private func measurePane() {
        let items = current.pane ?? []
        let views = items.compactMap { toggles[$0.id]?.control ?? hosts[$0.id] }.filter { $0.window != nil }
        let widths = views.map(\.frame.width)
        let taken = views.isEmpty || views.count < items.count || widths.contains(0) ? 0
            : (widths.reduce(0, +) + Self.itemSpacing * CGFloat(views.count - 1) + Self.edgeInset).rounded()
        if abs(room.paneTrailing - taken) >= 1 { room.paneTrailing = taken }
    }
    /// The toolbar's own spacing between items, and from the last to the window's edge, on macOS 26.
    private static let itemSpacing: CGFloat = 8, edgeInset: CGFloat = 8

    @objc private func paneItemResized(_ notification: Notification) { measurePane() }

    /// In full screen the toolbar is in a window of its own, apart from the columns, so frames are
    /// compared on screen and both windows are laid out.
    private func layOut(_ window: NSWindow, _ toolbarView: NSView) {
        window.layoutIfNeeded()
        if let other = toolbarView.window, other !== window { other.layoutIfNeeded() }
    }

    private static func screenFrame(_ view: NSView) -> NSRect {
        let frame = view.convert(view.bounds, to: nil)
        return view.window?.convertToScreen(frame) ?? frame
    }

    /// What each side of the middle keeps when it is pushed off centre for want of room: the
    /// flexible space with the toolbar's spacing around it. A spacer asking for more than the room
    /// there is would go to the overflow menu, taking the balance with it.
    private static let minimumGap: CGFloat = 40

    /// The screen's column, between the sidebar and the context pane: the section the middle is
    /// centred in.
    private static func screenColumn(in window: NSWindow) -> NSView? {
        (window.contentViewController as? NSSplitViewController)?.splitViewItems
            .first { $0.behavior == .default }?.viewController.view
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField { searchFieldChanged(field) }
    }

    @objc private func segmentChanged(_ control: NSSegmentedControl) {
        guard let id = control.identifier?.rawValue else { return }
        segmentActions[id]?(control.selectedSegment)
    }

    @objc private func pickerChanged(_ group: NSToolbarItemGroup) {
        segmentActions[group.itemIdentifier.rawValue]?(group.selectedIndex)
    }

    /// A click reports the segment clicked, the selected one included, and leaves the selection to
    /// the description, which follows whatever the caller made of it.
    @objc private func toggleChanged(_ control: NSSegmentedControl) {
        guard let id = control.identifier?.rawValue, let described = toggles[id]?.selected else { return }
        let clicked = control.selectedSegment
        control.selectedSegment = described
        if clicked >= 0 { segmentActions[id]?(clicked) }
    }

    /// A toggling picker's segments: one symbol per choice, named by its title, enabled as it says.
    /// Only what differs is set, so a description that changed nothing redraws nothing.
    private static func configure(_ control: NSSegmentedControl, choices: [WindowToolbarItem.Choice]) {
        if control.segmentCount != choices.count { control.segmentCount = choices.count }
        for (index, choice) in choices.enumerated() {
            if control.toolTip(forSegment: index) != choice.title {
                control.setImage(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.title), forSegment: index)
                control.setToolTip(choice.title, forSegment: index)
            }
            if control.isEnabled(forSegment: index) != choice.enabled { control.setEnabled(choice.enabled, forSegment: index) }
        }
    }

    @objc private func searchFieldChanged(_ field: NSSearchField) {
        guard let id = field.identifier?.rawValue, let text = searchTexts[id], text.wrappedValue != field.stringValue else { return }
        text.wrappedValue = field.stringValue
    }
}

/// The toolbar's room, from `MainToolbarController`. `afterLeading` is the width free after the
/// leading items: a leading item may draw into it, as the build title does its session name, but
/// nothing measured may depend on it, since an item that grew with it would take the room it was
/// told of. `paneTrailing` is what the pane section's items take at the window's trailing edge,
/// from the first of them to the edge: what a column drawing its own bar in the title-bar zone
/// keeps clear of (`SessionWorkspacePane`). Zero until measured.
@MainActor @Observable final class ToolbarRoom {
    var afterLeading: CGFloat = 0
    var paneTrailing: CGFloat = 0
}

private extension NSToolbarItem.Identifier {
    static let leadingBalance = Self("center-balance-leading")
    static let trailingBalance = Self("center-balance-trailing")
    static let roomSpacer = Self("leading-room")
}

private extension WindowToolbarItem {
    var fills: Bool { if case .fill = style { true } else { false } }
    /// Drawn in the toolbar's own capsule: a picker's group is, like a hosted glass item.
    var glass: Bool {
        switch style {
        case .glass, .picker: true
        default: false
        }
    }
}
