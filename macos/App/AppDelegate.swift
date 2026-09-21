import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppViewModel = {
        // Before the model: it reads preferences as it is built.
        LegacyIdentity.carryDefaults()
        return AppViewModel()
    }()
    /// The single SwiftUI `Window("main")` scene, looked up on demand.
    private var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasSuffix("main") == true && !($0 is NSPanel) }
    }
    @ObservationIgnored private var statusItem: NSStatusItem?
    /// What the status glyph is currently painted with, and the menu bar thickness it was drawn
    /// for, so it is repainted only when one of them changes.
    @ObservationIgnored private var statusTint: NSColor?
    @ObservationIgnored private var statusThickness: CGFloat = 0
    @ObservationIgnored private var tray: TrayCoordinator?
    @ObservationIgnored private var trayMenu: TrayMenuController?
    private var updater: AppUpdater?
    @ObservationIgnored private lazy var termination = AppTerminationCoordinator(prepare: { [weak self] reason in
        guard let self else { throw CancellationError() }
        switch reason {
        case .quit: try await self.model.quit()
        case .update: try await self.model.prepareForUpdate()
        }
    }, finished: { reason, approved in
        if reason == .update { NSApp.reply(toApplicationShouldTerminate: approved) }
        else if approved { NSApp.terminate(nil) }
    }, failed: { [weak self] error in
        self?.showTerminationError(error)
    })

    /// A second copy of Craft must not start: both would share the PTY daemon and the
    /// database, and whichever quits first takes the daemon — and the other's terminals —
    /// with it. Decided before anything is touched; `applicationDidFinishLaunching` then hands
    /// focus and any launch URLs to the running copy and leaves.
    @ObservationIgnored private var runningCopy: NSRunningApplication?
    @ObservationIgnored private var forwardedURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        // A copy still running under the app's old name shares the same database.
        runningCopy = [identifier, LegacyIdentity.bundleIdentifier]
            .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private func yield(to other: NSRunningApplication) {
        other.activate()
        // `exit`, never `terminate`: terminating would run the quit contract and kill the
        // daemon the other copy is using — the very failure this prevents.
        guard !forwardedURLs.isEmpty, let bundle = other.bundleURL else { exit(0) }
        NSWorkspace.shared.open(forwardedURLs, withApplicationAt: bundle, configuration: .init()) { _, _ in exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = runningCopy { yield(to: other); return }
        model.shell.applyAppearance()
        // SwiftUI can have made the window key before this runs, so cover both orders.
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        adoptWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(sheetDidEnd),
            name: NSWindow.didEndSheetNotification, object: nil)
        // The terminal surface binds ⌘T, ⌘1–9 and the tab-cycling keys itself and would consume
        // them before the menu, so claim those ahead of the responder chain, under whatever keys
        // Settings → Shortcuts gives them. Every one carries ⌘, so nothing the CLI reads is taken.
        // A claimed key that cannot run right now is dropped, as a disabled menu item's is, rather
        // than passed on for the terminal surface to read as a binding of its own.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !ShortcutRecorder.recording, window?.isKeyWindow == true, window?.attachedSheet == nil,
                  let command = ShortcutRegistry.shared.command(for: event), command.claimedAheadOfResponders else { return event }
            if model.canPerform(command) { perform(command) } else { NSSound.beep() }
            return nil
        }
        model.configureNativeNotifications(isMainWindowFocused: { [weak self] in self?.window?.isKeyWindow == true },
            showWindow: { [weak self] in self?.showWindow() })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage(tint: nil)
        statusThickness = NSStatusBar.system.thickness
        item.button?.setAccessibilityIdentifier("craft-status-item")
        statusItem = item
        // A display added, removed or rearranged can change the menu bar's height under the glyph.
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let tray = model.makeTray(openWindow: { [weak self] in self?.showWindow() },
            dismiss: { [weak self] in self?.trayMenu?.dismiss() },
            quit: { NSApp.terminate(nil) })
        self.tray = tray
        // The tray is the status item's own menu: either click opens it, AppKit closes it.
        let trayMenu = TrayMenuController(model: tray.model, setActive: { [weak tray] in tray?.setActive($0) })
        item.menu = trayMenu.menu
        self.trayMenu = trayMenu
        observeStatus()
        updater = AppUpdater()
        Task { await model.start() }
    }

    var canCheckForUpdates: Bool {
        termination.pending == nil && updater?.canCheckForUpdates == true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if runningCopy != nil { forwardedURLs += urls; return }
        var handled = false
        for url in urls { if model.handleOpenURL(url) { handled = true } }
        guard handled else { return }
        showWindow()
    }

    @objc private func sheetDidEnd(_ notification: Notification) { model.resumePendingDeepLink() }

    func perform(_ command: ShellCommand) {
        switch command {
        case .checkForUpdates: updater?.checkForUpdates()
        case .closePage:
            if model.hasActivePage { model.perform(command) } else { hideMainWindow() }
        case .tray: toggleTray()
        case .sidebar:
            func findOutline(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == "workspace-sidebar" { return view }
                return view.subviews.lazy.compactMap(findOutline).first
            }
            revealWindow()
            if let root = window?.contentView, let outline = findOutline(root) { window?.makeFirstResponder(outline) }
        default:
            revealWindow()
            model.perform(command)
        }
    }

    /// The tray shortcut opens the status item's menu the way a click does.
    @objc func toggleTray() { statusItem?.button?.performClick(nil) }

    static let trayBronze = NSColor(srgbRed: 0.596, green: 0.443, blue: 0.173, alpha: 1)

    /// The status item carries the app's own mark, sized from the menu bar's own thickness rather
    /// than a fixed point size, so it keeps its margin whatever height the bar is on this Mac.
    ///
    /// Idle is a template image and takes no tint: the bar draws it in its own black or white and
    /// inverts it under the highlight. A status color cannot go through `contentTintColor` — the
    /// menu bar draws its button vibrantly, and a tinted template glyph comes back a flat black
    /// silhouette there whatever color is asked for. Bronze and blue are painted into a plain
    /// image instead, which the bar leaves alone.
    private static func menuBarImage(tint: NSColor?) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else { return nil }
        let side = (NSStatusBar.system.thickness * 0.72).rounded()
        base.size = NSSize(width: side, height: side)
        base.accessibilityDescription = "Craft"
        guard let tint else { base.isTemplate = true; return base }
        let painted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        painted.accessibilityDescription = "Craft"
        return painted
    }

    /// Repaints the glyph, but only when something about it actually changed: its color, or the
    /// thickness it is drawn for. Moving the bar to a display of another height is a screen-
    /// parameter change, not a status change, so it comes through `screenParametersChanged`.
    private func applyStatusImage(tint: NSColor?) {
        let thickness = NSStatusBar.system.thickness
        guard let button = statusItem?.button else { return }
        guard tint != statusTint || thickness != statusThickness || button.image == nil else { return }
        statusTint = tint; statusThickness = thickness
        button.image = Self.menuBarImage(tint: tint)
    }

    @objc private func screenParametersChanged() { applyStatusImage(tint: statusTint) }

    private func observeStatus() {
        withObservationTracking {
            let reviews = model.shell.pendingReviewCount
            // Only a review request colors the glyph. Running tasks leave it untinted, so it stays
            // the menu bar's own black or white like every other icon up there.
            applyStatusImage(tint: reviews > 0 ? Self.trayBronze : nil)
            statusItem?.button?.toolTip = reviews > 0 ? "Craft: \(reviews) pending reviews" : "Craft"
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    /// The red close button (and ⌘W with no page open) puts the window away instead of
    /// closing it: sessions keep running and the app quits only through Quit. `orderOut`
    /// rather than `miniaturize`, so there is no genie animation and no Dock thumbnail; the
    /// Dock icon or the tray brings it back. The button is re-targeted rather than the window
    /// delegate swapped — replacing SwiftUI's delegate mid-layout is what tripped AppKit's
    /// constraint-pass assertion before (0cfa497).
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { adoptWindow() }
    }

    /// One-time setup on the SwiftUI window: the close button hides rather than closes, and
    /// the frame persists across launches (SwiftUI does not restore it for this scene).
    private func adoptWindow() {
        guard let window else { return }
        if window.frameAutosaveName != "CraftNativeMain" { window.setFrameAutosaveName("CraftNativeMain") }
        guard let close = window.standardWindowButton(.closeButton), close.target !== self else { return }
        close.target = self
        close.action = #selector(hideMainWindow)
    }

    @objc private func hideMainWindow() { window?.orderOut(nil) }

    /// The menu bar stays up after the window is put away, so a menu command can arrive
    /// with nothing on screen; what it does must be visible.
    private func revealWindow() { if window?.isVisible != true { showWindow() } }

    // With no visible window AppKit asks whether to quit, and SwiftUI's own delegate says
    // yes. The window was only put away, so no: quitting is Quit's job.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    /// Brings Craft forward from the background: a notification, the tray, a deep link, a
    /// Dock click after the window was put away, or a failed quit. The window always exists —
    /// closing only orders it out — so this undoes a hide. Menu commands never need it; they
    /// only fire while Craft is active.
    private func showWindow() {
        trayMenu?.dismiss()
        NSApp.unhide(nil)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    func applicationDidHide(_ notification: Notification) { model.cancelBrowserPresentation() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch termination.systemTermination(updateRequested: updater?.restartRequested == true) {
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }

    private func showTerminationError(_ error: Error) {
        showWindow()
        if error is CancellationError { return }
        Task {
            let alert = NSAlert()
            alert.messageText = "Craft could not quit"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window { _ = await alert.beginSheetModal(for: window) }
        }
    }
}
