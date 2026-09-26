import SwiftUI

/// The page name at the toolbar's leading edge, drawn flat with no glass capsule. The
/// window's own title is hidden, so every screen names itself in its toolbar. An
/// optional accessory (a brand icon, say) sits before the title.
struct PageTitle<Accessory: View>: View {
    let title: String
    /// A session's title is a branch name or a PR subject, far longer than "Settings" or a
    /// project name, so that screen asks for a smaller one.
    let font: Font
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, font: Font = .title3, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.font = font
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            accessory()
            Text(title).font(font).fontWeight(.regular).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

extension PageTitle where Accessory == EmptyView {
    init(title: String, font: Font = .title3) { self.init(title: title, font: font) { EmptyView() } }
}
