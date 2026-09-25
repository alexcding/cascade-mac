import Foundation

struct ReviewAnnouncementTracker {
    private var seeded = false
    private var markers: [String: String] = [:]

    mutating func consume(_ prs: [TrayPR]) -> [TrayPR] {
        let pending = prs.filter(\.pendingReview)
        let fresh = pending.filter { markers[$0.id] != ($0.requestedAt.flatMap { $0.isEmpty ? nil : $0 } ?? "pending") }
        markers = Dictionary(pending.map { ($0.id, $0.requestedAt.flatMap { $0.isEmpty ? nil : $0 } ?? "pending") },
                             uniquingKeysWith: { first, _ in first })
        defer { seeded = true }
        return seeded ? fresh : []
    }
}

public struct ActivityEvent: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        struct PR: Codable, Equatable, Sendable {
            let number: Int?
            let title: String?
            let url: String?
        }
        let repo: String?
        let pr: PR?
        let key: String?
        let transition: String?
        let version: String?
        let project: String?
        let error: String?
        let detail: String?
        var title: String? = nil
        var body: String? = nil
        var url: String? = nil
        var automation: String? = nil
        var subject: String? = nil
        var mode: String? = nil
    }
    let type: String
    let payload: Payload?
    let created_at: String?

    var message: NativeNotice {
        let p = payload
        let repo = p?.repo?.split(separator: "/").last.map(String.init) ?? String(localized: "repository")
        let prBody = "#\(p?.pr?.number.map(String.init) ?? "?") \(p?.pr?.title ?? "")".trimmingCharacters(in: .whitespaces)
        let title: String
        let body: String
        var url: String?
        switch type {
        case "pr_opened":
            title = String(localized: "Pull request opened in \(repo)"); body = prBody; url = p?.pr?.url
        case "pr_merged":
            title = String(localized: "Pull request merged in \(repo)"); body = prBody; url = p?.pr?.url
        case "pr_closed":
            title = String(localized: "Pull request closed in \(repo)"); body = prBody; url = p?.pr?.url
        case "jira_transitioned":
            title = "\(p?.key ?? String(localized: "Ticket")) → \(p?.transition ?? "?")"
            body = p?.version.map { String(localized: "Fix Version \($0)") } ?? ""
        case "jira_version_created": title = String(localized: "Fix Version \(p?.version ?? "?") created"); body = p?.project ?? ""
        case "jira_fixversion_set": title = String(localized: "Fix Version \(p?.version ?? "?") set"); body = p?.key ?? ""
        case "jira_transition_failed": title = String(localized: "Failed to transition \(p?.key ?? String(localized: "Ticket"))"); body = p?.error ?? ""
        case "jira_fixversion_failed": title = String(localized: "Failed to set Fix Version"); body = p?.error ?? ""
        case "sync_failed": title = String(localized: "Sync failed for \(repo)"); body = p?.error ?? ""
        case "automation_notify":
            title = p?.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Automation"); body = p?.body ?? ""; url = p?.url
        case "automation_run":
            title = p?.mode == "dry"
                ? String(localized: "Preview completed for \(p?.automation ?? String(localized: "Automation"))")
                : String(localized: "\(p?.automation ?? String(localized: "Automation")) ran")
            body = p?.subject ?? ""
        case "automation_failed": title = String(localized: "\(p?.automation ?? String(localized: "Automation")) failed"); body = p?.subject ?? ""
        case "automation_limited":
            title = String(localized: "\(p?.automation ?? String(localized: "Automation")) held back")
            body = [String(localized: "Over its hourly run limit"), p?.subject].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        default: title = diagnosticTitle ?? (type.isEmpty ? String(localized: "Activity") : type.replacingOccurrences(of: "_", with: " ").capitalized)
            body = p?.error ?? p?.detail ?? ""
        }
        return NativeNotice(kind: .activity, title: title, body: body, url: url.flatMap(safeWebURL)?.absoluteString, eventType: type)
    }

    private var diagnosticTitle: String? {
        switch type {
        case "worktree_setup_finished": String(localized: "Worktree setup finished")
        case "worktree_setup_failed": String(localized: "Worktree setup failed")
        case "worktree_fetch_skipped": String(localized: "Worktree fetch skipped")
        case "worktree_derived_data_deleted": String(localized: "Worktree build data deleted")
        case "worktree_derived_data_failed": String(localized: "Could not delete worktree build data")
        case "worktree_branch_deleted": String(localized: "Worktree branch deleted")
        case "worktree_branch_kept": String(localized: "Worktree branch kept")
        case "worktree_copy_failed": String(localized: "Could not copy worktree files")
        case "forwarder_started": String(localized: "Webhook forwarding started")
        case "forwarder_failed": String(localized: "Webhook forwarding failed")
        case "analyze_failed": String(localized: "Agent analysis failed")
        default: nil
        }
    }

}

extension ActivityEvent {
    private enum CodingKeys: String, CodingKey { case type, payload, created_at }

    // Both backends broadcast the stored log row, whose `payload` is the JSON
    // TEXT column as-is (the web renderer JSON.parses it); fixtures and the
    // Logs page hand over a decoded object. Accept either, and never let one
    // odd payload fail the whole server event: the stream would drop and the
    // reconnect banner would follow every activity event.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        created_at = try values.decodeIfPresent(String.self, forKey: .created_at)
        if let object = try? values.decodeIfPresent(Payload.self, forKey: .payload) {
            payload = object
        } else if let text = try? values.decodeIfPresent(String.self, forKey: .payload) {
            payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        } else {
            payload = nil
        }
    }
}

struct NativeNotice: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case review, activity }
    var id = UUID().uuidString
    let kind: Kind
    let title: String
    let body: String
    var url: String?
    var repo: String?
    var number: Int?
    /// The activity event's type (`pr_merged`, `sync_failed`, …) — picks the toast's glyph.
    var eventType: String? = nil
}

enum NotificationPermission: String, Sendable {
    case notDetermined, denied, authorized, unavailable
    var label: String {
        switch self {
        case .notDetermined: String(localized: "Notifications are not enabled")
        case .denied: String(localized: "Notifications are disabled in System Settings")
        case .authorized: String(localized: "Notifications enabled")
        case .unavailable: String(localized: "Notification status unavailable")
        }
    }
}

struct NotificationAccess: Sendable {
    var permission: NotificationPermission
    var soundAllowed = false
}

@MainActor protocol NotificationDelivery: AnyObject {
    func access() async -> NotificationAccess
    func requestAuthorization() async throws
    func deliver(_ notice: NativeNotice) async throws
    func playReviewSound(_ path: String) throws
}
