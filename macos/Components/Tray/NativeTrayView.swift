import AppKit
import SwiftUI

/// The tray's width is fixed; its height is whatever the content needs, up to what the screen
/// can show without the popover running off the bottom.
enum TrayMetrics {
    static let width: CGFloat = 380
    /// The ceiling belongs to the screen the status item is on, since the popover hangs off it —
    /// not to whichever screen holds the key window. Falling back to the screen that owns the
    /// menu bar, which is the first one.
    static func maxHeight(on screen: NSScreen?) -> CGFloat {
        max(280, ((screen ?? NSScreen.screens.first)?.visibleFrame.height ?? 720) - 120)
    }
}

// The menu bar tray shows two things: the pull requests waiting on your review, and the AI plan
// usage. A review opens in a Craft tab. Everything else lives in the app's own window.
public struct NativeTrayView: View {
    let model: TrayViewModel
    /// Set from the status item's own screen each time the tray is about to open.
    var maxHeight: CGFloat = TrayMetrics.maxHeight(on: nil)
    /// What the content last measured. The first layout replaces this estimate, and every later
    /// one resizes the popover through the hosting controller's preferred content size.
    @State private var contentHeight: CGFloat = 320

    public init(model: TrayViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    reviews
                    if showsNothing {
                        Text("Nothing to review").foregroundStyle(.secondary).font(.callout)
                    }
                    Divider()
                    UsagePanel(shell: model.shell)
                }
                .padding(16)
                // Measured inside the scroll view, so this is the height the content wants, not the
                // height it was given: the panel hugs a short list and only a long one scrolls.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, maxHeight))
            .scrollBounceBehavior(.basedOnSize)
            if let error = model.actionError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 8) }
        }
        .frame(width: TrayMetrics.width)
        .accessibilityIdentifier("native-tray-panel")
    }

    /// Loaded, with no review request.
    private var showsNothing: Bool {
        model.shell.trayUpdated != nil && model.shell.trayError == nil && model.pendingReviews.isEmpty
    }

    private var reviews: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.shell.trayUpdated == nil || model.shell.trayError != nil || !model.pendingReviews.isEmpty {
                Text("Review requested").font(.headline)
            }
            if let error = model.shell.trayError {
                Text("Showing last available reviews. \(error)").font(.caption).foregroundStyle(.orange)
            }
            if model.shell.trayLoading && model.shell.trayUpdated == nil {
                ProgressView("Loading reviews…").controlSize(.small)
            } else if model.shell.trayUpdated == nil {
                Text("Connect to load review requests").foregroundStyle(.secondary).font(.callout)
            } else if model.pendingReviews.isEmpty && model.shell.trayError != nil {
                Text("Reviews unavailable").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(model.pendingReviews) { pr in
                Button {
                    model.openReview(pr)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: ciSymbol(pr)).foregroundStyle(ciColor(pr))
                            .accessibilityLabel(pr.ciLabel)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PR #\(pr.number) \(pr.title)").lineLimit(2).multilineTextAlignment(.leading)
                            Text("\(pr.projectName ?? pr.repo) · \(pr.ciLabel)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(!model.canOpen(pr))
                    .help("Open in a Craft tab and mark this review request opened")
            }
        }
    }

    private func ciSymbol(_ pr: TrayPR) -> String {
        if pr.ci?.status == "in_progress" { return "clock" }
        switch pr.ci?.conclusion { case "success": return "checkmark.circle"; case "failure": return "xmark.circle"; default: return "circle.dashed" }
    }
    private func ciColor(_ pr: TrayPR) -> Color {
        if pr.ci?.status == "in_progress" { return .orange }
        switch pr.ci?.conclusion { case "success": return .green; case "failure": return .red; default: return .secondary }
    }
}
