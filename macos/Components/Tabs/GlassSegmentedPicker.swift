import SwiftUI

/// A segmented switch drawn as the compact tab bar is: the options share one pill, and the chosen
/// one wears the raised glass capsule of the selected tab. 32pt tall, the height of the glass
/// buttons it sits beside. An `accessory` — a control that belongs with the options, not a choice
/// among them — follows them inside the same pill, past a hairline.
struct GlassSegmentedPicker<Option: Hashable & Identifiable, Accessory: View>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option
    @ViewBuilder var accessory: () -> Accessory

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
                .background { if selected { ActiveTabCapsule() } }
            }
            if Accessory.self != EmptyView.self {
                Divider().frame(height: 14).padding(.horizontal, 2)
                accessory()
            }
        }
        .padding(2)
        .frame(height: Theme.Size.largeControl)
        .background(Theme.surfaceHover, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
        .fixedSize()
        // To VoiceOver and UI tests it is what it stands for: a segmented control of radio buttons,
        // and the accessory beside it as itself.
        .accessibilityRepresentation {
            HStack {
                Picker(title, selection: $selection) {
                    ForEach(options) { Text(label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                accessory()
            }
        }
    }
}
