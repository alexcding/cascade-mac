import AppKit
import Testing
@testable import Cascade

/// The editor follows one change of width at once, keeps its width through a drag, and takes the
/// final width once the drag stops.
@MainActor struct EditorResizeContainerTests {
    @Test func aDragHoldsTheEditorsWidthUntilItSettles() async throws {
        let editor = NSView()
        let container = EditorResizeContainer(editor: editor)
        container.pointerHeld = { true }
        container.setFrameSize(NSSize(width: 600, height: 400))
        #expect(editor.frame.size == NSSize(width: 600, height: 400), "the first width reaches the editor")
        container.setFrameSize(NSSize(width: 590, height: 400))
        container.setFrameSize(NSSize(width: 580, height: 380))
        #expect(editor.frame.width == 600 && editor.frame.height == 380, "mid-drag: the width holds, the height follows")
        try await Task.sleep(for: .seconds(EditorResizeContainer.settleDelay + 0.15))
        #expect(editor.frame.size == NSSize(width: 580, height: 380), "settled: the editor takes the last width")
        try await Task.sleep(for: .seconds(EditorResizeContainer.dragGap))
        container.setFrameSize(NSSize(width: 700, height: 380))
        #expect(editor.frame.width == 700, "a lone change after the drag reaches the editor at once")
    }

    @Test func anAnimationsWidthsAllReachTheEditor() {
        let editor = NSView()
        let container = EditorResizeContainer(editor: editor)
        container.pointerHeld = { false }
        for width in stride(from: 600, through: 500, by: -20) {
            container.setFrameSize(NSSize(width: CGFloat(width), height: 400))
            #expect(editor.frame.width == CGFloat(width), "no button held: the pane sliding, not a drag")
        }
    }
}
