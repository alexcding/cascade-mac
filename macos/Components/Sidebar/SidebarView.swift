import AppKit
import SwiftUI

// The chrome around the outline: a footer of glass buttons — Settings (gear only) on the left, and
// the activity capsule beside it filling the rest, which shows the latest activity until it is read
// and unfolds into the Today menu. New Project is File → New Project and New Task's project picker. The
// outline itself starts at the top of the column.
struct SidebarView: View {
    let viewModel: RootViewModel
    /// The activity the capsule shows, taken from the store in `lift` so its line lifts over.
    @State private var notice: NativeNotice?
    /// The Today menu is up, and how far it has unfolded out of the capsule.
    @State private var menuShown = false
    @State private var menuOpen = false
    @State private var capsuleHidden = false
    /// The column's height, which the menu's list is kept inside.
    @State private var columnHeight: CGFloat = 600
    private static let lift = Animation.spring(response: 0.42, dampingFraction: 0.8)
    private static let unfold = Animation.spring(response: 0.48, dampingFraction: 0.82)
    private static let fold = Animation.spring(response: 0.34, dampingFraction: 0.95)

    var body: some View {
        VStack(spacing: 0) {
            CocoaSidebar(entries: viewModel.entries, selection: viewModel.selection,
                         pinnedIDs: viewModel.pinnedIDs, forkableIDs: viewModel.forkableIDs, sessionShortcuts: viewModel.sessionShortcuts,
                         onSelect: viewModel.select, onTogglePin: viewModel.togglePin,
                         onNewTask: viewModel.newTask(in:),
                         onMoveProject: viewModel.moveProject, onMoveSession: viewModel.moveSession, onMovePinned: viewModel.movePinned,
                         onRemoveSession: viewModel.removeSession,
                         onRenameSession: viewModel.renameSession, onForkSession: viewModel.forkSession,
                         onReattachSession: viewModel.reattachSession,
                         onFocusSession: viewModel.focusSession,
                         gitClientLabel: viewModel.gitClientLabel, onOpenGitClient: viewModel.openGitClient,
                         onRenameChat: viewModel.renameChat(_:to:),
                         onDeleteChat: viewModel.deleteChat(_:))

            HStack(spacing: 8) {
                SidebarAppButton(icon: "gearshape", label: String(localized: "Settings"), help: String(localized: "Settings")) { viewModel.openSettings() }
                ActivityCapsule(notice: notice, action: capsuleClicked)
                    // The menu unfolds out of the capsule's own glass, and the capsule is back as
                    // the menu lands.
                    .opacity(capsuleHidden ? 0 : 1)
                    .animation(capsuleHidden ? nil : .easeIn(duration: 0.1).delay(0.2), value: capsuleHidden)
            }
            .glassIconButtons()
            .foregroundStyle(Color(nsColor: SidebarPalette.text2))
            .overlay(alignment: .bottom) {
                if menuShown, let today = viewModel.todayActivity {
                    let shape = RisingGlass(open: menuOpen ? 1 : 0, side: Theme.Size.largeControl)
                    // Room above the footer, less the menu's header and foot and a margin at the top.
                    TodayActivityMenu(model: today, revealed: menuOpen, listHeight: max(min(columnHeight - 170, 360), 80), showAllEvents: {
                        closeMenu()
                        viewModel.openActivity()
                    }, dismiss: { closeMenu() })
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(shape)
                    .glassSurface(shape)
                    .allowsHitTesting(menuOpen)
                    .background(DismissOnOutsideClick(dismiss: closeMenu))
                    .onAppear { withAnimation(Self.unfold) { menuOpen = true } }
                    // Gone with the column or the window: stop refreshing what nobody sees.
                    .onDisappear(perform: menuGone)
                    .padding(.leading, Theme.Size.largeControl + 8)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .zIndex(1)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
        .onChange(of: viewModel.shell.notifications.toast, initial: true) { _, latest in
            // Activity that comes while the menu is open is read there, as it is listed.
            if menuOpen, latest != nil { viewModel.shell.notifications.dismissToast(); return }
            withAnimation(Self.lift) { notice = latest }
        }
    }

    /// An activity with a page opens it, as its banner does; the plain capsule, or an activity with
    /// no page, opens the menu.
    private func capsuleClicked() {
        if let notice, notice.url != nil { viewModel.shell.notifications.open(notice) } else { openMenu() }
    }

    /// Opening the menu reads the activity the capsule showed. A click while it folds opens it again.
    private func openMenu() {
        if menuShown {
            guard !menuOpen else { return }
            capsuleHidden = true
            withAnimation(Self.unfold) { menuOpen = true }
            return
        }
        menuOpen = false
        menuShown = true
        capsuleHidden = true
        viewModel.todayActivity?.setVisible(true)
        viewModel.shell.notifications.dismissToast()
    }

    /// Whether there was an open menu to close.
    @discardableResult private func closeMenu() -> Bool {
        guard menuShown, menuOpen else { return false }
        capsuleHidden = false
        withAnimation(Self.fold) { menuOpen = false } completion: {
            guard !menuOpen else { return }
            menuShown = false
            viewModel.todayActivity?.setVisible(false)
        }
        return true
    }

    private func menuGone() {
        menuShown = false; menuOpen = false; capsuleHidden = false
        viewModel.todayActivity?.setVisible(false)
    }
}

/// Calls `dismiss` as a menu closes: for a click in Cascade outside the view it backs, in its window
/// or another, for Escape, when Cascade goes to the background, and when the view is hidden (its
/// column collapsed). Escape is taken only when there was something to close.
private struct DismissOnOutsideClick: NSViewRepresentable {
    let dismiss: () -> Bool

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.dismiss = dismiss }

    final class Probe: NSView {
        var dismiss: () -> Bool = { false }
        private var monitor: Any?
        private var resign: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resign { NotificationCenter.default.removeObserver(resign); self.resign = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event }
                    return dismiss() ? nil : event
                }
                if event.window !== window || !convert(bounds, to: nil).contains(event.locationInWindow) { _ = dismiss() }
                return event
            }
            resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.dismiss() }
            }
        }

        override func viewDidHide() {
            super.viewDidHide()
            _ = dismiss()
        }
    }
}

/// A footer button: a system symbol at its default size, whose title is its accessibility name. The footer's
/// `glassIconButtons()` gives it the round Liquid Glass look.
private struct SidebarAppButton: View {
    let icon: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .help(help)
    }
}
