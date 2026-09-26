import SwiftUI

/// The toolbar of a workspace, a session's or a sidebar tab's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls in the middle; the run
/// controls and the mode picker trailing, against the context pane. Beside a terminal the pane's
/// own section is its toggle alone, at the window's edge whether the pane is open or not: the pane
/// draws its bar itself, in its title-bar zone (`SessionWorkspacePane`), so showing or hiding it
/// changes no item, and the toolbar's items keep pace with the divider as it slides. A sidebar tab
/// browsing the web has no title: its tab bar is the whole section, as Safari's is.
@MainActor struct SessionWorkspaceToolbar {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var toolbar: WindowToolbar {
        var toolbar = WindowToolbar(leading: leading)
        if model.offersPageSession, !model.barFillsToolbar {
            toolbar.trailing.append(item("create-session") {
                CreateSessionButton(model: model)
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canCreateSession)
                    .help(String(localized: "Start an agent session for this page in its project"))
            })
        }
        if let driver = model.agentDriver {
            toolbar.center = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
        }
        if model.showsModePicker {
            toolbar.trailing.append(item("mode-picker") { SessionWorkspaceModePicker(model: model) })
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
        if model.barFillsToolbar {
            return [item("page-bar", style: .fill) { BrowserCompactTabBar(context: context, model: model, placement: .toolbar) }]
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

/// Create Session as a dropdown: every click asks which agent runs the session.
struct CreateSessionButton: View {
    let model: SessionWorkspaceViewModel
    var body: some View {
        Menu {
            ForEach(PageRowMenu.agents) { agent in Button(agent.label) { model.createSession(agent: agent) } }
        } label: {
            Label(String(localized: "Create Session"), systemImage: "terminal")
        }
    }
}
