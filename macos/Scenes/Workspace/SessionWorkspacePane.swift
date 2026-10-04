import SwiftUI

/// A session's context pane, beside its terminal: the window's inspector column, which reaches the
/// window's top (`MainSplitViewController`). The pane draws its tab strip in the title-bar zone, as
/// Xcode's inspector does — AppKit reports the zone as the safe area — clear of the toolbar's pane
/// toggle at its trailing end. The strip is part of the column, so it slides with it, and showing
/// or hiding the pane changes no toolbar item. Over a web page the next row is its navigation and
/// address, as ChatGPT's is, the field's suggestions hanging under it over the page; over Diff,
/// its review controls.
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    /// What the toolbar's pane toggle takes of the zone's trailing end, and a gap before it. The
    /// system's own item has no view to measure: its size on macOS 26, about 36.5pt and 8pt from the
    /// window's edge.
    private static let toggleInset: CGFloat = 8 + 36.5 + 12

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                BrowserCompactTabBar(context: context, model: model,
                                     placement: .titleBar(height: proxy.safeAreaInsets.top, trailingInset: Self.toggleInset), part: .tabs)
                if model.showsChanges {
                    ReviewBar(context: context, diff: model.diff)
                    Divider()
                } else if context.activePage != nil {
                    BrowserCompactTabBar(context: context, model: model, part: .address)
                    Divider()
                }
                SessionWorkspaceContextBody(context: context, model: model)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: model.simulatorPreview == nil, initial: true) { _, ended in if ended { model.leaveEndedSimulator() } }
    }
}
