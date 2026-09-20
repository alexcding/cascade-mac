import SwiftUI

/// Toolbar for a session workspace: IDE icon and title flat at the leading edge, the agent's
/// controls grouped in the centre, run controls in a glass container, session actions trailing.
struct SessionWorkspaceToolbar: ToolbarContent {
    let model: SessionWorkspaceViewModel

    var body: some ToolbarContent {
        // A session always shows its terminal, so the bar never fills the title-bar zone here.
        if model.showsBuildActions {
            // Run keeps the system's glass; the title beside it stays flat.
            ToolbarItem(placement: .navigation) { SessionWorkspaceRunButton(model: model) }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { SessionWorkspaceBuildTitle(model: model) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { SessionWorkspaceBuildTitle(model: model) }
            }
        } else if !model.fillsTitleBar {
            PageTitleToolbarItem(title: model.title, font: .headline) {
                if model.session != nil {
                    SessionWorkspaceEditorButton(model: model)
                } else if let url = model.activePageURL {
                    FaviconImage(url: url, size: 18)
                }
            }
        }
        // The agent's model, effort and context, as one group in the centre.
        if let driver = model.agentDriver {
            ToolbarItem(placement: .principal) { SessionAgentControlsView(model: model, driver: driver) }
        }
        // With the bar in the title-bar zone, Create Session lives in the bar instead.
        if model.offersPageSession, !model.fillsTitleBar {
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            ToolbarItem(placement: .primaryAction) {
                Button("Create Session", systemImage: "terminal", action: model.createSession)
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canCreateSession)
                    .help("Start an agent session for this page in its project")
            }
        }
        let showsRunGroup = model.session != nil && model.workflow != nil
        if showsRunGroup {
            // Flat, like the title at the other end: the run controls carry their own
            // shapes, and a glass capsule around them only boxes in what is already legible.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) { SessionWorkspaceLeadingToolbar(model: model) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { SessionWorkspaceLeadingToolbar(model: model) }
            }
        }
        if model.showsModePicker {
            // One flexible spacer per trailing run, or two of them split the free space and
            // leave the run controls stranded mid-bar. When that group is absent, this is the
            // spacer that does the pushing.
            if #available(macOS 26.0, *) { ToolbarSpacer(showsRunGroup ? .fixed : .flexible) }
            ToolbarItem(placement: .primaryAction) { SessionWorkspaceModePicker(model: model) }
        }
        if model.showsTerminal {
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
            ToolbarItem(placement: .primaryAction) { SessionWorkspaceContextToggle(model: model) }
        }
    }
}
