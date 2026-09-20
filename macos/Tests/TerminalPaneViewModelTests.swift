import AppKit
import Testing

@MainActor private final class TerminalPresentationFixture: TerminalPaneServing {
    var ready = true
    /// One entry per display pass: whether it asked for focus.
    var focusRequests: [Bool] = []
    var style: TerminalStyle?
    var starts = 0
    func setStyle(_ value: TerminalStyle) { style = value }
    func start() async { starts += 1 }
    func ownsPresentationWindow(_ window: NSWindow) -> Bool { false }
    func applyPresentation(focus: Bool) { focusRequests.append(focus) }
}

@MainActor private func flushPresentation() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor @Test func terminalPresentationDefersDisplayAndSkipsAPaneThatLeftTheHierarchy() async {
    let session = TerminalPresentationFixture(), model = TerminalPaneViewModel(session: session)
    model.appear()
    #expect(session.focusRequests.isEmpty)
    model.style = TerminalStyle(font: CodeFont(size: 14))
    model.style = TerminalStyle(font: CodeFont(size: 18))
    #expect(session.style == nil)
    model.surfaceChanged(); model.becameReady()
    model.disappear()
    #expect(session.focusRequests.isEmpty)
    await flushPresentation()
    // The style still lands — a hidden pane must draw correctly when it comes back — but
    // nothing is displayed or focused for a pane that is no longer mounted.
    #expect(session.focusRequests.isEmpty && session.style == TerminalStyle(font: CodeFont(size: 18)))
    model.style = TerminalStyle(font: CodeFont(size: 18))
    await flushPresentation()
    #expect(session.focusRequests.isEmpty) // Equal input does not enqueue display work.

    model.appear(); model.becameReady()
    await flushPresentation()
    #expect(session.focusRequests == [true])
    model.disappear()
    await flushPresentation()
    #expect(session.focusRequests == [true])
    #expect(session.starts == 0) // Presentation never starts or restarts a shell.
}

@MainActor @Test func terminalPresentationDoesNotFocusUnreadyOrUnmountedSurfaces() async {
    let session = TerminalPresentationFixture(), model = TerminalPaneViewModel(session: session)
    model.appear()
    session.ready = false
    model.becameReady()
    await flushPresentation()
    #expect(session.focusRequests == [false])
    session.ready = true
    model.becameReady()
    model.disappear()
    await flushPresentation()
    #expect(session.focusRequests == [false])
    model.windowOcclusionChanged(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: NSObject()))
    await flushPresentation()
    #expect(session.focusRequests == [false]) // Another window's occlusion is not ours.
}

@MainActor @Test func terminalPresentationForwardsStartupAndDoesNotRetainClosedRuntime() async {
    var session: TerminalPresentationFixture? = TerminalPresentationFixture()
    weak var retained = session
    let model = TerminalPaneViewModel(session: session!)
    let style = TerminalStyle(font: CodeFont(size: 16))
    model.style = style; await model.start()
    #expect(session?.style == style && session?.starts == 1)
    model.appear()
    session = nil
    #expect(retained == nil)
    await flushPresentation()
    model.style = TerminalStyle(font: CodeFont(size: 17)); await model.start()
}
