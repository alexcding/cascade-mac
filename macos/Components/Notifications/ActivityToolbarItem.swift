import SwiftUI

/// The activity bell before the sidebar's toggle in the toolbar: badged while there is activity to
/// read, the latest of it in its tooltip, and the Today menu dropping from it. Opening the menu reads
/// that activity; activity that comes while it is open is read there, as it is listed.
struct ActivityToolbarItem: View {
    let viewModel: RootViewModel
    /// A row with a link, clicked: opened in the session on show's pane.
    let openLink: (LogEntry) -> Void
    @State private var menuShown = false

    var body: some View {
        let notice = viewModel.shell.notifications.toast
        let line = notice.map { [$0.title, $0.body].filter { !$0.isEmpty }.joined(separator: "\n") }
        Button(action: openMenu) {
            Label("Today's activity", systemImage: notice == nil ? "bell" : "bell.badge")
                .symbolEffect(.bounce, value: notice?.id)
        }
        .buttonStyle(.toolbarIcon)
        .help(line ?? String(localized: "Today's activity"))
        .accessibilityLabel(line ?? String(localized: "Today's activity"))
        .accessibilityIdentifier(notice == nil ? "activity-capsule" : "activity-capsule-notice")
        .popover(isPresented: Binding(get: { menuShown }, set: { if !$0 { closeMenu() } }), arrowEdge: .bottom) {
            if let today = viewModel.todayActivity {
                TodayActivityMenu(model: today, open: { entry in
                    closeMenu()
                    openLink(entry)
                }, showAllEvents: {
                    closeMenu()
                    viewModel.openActivity()
                })
                .frame(width: 320)
                // Gone with the window or the item: stop refreshing what nobody sees.
                .onDisappear { menuShown = false; today.setVisible(false) }
            }
        }
        .onChange(of: notice) { _, latest in
            if menuShown, latest != nil { viewModel.shell.notifications.dismissToast() }
        }
    }

    private func openMenu() {
        guard !menuShown, let today = viewModel.todayActivity else { return }
        menuShown = true
        today.setVisible(true)
        viewModel.shell.notifications.dismissToast()
    }

    private func closeMenu() {
        guard menuShown else { return }
        menuShown = false
        viewModel.todayActivity?.setVisible(false)
    }
}
