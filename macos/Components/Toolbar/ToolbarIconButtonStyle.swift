import SwiftUI

/// An icon button as the toolbar draws its own: the glyph alone, in a square as tall as the toolbar's
/// glass, which the glass then wraps into a circle. Toolbar items host their SwiftUI content
/// (`MainToolbarController`), and SwiftUI, not knowing it is in a toolbar there, would give a button
/// its standard bezel inside the glass — so a toolbar's icon button asks for this.
struct ToolbarIconButtonStyle: ButtonStyle {
    /// The height of the glass the toolbar puts around an item.
    static let side: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.textTertiary))
                .frame(width: ToolbarIconButtonStyle.side, height: ToolbarIconButtonStyle.side)
                .contentShape(Circle())
                .opacity(configuration.isPressed ? 0.5 : 1)
        }
    }
}

extension ButtonStyle where Self == ToolbarIconButtonStyle {
    static var toolbarIcon: ToolbarIconButtonStyle { ToolbarIconButtonStyle() }
}
