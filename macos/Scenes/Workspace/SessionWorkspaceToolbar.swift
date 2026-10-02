import SwiftUI

/// The toolbar of a workspace, a session's or the scratch terminal's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls trailing, against the
/// context pane. Beside a terminal the pane's own section holds, while
/// the pane is open, its tabs and then its toggle, as ChatGPT's does — the address and navigation
/// are a row at the top of the pane (`SessionWorkspacePane`); shut, the toggle alone at the
/// window's edge.
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        if let driver = model.agentDriver {
            toolbar.trailing = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
        }
        if model.showsTerminal {
            // Over the Browser or Files the strip of that section's tabs; over Diff its review
            // controls; over the Simulator nothing. Shut, the toggle alone, which brings the pane back.
            let toggle = item("pane-toggle") { SessionWorkspaceContextToggle(model: model) }
            if !model.showsPage || model.shownSection == .simulator {
                toolbar.pane = [toggle]
            } else if model.showsChanges {
                toolbar.pane = [item("pane-review", style: .fill) { ReviewBar(context: context, diff: model.diff, inToolbar: true) }, toggle]
            } else {
                toolbar.pane = [item("pane-bar", style: .fill) { BrowserCompactTabBar(context: context, model: model, placement: .toolbar, part: .tabs) }, toggle]
            }
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
