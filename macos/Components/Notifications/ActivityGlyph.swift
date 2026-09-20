import AppKit
import SwiftUI

/// One activity event's mark — the tinted round icon of pages/logs.js `presentEvent`, shared by the
/// activity toast and the bell's Today popover so both read like the same feed row.
@MainActor enum ActivityGlyph {
    static func style(type: String, level: String?) -> (icon: Image, tint: Color) {
        switch type {
        case "pr_opened", "review_requested":
            (Image(nsImage: SidebarIcons.brand("github", size: 15) ?? NSImage()).renderingMode(.template), .accentColor)
        case "pr_merged": (Image(systemName: "arrow.triangle.merge"), .purple)
        case "pr_closed": (Image(systemName: "xmark"), .secondary)
        case "jira_transitioned": (Image(systemName: "arrow.clockwise"), .green)
        case "jira_version_created": (Image(systemName: "plus"), .accentColor)
        case "jira_fixversion_set": (Image(systemName: "checkmark.circle"), .green)
        case "jira_transition_failed", "jira_fixversion_failed", "sync_failed": (Image(systemName: "exclamationmark.triangle"), .red)
        default: (Image(systemName: "clock"), level == "error" ? .red : level == "warn" ? .orange : .secondary)
        }
    }
}

/// .act-icon: a 28pt circle in the tint's soft background with the 15pt glyph.
struct ActivityGlyphView: View {
    let type: String
    let level: String?

    var body: some View {
        let style = ActivityGlyph.style(type: type, level: level)
        ZStack {
            Circle().fill(style.tint.opacity(0.12))
            style.icon.font(.system(size: 13, weight: .medium)).foregroundStyle(style.tint)
        }
        .frame(width: 28, height: 28)
    }
}
