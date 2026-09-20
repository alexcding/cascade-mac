import SwiftUI
import Observation

/// The sidebar bell's popover — src/renderer/components/events-popover.js: today's activity rows
/// (the Activity page's events, today only), refreshed live while it is open, with "All events"
/// leading to the Activity page.
@MainActor @Observable final class TodayActivityViewModel {
    private(set) var entries: [LogEntry] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var visible = false
    /// The row whose PR / ticket page is being opened.
    private(set) var opening: Int?
    @ObservationIgnored private var service: (any LogService)?
    @ObservationIgnored private var task: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private let now: () -> Date
    /// Opens an entry's PR or Jira page in Craft (the popover's row links, events-popover.js).
    @ObservationIgnored var openPage: (LogEntry) async throws -> Void = { _ in }

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func connect(_ service: (any LogService)?) {
        self.service = service
        if visible { refresh() }
    }

    /// Every open starts from "Loading…", like the web popover: rows from an earlier open (maybe
    /// an earlier day) never stand in for today's.
    func setVisible(_ value: Bool) {
        visible = value
        entries = []; loaded = false; error = nil; opening = nil
        if value { refresh() } else { task = nil; loading = false }
    }

    /// A new activity event arrived: re-fetch only while the popover is showing.
    func activityReceived() { if visible { refresh() } }

    func refresh() {
        guard let service else { error = "Connect to load activity."; return }
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

    func canOpen(_ entry: LogEntry) -> Bool { entry.link != nil || entry.jiraKey != nil }

    /// Open a row's page; true when it opened (the popover then closes), false with `error` set.
    func open(_ entry: LogEntry) async -> Bool {
        guard canOpen(entry), opening == nil else { return false }
        opening = entry.id; error = nil
        defer { opening = nil }
        do { try await openPage(entry); return true }
        catch { self.error = "Could not open the page: \(error.localizedDescription)"; return false }
    }
}

struct TodayActivityPopover: View {
    let model: TodayActivityViewModel
    let showAllEvents: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today").font(.system(size: 12, weight: .semibold)).kerning(0.3)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            if let error = model.error, model.loaded {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.loaded {
                        empty(model.error ?? "Loading…", icon: false)
                    } else if model.entries.isEmpty {
                        empty("No activity today", icon: true)
                    } else {
                        ForEach(model.entries) { entry in
                            if model.canOpen(entry) {
                                Button {
                                    Task { if await model.open(entry) { dismiss() } }
                                } label: {
                                    TodayActivityRow(entry: entry, opening: model.opening == entry.id)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.opening != nil)
                                .help(entry.link ?? entry.jiraKey ?? "")
                            } else {
                                TodayActivityRow(entry: entry, opening: false)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button(action: showAllEvents) {
                Text("All events").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 340)
        .accessibilityIdentifier("today-activity-popover")
    }

    private func empty(_ text: String, icon: Bool) -> some View {
        HStack(spacing: 8) {
            if icon { Image(systemName: "clock").font(.system(size: 14)) }
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 12)
    }
}

/// .act-row: a tinted round icon, the event line with its detail, and how long ago.
private struct TodayActivityRow: View {
    let entry: LogEntry
    let opening: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityGlyphView(type: entry.type ?? "", level: entry.level).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opening {
                ProgressView().controlSize(.mini).padding(.top, 3)
            } else if let date = entry.date {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .padding(.top, 3).help(entry.created_at)
            }
        }
        .padding(8)
        .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovered = $0 && (entry.link != nil || entry.jiraKey != nil) }
        .accessibilityElement(children: .combine)
    }
}
