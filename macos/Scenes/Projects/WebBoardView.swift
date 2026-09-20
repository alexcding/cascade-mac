import AppKit
import SwiftUI

struct WebBoardView: View {
    let model: WebBoardViewModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let title = model.sprintTitle { Text(title).font(.headline) }
                Spacer()
                TextField("Filter, e.g. component = iOS", text: Bindable(model).queryDraft)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 170, maxWidth: 260)
                    .focused($queryFocused)
                    .onSubmit { model.applyQuery() }
                    .help("A JQL clause ANDed into the board and the tickets (blank = everything). Return applies.")
                    .onChange(of: queryFocused) { _, focused in model.queryEditing = focused }
                Picker("Assignee", selection: Bindable(model).assigneeFilter) {
                    Text("All assignees").tag("")
                    if model.showsUnassignedFilter { Text("Unassigned").tag(WebBoardViewModel.unassigned) }
                    ForEach(model.assignees, id: \.id) { Text($0.name).tag($0.id) }
                }.frame(width: 190)
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh Board", systemImage: "arrow.clockwise") { model.reload() }.labelStyle(.iconOnly)
            }
            if let error = model.navigation.error { Text(error).foregroundStyle(Theme.warn).textSelection(.enabled) }
            if let error = model.error, model.emptyMessage != error { Text(error).foregroundStyle(Theme.warn).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(Theme.textSecondary).transition(.opacity) }
            if model.snapshot == nil {
                if model.loading {
                    ProgressView("Loading…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Active Sprint", systemImage: "rectangle.3.group")
                }
            } else if let message = model.emptyMessage {
                ContentUnavailableView(message, systemImage: "rectangle.3.group")
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.groups) { group in BoardColumnView(model: model, group: group) }
                    }.padding(.bottom, 8).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.notice)
        .task(id: model.dragID) { await watchDragEnd() }
    }

    /// SwiftUI reports a drag's start but not its end when the card is released somewhere that is
    /// not a drop zone, so watch the mouse button while a drag is live.
    private func watchDragEnd() async {
        guard let drag = model.dragID else { return }
        // Give the drag session a moment to take the button before sampling it.
        try? await Task.sleep(for: .milliseconds(300))
        while !Task.isCancelled, model.dragID == drag {
            if NSEvent.pressedMouseButtons & 1 == 0 {
                // A drop's action lands after the release; keep the zones mounted until it has.
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { model.endDrag(drag) }
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

private struct BoardColumnView: View {
    let model: WebBoardViewModel
    let group: BoardGroup

    var body: some View {
        let dragging = model.draggingKey != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(group.total)").monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            // The cards stay mounted under the drop zones: removing the view a drag started from
            // can drop the session's end on the floor.
            ZStack(alignment: .top) {
                // Bound each column to the viewport. Eager stacks measured every card (and its
                // menus) on tab entry and compressed long columns to fit.
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(group.lanes) { lane in
                            ForEach(lane.tickets) { ticket in BoardCard(model: model, ticket: ticket) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 30)
                }
                .opacity(dragging ? 0 : 1)
                .allowsHitTesting(!dragging)
                if dragging {
                    VStack(spacing: 8) {
                        // A lane with no status name can't be a transition target, so an empty one
                        // is hidden. "Other" holds cards and stays, and a drop there is refused
                        // with a pointer to the move menu, as on the old board.
                        ForEach(group.lanes.filter { !$0.status.isEmpty || !$0.tickets.isEmpty }) { lane in
                            BoardDropZone(model: model, lane: lane, labeled: group.isGrouped)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(10)
        .frame(width: 280, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.12), value: dragging)
    }
}

/// One status while a card is being dragged: an equal-height labelled target, ringed in the
/// accent colour while the pointer is over it.
private struct BoardDropZone: View {
    let model: WebBoardViewModel
    let lane: BoardLane
    let labeled: Bool

    var body: some View {
        let targeted = model.dropTarget == lane.id
        let tint = targeted ? Theme.accent : Theme.textTertiary
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 5) {
            if labeled {
                HStack {
                    Text(lane.status.isEmpty ? "—" : lane.status.uppercased())
                        .font(.caption2.weight(.bold)).tracking(0.4).lineLimit(1)
                    Spacer()
                    Text("\(lane.tickets.count)").font(.caption2).monospacedDigit()
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 3)
            }
            shape
                .fill(targeted ? Theme.accentBackground : Color.clear)
                .overlay {
                    if targeted { shape.strokeBorder(Theme.accent, lineWidth: 2) }
                    else { shape.strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                }
                .overlay {
                    if !labeled { Text(lane.status.isEmpty ? "—" : lane.status).font(.callout).foregroundStyle(tint) }
                }
                .frame(minHeight: 40)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first else { model.endDrag(); return false }
            return model.drop(key, on: lane)
        } isTargeted: { model.target(lane, $0) }
        .animation(.easeOut(duration: 0.12), value: targeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Move to \(lane.status.isEmpty ? "unmapped status" : lane.status)")
    }
}

private struct BoardCard: View {
    let model: WebBoardViewModel
    let ticket: JiraTicket
    @State private var hovering = false

    var body: some View {
        let dragged = model.draggingKey == ticket.key
        VStack(alignment: .leading, spacing: 10) {
            Text(ticket.summary ?? "")
                .font(.body.weight(.medium))
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 18)
            HStack(spacing: 4) {
                BoardTypeMark(type: ticket.type)
                Button(ticket.key) { model.open(ticket) }
                    .buttonStyle(.plain).font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                BoardPriorityMark(priority: ticket.priority)
                Spacer(minLength: 4)
                assigneeMenu
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(hovering ? Theme.textTertiary : Theme.border))
        .overlay(alignment: .topTrailing) { if hovering { moveMenu.padding(6) } }
        .opacity(dragged ? 0.5 : model.busy.contains(ticket.key) ? 0.55 : 1)
        .onHover { hovering = $0 }
        .onDrag {
            model.beginDrag(ticket)
            return NSItemProvider(object: ticket.key as NSString)
        }
        .contextMenu {
            Button("Open Ticket") { model.open(ticket) }
            Divider()
            Menu("Move To") { moveItems }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ticket.key), \(ticket.summary ?? "")")
    }

    @ViewBuilder private var moveItems: some View {
        ForEach(model.columns.filter { $0 != ticket.status }, id: \.self) { status in
            Button(status) { model.move(ticket, to: status) }
        }
    }

    private var moveMenu: some View {
        Menu { moveItems } label: {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .frame(width: 20, height: 20)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(Theme.textTertiary)
        .help("Move to status")
    }

    private var assigneeMenu: some View {
        Menu {
            Button("Unassigned") { model.assign(ticket, to: "") }
            Divider()
            ForEach(model.assignees, id: \.id) { person in Button(person.name) { model.assign(ticket, to: person.id) } }
        } label: {
            BoardAvatar(name: ticket.assignee, mine: model.isMine(ticket))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(ticket.assignee.map { "Assigned to \($0)" } ?? "Assign")
        .accessibilityLabel(ticket.assignee.map { "Assignee \($0)" } ?? "Assign")
    }
}

/// Initials in a circle; a dashed "+" when unassigned; accent-tinted when the ticket is mine.
private struct BoardAvatar: View {
    let name: String?
    let mine: Bool

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return "?" }
        let second = parts.count > 1 ? parts[parts.count - 1].prefix(1) : first.dropFirst().prefix(1)
        return (first.prefix(1) + second).uppercased()
    }

    var body: some View {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        ZStack {
            if trimmed.isEmpty {
                Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Image(systemName: "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
            } else {
                Circle().fill(mine ? Theme.accentBackground : Theme.surfaceHover)
                Text(Self.initials(trimmed)).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(mine ? Theme.accent : Theme.textSecondary)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(Circle())
    }
}

/// The Jira issue-type glyph, coloured by type. Unknown types fall back to their name.
private struct BoardTypeMark: View {
    let type: String?

    var body: some View {
        let key = (type ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let mark: (symbol: String, color: Color)? = switch key {
        case "story": ("bookmark", Theme.success)
        case "bug": ("ladybug", Theme.danger)
        case "task", "sub-task", "subtask": ("checkmark.square", Theme.accent)
        case "epic": ("bolt", Theme.merged)
        default: nil
        }
        if let mark {
            Image(systemName: mark.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(mark.color).help(type ?? "")
                .accessibilityLabel(type ?? "")
        } else if let type, !type.isEmpty {
            Text(type).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }
}

/// Stacked chevrons: three for high (red), two for medium (amber), one for low (grey).
private struct BoardPriorityMark: View {
    let priority: String?

    static func level(_ priority: String?) -> Int {
        let value = (priority ?? "").lowercased()
        // Highest/lowest are checked through the high/low words they contain.
        if ["highest", "high", "blocker", "critical", "urgent", "major"].contains(where: value.contains) { return 3 }
        if ["medium", "normal"].contains(where: value.contains) { return 2 }
        if ["lowest", "low", "minor", "trivial"].contains(where: value.contains) { return 1 }
        return 0
    }

    var body: some View {
        let level = Self.level(priority)
        if level > 0 {
            BoardChevrons(count: level)
                .stroke(level == 3 ? Theme.danger : level == 2 ? Theme.warn : Theme.textTertiary,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
                .help("\(priority ?? "") priority")
                .accessibilityLabel("\(priority ?? "") priority")
        }
    }
}

private struct BoardChevrons: Shape {
    let count: Int

    // Each chevron is 6 wide by 3 tall on a 14 grid, stacked 3 apart and centred vertically.
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 14
        let top = (14 - (3 + 3 * CGFloat(count - 1))) / 2
        var path = Path()
        for index in 0..<count {
            let y = top + 3 * CGFloat(index)
            path.move(to: CGPoint(x: rect.minX + 4 * unit, y: rect.minY + (y + 3) * unit))
            path.addLine(to: CGPoint(x: rect.minX + 7 * unit, y: rect.minY + y * unit))
            path.addLine(to: CGPoint(x: rect.minX + 10 * unit, y: rect.minY + (y + 3) * unit))
        }
        return path
    }
}
