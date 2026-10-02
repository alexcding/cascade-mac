import SwiftUI

/// The toolbar of a workspace, a session's or the scratch terminal's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls in the middle; the run
/// controls and the mode picker trailing, against the context pane. Beside a terminal the pane's
/// own section is its toggle alone, at the window's edge whether the pane is open or not: the pane
/// draws its bar itself, in its title-bar zone (`SessionWorkspacePane`), so showing or hiding it
/// changes no item, and the toolbar's items keep pace with the divider as it slides.
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        if let driver = model.agentDriver {
            toolbar.center = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
        }
        if model.showsModePicker {
            toolbar.trailing.append(modePicker)
        }
        if model.showsTerminal {
            toolbar.pane = [item("pane-toggle") { SessionWorkspaceContextToggle(model: model) }]
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

    /// Tabs, Diff and Simulator: segments while the screen's section has room, one pop-up button
    /// with the chosen mode's symbol when it has not.
    private var modePicker: WindowToolbarItem {
        let modes = model.modes
        return .picker("mode-picker",
                       label: String(localized: "Panel"),
                       choices: modes.map { .init(title: $0.title, symbol: $0.symbol, enabled: model.canSelectMode($0)) },
                       selected: modes.firstIndex(of: model.mode) ?? 0) { index in
            if modes.indices.contains(index) { model.selectMode(modes[index]) }
        }
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
