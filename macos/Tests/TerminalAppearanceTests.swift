import AppKit
import Combine
import GhosttyTerminal
import SwiftUI
import Testing

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func terminalAppearanceDoesNotPublishInsideNativeAttachment(swiftUI: Bool) async throws {
    _ = NSApplication.shared
    let memory = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    let state = TerminalViewState()
    state.adopt(terminalColorScheme: .dark)
    let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    view.delegate = state; view.controller = state.controller
    state.configuration = .init(backend: .inMemory(memory))
    view.configuration = state.configuration
    let hosting = NSHostingView(rootView: TerminalSurfaceView(context: state))
    hosting.frame = view.frame; hosting.sizingOptions = []
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    defer { window.contentView = nil; window.close() }
    var attaching = true
    var stacks: [[String]] = []
    let observation = state.objectWillChange.sink {
        if attaching { stacks.append(Array(Thread.callStackSymbols.prefix(20))) }
    }
    window.contentView = swiftUI ? hosting : view
    window.contentView?.layoutSubtreeIfNeeded()
    attaching = false
    #expect(stacks.isEmpty, "Synchronous attachment publication: \(stacks.map { $0.joined(separator: "\n") }.joined(separator: "\n---\n"))")
    for _ in 0..<50 {
        if state.effectiveColorScheme == .light { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.effectiveColorScheme == .light)
    let surface = try #require(state.surface)
    attaching = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.appearance = NSAppearance(named: .aqua)
    window.appearance = NSAppearance(named: .darkAqua)
    attaching = false
    for _ in 0..<50 {
        if state.effectiveColorScheme == .dark { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.effectiveColorScheme == .dark)
    #expect(state.surface === surface)
    #expect(stacks.isEmpty)
    do {
        attaching = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = nil
        attaching = false
        try await Task.sleep(for: .milliseconds(30))
        #expect(state.effectiveColorScheme == .dark) // A detached view cannot apply queued appearance.
        window.contentView = swiftUI ? hosting : view
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<50 {
            if state.effectiveColorScheme == .light { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.effectiveColorScheme == .light && state.surface === surface)
    }
    withExtendedLifetime(observation) {}
}
