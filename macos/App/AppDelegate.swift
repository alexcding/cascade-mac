import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
    private let popover = NSPopover()
    @ObservationIgnored private var tray: TrayCoordinator?
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
        // ⌘T is New Tab and ⌥⌘T is New Sidebar Tab everywhere in the app. The terminal surface
        // binds ⌘T itself and would consume it before the menu, so claim both ahead of the
        // responder chain.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, window?.isKeyWindow == true, window?.attachedSheet == nil,
                  event.charactersIgnoringModifiers?.lowercased() == "t" else { return event }
            let command: ShellCommand
            switch event.modifierFlags.intersection(.deviceIndependentFlagsMask) {
            case .command: command = .newTab
            case [.command, .option]: command = .newSidebarTab
            default: return event
            }
            guard model.canPerform(command) else { return event }
            perform(command)
            return nil
        }
        model.configureNativeNotifications(isMainWindowFocused: { [weak self] in self?.window?.isKeyWindow == true },
            showWindow: { [weak self] in self?.showWindow() })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Craft")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityIdentifier("craft-status-item")
        item.button?.target = self
        item.button?.action = #selector(toggleTray)
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 580)
        let tray = model.makeTray(openWindow: { [weak self] in self?.showWindow() },
            dismiss: { [weak self] in self?.popover.performClose(nil) })
        self.tray = tray
        popover.contentViewController = NSHostingController(rootView: NativeTrayView(model: tray.model))
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

    @objc func toggleTray() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem?.button else { return }
        tray?.setActive(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { tray?.setActive(false) }

    private func observeStatus() {
        withObservationTracking {
            let reviews = model.shell.pendingReviewCount
            statusItem?.button?.contentTintColor = reviews > 0
                ? NSColor(srgbRed: 0.596, green: 0.443, blue: 0.173, alpha: 1)
                : (model.hasOpenWork ? .systemBlue : .labelColor)
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
        popover.performClose(nil)
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
