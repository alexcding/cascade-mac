import SwiftUI

/// A session's context pane, beside its terminal: the window's inspector column
/// (`MainSplitViewController`), under the toolbar's pane section, which holds its tabs
/// (`SessionWorkspaceToolbar`); the pane's content keeps to the safe area below it. Over a web page the pane's top row is its navigation and address,
/// as ChatGPT's is; the field's suggestions hang under it, over the page. Down its trailing edge
/// a rail switches it between the Browser, Files, Diff and the Simulator, as Xcode's inspector
/// tabs do; the toolbar's strip shows the section's own tabs.
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if context.activePage != nil {
                    BrowserCompactTabBar(context: context, model: model, part: .address)
                    Divider()
                }
                SessionWorkspaceContextBody(context: context, model: model)
            }
            if model.railSections.count > 1 {
                Divider()
                SessionWorkspacePaneRail(context: context, model: model)
            }
        }
        .onChange(of: model.simulatorPreview == nil, initial: true) { _, ended in if ended { model.leaveEndedSimulator() } }
    }
}

/// The pane's icon rail: one button per section the workspace offers, drawn as refine-ui's
/// sidebar rail is — the shown section is its symbol filled in the text's full colour, the rest
/// outlines in the sidebar's icon grey, and a plate only under the pointer. The Simulator is
/// marked while it streams.
struct SessionWorkspacePaneRail: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    static let width: CGFloat = 50
    /// An icon's plate, square.
    static let tile: CGFloat = 40

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.railSections, id: \.self) { section in
                SessionWorkspaceRailButton(section: section, selected: model.shownSection == section,
                                           enabled: model.canShowSection(section)) { model.showSection(section) }
                    .overlay(alignment: .topTrailing) { mark(section) }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pane"))
        .accessibilityIdentifier("workspace-pane-rail")
    }

    @ViewBuilder private func mark(_ section: WorkspaceSection) -> some View {
        switch section {
        case .simulator:
            if case .live = model.simulatorPreview?.state {
                Circle().fill(Theme.success).frame(width: 6, height: 6).offset(x: -5, y: 5).allowsHitTesting(false)
            }
        case .browser, .files, .diff: EmptyView()
        }
    }
}

/// One of the rail's icons. Selection is the symbol's colour and its filled form, monochrome; a
/// symbol with no filled form is drawn hierarchical instead, its layers in shades of the one
/// colour. Never a background: the plate is the pointer's.
private struct SessionWorkspaceRailButton: View {
    let section: WorkspaceSection
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    private var hasFill: Bool { section.hasFilledSymbol }
    /// Selected, the symbol's filled form where there is one, else the symbol as it is: a variant
    /// asked for that does not exist is not always the plain symbol.
    private var symbol: String { selected && hasFill ? section.symbol + ".fill" : section.symbol }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(selected && !hasFill ? .hierarchical : .monochrome)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Color(nsColor: selected ? SidebarPalette.text : SidebarPalette.icon))
                .frame(width: SessionWorkspacePaneRail.tile, height: SessionWorkspacePaneRail.tile)
                .background(shape.fill(hovered && enabled ? Theme.surfaceHover : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("workspace-pane-rail-\(section.rawValue)")
    }
}
