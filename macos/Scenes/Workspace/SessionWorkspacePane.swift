import SwiftUI

/// A session's context pane, beside its terminal: the last column of the window's card
/// (`MainSplitViewController`), under the toolbar's pane section. The pane draws its tab bar at
/// its own top and the panel sits under it; the toolbar's pane section is its toggle alone
/// (`SessionWorkspaceToolbar`). The bar is part of the column, so it slides with it.
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            SessionWorkspaceContextBody(context: context, model: model)
        }
    }

    /// The mode's bar, pane open or closed: a closed pane keeps its last mode, so its bar is there
    /// as the column slides shut and back open, not blinking in after it. Any other mode has none.
    @ViewBuilder private var bar: some View {
        if model.mode == .browser, !model.showsChanges {
            BrowserCompactTabBar(context: context, model: model, placement: .paneBar)
        }
    }
}
