import AppKit
import SwiftUI

/// The pinned-tabs grid right under Dashboard, after Arc's Favorites: one pinned tab is a
/// full-width row with its favicon and title; two to four share the row as equal favicon tiles,
/// and from five on the grid wraps at four columns. Titles move to tooltips once there is more
/// than one tile. The grid is one outline row; the tiles handle their own hover, selection and menu.
struct SidebarPinnedTabsGrid: View {
    let tabs: [SidebarPinnedTab]
    let selectedID: String?
    var onSelect: (String) -> Void = { _ in }
    var onUnpin: (String) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }

    static let columns = 4
    static let tileHeight: CGFloat = 36
    static let gap: CGFloat = 6
    /// The Dashboard row's plate is inset 1pt, so this many points above the first tiles gives the
    /// same visible gap as between two tile rows. Below, the next heading brings its own air.
    private static let topPadding: CGFloat = gap - 1
    private static let bottomPadding: CGFloat = 2

    /// The outline row height for `count` pinned tabs.
    static func height(count: Int) -> CGFloat {
        let rows = CGFloat(max(1, (count + columns - 1) / columns))
        return rows * tileHeight + (rows - 1) * gap + topPadding + bottomPadding
    }

    var body: some View {
        Group {
            if tabs.count == 1, let tab = tabs.first {
                tile(tab, showsTitle: true).frame(height: Self.tileHeight)
            } else {
                // As Arc's Favorites: up to four tabs share the full row width, so two tiles are
                // halves and three are thirds; from five on the grid settles at four columns.
                let columns = Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: min(tabs.count, Self.columns))
                LazyVGrid(columns: columns, spacing: Self.gap) {
                    ForEach(tabs) { tab in tile(tab, showsTitle: false).frame(height: Self.tileHeight) }
                }
            }
        }
        .padding(.top, Self.topPadding).padding(.bottom, Self.bottomPadding)
        .accessibilityIdentifier("pinned-tabs")
    }

    private func tile(_ tab: SidebarPinnedTab, showsTitle: Bool) -> some View {
        SidebarPinnedTabTile(tab: tab, selected: tab.id == selectedID, showsTitle: showsTitle,
                             select: { onSelect(tab.id) }, unpin: { onUnpin(tab.id) }, close: { onClose(tab.id) })
    }
}

private struct SidebarPinnedTabTile: View {
    let tab: SidebarPinnedTab
    let selected: Bool
    let showsTitle: Bool
    let select: () -> Void
    let unpin: () -> Void
    let close: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if selected { return Color(nsColor: SidebarPalette.selected) }
        if hovered { return Color(nsColor: SidebarPalette.hover) }
        return Color(nsColor: SidebarPalette.text).opacity(0.04)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                SidebarPinnedTabIcon(icon: tab.icon, url: tab.url, size: showsTitle ? 18 : 20)
                if showsTitle {
                    Text(tab.title)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .foregroundStyle(Color(nsColor: hovered || selected ? SidebarPalette.text : SidebarPalette.navText))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, showsTitle ? SidebarMetrics.plateOutset + SidebarMetrics.leading : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(showsTitle ? tab.url : tab.title)
        .accessibilityIdentifier("pinned-tab:\(tab.id)")
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Copy Link") { SidebarLinkActions.copy(tab.url) }
            Divider()
            Button("Unpin Tab", action: unpin)
            Button("Close Tab", action: close)
        }
    }
}

/// The same leading mark a Tabs row shows: the PR author's avatar, the Jira mark, or the
/// domain favicon with a globe until one loads.
private struct SidebarPinnedTabIcon: View {
    let icon: SidebarTabIcon
    let url: String
    let size: CGFloat

    var body: some View {
        switch icon.kind {
        case "github":
            if let avatar = SidebarAvatars.image(login: icon.login, frozen: icon.avatar) {
                Image(nsImage: avatar).resizable().scaledToFit().frame(width: size, height: size).clipShape(Circle())
            } else {
                brand("github")
            }
        case "jira": brand("jira")
        default: FaviconImage(url: url, size: size)
        }
    }

    private func brand(_ name: String) -> some View {
        Group {
            if let image = SidebarIcons.brand(name, size: size) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color(nsColor: SidebarPalette.navText))
    }
}

/// The outline cell that hosts the grid. One instance per pinned-tabs row; the row itself is
/// neither selectable nor hoverable, the tiles are.
@MainActor final class SidebarPinnedTabsCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-pinned-tabs")
    private let hosting: NSHostingView<SidebarPinnedTabsGrid>

    override init(frame frameRect: NSRect) {
        hosting = NSHostingView(rootView: SidebarPinnedTabsGrid(tabs: [], selectedID: nil))
        super.init(frame: frameRect)
        hosting.sizingOptions = []
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ grid: SidebarPinnedTabsGrid) { hosting.rootView = grid }

    override func layout() {
        super.layout()
        hosting.frame = bounds.insetBy(dx: -SidebarMetrics.plateOutset, dy: 0)
    }
}
