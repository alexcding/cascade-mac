import SwiftUI
import GhosttyTerminal

/// The emulator surface, full-bleed. Failures draw *over* it rather than above it, so the
/// terminal keeps one size — and therefore one PTY geometry — no matter what state it is in.
struct TerminalPane: View {
    let session: TerminalSession
    private var model: TerminalPaneViewModel { session.presentation }
    /// Both at once when both are set, so neither hides behind the other. `dismissNotice`
    /// hides this banner without clearing `error`/`styleError` themselves; a new error or
    /// style issue (a changed value, not just a re-set) shows it again.
    private var notice: String? {
        guard !session.noticeDismissed else { return nil }
        let messages = [session.error, session.styleError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    var body: some View {
        TerminalSurfaceView(context: session.surface)
            .id(session.surfaceGeneration)
            .allowsHitTesting(session.ready)
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            .background(.background)
            .overlay(alignment: .top) { if let notice { banner(notice) } }
            .onAppear(perform: model.appear)
            .onDisappear(perform: model.disappear)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification), perform: model.windowOcclusionChanged)
            .task { await model.start() }
    }


    /// Dismissible: a failure that has already been read must not keep covering output.
    /// Dismissing only hides this banner — it does not clear the underlying error.
    private func banner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: session.dismissNotice) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("Dismiss")
        }
        .font(Theme.Typography.emptyHint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: Theme.Size.hairline))
        .padding(10)
    }
}
