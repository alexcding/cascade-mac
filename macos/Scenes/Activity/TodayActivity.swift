import SwiftUI
import Observation

/// The sidebar's Today menu — src/renderer/components/events-popover.js: today's activity rows
/// (the Activity page's events, today only), refreshed live while it is open, with "Show all activity"
/// leading to the Activity page. Rows are read here, not links.
@MainActor @Observable final class TodayActivityViewModel {
    private(set) var entries: [LogEntry] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var visible = false
    @ObservationIgnored private var service: (any LogService)?
    @ObservationIgnored private var task: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func connect(_ service: (any LogService)?) {
        self.service = service
        if visible { refresh() }
    }

    /// Every open starts from "Loading…", like the web popover: rows from an earlier open (maybe
    /// an earlier day) never stand in for today's.
    func setVisible(_ value: Bool) {
        visible = value
        entries = []; loaded = false; error = nil
        if value { refresh() } else { task = nil; loading = false }
    }

    /// A new activity event arrived: re-fetch only while the popover is showing.
    func activityReceived() { if visible { refresh() } }

    func refresh() {
        guard let service else { error = String(localized: "Connect to load activity."); return }
        loading = true
        task = Task { [weak self] in
            do {
                let all = try await service.entries(category: "event", errorsOnly: false)
                try Task.checkCancellation()
                guard let self else { return }
                let today = now()
                entries = all.filter { entry in entry.date.map { Calendar.current.isDate($0, inSameDayAs: today) } ?? false }
                error = nil; loaded = true; loading = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
}

/// The menu's content. While `revealed` turns on, its parts settle in one after another from the
/// foot up, and leave the other way.
struct TodayActivityMenu: View {
    let model: TodayActivityViewModel
    let revealed: Bool
    /// The most the list may take, so the menu stays inside its column.
    var listHeight: CGFloat = 360
    let showAllEvents: () -> Void

    var body: some View {
        let count = model.entries.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.loaded, count > 0 {
                    Text("\(count) today").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 4)
            .settles(revealed, step: min(count, 8) + 2)
            if let error = model.error, model.loaded {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.loaded {
                        empty(model.error ?? "Loading…", icon: false)
                    } else if model.entries.isEmpty {
                        empty(String(localized: "No activity today"), icon: true)
                    } else {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            TodayActivityRow(entry: entry).help(entry.summary).settles(revealed, step: max(min(count, 8) - index, 0) + 1)
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 4)
            }
            .frame(maxHeight: listHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.6).settles(revealed, step: 0)
            Button(action: showAllEvents) {
                Text("Show all activity →").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 11).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settles(revealed, step: 0)
        }
        .accessibilityIdentifier("today-activity-menu")
    }

    private func empty(_ text: String, icon: Bool) -> some View {
        HStack(spacing: 8) {
            if icon { Image(systemName: "clock").font(.system(size: 14)) }
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        .frame(maxWidth: .infinity, minHeight: 150).padding(.horizontal, 12)
    }
}

private extension View {
    /// Settles in `step` beats after the menu starts to open, rising a little as it fades in.
    func settles(_ revealed: Bool, step: Int) -> some View {
        opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 10)
            .animation(revealed ? .smooth(duration: 0.3).delay(0.12 + Double(step) * 0.045) : .easeOut(duration: 0.12), value: revealed)
    }
}

/// .act-row, as the menu draws it: a tinted round icon, the event's line on up to two lines and its
/// detail on one.
private struct TodayActivityRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 9) {
            ActivityGlyphView(type: entry.type ?? "", level: entry.level, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
