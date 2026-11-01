import AppKit
import SwiftUI

/// Terminals started here with no screen showing them: a paired Mac started a session of this
/// Mac. Each is mounted as a screen here mounts it (`TerminalPane`), in a window that is never
/// shown, so it starts exactly as one opened here does, at the size given; it leaves when a screen
/// here shows the session (`release`), which then takes its view and sizes it as it does any.
@MainActor final class UnseenTerminals {
    private var windows: [String: (window: NSWindow, terminal: TerminalSession)] = [:]

    func contains(_ key: String) -> Bool { windows[key] != nil }

    /// Keeps only the terminals still the app's under their key: one replaced or gone is let go.
    func keep(_ current: [String: TerminalSession]) {
        for (key, entry) in windows where current[key] !== entry.terminal { release(key) }
    }

    func mount(_ terminal: TerminalSession, key: String, size: NSSize) {
        release(key)
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TerminalPane(session: terminal).frame(width: size.width, height: size.height))
        host.frame = frame
        window.contentView = host
        // Laid out now, so the surface exists before the terminal starts.
        host.layoutSubtreeIfNeeded()
        windows[key] = (window, terminal)
    }

    /// Lets the terminal's view go, for a screen here that shows it, or as the session goes.
    func release(_ key: String) {
        guard let window = windows.removeValue(forKey: key)?.window else { return }
        window.contentView = nil
        window.close()
    }

    func releaseAll() { for key in Array(windows.keys) { release(key) } }
}
