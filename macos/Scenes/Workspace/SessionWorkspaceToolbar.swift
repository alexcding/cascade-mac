import SwiftUI

/// The toolbar of a workspace, a session's or the scratch terminal's: the IDE icon and title, or
/// Run with the run destination and the build title, flat at the leading edge; Terminal / Chat at the trailing edge, and
/// nothing in the middle: the agent shows its model and context itself. Beside a terminal the
/// pane's own section is the system's inspector toggle alone, at the window's edge,
/// which shows and hides the pane; the pane draws its tabs itself, under the toolbar
/// (`SessionWorkspacePane`).
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        // Only a session that runs an agent has a conversation to show; a shell has none.
        if model.canShowChat, model.agentDriver != nil {
            toolbar.trailing = [.picker("agent-mode", label: String(localized: "Terminal / Chat"), choices: [
                .init(title: String(localized: "Terminal"), symbol: "terminal"),
                .init(title: String(localized: "Chat"), symbol: "bubble.left.and.bubble.right"),
            ], selected: model.showsChat ? 1 : 0) { model.setChatShown($0 == 1) }]
        }
        if model.showsTerminal {
            // The toggle alone, pane open or shut: the pane draws its tabs in its own title-bar zone
            // (`SessionWorkspacePane`), so showing or hiding it changes no item, and the toolbar's
            // items keep pace with the divider as it slides.
            toolbar.pane = []
        }
        return toolbar
    }

    private var leading: [WindowToolbarItem] {
        if model.showsBuildActions {
            return [
                item("run") { SessionWorkspaceRunButton(model: model) },
                item("build-title", style: .plain, priority: .high) { SessionWorkspaceBuildTitle(model: model) },
            ]
        }
        return [item("title", style: .plain, priority: .high) {
            PageTitle(title: model.title, font: .headline) {
                if model.session != nil {
                    SessionWorkspaceEditorButton(model: model)
                } else if let url = model.activePageURL {
                    FaviconImage(url: url, size: 18)
                }
            }
        }]
    }

    /// An item whose content belongs to this workspace. Another workspace's toolbar can have the
    /// same items, and AppKit keeps an item across the switch: keyed to the context, the content is
    /// a new view for the new workspace, and the last one's leaves — releasing its field and its
    /// suggestions — rather than carrying on with the next workspace's models.
    private func item<Content: View>(_ id: String, style: WindowToolbarItem.Style = .glass,
                                     priority: NSToolbarItem.VisibilityPriority = .standard,
                                     @ViewBuilder content: () -> Content) -> WindowToolbarItem {
        WindowToolbarItem(id, style: style, priority: priority) { content().id(context.id) }
    }
}
