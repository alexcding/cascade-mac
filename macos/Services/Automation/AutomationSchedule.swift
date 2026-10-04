import Foundation

/// How a scheduled automation's times read, and the editor's conversions to and from them.
extension Automation.Schedule {
    /// The repeat on its own, as the New menu and a template's kicker name it.
    var repeatLabel: String { Self.label(self.repeat) }

    static func label(_ value: Repeat) -> String {
        switch value {
        case .daily: String(localized: "Daily")
        case .weekdays: String(localized: "Weekdays")
        case .weekly: String(localized: "Weekly")
        case .hours: String(localized: "Every few hours")
        case .cron: String(localized: "Cron")
        }
    }

    /// When it runs, as the table shows it: "Weekdays at 9:00 AM".
    var summary: String {
        let at = Self.clock(time)
        switch self.repeat {
        case .daily: return String(localized: "Daily at \(at)")
        case .weekdays: return String(localized: "Weekdays at \(at)")
        case .weekly:
            let names = Calendar.current.shortWeekdaySymbols
            // ISO 1 is Monday; the calendar's symbols start on Sunday.
            let days = days.sorted().filter { (1...7).contains($0) }.map { names[$0 % 7] }
            return days.isEmpty ? String(localized: "Weekly, no days chosen") : String(localized: "\(days.joined(separator: ", ")) at \(at)")
        case .hours:
            return everyHours == 1 ? String(localized: "Hourly from \(at)") : String(localized: "Every \(everyHours) hours from \(at)")
        case .cron:
            let expression = cron.trimmingCharacters(in: .whitespaces)
            return expression.isEmpty ? String(localized: "Cron, not set") : String(localized: "Cron \(expression)")
        }
    }

    /// The time of day as a date today, for a time picker.
    var timeOfDay: Date {
        get {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            let hour = parts.first ?? 9, minute = parts.count > 1 ? parts[1] : 0
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
    }

    /// `HH:MM` as the user's clock writes it.
    static func clock(_ time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
        else { return time }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// How late a missed run may still start, as the editor offers it.
    static let graceChoices: [(minutes: Int, label: String)] = [
        (0, String(localized: "Don’t catch up")),
        (15, String(localized: "15 minutes")),
        (60, String(localized: "1 hour")),
        (4 * 60, String(localized: "4 hours")),
        (12 * 60, String(localized: "12 hours")),
        (24 * 60, String(localized: "1 day")),
    ]

    /// How long a precheck may run, as the editor offers it.
    static let timeoutChoices: [(seconds: Int, label: String)] = [
        (15, String(localized: "15 sec")),
        (30, String(localized: "30 sec")),
        (60, String(localized: "1 min")),
        (5 * 60, String(localized: "5 min")),
        (10 * 60, String(localized: "10 min")),
    ]
}
