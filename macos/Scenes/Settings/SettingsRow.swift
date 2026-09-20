import SwiftUI

/// A settings row: title, optional explanatory sub-text, and the control.
///
/// Deliberately thin. `LabeledContent` already renders a second `Text` in its label as the
/// secondary description, and a `.grouped` Form already owns label/control alignment and the row
/// insets — so this adds no padding, no fixed widths and no fonts of its own. Overriding those is
/// what makes a row stop lining up with its neighbours.
struct SettingsRow<Content: View>: View {
    let title: String
    var caption: String?
    /// Makes the title a link: accent-coloured, not underlined, the rest of the row unchanged.
    var titleAction: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        LabeledContent {
            content
        } label: {
            if let titleAction { Button(title, action: titleAction).buttonStyle(.link) } else { Text(title) }
            if let caption { Text(caption) }
        }
    }
}

/// A section header carrying a trailing action — the Refresh buttons on the CLI, Resource usage
/// and Database groups.
struct SettingsSectionHeader<Trailing: View>: View {
    let title: String
    var busy = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            trailing
        }
    }
}

/// A secret field with an eye button that flips it to plain text (the web's `.input-reveal`).
struct RevealableSecureField: View {
    let prompt: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack {
            Group {
                if revealed { TextField(prompt, text: $text) } else { SecureField(prompt, text: $text) }
            }
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless).help(revealed ? "Hide" : "Reveal")
                .accessibilityLabel(revealed ? "Hide token" : "Reveal token")
        }
    }
}

/// A tool row: name, a tinted status pill, then its actions. Goes through `LabeledContent` so the
/// name column lines up with every other row in the section instead of a hand-set width.
struct SettingsStatusRow<Actions: View>: View {
    let title: String
    let status: String
    var tone: ThemeTone = .neutral
    var statusIdentifier: String?
    var busy = false
    @ViewBuilder var actions: Actions

    var body: some View {
        LabeledContent {
            HStack {
                StatusPill(text: status, tone: tone, identifier: statusIdentifier)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                actions
            }
        } label: {
            Text(title)
        }
    }
}
