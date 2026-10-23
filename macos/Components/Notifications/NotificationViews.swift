import SwiftUI

/// The Notifications group — its own `Section`, rows through `SettingsRow` so the Form aligns them.
struct NotificationPreferencesView: View {
    let shell: ShellStore
    var sounds: [ReviewSound] = []

    var body: some View {
        Section("Notifications") {
            SettingsRow(title: String(localized: "Review sound")) {
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
                         ? String(localized: "Allow Cascade in System Settings → Notifications.")
                         : shell.notifications.permission.label)
                }
            }
            if let error = shell.notifications.error { Text(error).foregroundStyle(Theme.danger) }
            if let error = shell.notifications.actionError { Text(error).foregroundStyle(Theme.danger) }
        }
    }
}

/// The sidebar's activity capsule: "Today's activity" until there is activity to read, then the
/// latest of it on the same line, until it is opened — its tinted glyph, its line and detail, and an unread dot. A newer
/// activity lifts the old one up and out as it rises in, so the owner changes `notice` in an
/// animation.
struct ActivityCapsule: View {
    let notice: NativeNotice?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let notice {
                    line(notice).id(notice.id).transition(Self.lift)
                } else {
                    Label("Today's activity", systemImage: "bell")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.animation(.easeOut(duration: 0.1)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.largeControl)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(Capsule(), interactive: true)
        .help(notice.map { [$0.title, $0.body].filter { !$0.isEmpty }.joined(separator: "\n") } ?? String(localized: "Today's activity"))
        .accessibilityIdentifier(notice == nil ? "activity-capsule" : "activity-capsule-notice")
    }

    private func line(_ notice: NativeNotice) -> some View {
        HStack(spacing: 7) {
            ActivityGlyphView(type: notice.eventType ?? (notice.kind == .review ? "review_requested" : ""), level: nil, size: 22)
            (Text(notice.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                + Text(notice.body.isEmpty ? "" : "  \(notice.body)").font(.system(size: 12)).foregroundStyle(.secondary))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
        }
        .padding(.leading, 5).padding(.trailing, 12)
        .accessibilityElement(children: .combine)
    }

    private static let lift = AnyTransition.asymmetric(
        insertion: .offset(y: 18).combined(with: .opacity),
        removal: .offset(y: -16).combined(with: .scale(scale: 0.97)).combined(with: .opacity))
}

/// Glass that rises out of a capsule `side` tall at its foot, `inset` in from its leading edge
/// (`open` 0), to fill its whole frame (`open` 1). Drawn as the risen view's own shape, its content
/// stands on the glass.
struct RisingGlass: Shape {
    var open: CGFloat
    let side: CGFloat
    var inset: CGFloat = 0
    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * open }
        let height = mix(side, rect.height)
        let leading = rect.minX + inset * (1 - open)
        let frame = CGRect(x: leading, y: rect.maxY - height, width: rect.maxX - leading, height: height)
        let radius = min(mix(side / 2, 18), frame.height / 2, frame.width / 2)
        return RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous).path(in: frame)
    }
}

extension View {
    /// Liquid Glass in `shape` on macOS 26, answering the pointer when `interactive`; the window
    /// surface with a hairline and a soft shadow before it.
    @ViewBuilder func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(shape.fill(.regularMaterial)
                .overlay(shape.stroke(Theme.border, lineWidth: Theme.Size.hairline))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5))
        }
    }
}
