import AppKit
import Observation

@MainActor protocol TerminalPaneServing: AnyObject {
    var ready: Bool { get }
    func setStyle(_ value: TerminalStyle)
    func start() async
    func ownsPresentationWindow(_ window: NSWindow) -> Bool
    func applyPresentation(focus: Bool)
}

/// Presentation policy for one pane, without owning or stopping the detached shell.
///
/// Being on screen is SwiftUI's decision: only the selected workspace's panes are mounted,
/// and a Ghostty view that leaves its window stops drawing by itself. What is left here is
/// what the package does not track — the style to draw with, a window the close button has
/// ordered out, and handing the shell focus once it is ready — applied after the current
/// update pass, because display and focus changes can originate in AppKit layout
/// notifications mid-update.
@MainActor @Observable final class TerminalPaneViewModel {
    var style = TerminalStyle() {
        didSet {
            guard oldValue != style else { return }
            pendingStyle = style
            refresh()
        }
    }
    @ObservationIgnored private weak var session: (any TerminalPaneServing)?
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var scheduled = false
    @ObservationIgnored private var pendingFocus = false
    @ObservationIgnored private var pendingStyle: TerminalStyle?

    init(session: any TerminalPaneServing) { self.session = session }

    func appear() { mounted = true; refresh() }
    func disappear() { mounted = false }
    func surfaceChanged() { refresh() }
    func becameReady() { refresh(focus: true) }

    func start() async {
        pendingStyle = style; refresh()
        // SwiftUI tasks may execute synchronously up to their first suspension.
        // Apply the queued style after the update pass, before attaching output.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await session?.start()
    }

    func windowOcclusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              session?.ownsPresentationWindow(window) == true else { return }
        refresh()
    }

    private func refresh(focus: Bool = false) {
        pendingFocus = pendingFocus || focus
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scheduled = false
            let focus = pendingFocus
            pendingFocus = false
            let style = pendingStyle
            pendingStyle = nil
            guard let session else { return }
            if let style { session.setStyle(style) }
            // A pane that has left the hierarchy has nothing to show and must not take focus.
            guard mounted else { return }
            session.applyPresentation(focus: focus && session.ready)
        }
    }
}

extension TerminalSession: TerminalPaneServing {
    func ownsPresentationWindow(_ window: NSWindow) -> Bool {
        window === surface.attachedPlatformView?.window
    }

    /// Occlusion is the one visibility input the package does not track: the close button
    /// orders the window out while the shell keeps streaming, and the surface should stop
    /// drawing frames nobody sees.
    func applyPresentation(focus: Bool) {
        let view = surface.attachedPlatformView
        let visible = view?.window?.occlusionState.contains(.visible) ?? true
        if surface.isSurfaceVisible != visible { surface.isSurfaceVisible = visible }
        // Already outside the update pass. Avoid queuing a focus request that could
        // later steal focus after this workspace is hidden.
        if visible && focus { _ = view?.acquireProgrammaticFocus() }
    }
}
