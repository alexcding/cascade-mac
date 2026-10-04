import AppKit
import Foundation
import Testing
@testable import Cascade

@MainActor private final class Attention {
    var looking = false
    var attended = 0
}

/// A read when looking starts, one each interval while it lasts, one on waking, and none at all
/// while nobody can see the window or after the monitor is stopped.
@MainActor @Test func attentionReadsWhenSomeoneLooksAndKeepsTimeOnlyWhileTheyDo() async throws {
    let center = NotificationCenter(), workspace = NotificationCenter()
    let state = Attention()
    let monitor = AttentionMonitor(isLooking: { state.looking }, interval: { 0.05 }, center: center, workspace: workspace)
    monitor.onAttend = { state.attended += 1 }
    func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    // Nobody is looking: nothing is asked, however long that lasts, and waking changes nothing.
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.attended == 0)

    // The app comes to the front with its window on screen: a read at once, then one each interval.
    state.looking = true
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try await eventually { state.attended >= 1 }
    #expect(state.attended >= 1)
    try await eventually { state.attended >= 3 }
    #expect(state.attended >= 3)

    // The app goes to the background: the reads stop.
    state.looking = false
    center.post(name: NSApplication.didResignActiveNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    let resting = state.attended
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.attended == resting)

    // The window comes back on screen: a read at once. Waking while looking is another.
    state.looking = true
    center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    try await eventually { state.attended > resting }
    #expect(state.attended > resting)
    let before = state.attended
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await eventually { state.attended > before }
    #expect(state.attended > before)

    // Stopped is final: no notification and no timer asks again.
    monitor.stop()
    try await Task.sleep(for: .milliseconds(100))
    let stopped = state.attended
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.attended == stopped)
}
