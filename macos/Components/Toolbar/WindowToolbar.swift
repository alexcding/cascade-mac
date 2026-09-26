import SwiftUI

/// The main window's toolbar as the screen on show describes it; `MainToolbarController` draws it.
/// The toolbar is split where the window is: the sidebar's section, then the screen's, then the
/// context pane's while one is open, each tracking its divider. A screen names its items from its
/// models, so an item's content stays live without the description being rebuilt.
struct WindowToolbar {
    /// The leading edge of the screen's section: its title, or what stands in for one.
    var leading: [WindowToolbarItem] = []
    /// The middle of the screen's section, between its leading and trailing items, so it moves
    /// with the pane's divider rather than sitting at the window's centre.
    var center: [WindowToolbarItem] = []
    /// The trailing edge of the screen's section, against the pane while one is open.
    var trailing: [WindowToolbarItem] = []
    /// The context pane's section, from its leading edge; nil while no pane is open.
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

    /// The page name, flat at the leading edge: the window's own title is hidden.
    static func title(_ title: String, font: Font = .title3) -> Self {
        Self("title", style: .plain, priority: .high) { PageTitle(title: title, font: font) }
    }
}
