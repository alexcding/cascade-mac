import SwiftUI

/// The page name at the toolbar's leading edge, drawn flat with no glass capsule and in the
/// window title's own face: a unified toolbar sets its title in 15-point semibold, in the label
/// colour (measured from an `NSWindow` with `titleVisibility = .visible`). The window's own title
/// is hidden, so every screen names itself in its toolbar. An optional accessory (a brand icon,
/// say) sits before the title.
struct PageTitle<Accessory: View>: View {
    let title: String
    /// A session's title is a branch name or a PR subject, far longer than "Settings" or a
    /// project name, so that screen asks for a smaller one.
    let font: Font
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, font: Font = .windowTitle, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.font = font
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            accessory()
            Text(title).font(font).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

extension PageTitle where Accessory == EmptyView {
    init(title: String, font: Font = .windowTitle) { self.init(title: title, font: font) { EmptyView() } }
}

extension Font {
    /// The unified toolbar's title face: 15-point semibold, as `NSWindow` sets its visible title.
    static let windowTitle = Font.system(size: 15, weight: .semibold)
}
