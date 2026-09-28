import SwiftUI

/// A file's icon from the installed VS Code icon theme chosen in Settings, `size` points square,
/// in the variant for the appearance it is shown in. With no theme it is `fallback`, the symbol
/// that place drew before themes existed.
struct FileIcon<Fallback: View>: View {
    let name: String
    var size: CGFloat = 16
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = FileIconStore.shared.image(forFile: name, light: colorScheme == .light) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            fallback()
        }
    }
}
