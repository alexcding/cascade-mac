import AppKit
import SwiftUI

struct EditorDocumentView: View {
    let model: EditorDocumentViewModel
    /// App-wide, so it is the workspace's to change, not the document's.
    var togglePreview: () -> Void = {}
    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    if !model.loaded && !model.loading { Button("Retry", action: model.retry) }
                }.padding(8)
                Divider()
            }
            if let view = model.editorView { NativeEditorHost(view: view) }
            else { Color.clear }
            Divider()
            // The same glass capsules as the tab bar above.
            HStack(spacing: 8) {
                HoverCircleButton("Show or Hide Preview", systemImage: "map", enabled: model.loaded, action: togglePreview)
                    .help("Show or Hide Preview")
                    .barGlass()
                Spacer()
                if model.readOnly { Text("Read Only").font(.callout).foregroundStyle(Theme.textSecondary) }
                if model.loading || model.saving { ProgressView().controlSize(.small) }
                Button("Save") { Task { await model.save() } }
                    .padding(.horizontal, 14)
                    .barGlass(iconOnly: false)
                    .disabled(!canEdit)
                    .opacity(canEdit ? 1 : 0.5)
            }.padding(8)
        }
    }

    private var canEdit: Bool { model.loaded && !model.readOnly && !model.saving && !model.closing }
}

private struct NativeEditorHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
