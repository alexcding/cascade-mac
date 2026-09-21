import AppKit
import SwiftUI

/// Click, then press the combination. Escape leaves it as it was; Delete clears it.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    var placeholder = "Add Shortcut"
    /// Why a combination cannot be used, or nil when it can. A refused press is reported and
    /// the shortcut stays as it was.
    var conflict: (KeyShortcut) -> String? = { _ in nil }
    var rejected: (String?) -> Void = { _ in }
    @State private var monitor: Any?
    /// True while any recorder is waiting for a press, so the app's own key monitor stands aside
    /// and the press is recorded, or refused with its reason, rather than carried out.
    @MainActor static private(set) var recording = false

    var body: some View {
        Button(monitor != nil ? "Press keys…" : shortcut?.title ?? placeholder) { monitor == nil ? start() : stop() }
            .frame(width: 96)
            .help("Click, then press a combination that includes ⌘. Delete clears it.")
            .onDisappear(perform: stop)
    }

    private func start() {
        rejected(nil)
        Self.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; stop(); return nil }
            guard let value = KeyShortcut(event: event) else { return nil }
            if let reason = conflict(value) { rejected(reason) } else { shortcut = value }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); Self.recording = false }
        monitor = nil
    }
}
