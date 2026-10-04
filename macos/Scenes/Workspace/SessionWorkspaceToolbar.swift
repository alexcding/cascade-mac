import SwiftUI

/// The toolbar of a workspace, a session's or the scratch terminal's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls in the middle. Beside a
/// terminal the pane's own section is the system's inspector toggle alone, at the window's edge,
/// which shows and hides the pane; the pane draws its tabs itself, under the toolbar
/// (`SessionWorkspacePane`).
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        if let driver = model.agentDriver {
            toolbar.center = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
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
