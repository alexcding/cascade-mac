import SwiftUI

/// The sample at the top of Terminal and Text Editor. It opens in the appearance the app is in,
/// so it shows what the surface shows now; the switch looks at the other appearance's theme
/// without changing a setting.
struct SettingsPreviewSection<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: (_ dark: Bool) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var sampleDark: Bool?

    private var showsDark: Bool { sampleDark ?? (colorScheme == .dark) }

    var body: some View {
        Section("Preview") {
            content(showsDark)
                .environment(\.colorScheme, showsDark ? .dark : .light)
                .overlay(alignment: .topTrailing) {
                    Picker("Preview appearance", selection: Binding(get: { showsDark }, set: { sampleDark = $0 })) {
                        Label("Light", systemImage: "sun.max").tag(false)
                        Label("Dark", systemImage: "moon").tag(true)
                    }
                    .pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden().fixedSize()
                    .padding(8)
                    .help("Preview the light or the dark theme")
                    .accessibilityIdentifier("settings-\(identifier)-preview-appearance")
                }
                .listRowInsets(EdgeInsets())
        }
    }
}

extension CodeFont {
    /// The SwiftUI font a settings sample is drawn in.
    var sampleFont: Font {
        family.isEmpty ? .system(size: CGFloat(size), design: .monospaced) : .custom(family, size: CGFloat(size))
    }
}
