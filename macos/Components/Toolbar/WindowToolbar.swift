import SwiftUI

/// The main window's toolbar as the screen on show describes it; `MainToolbarController` draws it.
/// The toolbar is split where the window is: the sidebar's section, then the screen's, then the
/// context pane's while one is open, each tracking its divider. A screen names its items from its
/// models, so an item's content stays live without the description being rebuilt.
struct WindowToolbar {
    /// The leading edge of the screen's section: its title, or what stands in for one.
    var leading: [WindowToolbarItem] = []
    /// The middle of the screen's section, centred in it however wide its leading and trailing
    /// items are, so it moves with the pane's divider rather than sitting at the window's centre.
    var center: [WindowToolbarItem] = []
    /// The trailing edge of the screen's section, against the pane's.
    var trailing: [WindowToolbarItem] = []
    /// The context pane's section, from its leading edge: nil on a screen with no pane; beside a
    /// terminal it is there whether the pane is open or collapsed, so toggling the pane changes no item.
    var pane: [WindowToolbarItem]?

    static var empty: WindowToolbar { WindowToolbar() }
}

struct WindowToolbarItem: Identifiable {
    enum Style {
        /// In the toolbar's own glass capsule.
        case glass
        /// Drawn as it is, with no capsule: a title, or controls that carry their own shapes.
        case plain
        /// Takes whatever width its section leaves: a compact tab bar, which draws its own glass.
        case fill
        /// The system search field, bound to the screen's query. The text is read as the toolbar is
        /// described, so a query the screen changes itself reaches the field.
        case search(prompt: String, value: String, text: Binding<String>)
        /// The system's toolbar segmented control, one segment per title: AppKit sizes and draws
        /// it, so it is never clipped the way hosted content measured once can be. `selected` is
        /// read as the toolbar is described, like a search field's text.
        case segments(titles: [String], selected: Int, select: (Int) -> Void)
        /// A choice of one as the system's toolbar item group: segments of symbols while the
        /// section has room, one pop-up button showing the chosen symbol when it is short of it.
        /// AppKit decides which, except for choices that toggle, which are always segments. `selected` and each choice's `enabled` are read as the toolbar is
        /// described. One choice is always selected — AppKit ignores -1 here — unless the choices
        /// `toggle`: then none is while `selected` is -1, and clicking the selected one reports it
        /// again rather than leaving it selected, so the caller can turn it off.
        case picker(label: String, choices: [Choice], selected: Int, toggles: Bool, select: (Int) -> Void)
    }

    struct Choice {
        let title: String
        let symbol: String
        var enabled = true
    }

    let id: String
    let style: Style
    let content: AnyView
    /// Kept when the toolbar is short of room; a title outlasts the controls beside it.
    var priority: NSToolbarItem.VisibilityPriority = .standard

    init<Content: View>(_ id: String, style: Style = .glass, priority: NSToolbarItem.VisibilityPriority = .standard,
                        @ViewBuilder content: () -> Content) {
        self.id = id
        self.style = style
        self.priority = priority
        self.content = AnyView(content())
    }

    static func search(_ id: String, prompt: String, text: Binding<String>) -> Self {
        Self(id, style: .search(prompt: prompt, value: text.wrappedValue, text: text)) { EmptyView() }
    }

    /// Tabs as the system's toolbar segmented control. `id` names the item, so a different set of
    /// titles should come with a different id: the toolbar is then rebuilt rather than resized.
    static func segments(_ id: String, titles: [String], selected: Int, priority: NSToolbarItem.VisibilityPriority = .standard,
                         select: @escaping (Int) -> Void) -> Self {
        Self(id, style: .segments(titles: titles, selected: selected, select: select), priority: priority) { EmptyView() }
    }

    /// A choice of one that collapses to a pop-up button when short of room. A different set of
    /// choices rebuilds the toolbar itself, so the id can stay the same.
    static func picker(_ id: String, label: String, choices: [Choice], selected: Int, toggles: Bool = false,
                       priority: NSToolbarItem.VisibilityPriority = .standard, select: @escaping (Int) -> Void) -> Self {
        Self(id, style: .picker(label: label, choices: choices, selected: selected, toggles: toggles, select: select),
             priority: priority) { EmptyView() }
    }

    /// The page name, flat at the leading edge: the window's own title is hidden.
    static func title(_ title: String, font: Font = .title3) -> Self {
        Self("title", style: .plain, priority: .high) { PageTitle(title: title, font: font) }
    }
}
