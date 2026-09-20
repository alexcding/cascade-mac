import SwiftUI

/// Settings → Text Editor: the code font, the colour theme and the preview of the file editor.
/// Ordered as Terminal is: preview, font, theme, then what only this surface has.
struct EditorSettingsView: View {
    let fonts: FontSettingsViewModel
    let shell: ShellStore

    var body: some View {
        SettingsPreviewSection(identifier: "editor") { dark in
            CodeThemeSample(theme: shell.editorStyle.theme(dark: dark), font: shell.font(.diff))
        }
        FontSettingsView(model: fonts, shell: shell, kinds: [.diff])
        theme
        Section("Editor") {
            SettingsRow(title: "Show code preview", caption: "The miniature of the file beside the text.") {
                Toggle("Show code preview", isOn: Binding(get: { shell.editorStyle.showMinimap }, set: shell.setEditorMinimap))
                    .labelsHidden().accessibilityIdentifier("settings-editor-minimap")
            }
        }
        if let error = shell.settingsError {
            Section { Text(error).foregroundStyle(Theme.danger) }
        }
    }

    /// One theme per appearance, as the terminal has. Default is the app's own syntax colours.
    @ViewBuilder private var theme: some View {
        Section("Theme") {
            themeRow(title: "Dark", dark: true, selection: shell.editorStyle.darkTheme) { shell.setEditorTheme(dark: $0) }
            themeRow(title: "Light", dark: false, selection: shell.editorStyle.lightTheme) { shell.setEditorTheme(light: $0) }
        }
    }

    @ViewBuilder
    private func themeRow(title: String, dark: Bool, selection: String, set: @escaping (String) -> Void) -> some View {
        SettingsRow(title: title) {
            Picker(title, selection: Binding(get: { selection }, set: set)) {
                Text("Default").tag("")
                ForEach(CodeTheme.names(dark: dark), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().accessibilityIdentifier("settings-editor-theme-\(dark ? "dark" : "light")")
        }
    }
}

/// A few lines of code coloured by hand: the sample has to show every token a theme defines, and
/// must not wait on a parser.
private struct CodeThemeSample: View {
    let theme: CodeTheme
    let font: CodeFont

    private enum Token { case text, keyword, string, comment, number, function, type }
    private static let lines: [[(String, Token)]] = [
        [("// Greets every reviewer once.", .comment)],
        [("struct", .keyword), (" ", .text), ("Greeter", .type), (" {", .text)],
        [("    ", .text), ("let", .keyword), (" limit = ", .text), ("42", .number)],
        [("    ", .text), ("func", .keyword), (" ", .text), ("greet", .function), ("(_ name: ", .text), ("String", .type), (") -> ", .text), ("String", .type), (" {", .text)],
        [("        ", .text), ("return", .keyword), (" ", .text), ("\"Hello, \\(name) 👋\"", .string)],
        [("    }", .text)],
        [("}", .text)],
    ]

    private func color(_ token: Token) -> Color {
        let rgb: UInt32 = switch token {
        case .text: theme.text
        case .keyword: theme.keyword
        case .string: theme.string
        case .comment: theme.comment
        case .number: theme.number
        case .function: theme.function
        case .type: theme.type
        }
        return Color(nsColor: CodeTheme.color(rgb))
    }

    private var sample: AttributedString {
        var result = AttributedString()
        for (index, line) in Self.lines.enumerated() {
            for (text, token) in line {
                var part = AttributedString(text)
                part.foregroundColor = color(token)
                result += part
            }
            if index < Self.lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    var body: some View {
        Text(sample)
            .font(font.sampleFont)
            .lineSpacing(CGFloat(font.size) * 0.2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.background.map { Color(nsColor: CodeTheme.color($0)) } ?? Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("Code theme preview")
            .accessibilityIdentifier("settings-editor-preview")
    }
}
