import AppKit
import SwiftUI

/// The icon-only strip at the sidebar's leading edge, on the sidebar's own glass. From the top:
/// one icon per sidebar list (`SidebarMode`); Settings is at the bottom. Picking a list changes
/// what the sidebar lists, not what the window shows. The icons are fixed: nothing adds to them,
/// removes one or reorders them.
struct SidebarRail: View {
    let mode: SidebarMode
    var onSelect: (SidebarMode) -> Void = { _ in }
    var onSettings: () -> Void = {}

    /// An icon's plate, square.
    static let tile: CGFloat = 40

    var body: some View {
        VStack(spacing: 8) {
            ForEach(SidebarMode.allCases) { item in
                SidebarRailButton(symbol: item.symbol, title: item.title, selected: item == mode) { onSelect(item) }
                    .accessibilityIdentifier("sidebar-rail:\(item.rawValue)")
            }
            Spacer(minLength: 0)
            SidebarRailButton(symbol: "gearshape", title: String(localized: "Settings"), selected: false, action: onSettings)
        }
        // The first icon is centred on the list's first row: a plate taller than a row starts
        // that much above it.
        .padding(.top, SidebarMetrics.topInset + (SidebarMetrics.rowHeight - Self.tile) / 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sidebar-rail")
    }
}

/// One of the rail's icons: a system symbol, on a plate only while the pointer is over it. The
/// selected one is in the text's full colour and has no background; the rest are the grey of a
/// row's symbol. Its title is its tooltip and its accessibility name.
private struct SidebarRailButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    /// The plate is the pointer's, not the selection's: selection is the icon's colour alone.
    private var fill: Color { hovered ? Color(nsColor: SidebarPalette.hover) : .clear }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color(nsColor: selected ? SidebarPalette.text : SidebarPalette.icon))
                .frame(width: SidebarRail.tile, height: SidebarRail.tile)
                .background(RoundedRectangle(cornerRadius: 10).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
