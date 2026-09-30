import AppKit
import Observation
import SwiftUI

/// Draws the main window's toolbar from the description the screen on show gives
/// (`AppCoordinator.windowToolbar`). The toolbar is split where the card's columns are: the list's
/// section, the screen's, and beside a terminal the context pane's, each tracking its divider in
/// `MainSplitViewController`'s split view, which the toolbar is told of (`splitView`). The columns
/// are plain split items inside the card, not AppKit's sidebar and inspector, so the separators are
/// tracking separators bound to that split view's dividers. Every item hosts its SwiftUI content; the description is read under
/// observation, so anything it reads redraws the toolbar, and an item's content is handed over
/// again on every pass rather than only when the set of items changes.
///
/// Nothing in the toolbar animates. A toolbar told to change its items slides the old ones out and
/// the new ones in, even inside a zero-length animation, so a new set of items is a new toolbar,
/// installed in the window at once. While the set stays the same, items are updated in place, never
/// rebuilt, so the state inside them (a focused field, an open menu) survives.
@MainActor final class MainToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    /// The window the toolbar is installed in; each new toolbar replaces the last in it.
    weak var window: NSWindow? {
        didSet { window?.toolbar = toolbar }
    }
    /// The card's columns: the list, the screen and the pane. Set before `window`, since the
    /// toolbar's separators are made against it.
    weak var splitView: NSSplitView?
    private(set) var toolbar = NSToolbar()
    private let describe: () -> WindowToolbar
    private var current = WindowToolbar.empty
    private var identifiers: [NSToolbarItem.Identifier] = []
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var searchTexts: [String: Binding<String>] = [:]
    private var searchItems: [String: NSSearchToolbarItem] = [:]
    private var segmentControls: [String: NSSegmentedControl] = [:]
    private var pickers: [String: (group: NSToolbarItemGroup, choices: [WindowToolbarItem.Choice])] = [:]
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
        let identifiers = Self.identifiers(for: next)
        // A group's choices are fixed once it is made, so a picker offering others is a new toolbar too.
        guard identifiers == self.identifiers, !allItems(next).contains(where: reshapesPicker) else {
            self.identifiers = identifiers
            install()
            return
        }
        for item in allItems(next) { refresh(item) }
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
        // The list's section holds nothing: the window's buttons are over it.
        var identifiers: [NSToolbarItem.Identifier] = [.listSeparator]
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
            identifiers.append(.paneSeparator)
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
        guard case .picker(_, let choices, _, _) = item.style, let built = pickers[item.id]?.choices else { return false }
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
        case .picker(let label, let choices, let selected, let select):
            segmentActions[item.id] = select
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
        if identifier == .listSeparator || identifier == .paneSeparator {
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView,
                                                  dividerIndex: identifier == .listSeparator ? 0 : 1)
        }
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
        case .picker(let label, let choices, let selected, let select):
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
            guard split === splitView else { return }
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
              let section = screenColumn else { return }
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

    /// The screen's column, between the list and the context pane: the section the middle is
    /// centred in.
    private var screenColumn: NSView? {
        guard let splitView, splitView.arrangedSubviews.count > 1 else { return nil }
        return splitView.arrangedSubviews[1]
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

    @objc private func searchFieldChanged(_ field: NSSearchField) {
        guard let id = field.identifier?.rawValue, let text = searchTexts[id], text.wrappedValue != field.stringValue else { return }
        text.wrappedValue = field.stringValue
    }
}

/// The width free after the toolbar's leading items, from `MainToolbarController`. A leading item
/// may draw into it, as the build title does its session name, but nothing measured may depend on
/// it: an item that grew with it would take the room it was told of.
@MainActor @Observable final class ToolbarRoom {
    var afterLeading: CGFloat = 0
}

private extension NSToolbarItem.Identifier {
    static let leadingBalance = Self("center-balance-leading")
    static let trailingBalance = Self("center-balance-trailing")
    static let roomSpacer = Self("leading-room")
    /// The dividers of the card's columns: between the list and the screen, and the screen and the pane.
    static let listSeparator = Self("list-separator")
    static let paneSeparator = Self("pane-separator")
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
