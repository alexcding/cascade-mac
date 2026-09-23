import Foundation
import os

/// Intervals in Instruments' Points of Interest lane, which the Time Profiler template records, so a
/// slow interaction is measured rather than guessed at. Free while nothing is recording.
enum Signposts {
    static let navigation = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Craft", category: .pointsOfInterest)
}

/// A sidebar switch to a session or the terminal: from the selection to the end of the run-loop
/// turn whose frame shows its workspace (`SessionWorkspaceDeck`).
@MainActor enum WorkspaceSwitchSignpost {
    private static var interval: OSSignpostIntervalState?

    static func begin() {
        end()
        interval = Signposts.navigation.beginInterval("Switch Workspace")
    }

    /// Once the frame being built now is committed: the next turn of the main run loop.
    static func endAfterCommit() {
        guard interval != nil else { return }
        DispatchQueue.main.async { end() }
    }

    private static func end() {
        guard let interval else { return }
        Signposts.navigation.endInterval("Switch Workspace", interval)
        self.interval = nil
    }
}
