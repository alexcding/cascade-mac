import AppKit
import GhosttyTerminal

// The package's SwiftUI state does not adopt its URL delegate. Interpose at
// its supported platform-view factory, forwarding every state/lifecycle/input
// callback the state currently adopts. The emulator and its input path stay intact.
@MainActor final class WorkspaceTerminalView: TerminalView,
    TerminalSurfaceOpenURLDelegate, TerminalSurfaceHoverLinkDelegate, TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate, TerminalSurfacePwdDelegate,
    TerminalSurfaceScrollbarDelegate, TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate, TerminalSurfaceTextSelectionRequestDelegate,
    TerminalSurfaceClipboardConfirmationDelegate {
    private weak var recipient: (any TerminalSurfaceViewDelegate)?
    var openLink: (String, String?, Bool) -> Void = { _, _, _ in }
    private weak var linkSurface: TerminalSurface?
    private var hoveredLink: String?
    private var optionClick: (url: String, point: NSPoint, dragged: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(TerminalDrop.types)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Ask Ghostty to hit-test the actual click position, not a stale hover. The
    // Command requests link recognition. Shift also releases TUI mouse capture
    // when Ghostty permits it; Command alone does not bypass mouse reporting.
    private func link(at event: NSEvent) -> String? {
        guard let surface = linkSurface else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let modifiers: TerminalInputModifiers = surface.isMouseCaptured ? [.super_, .shift] : .super_
        surface.sendMousePos(x: -1, y: -1, modifiers: modifiers)
        hoveredLink = nil
        surface.sendMousePos(x: point.x, y: bounds.height - point.y, modifiers: modifiers)
        return hoveredLink
    }
    override func mouseDown(with event: NSEvent) {
        optionClick = nil
        if event.modifierFlags.contains(.option), let url = link(at: event) {
            window?.makeFirstResponder(self)
            optionClick = (url, event.locationInWindow, false)
            return
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if var click = optionClick {
            if hypot(event.locationInWindow.x - click.point.x, event.locationInWindow.y - click.point.y) > 4 {
                click.dragged = true; optionClick = click
            }
            return
        }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if let click = optionClick {
            optionClick = nil
            if !click.dragged, event.modifierFlags.contains(.option), link(at: event) == click.url {
                openLink(click.url, directory, true)
            }
            return
        }
        super.mouseUp(with: event)
    }
    func terminalDidUpdateHoverLink(_ url: String?) {
        hoveredLink = url
        (recipient as? any TerminalSurfaceHoverLinkDelegate)?.terminalDidUpdateHoverLink(url)
    }
    private(set) var directory: String?

    override var delegate: (any TerminalSurfaceViewDelegate)? {
        get { recipient }
        set { recipient = newValue; super.delegate = newValue == nil ? nil : self }
    }
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        // Returning through this delegate suppresses Ghostty's /usr/bin/open
        // fallback even when the host refuses an unsupported URI scheme.
        openLink(url, directory, false)
    }
    func terminalDidChangeTitle(_ title: String) { (recipient as? any TerminalSurfaceTitleDelegate)?.terminalDidChangeTitle(title) }
    func terminalDidResize(_ size: TerminalGridMetrics) { (recipient as? any TerminalSurfaceGridResizeDelegate)?.terminalDidResize(size) }
    func terminalDidChangeFocus(_ focused: Bool) { (recipient as? any TerminalSurfaceFocusDelegate)?.terminalDidChangeFocus(focused) }
    func terminalDidClose(processAlive: Bool) { (recipient as? any TerminalSurfaceCloseDelegate)?.terminalDidClose(processAlive: processAlive) }
    func terminalDidRingBell() { (recipient as? any TerminalSurfaceBellDelegate)?.terminalDidRingBell() }
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        (recipient as? any TerminalSurfaceDesktopNotificationDelegate)?.terminalDidRequestDesktopNotification(title: title, body: body)
    }
    func terminalDidChangeWorkingDirectory(_ path: String) {
        if path.isEmpty { directory = nil }
        else if path.hasPrefix("/"), !path.contains("\0") { directory = path }
        (recipient as? any TerminalSurfacePwdDelegate)?.terminalDidChangeWorkingDirectory(path)
    }
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { (recipient as? any TerminalSurfaceScrollbarDelegate)?.terminalDidUpdateScrollbar(scrollbar) }
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        (recipient as? any TerminalSurfaceCommandFinishedDelegate)?.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }
    func terminalDidAttachSurface(_ surface: TerminalSurface) { linkSurface = surface; (recipient as? any TerminalSurfaceLifecycleDelegate)?.terminalDidAttachSurface(surface) }
    func terminalDidDetachSurface() { linkSurface = nil; hoveredLink = nil; optionClick = nil; (recipient as? any TerminalSurfaceLifecycleDelegate)?.terminalDidDetachSurface() }
    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        (recipient as? any TerminalSurfaceTextSelectionRequestDelegate)?.terminalDidRequestTextSelection(request)
    }
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        if let recipient = recipient as? any TerminalSurfaceClipboardConfirmationDelegate {
            recipient.terminalDidRequestClipboardConfirmation(request)
        } else { request.respond(allow: false) }
    }
}
