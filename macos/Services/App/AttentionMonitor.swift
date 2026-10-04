import AppKit

/// Says when someone is looking at the main window, so what it shows is read again: when the
/// app comes to the front with the window on screen, when the window comes back on screen, when
/// the Mac wakes, and every `interval` for as long as both stay true. An app in the background,
/// a window that is closed, covered or minimized, and a display that is asleep ask nothing: the
/// backend syncs behind a read, and nobody reads what nobody sees.
@MainActor final class AttentionMonitor {
    /// Someone is looking: read again what the window shows.
    var onAttend: () -> Void = {}
    private let isLooking: () -> Bool
    private let interval: () -> TimeInterval
    private var looking = false
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// `isLooking`: the app is frontmost and its main window is on screen. `interval`: seconds
    /// between reads while that holds, asked again before each wait so a changed setting is
    /// taken up. The centers are where AppKit and the workspace post; a test passes its own.
    init(isLooking: @escaping () -> Bool, interval: @escaping () -> TimeInterval,
         center: NotificationCenter = .default,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.isLooking = isLooking
        self.interval = interval
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observe(center, name) { $0.evaluate() }
        }
        // Waking changes nothing the app can see when the window was on screen all along.
        observe(workspace, NSWorkspace.didWakeNotification) { $0.woke() }
        evaluate()
    }

    /// Stops watching; nothing is asked afterwards.
    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate(); timer = nil
        looking = false
        onAttend = {}
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (AttentionMonitor) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        observers.append((center, observer))
    }

    /// Attends once when looking starts, and keeps time only while it lasts.
    private func evaluate() {
        let now = isLooking()
        guard now != looking else { return }
        looking = now
        if now { onAttend(); schedule() } else { timer?.invalidate(); timer = nil }
    }

    /// Waking while already looking is a read of its own; when waking is what starts the
    /// looking, `evaluate` has made that read.
    private func woke() {
        let was = looking
        evaluate()
        guard was, looking else { return }
        onAttend(); schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let wait = max(interval(), 1)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.looking else { return }
                self.onAttend(); self.schedule()
            }
        }
        // The read may slide a little, so the system can fire it with its other wake-ups.
        timer.tolerance = wait / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
