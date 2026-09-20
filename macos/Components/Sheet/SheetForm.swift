import SwiftUI

// The web modals' form pieces (css/components.css + pages.css): a 12pt label above its
// control (.form-label), a muted hint under it (.form-hint), a hairline-topped section with
// a small caps title (.form-section), and the 16pt sheet title (.modal h2).
struct SheetTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 16, weight: .semibold)).padding(.bottom, 16) }
}

struct SheetField<Content: View>: View {
    let label: String
    var last = false
    @ViewBuilder let content: Content

    init(_ label: String, last: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label; self.last = last; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(.bottom, last ? 0 : 14)
    }
}

struct SheetHint: View {
    let text: Text
    var isError = false
    init(_ text: String, isError: Bool = false) { self.text = Text(text); self.isError = isError }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text.font(.system(size: 12)).lineSpacing(3)
            .foregroundStyle(isError ? Color.red : Color(nsColor: .tertiaryLabelColor))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
    }
}

struct SheetSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 16)
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.5)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor)).padding(.bottom, 12)
            content
        }
        .padding(.top, 4)
    }
}

/// .code-chip: an inline monospaced token inside a hint.
func sheetCode(_ value: String) -> Text {
    Text(value).font(.system(size: 11.5, design: .monospaced))
}
