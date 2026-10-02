import AppKit
import SwiftUI

/// The file itself. Its Save and status sit in the row above it (`WorkspaceFileBrowser`).
struct EditorDocumentView: View {
    let model: EditorDocumentViewModel
    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    if !model.loaded && !model.loading { Button(String(localized: "Retry"), action: model.retry) }
                }.padding(8)
                Divider()
            }
            if let view = model.editorView { NativeEditorHost(view: view) }
            else { Color.clear }
        }
    }
}

private struct NativeEditorHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> EditorResizeContainer { EditorResizeContainer(editor: view) }
    func updateNSView(_ nsView: EditorResizeContainer, context: Context) {}
}

/// Holds the editor at its width while that width is being dragged. CodeEditSourceEditor lays the
/// file out again at every width it is given, re-wrapping each line: 10 to 25 ms a step for a
/// file of 1,700 lines, more than a frame, so a divider or the window dragged beside it stuttered.
/// One change of width reaches the editor at once; changes that follow within `dragGap` of each
/// other with the mouse button held are a drag, and the editor keeps the width it had, clipped or
/// with room beside it, until they stop for `settleDelay`, or the window's live resize ends. An
/// animation — the pane opening or shutting — is also a run of changes, but no button is held:
/// each of its widths reaches the editor, so it never shows a stale width as it slides.
final class EditorResizeContainer: NSView {
    static let dragGap: TimeInterval = 0.2
    static let settleDelay: TimeInterval = 0.15

    let editor: NSView
    private var lastChange = Date.distantPast
    /// Whether the mouse button is down: what tells a divider dragged from a pane animating.
    var pointerHeld: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    private var settle: DispatchWorkItem?

    init(editor: NSView) {
        self.editor = editor
        super.init(frame: .zero)
        clipsToBounds = true
        editor.autoresizingMask = []
        addSubview(editor)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        place(settled: false)
    }

    /// A container SwiftUI is done with lets its timer go: the editor may already be in a new one.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { settle?.cancel() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        place(settled: true)
    }

    /// The editor at the container's size, or, mid-drag, at its own width and the container's height.
    private func place(settled: Bool) {
        // The editor belongs to its document, and a rebuilt view moves it to a new container.
        guard editor.superview === self else { settle?.cancel(); return }
        let now = Date()
        guard editor.frame.width != bounds.width else { editor.frame = bounds; return }
        let dragging = !settled && editor.frame.width > 0 && (inLiveResize || (pointerHeld() && now.timeIntervalSince(lastChange) < Self.dragGap))
        lastChange = now
        guard dragging else { settle?.cancel(); editor.frame = bounds; return }
        editor.frame = NSRect(x: 0, y: 0, width: editor.frame.width, height: bounds.height)
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.place(settled: true) }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
