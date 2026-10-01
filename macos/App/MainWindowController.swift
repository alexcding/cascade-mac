import AppKit
import SwiftUI

/// The main window, made and kept by AppKit rather than a SwiftUI scene, so its toolbar can be
/// split where the window's columns are (`MainWindowViewController`, `MainToolbarController`). The
/// toolbar is transparent, over the sidebar and the card's backdrop. It is never closed: the red button, like ⌘W
/// with no page open, only puts it away, and sessions keep running until Quit. Its frame persists
/// across launches.
@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let content: MainWindowViewController
    private let toolbarController: MainToolbarController
    private static let frameName = "CascadeNativeMain"

    init(model: AppViewModel) {
        content = MainWindowViewController(model: model)
        let coordinator = model.coordinator
        toolbarController = MainToolbarController { coordinator.windowToolbar }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Cascade"
        // Every screen names itself in its bar (`PageTitle`).
        window.titleVisibility = .hidden
        // The toolbar is the content's backdrop, showing through: it has no surface of its own.
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        // The toolbar's pane section tracks the card's divider, so it is made against the card's split view.
        toolbarController.splitView = content.columns.splitView
        toolbarController.screenColumn = content.columns.screenColumn
        toolbarController.window = window
        window.contentMinSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.delegate = self
        Self.restoreFrame(of: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func restoreFrame(of window: NSWindow) {
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
