import SwiftUI

/// The Dashboard's own colours: the text steps, the priority ramp and the status pills the app palette
/// does not carry. Bars and usage take the menu bar tray's colours, so the two read alike.
enum DashboardPalette {
    static let ink2 = ThemeColor(light: 0x52514E, dark: 0xC3C2B7).color
    static let ink3 = ThemeColor(light: 0x6E6D68, dark: 0x9B9A90).color
    static let hairline = ThemeColor(light: 0xE6E5E0, dark: 0x2C2C2A).color
    static let link = ThemeColor(light: 0x1C5CAB, dark: 0x86B6EF).color
    static let criticalText = ThemeColor(light: 0xB02A2A, dark: 0xF08A8A).color
    static let buttonBorder = ThemeColor(light: 0xDDDCD6, dark: 0x383835).color
    /// What waits on the user: Needs you's amber, washed for a box behind it, and its outline.
    static let attention = ThemeColor(light: 0xFDF8EC, dark: 0x2A2310).color
    static let attentionRule = ThemeColor(light: 0xEAD7A6, dark: 0x4A3A14).color
    /// Needs you's words on the page or its box, clearing 4.5:1 in both appearances.
    static let attentionText = ThemeColor(light: 0x8A5A00, dark: 0xF5C45C).color

    /// A stage's chip: its words on a soft fill of its colour, clearing 4.5:1 in both appearances,
    /// in the ticket status pills' fills.
    static func stageChip(_ stage: DashboardSessionStage) -> (text: Color, fill: Color) {
        switch stage {
        case .needsYou: (ThemeColor(light: 0x6A4200, dark: 0xF5C45C).color, ThemeColor(light: 0xFCF0D6, dark: 0x382C14).color)
        case .working: (ThemeColor(light: 0x135E3C, dark: 0x6FD49C).color, ThemeColor(light: 0xDEF3E8, dark: 0x15302A).color)
        case .inReview: (ThemeColor(light: 0x1C4F8F, dark: 0x9EC5F4).color, ThemeColor(light: 0xE6F0FC, dark: 0x1B2B42).color)
        case .idle: (ink2, ThemeColor(light: 0xEEEDE8, dark: 0x2A2A28).color)
        }
    }

    /// A failure's tag: red words on a soft red fill, as a failing check's.
    static let criticalChip = (text: ThemeColor(light: 0x9E2626, dark: 0xF08A8A).color,
                               fill: ThemeColor(light: 0xFBE5E5, dark: 0x3A1A1A).color)

    /// Priority runs warm to cool: red, orange, amber, then a calm blue for Low, so urgency reads
    /// at a glance; the level's arrow glyph carries it without the colour.
    static func priority(_ level: TicketPriority) -> Color {
        switch level {
        case .urgent: return ThemeColor(light: 0xE5484D, dark: 0xEC5D5E).color
        case .high: return ThemeColor(light: 0xF5803A, dark: 0xF28A48).color
        case .medium: return ThemeColor(light: 0xC98A0A, dark: 0xE0AE35).color
        case .low: return ThemeColor(light: 0x7FB0EE, dark: 0x5A92DE).color
        }
    }

    /// A status pill's text and fill; the text clears 4.5:1 on its own fill in both appearances.
    static func pill(_ stage: TicketStage) -> (text: Color, fill: Color) {
        switch stage {
        case .toDo: return (ThemeColor(light: 0x1C4F8F, dark: 0x9EC5F4).color, ThemeColor(light: 0xE6F0FC, dark: 0x1B2B42).color)
        case .inProgress: return (ThemeColor(light: 0x6A4200, dark: 0xF5C45C).color, ThemeColor(light: 0xFCF0D6, dark: 0x382C14).color)
        case .pendingRelease: return (ThemeColor(light: 0x135E3C, dark: 0x6FD49C).color, ThemeColor(light: 0xDEF3E8, dark: 0x15302A).color)
        case .blocked: return (ThemeColor(light: 0xA12626, dark: 0xF08A8A).color, ThemeColor(light: 0xFBE5E5, dark: 0x3A1C1C).color)
        }
    }
}

/// A section's title line: the name, a quiet count or summary, and its refresh button far right,
/// level with the rows' trailing edge; the page's own trailing inset keeps both clear of the scroller.
struct DashboardSectionHeader: View {
    let title: String
    let detail: String
    var refresh: (() -> Void)? = nil
    var busy = false
    /// The refresh button's accessibility id, `dashboard-refresh-<id>`; stable across copy changes.
    var id = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.3)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            if let refresh {
                DashboardRefreshButton(name: title, id: id, busy: busy, action: refresh)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .padding(.bottom, 14)
    }
}

/// The outlined refresh button a section carries far right, level with its rows' trailing edge.
struct DashboardRefreshButton: View {
    let name: String
    let id: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small).scaleEffect(0.6) } }
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(DashboardPalette.buttonBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DashboardPalette.ink2)
        .disabled(busy)
        .accessibilityLabel("Refresh \(name)")
        .accessibilityIdentifier("dashboard-refresh-\(id)")
        .help("Refresh \(name)")
    }
}

/// An agent's own mark from the asset catalogue, tinted its colour.
struct AgentMark: View {
    let key: String
    var size: CGFloat = 14
    var body: some View {
        if let asset = PageSessionMark(cli: key).asset {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size).foregroundStyle(AgentDrivers.driver(for: key).tint).accessibilityHidden(true)
        }
    }
}

/// A short word on a soft fill of its colour: a stage on the board and in the tables, and what a
/// total or a warning needs.
struct DashboardTag: View {
    let text: String
    let tint: (text: Color, fill: Color)
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint.text).lineLimit(1)
            .padding(.horizontal, 7).frame(height: 20)
            .background(tint.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Tickets

/// A ticket's priority as Jira draws it: an arrow shape per level in the level's colour, named in
/// the tooltip and to VoiceOver.
struct TicketPriorityMark: View {
    let level: TicketPriority
    var body: some View {
        Image(systemName: level.symbol).font(.system(size: 10, weight: .bold))
            .foregroundStyle(DashboardPalette.priority(level)).frame(width: 14)
            .help("\(level.title) priority").accessibilityLabel("\(level.title) priority")
    }
}

/// A ticket's status as a filled pill, coloured by its stage.
struct TicketStatusPill: View {
    let row: DashboardTicketRow
    var body: some View {
        if !row.status.isEmpty {
            let colors = DashboardPalette.pill(row.stage)
            Text(row.status).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.text)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 7).frame(height: 20)
                .background(colors.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
