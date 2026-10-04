import AppKit
import SwiftUI

/// A segmented switch with no glass: the options share one grey pill, and the chosen one is a
/// `RaisedCapsule`, a shade lighter with an outline round it. As tall as the toolbar's own controls
/// (`Theme.Size.toolbarControl`), so it lines up with the toolbar's controls.
struct SegmentedPicker<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                // The padded capsule is the label, so all of it takes the click.
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.textSecondary))
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background { if selected { RaisedCapsule() } }
            }
        }
        .modifier(SegmentPill())
        .fixedSize()
        // To VoiceOver and UI tests it is what it stands for: a segmented control of radio buttons.
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Buttons that go together, beside a segmented pill: one capsule as tall as the pill, on the
/// pane's own colour with an outline round it and a divider between them — the run controls'
/// shape, without glass. A grey fill read as disabled. The outline is one display pixel, as the
/// bar's other buttons' are (`barGlass`, outlined).
struct ButtonGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 2)
            .frame(height: Theme.Size.toolbarControl)
            .backdropFill(Theme.paneBackground, in: Capsule())
            .pixelOutline(Capsule())
    }
}

/// The pill a segmented switch sits in: the toolbar's control height, the theme's hover grey, a
/// one-pixel outline round it.
private struct SegmentPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(CompactTabMetrics.pillInset)
            .frame(height: Theme.Size.toolbarControl)
            .backdropFill(Theme.surfaceHover, in: Capsule())
            .pixelOutline(Capsule())
    }
}

/// The chosen option inside a segment pill: a shade lighter than the pill with an outline round it
/// and no shadow, as the selected tab's glass reads when flattened.
struct RaisedCapsule: View {
    /// White over the pill: most of it in light, a touch in dark, where the pill is already grey.
    private static let lift = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.7)
    })

    var body: some View {
        Capsule().fill(Self.lift).pixelOutline(Capsule())
    }
}
