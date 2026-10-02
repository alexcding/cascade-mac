import SwiftUI

/// A session's context pane, beside its terminal: the window's inspector column, which reaches the
/// window's top (`MainSplitViewController`). The pane draws its own bar in the title-bar zone, as
/// Xcode's inspector does — AppKit reports the zone as the safe area — clear of the toolbar's pane
/// picker at its trailing end: the tabs' strip, or Diff's review controls. The bar is part of the
/// column, so it slides with it, and showing or hiding the pane changes no toolbar item. Over a
/// web page the next row is its navigation and address, as ChatGPT's is; the field's suggestions
/// hang under it, over the page.
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    @Environment(ToolbarRoom.self) private var room: ToolbarRoom?

    /// What the toolbar's picker takes of the zone's trailing end, as the toolbar measured it, and a
    /// gap before it. Until it is measured, its size as measured on macOS 26: about 36.5pt a segment
    /// and 8pt from the window's edge.
    private var pickerInset: CGFloat {
        let measured = room?.paneTrailing ?? 0
        return (measured > 0 ? measured : 8 + 36.5 * CGFloat(model.paneSections.count)) + 12
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                bar(height: proxy.safeAreaInsets.top)
                if context.activePage != nil, model.shownSection == .browser {
                    BrowserCompactTabBar(context: context, model: model, part: .address)
                    Divider()
                }
                SessionWorkspaceContextBody(context: context, model: model)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: model.simulatorPreview == nil, initial: true) { _, ended in if ended { model.leaveEndedSimulator() } }
    }

    /// The section's bar, pane open or shut: a shut pane keeps its last section, so its bar is there
    /// as the column slides shut and back open, not blinking in after it.
    @ViewBuilder private func bar(height: CGFloat) -> some View {
        switch model.shownSection {
        case .diff?:
            ReviewBar(context: context, diff: model.diff, inTitleBar: true)
                .padding(.leading, 12).padding(.trailing, pickerInset)
                .frame(height: height)
        case .browser?, nil:
            BrowserCompactTabBar(context: context, model: model, placement: .titleBar(height: height, trailingInset: pickerInset), part: .tabs)
        case .simulator?:
            Color.clear.frame(height: height)
        }
    }
}
