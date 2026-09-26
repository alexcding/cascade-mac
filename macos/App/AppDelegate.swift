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
    /// The main window, made once the launch has not yielded to another copy.
    @ObservationIgnored private var mainWindow: MainWindowController?
    private var window: NSWindow? { mainWindow?.window }
    @ObservationIgnored private var helpWindow: NSWindow?
    @ObservationIgnored private var statusItem: NSStatusItem?
    /// Whether the status glyph is currently painted for a review, whether a number follows it, and
    /// the menu bar thickness it was drawn for, so it is repainted only when one of them changes.
    @ObservationIgnored private var statusReview = false
    @ObservationIgnored private var statusTitled = false
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

    /// A second copy of Cascade on the same data folder must not start: both would share the PTY
    /// daemon and the database, and whichever quits first takes the daemon — and the other's
    /// terminals — with it. Decided before anything is touched; `applicationDidFinishLaunching`
    /// then hands focus and any launch URLs to the running copy and leaves. A run given its own
    /// data folder (a checkout run from Xcode) shares neither, and runs beside the installed app.
    @ObservationIgnored private var yielding = false
    @ObservationIgnored private var runningCopy: NSRunningApplication?
    @ObservationIgnored private var forwardedURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        let explicit = LegacyIdentity.explicitDataDirectory
        let folder = explicit.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LegacyIdentity.supportDirectory
        if case .held(let pid) = InstanceLock.acquire(in: folder) {
            yielding = true
            runningCopy = pid.flatMap(NSRunningApplication.init(processIdentifier:))
        } else if explicit == nil {
            // A copy still running under the app's old name has the default data open too.
            runningCopy = LegacyIdentity.runningOldCopy()
            yielding = runningCopy != nil
        }
    }

    private func yield(to other: NSRunningApplication?) {
        other?.activate()
        // `exit`, never `terminate`: terminating would run the quit contract and kill the
        // daemon the other copy is using — the very failure this prevents.
        guard !forwardedURLs.isEmpty, let bundle = other?.bundleURL else { exit(0) }
        NSWorkspace.shared.open(forwardedURLs, withApplicationAt: bundle, configuration: .init()) { _, _ in exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if yielding { yield(to: runningCopy); return }
        // Looked for again: an old copy can have started since. With none running, the old data is
        // carried now, before anything below starts the backend or the terminal daemon. A run given
        // its own data folder never moves the default one.
        if LegacyIdentity.explicitDataDirectory == nil {
            if let other = LegacyIdentity.runningOldCopy() { yield(to: other); return }
            LegacyIdentity.carryData()
        }
        model.shell.applyAppearance()
        let mainWindow = MainWindowController(model: model)
        self.mainWindow = mainWindow
        mainWindow.window?.makeKeyAndOrderFront(nil)
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
        // Variable, not square: the share left sits beside the glyph. Unscaled, so the gap between
        // them is the bar's own image-to-title spacing, as for the weather and every titled item.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imageScaling = .scaleNone
        // The menu bar's own face, as the clock and weather set theirs; only the digits are fixed
        // width, so the item does not shift as the number changes.
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        item.button?.setAccessibilityIdentifier("cascade-status-item")
        statusItem = item
        applyStatusImage(review: false, titled: false)
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
        if yielding { forwardedURLs += urls; return }
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

    /// Cascade Help, in an AppKit window as the main window is: a SwiftUI window scene beside Settings
    /// would be opened by SwiftUI at every launch. Made once and kept, so it reopens where it was.
    func showHelp() {
        let help = helpWindow ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = String(localized: "Cascade Help")
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: HelpView())
            // The window is the user's to size; the page only sets its least.
            host.sizingOptions = [.minSize]
            window.contentViewController = host
            window.setContentSize(NSSize(width: 700, height: 650))
            window.center()
            window.setFrameAutosaveName("CascadeHelp")
            return window
        }()
        helpWindow = help
        help.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The tray shortcut opens the status item's menu the way a click does.
    @objc func toggleTray() { statusItem?.button?.performClick(nil) }

    /// Repaints the glyph, but only when something about it actually changed: its color, whether a
    /// number follows it, or the thickness it is drawn for. Moving the bar to a display of another
    /// height is a screen-parameter change, not a status change, so it comes through
    /// `screenParametersChanged`.
    private func applyStatusImage(review: Bool, titled: Bool) {
        let thickness = NSStatusBar.system.thickness
        guard let button = statusItem?.button else { return }
        guard review != statusReview || titled != statusTitled || thickness != statusThickness || button.image == nil else { return }
        statusReview = review; statusTitled = titled; statusThickness = thickness
        // A little more room before the number than the bar's own image-to-title gap gives; none
        // with the glyph alone, so it stays centred.
        button.image = StatusGlyph.image(review: review, trailing: titled ? 2 : 0)
    }

    /// The share of usage left beside the glyph. A plain title, so the bar draws it in its own black or
    /// white like the clock beside it — a brand color read poorly on a tinted bar — and inverts it
    /// under the highlight. No usage window (signed out, or not fetched yet) leaves the glyph alone.
    private func applyStatusTitle(left: Int?) {
        guard let button = statusItem?.button else { return }
        let title = left.map { "\($0)%" } ?? ""
        guard button.title != title else { return }
        button.title = title
        button.imagePosition = left == nil ? .imageOnly : .imageLeading
    }

    @objc private func screenParametersChanged() { applyStatusImage(review: statusReview, titled: statusTitled) }

    private func observeStatus() {
        withObservationTracking {
            let reviews = model.shell.pendingReviewCount
            let agent = model.shell.usageAgent
            let usage = model.shell.menuBarUsage
            let left = usage.map { Int($0.window.remaining.rounded()) }
            // Only a review request colors the glyph, so it otherwise stays the menu bar's own black or
            // white; the share left of the session (or the week) sits beside it.
            applyStatusImage(review: reviews > 0, titled: left != nil)
            applyStatusTitle(left: left)
            let name = Theme.usageAgents.first { $0.key == agent }?.title ?? agent
            let status = reviews > 0 ? String(localized: "Cascade · Pending reviews: \(reviews)") : "Cascade"
            statusItem?.button?.toolTip = left.map {
                status + " · " + (usage?.weekly == true ? String(localized: "\(name) weekly: \($0)% left")
                                                        : String(localized: "\(name) session: \($0)% left"))
            } ?? status
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    /// ⌘W with no page open puts the window away instead of closing it, as the red button does
    /// (`MainWindowController`): sessions keep running and the app quits only through Quit.
    /// `orderOut` rather than `miniaturize`, so there is no genie animation and no Dock thumbnail;
    /// the Dock icon or the tray brings it back.
    private func hideMainWindow() { window?.orderOut(nil) }

    /// The menu bar stays up after the window is put away, so a menu command can arrive
    /// with nothing on screen; what it does must be visible.
    private func revealWindow() { if window?.isVisible != true { showWindow() } }

    // With no visible window AppKit asks whether to quit. The window was only put away, so no:
    // quitting is Quit's job.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    /// Brings Cascade forward from the background: a notification, the tray, a deep link, a
    /// Dock click after the window was put away, or a failed quit. The window always exists —
    /// closing only orders it out — so this undoes a hide. Menu commands never need it; they
    /// only fire while Cascade is active.
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
            alert.messageText = String(localized: "Cascade could not quit")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            if let window { _ = await alert.beginSheetModal(for: window) }
        }
    }
}
