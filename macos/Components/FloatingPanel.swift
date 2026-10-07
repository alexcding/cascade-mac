import AppKit
import SwiftUI

extension View {
    /// Hangs `content` under this view while `isPresented`, as a web app's menus hang: a panel of
    /// its own, blurred behind, with a rounded edge and the window's shadow, and no popover arrow.
    /// It takes the keyboard, for a field in it. A click anywhere else, Escape, the app going to
    /// the back or the window closing takes it down; a click on this view is left to this view,
    /// so a button that opens it closes it too.
    func floatingPanel<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        background(FloatingPanelAnchor(isPresented: isPresented, content: content))
    }
}

/// The view the panel hangs under, the size of the view it backs, and the panel's keeper.
private struct FloatingPanelAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.close = { isPresented = false }
        if isPresented {
            coordinator.show(FloatingPanelChrome { content() }, under: anchor)
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) { coordinator.dismiss() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var close: () -> Void = {}
        private var panel: FloatingPanelWindow?
        private var hosting: FloatingPanelHostingView<FloatingPanelChrome<Content>>?
        private weak var anchor: NSView?
        /// Where the anchor was when the panel opened, in the window's coordinates, read again
        /// only when the window is resized: the anchor's own changes while the panel is open (a
        /// button's label as the pick changes) do not move the panel, as the page's trigger is
        /// frozen while its menu is open.
        private var anchorRect: NSRect?
        private var placing = false
        private var monitors: [Any] = []
        private var observers: [NSObjectProtocol] = []

        func show(_ content: FloatingPanelChrome<Content>, under anchor: NSView) {
            self.anchor = anchor
            if let hosting {
                hosting.rootView = content
                schedulePlace()
                return
            }
            guard let parent = anchor.window else { return }
            anchorRect = anchor.convert(anchor.bounds, to: nil)
            let hosting = FloatingPanelHostingView(rootView: content)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.resized = { [weak self] in self?.schedulePlace() }
            let panel = FloatingPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // The chrome draws the page's faint shadow, in the margin around it; a window's would be far heavier.
            panel.hasShadow = false
            panel.level = .floating
            panel.animationBehavior = .utilityWindow
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting
            place()
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            watch(parent)
        }

        /// Once the layout that asked has settled, not in its midst.
        private func schedulePlace() {
            guard !placing else { return }
            placing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.placing = false
                self.place()
            }
        }

        /// Under the anchor, left edges aligned, kept on the screen; above it when there is no
        /// room below. The frame is the chrome's margin wider all round, for the shadow. Called
        /// again as the content changes size, so the top edge stays put.
        private func place() {
            guard let panel, let hosting, let anchor, let window = anchor.window, let anchorRect else { return }
            let size = hosting.fittingSize, margin = FloatingPanelChrome<Content>.margin
            let anchored = window.convertToScreen(anchorRect)
            var origin = NSPoint(x: anchored.minX - margin, y: anchored.minY - 4 - size.height + margin)
            if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
                let left = screen.minX + 8 - margin, right = screen.maxX - size.width - 8 + margin
                origin.x = min(max(origin.x, left), max(left, right))
                if origin.y + margin < screen.minY { origin.y = anchored.maxY + 4 - margin }
            }
            let frame = NSRect(origin: origin, size: size)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }

        private func watch(_ parent: NSWindow) {
            // A click outside the panel closes it and still lands where it went. One on the anchor
            // is the anchor's: its button toggles the panel itself.
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                guard let self, let panel = self.panel, event.window !== panel else { return event }
                if let anchor = self.anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
                self.close()
                return event
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard let self, self.panel != nil, event.keyCode == 53 else { return event }
                self.close()
                return nil
            }) { monitors.append(monitor) }
            let center = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] notification in
                    let resignedKey = notification.name == NSWindow.didResignKeyNotification
                    MainActor.assumeIsolated {
                        // The panel taking the keyboard is not the window losing it.
                        guard let self else { return }
                        if resignedKey, NSApp.keyWindow === self.panel { return }
                        self.close()
                    }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let anchor = self.anchor else { return }
                    self.anchorRect = anchor.convert(anchor.bounds, to: nil)
                    self.place()
                }
            })
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }

        func dismiss() {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
            hosting = nil
        }
    }
}

/// A borderless panel that takes the keyboard, for the field in it, without activating the app.
private final class FloatingPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Tells its keeper when its content changed size, so the panel can follow.
private final class FloatingPanelHostingView<Root: View>: NSHostingView<Root> {
    var resized: () -> Void = {}
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        resized()
    }
}

/// The look every floating panel shares, the chat page's picker's: its fill, a rounded edge, a
/// hairline, and a faint shadow (`0 4px 18px -6px` of the text at 7%), drawn in a margin around
/// the panel so the window can be shadowless.
struct FloatingPanelChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content
    static var margin: CGFloat { 20 }
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        content()
            .background(Theme.chatPanel, in: shape)
            .overlay(shape.stroke(Theme.chatPanelBorder, lineWidth: 1))
            .shadow(color: Theme.chatPanelShadow, radius: 7, x: 0, y: 4)
            .padding(Self.margin)
    }
}
