import SwiftUI

/// The Notifications group — its own `Section`, rows through `SettingsRow` so the Form aligns them.
struct NotificationPreferencesView: View {
    let shell: ShellStore
    var sounds: [ReviewSound] = []

    var body: some View {
        Section("Notifications") {
            SettingsRow(title: "Review sound") {
                HStack {
                    Picker("Review sound", selection: Binding(get: { shell.reviewSound }, set: shell.setReviewSound)) {
                        Text("Glass (default)").tag("system")
                        Text("None").tag("off")
                        ForEach(sounds) { Text($0.name).tag($0.path) }
                        if !["system", "off"].contains(shell.reviewSound) && !sounds.contains(where: { $0.path == shell.reviewSound }) {
                            Text(URL(fileURLWithPath: shell.reviewSound).deletingPathExtension().lastPathComponent)
                                .tag(shell.reviewSound)
                        }
                    }.labelsHidden().accessibilityIdentifier("settings-review-sound")
                    Button { shell.notifications.previewSound(shell.reviewSound) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Preview").disabled(shell.reviewSound == "off")
                        .accessibilityLabel("Preview Sound").accessibilityIdentifier("settings-preview-sound")
                }
            }
            Toggle(isOn: Binding(get: { shell.activityNotify }, set: shell.setActivityNotify)) {
                Text("Activity notifications")
            }.accessibilityIdentifier("settings-activity-notify")
            if shell.notifications.permission != .authorized {
                LabeledContent {
                    if shell.notifications.permission == .notDetermined {
                        Button("Enable Notifications") { shell.notifications.enable() }
                            .disabled(!shell.notifications.canEnable)
                    }
                } label: {
                    Text("Permission")
                    Text(shell.notifications.permission == .denied
                         ? "Allow Craft Native in System Settings → Notifications."
                         : shell.notifications.permission.label)
                }
            }
            if let error = shell.notifications.error { Text(error).foregroundStyle(Theme.danger) }
            if let error = shell.notifications.actionError { Text(error).foregroundStyle(Theme.danger) }
        }
    }
}

/// The in-app activity toast — components/activity-toast.js + .act-toast (pages.css): a card with
/// the event's tinted glyph, its line and one-line detail, and a small ×. Slides in from the right;
/// hovering holds it on screen.
struct ActivityToastView: View {
    let notifications: NotificationStore
    @State private var closeHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let notice = notifications.toast {
                card(notice)
                    .id(notice.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: notifications.toast?.id)
    }

    private func card(_ notice: NativeNotice) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ActivityGlyphView(type: notice.eventType ?? (notice.kind == .review ? "review_requested" : ""), level: nil)
                .padding(.top, 1)
            Button { notifications.open(notice) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(notice.title).font(.system(size: 13)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !notice.body.isEmpty {
                        Text(notice.body).font(.system(size: 12)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if let error = notifications.actionError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("activity-toast-open")
            Button(action: notifications.dismissToast) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(closeHovered ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 18, height: 18)
                    .background(closeHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .accessibilityLabel("Dismiss activity")
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(width: 340, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        .onHover { $0 ? notifications.holdToast() : notifications.releaseToast() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-toast")
    }
}
