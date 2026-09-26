import SwiftUI

/// The toolbar of a workspace, a session's or a sidebar tab's: the IDE icon and title, or the run
/// button and build title, flat at the leading edge; the agent's controls in the middle; the run
/// controls, the mode picker and the pane toggle trailing, against the context pane when it is open. The pane's
/// own section holds its tab bar and Hide. A sidebar tab browsing the web has no title: its tab bar
/// is the whole section, as Safari's is.
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
        if model.session != nil, model.workflow != nil {
            // Flat, like the title at the other end: the run controls carry their own shapes, and a
            // glass capsule around them only boxes in what is already legible.
            toolbar.trailing.append(item("run-group", style: .plain) { SessionWorkspaceLeadingToolbar(model: model) })
        }
        if let driver = model.agentDriver {
            toolbar.center = [item("agent") { SessionAgentControlsView(model: model, driver: driver) }]
        }
        if model.showsModePicker {
            toolbar.trailing.append(item("mode-picker") { SessionWorkspaceModePicker(model: model) })
        }
        if model.showsInspector {
            toolbar.pane = pane
        } else if model.showsTerminal {
            // Shows the pane; once shown, Hide is the last item of the pane's own section.
            toolbar.trailing.append(item("show-pane") { SessionWorkspaceContextToggle(model: model) })
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

    private var pane: [WindowToolbarItem] {
        var items: [WindowToolbarItem] = []
        if model.showsBrowser {
            items.append(item("pane-bar", style: .fill) { BrowserCompactTabBar(context: context, model: model, placement: .toolbar) })
        } else if model.showsFiles {
            items.append(item("pane-bar", style: .fill) { FilesCompactTabBar(context: context, model: model, placement: .toolbar) })
        }
        items.append(item("hide-pane") { SessionWorkspaceContextToggle(model: model) })
        return items
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
