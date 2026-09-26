import SwiftUI

/// A session's context pane, beside its terminal: the window's inspector column, which reaches the
/// window's top (`MainSplitViewController`). The pane draws its tab bar in the title-bar zone, as
/// Xcode's inspector draws its own — AppKit reports the zone as the safe area — and the panel sits
/// under it. The bar is part of the column, so it slides with it, and the toolbar's pane section
/// holds only the toggle (`SessionWorkspaceToolbar`).
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                bar(height: proxy.safeAreaInsets.top)
                SessionWorkspaceContextBody(context: context, model: model)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// The mode's bar, pane open or closed: a closed pane keeps its last mode, so its bar is there
    /// as the column slides shut and back open, not blinking in after it.
    @ViewBuilder private func bar(height: CGFloat) -> some View {
        if model.mode == .browser, !model.showsChanges {
            BrowserCompactTabBar(context: context, model: model, placement: .titleBar(height: height))
        } else if model.mode == .files, !model.showsChanges {
            FilesCompactTabBar(context: context, model: model, placement: .titleBar(height: height))
        } else {
            Color.clear.frame(height: height)
        }
    }
}
