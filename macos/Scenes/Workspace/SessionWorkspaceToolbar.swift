import SwiftUI

/// The toolbar of a workspace, a session's or the scratch terminal's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls in the middle. Beside a
/// terminal the pane's own section ends at the window's edge in the pane picker — Browser, Files,
/// Diff, Simulator — which also shows and hides the pane. While the pane is open the section holds,
/// before the picker, that section's tabs, as ChatGPT's does — the address and navigation are a row
/// at the top of the pane (`SessionWorkspacePane`) — or over Diff its review controls; shut, the
/// picker alone.
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        if let driver = model.agentDriver {
            toolbar.center = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
        }
        if model.showsTerminal {
            // Over the Browser or Files the strip of that section's tabs, over Diff its review
            // controls, over the Simulator nothing; then the picker, at the window's edge. Shut,
            // the picker alone.
            if model.showsPage, model.showsChanges {
                toolbar.pane = [item("pane-review", style: .fill) { ReviewBar(context: context, diff: model.diff, inToolbar: true) }, panePicker]
            } else if model.showsPage, model.shownSection != .simulator {
                toolbar.pane = [item("pane-bar", style: .fill) { BrowserCompactTabBar(context: context, model: model, placement: .toolbar, part: .tabs) }, panePicker]
            } else {
                toolbar.pane = [panePicker]
            }
        }
        return toolbar
    }

    /// The pane's sections, always as segments of symbols, and kept when the toolbar is short of
    /// room. The shown one is selected only while the pane is open; choosing it again hides the pane.
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
