import SwiftUI

/// A session's context pane, beside its terminal: the window's inspector column
/// (`MainSplitViewController`), under the toolbar's pane section, which holds its tabs
/// (`SessionWorkspaceToolbar`); the pane's content keeps to the safe area below it. Over a web page the pane's top row is its navigation and address,
/// as ChatGPT's is; the field's suggestions hang under it, over the page. The toolbar's pane picker
/// switches it between the Browser, Files, Diff and the Simulator; the toolbar's strip shows the
/// section's own tabs.
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            if context.activePage != nil {
                BrowserCompactTabBar(context: context, model: model, part: .address)
                Divider()
            }
            SessionWorkspaceContextBody(context: context, model: model)
        }
        .onChange(of: model.simulatorPreview == nil, initial: true) { _, ended in if ended { model.leaveEndedSimulator() } }
    }
}
