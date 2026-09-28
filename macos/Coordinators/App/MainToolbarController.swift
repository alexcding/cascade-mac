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
/// Nothing in the toolbar animates. A toolbar told to change its items slides the old ones out and
/// the new ones in, even inside a zero-length animation, so a new set of items is a new toolbar,
/// installed in the window at once. While the set stays the same, items are updated in place, never
/// rebuilt, so the state inside them (a focused field, an open menu) survives.
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
    private var segmentActions: [String: (Int) -> Void] = [:]

    init(describe: @escaping () -> WindowToolbar) {
        self.describe = describe
        super.init()
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
        hosts = [:]
        searchTexts = [:]
        searchItems = [:]
        segmentControls = [:]
        pickers = [:]
        segmentActions = [:]
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
        if !toolbar.leading.contains(where: \.fills) { identifiers.append(.flexibleSpace) }
        if !toolbar.center.isEmpty { identifiers += run(toolbar.center) + [.flexibleSpace] }
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
            hosts[item.id]?.rootView = item.content
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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
            let host = NSHostingView(rootView: spec.content)
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
            // Glass is the toolbar's own capsule; a plain item or a bar draws its own shapes.
            if case .glass = spec.style {} else { item.isBordered = false }
            hosts[spec.id] = host
        }
        item.visibilityPriority = spec.priority
        return item
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
