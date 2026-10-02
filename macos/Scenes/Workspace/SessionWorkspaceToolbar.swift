import SwiftUI

/// The toolbar of a workspace, a session's or the scratch terminal's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls in the middle. Beside a
/// terminal the pane's own section is the pane picker alone — Tabs, Diff, Simulator — at the
/// window's edge, which also shows and hides the pane; the pane draws its tabs or Diff's controls
/// itself, under the toolbar (`SessionWorkspacePane`).
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        if let driver = model.agentDriver {
            toolbar.center = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
        }
        if model.showsTerminal {
            // The picker alone, pane open or shut: the pane draws its tabs or Diff's controls in its
            // own title-bar zone (`SessionWorkspacePane`), so showing or hiding it changes no item,
            // and the toolbar's items keep pace with the divider as it slides.
            toolbar.pane = [panePicker]
        }
        return toolbar
    }

    /// The pane's sections, always as segments of symbols, and kept when the toolbar is short of
    /// room. The shown one is selected only while the pane is open; choosing it again hides the
    /// pane. The toolbar measures its width for the pane's own bar to keep clear of (`ToolbarRoom`).
    private var panePicker: WindowToolbarItem {
        let sections = model.paneSections
        let shown = model.showsPage ? model.shownSection.flatMap { sections.firstIndex(of: $0) } : nil
        return .picker("pane-picker", label: String(localized: "Pane"),
                       // The shown one stays clickable: it is how the pane is hidden.
                       choices: sections.map { .init(title: $0.title, symbol: $0.symbol,
                                                     enabled: model.canShowSection($0) || $0 == model.shownSection) },
                       selected: shown ?? -1, toggles: true, priority: .high) { index in
            if sections.indices.contains(index) { model.toggleSection(sections[index]) }
        }
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
