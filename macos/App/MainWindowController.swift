import AppKit

/// The main window, made and kept by AppKit rather than a SwiftUI scene, so its toolbar can be
/// split where its columns are (`MainSplitViewController`, `MainToolbarController`). It is never
/// closed: the red button, like ⌘W with no page open, only puts it away, and sessions keep running
/// until Quit. Its frame persists across launches.
@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let toolbarController: MainToolbarController
    private static let frameName = "CascadeNativeMain"

    init(model: AppViewModel) {
        let coordinator = model.coordinator
        toolbarController = MainToolbarController { coordinator.windowToolbar }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Cascade"
        // Every screen names itself in its toolbar (`PageTitle`).
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentViewController = MainSplitViewController(model: model)
        toolbarController.window = window
        window.contentMinSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.delegate = self
        Self.restoreFrame(of: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func restoreFrame(of window: NSWindow) {
        // The frame was saved under the name the window had while the app was called Craft.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "NSWindow Frame \(frameName)") == nil,
           let saved = defaults.object(forKey: "NSWindow Frame CraftNativeMain") {
            defaults.set(saved, forKey: "NSWindow Frame \(frameName)")
        }
        if !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.center()
        }
        window.setFrameAutosaveName(frameName)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
