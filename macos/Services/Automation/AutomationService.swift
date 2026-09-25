import Foundation

/// A pipeline as the backend stores it: one trigger, then filters and actions in order.
struct Automation: Codable, Equatable, Identifiable, Sendable {
    /// On or off. "live" is the stored name for on; try a pipeline with Dry Run before switching it on.
    enum Mode: String, Codable, CaseIterable, Sendable {
        case off, live
        var label: String { self == .live ? String(localized: "On") : String(localized: "Off") }
    }
    struct Trigger: Codable, Equatable, Sendable {
        var types: [String] = []
        /// Project IDs a PR event must belong to; empty covers every project.
        var projects: [String] = []
        var params: [String: ParamValue] = [:]

        init(types: [String] = [], projects: [String] = [], params: [String: ParamValue] = [:]) {
            self.types = types; self.projects = projects; self.params = params
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            types = try values.decodeIfPresent([String].self, forKey: .types) ?? []
            projects = try values.decodeIfPresent([String].self, forKey: .projects) ?? []
            params = try values.decodeIfPresent([String: ParamValue].self, forKey: .params) ?? [:]
        }
    }
    struct RunSummary: Codable, Equatable, Sendable {
        let status: String
        let mode: String
        let finishedAt: String
    }

    var id: String = ""
    var name: String = ""
    var mode: Mode = .off
    var armedAt: String? = nil
    var trigger = Trigger()
    var steps: [AutomationStep] = []
    var position: Int = 0
    var lastRun: RunSummary? = nil

    init(name: String = "", mode: Mode = .off, trigger: Trigger = Trigger(), steps: [AutomationStep] = []) {
        self.name = name; self.mode = mode; self.trigger = trigger; self.steps = steps
    }
    // Templates and older rows omit fields; every one of them has a default.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        // An unknown mode, such as the retired watch-only one, reads as off.
        mode = (try? values.decodeIfPresent(Mode.self, forKey: .mode)) ?? .off
        armedAt = try values.decodeIfPresent(String.self, forKey: .armedAt)
        trigger = try values.decodeIfPresent(Trigger.self, forKey: .trigger) ?? Trigger()
        steps = try values.decodeIfPresent([AutomationStep].self, forKey: .steps) ?? []
        position = try values.decodeIfPresent(Int.self, forKey: .position) ?? 0
        lastRun = try values.decodeIfPresent(RunSummary.self, forKey: .lastRun)
    }

    /// What the list shows under the name.
    func summary(_ catalog: AutomationCatalog?) -> String {
        let triggers = trigger.types.map { catalog?.trigger($0)?.localizedLabel ?? $0 }
        let when = triggers.isEmpty ? String(localized: "No trigger") : triggers.joined(separator: String(localized: " or "))
        let actions = steps.filter { $0.kind == .action }.map { catalog?.action($0.type)?.localizedLabel ?? $0.type }
        return actions.isEmpty ? when : "\(when) → \(actions.joined(separator: ", "))"
    }
}

struct AutomationStep: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case filter, action }
    var id: String = UUID().uuidString
    var kind: Kind
    var type: String
    var params: [String: ParamValue] = [:]
    /// An action whose failure is recorded without stopping the actions after it.
    var continueOnError = false

    init(id: String = UUID().uuidString, kind: Kind, type: String, params: [String: ParamValue] = [:],
         continueOnError: Bool = false) {
        self.id = id; self.kind = kind; self.type = type; self.params = params; self.continueOnError = continueOnError
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .filter
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        params = try values.decodeIfPresent([String: ParamValue].self, forKey: .params) ?? [:]
        continueOnError = try values.decodeIfPresent(Bool.self, forKey: .continueOnError) ?? false
    }
}

/// A node parameter's value: the JSON shapes the catalogue's param kinds use.
enum ParamValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case list([String])
    case null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let list = try? value.decode([String].self) { self = .list(list) }
        else { self = .null }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { try value.encode(Int(number)) } else { try value.encode(number) }
        case .flag(let flag): try value.encode(flag)
        case .list(let list): try value.encode(list)
        case .null: try value.encodeNil()
        }
    }
    /// Text as a field shows it: lists comma-joined, numbers without a trailing ".0".
    var text: String {
        switch self {
        case .text(let text): text
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .flag(let flag): flag ? "true" : ""
        case .list(let list): list.joined(separator: ", ")
        case .null: ""
        }
    }
    var flag: Bool { if case .flag(let flag) = self { flag } else { false } }
}

/// Every node the editor can place, served by the backend.
struct AutomationCatalog: Decodable, Equatable, Sendable {
    /// The params a node shows for these values: those whose `when` holds, an unset sibling
    /// counting as its default.
    static func visible(_ params: [Param], values: [String: ParamValue]) -> [Param] {
        params.filter { param in
            (param.when ?? [:]).allSatisfy { key, expected in
                let current = values[key] ?? params.first { $0.key == key }?.default
                return current?.text == expected
            }
        }
    }

    struct Option: Decodable, Equatable, Sendable {
        let value: String
        let label: String
        var localizedLabel: String { AutomationCatalogText.localized(label) }
    }
    struct Param: Decodable, Equatable, Identifiable, Sendable {
        let key: String
        let label: String
        let kind: String
        var options: [Option]? = nil
        var placeholder: String? = nil
        var help: String? = nil
        var `default`: ParamValue? = nil
        /// Shown only while each named sibling param holds the given value, such as the Fix
        /// Version name, which only a template needs.
        var when: [String: String]? = nil
        var localizedLabel: String { AutomationCatalogText.localized(label) }
        var localizedHelp: String? { help.map(AutomationCatalogText.localized) }
        var id: String { key }
    }
    struct Node: Decodable, Equatable, Identifiable, Sendable {
        let kind: String
        let type: String
        let group: String
        let label: String
        let summary: String
        let subject: String
        let params: [Param]
        var localizedLabel: String { AutomationCatalogText.localized(label) }
        var localizedSummary: String { AutomationCatalogText.localized(summary) }
        var id: String { type }
    }
    struct Template: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let summary: String
        let automation: Automation
        var localizedName: String { AutomationCatalogText.localized(name) }
        var localizedSummary: String { AutomationCatalogText.localized(summary) }
    }
    let triggers: [Node]
    let filters: [Node]
    let actions: [Node]
    var templates: [Template] = []
    let variables: [String]

    func trigger(_ type: String) -> Node? { triggers.first { $0.type == type } }
    func filter(_ type: String) -> Node? { filters.first { $0.type == type } }
    func action(_ type: String) -> Node? { actions.first { $0.type == type } }
    func node(for step: AutomationStep) -> Node? { step.kind == .filter ? filter(step.type) : action(step.type) }
    /// Nodes grouped for a picker menu, in catalogue order.
    static func grouped(_ nodes: [Node]) -> [(group: String, nodes: [Node])] {
        var order: [String] = []
        var groups: [String: [Node]] = [:]
        for node in nodes {
            if groups[node.group] == nil { order.append(node.group) }
            groups[node.group, default: []].append(node)
        }
        return order.map { (AutomationCatalogText.localized($0), groups[$0] ?? []) }
    }
    /// A step with each param at its catalogue default.
    func step(kind: AutomationStep.Kind, type: String) -> AutomationStep {
        let node = kind == .filter ? filter(type) : action(type)
        var params: [String: ParamValue] = [:]
        for param in node?.params ?? [] { if let value = param.default { params[param.key] = value } }
        return AutomationStep(kind: kind, type: type, params: params)
    }
}

/// One run of a pipeline: whether the trigger matched, then each step's outcome and commands.
struct AutomationTrace: Decodable, Equatable, Identifiable, Sendable {
    struct Step: Decodable, Equatable, Identifiable, Sendable {
        let stepId: String
        let node: String
        let label: String
        /// `passed`, `failed`, `planned`, `done`, `error` or `skipped`.
        let status: String
        let detail: String
        let commands: [String]
        var id: String { stepId }
    }
    var runID: Int? = nil
    let automationId: String
    let automationName: String
    let eventKind: String
    let eventKey: String
    let subject: String
    let mode: String
    let triggerMatched: Bool
    let triggerDetail: String
    /// `completed`, `filtered`, `error` or `limited`.
    let status: String
    let steps: [Step]
    let startedAt: String
    let finishedAt: String
    var id: String { runID.map(String.init) ?? "\(automationId):\(startedAt)" }

    private enum CodingKeys: String, CodingKey {
        case runID = "id", automationId, automationName, eventKind, eventKey, subject, mode, triggerMatched,
             triggerDetail, status, steps, startedAt, finishedAt
    }
}

/// A PR or ticket to dry-run against.
struct AutomationSample: Codable, Equatable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: String
    var projectId: String? = nil
    var number: Int? = nil
    var key: String? = nil
    let label: String
    var detail: String? = nil
}

struct AutomationSettings: Decodable, Equatable, Sendable {
    var paused: Bool
    var forwardWebhooks: Bool
    /// Repos with a webhook forwarder running now.
    var forwarding: [String]
    /// Repos an armed PR pipeline covers, which forwarding would serve.
    var forwardable: [String]
}

protocol AutomationService: Sendable {
    func list() async throws -> [Automation]
    func catalog() async throws -> AutomationCatalog
    func save(_ automation: Automation) async throws -> Automation
    func delete(id: String) async throws
    func samples(kind: String, projects: [String], jql: String) async throws -> [AutomationSample]
    func dryRun(_ automation: Automation, sample: AutomationSample, event: String?) async throws -> AutomationTrace
    func run(id: String, sample: AutomationSample, event: String?) async throws -> AutomationTrace
    func runs(id: String?) async throws -> [AutomationTrace]
    func settings() async throws -> AutomationSettings
    func updateSettings(paused: Bool?, forwardWebhooks: Bool?) async throws -> AutomationSettings
}

struct APIAutomationService: AutomationService {
    let api: APIClient

    private struct Ok: Decodable, Sendable {}
    private struct SampleBody: Encodable, Sendable {
        let kind: String
        let projectId: String?
        let number: Int?
        let key: String?
        let event: String?
        init(_ sample: AutomationSample, event: String?) {
            kind = sample.kind; projectId = sample.projectId; number = sample.number; key = sample.key; self.event = event
        }
    }

    func list() async throws -> [Automation] { try await api.get(Routes.AUTOMATIONS) }
    func catalog() async throws -> AutomationCatalog { try await api.get(Routes.AUTOMATIONS_CATALOG) }
    func save(_ automation: Automation) async throws -> Automation {
        if automation.id.isEmpty { return try await api.request(Routes.AUTOMATIONS, method: "POST", body: automation) }
        return try await api.request(Routes.automation(automation.id), method: "PUT", body: automation)
    }
    func delete(id: String) async throws {
        struct Empty: Encodable, Sendable {}
        let _: Ok = try await api.request(Routes.automation(id), method: "DELETE", body: Empty())
    }
    func samples(kind: String, projects: [String], jql: String) async throws -> [AutomationSample] {
        try await api.get(APIClient.query(Routes.AUTOMATIONS_SAMPLES, ["kind": kind, "projects": projects.joined(separator: ","), "jql": jql]),
                          timeout: 45)
    }
    func dryRun(_ automation: Automation, sample: AutomationSample, event: String?) async throws -> AutomationTrace {
        struct Body: Encodable, Sendable { let automation: Automation; let sample: SampleBody }
        return try await api.request(Routes.AUTOMATIONS_DRY_RUN, method: "POST",
                                     body: Body(automation: automation, sample: SampleBody(sample, event: event)))
    }
    func run(id: String, sample: AutomationSample, event: String?) async throws -> AutomationTrace {
        struct Body: Encodable, Sendable { let sample: SampleBody }
        return try await api.request(Routes.automationRun(id), method: "POST", body: Body(sample: SampleBody(sample, event: event)))
    }
    func runs(id: String?) async throws -> [AutomationTrace] {
        try await api.get(APIClient.query(Routes.AUTOMATIONS_RUNS, id.map { ["automation": $0] } ?? [:]))
    }
    func settings() async throws -> AutomationSettings { try await api.get(Routes.AUTOMATIONS_SETTINGS) }
    func updateSettings(paused: Bool?, forwardWebhooks: Bool?) async throws -> AutomationSettings {
        struct Body: Encodable, Sendable { let paused: Bool?; let forwardWebhooks: Bool? }
        return try await api.request(Routes.AUTOMATIONS_SETTINGS, method: "PUT", body: Body(paused: paused, forwardWebhooks: forwardWebhooks))
    }
}

/// Only backend-owned catalog copy is localized. API identifiers, user names, parameter
/// values, commands, and diagnostic details are preserved verbatim.
enum AutomationCatalogText {
    static func localized(_ source: String) -> String {
        switch source {
        case "A draft PR is marked ready.": String(localized: "A draft PR is marked ready.")
        case "A new pull request appears.": String(localized: "A new pull request appears.")
        case "A notification the moment someone asks for your review.": String(localized: "A notification the moment someone asks for your review.")
        case "A pull request is closed without merging.": String(localized: "A pull request is closed without merging.")
        case "A pull request is merged.": String(localized: "A pull request is merged.")
        case "A reviewer requests changes.": String(localized: "A reviewer requests changes.")
        case "A ticket in the JQL changes status.": String(localized: "A ticket in the JQL changes status.")
        case "A ticket newly matches the JQL.": String(localized: "A ticket newly matches the JQL.")
        case "Add labels": String(localized: "Add labels")
        case "Add labels to each ticket. Needs a Jira API token.": String(localized: "Add labels to each ticket. Needs a Jira API token.")
        case "Add labels to the PR.": String(localized: "Add labels to the PR.")
        case "Add ticket labels": String(localized: "Add ticket labels")
        case "An open PR has had no update for a number of days.": String(localized: "An open PR has had no update for a number of days.")
        case "Approve": String(localized: "Approve")
        case "Approve PRs from people you trust once CI is green.": String(localized: "Approve PRs from people you trust once CI is green.")
        case "Approve green dependency bumps and let GitHub merge them.": String(localized: "Approve green dependency bumps and let GitHub merge them.")
        case "Approve the PR as you. Never approves your own PR.": String(localized: "Approve the PR as you. Never approves your own PR.")
        case "Approved": String(localized: "Approved")
        case "Ask users or org/team slugs to review.": String(localized: "Ask users or org/team slugs to review.")
        case "Assign": String(localized: "Assign")
        case "Assign each ticket. @me is you; empty unassigns.": String(localized: "Assign each ticket. @me is you; empty unassigns.")
        case "Assign ticket": String(localized: "Assign ticket")
        case "Assign users to the PR. @me is you.": String(localized: "Assign users to the PR. @me is you.")
        case "Assignee": String(localized: "Assignee")
        case "Assignees": String(localized: "Assignees")
        case "Author": String(localized: "Author")
        case "Auto-approve trusted authors": String(localized: "Auto-approve trusted authors")
        case "Base branch": String(localized: "Base branch")
        case "Bring the PR branch up to date with its base.": String(localized: "Bring the PR branch up to date with its base.")
        case "CI failed": String(localized: "CI failed")
        case "CI failed → re-run checks": String(localized: "CI failed → re-run checks")
        case "CI is": String(localized: "CI is")
        case "CI passed": String(localized: "CI passed")
        case "CI state": String(localized: "CI state")
        case "Changed paths": String(localized: "Changed paths")
        case "Changes requested": String(localized: "Changes requested")
        case "Changes requested → In Progress": String(localized: "Changes requested → In Progress")
        case "Checks on the head commit turn green.": String(localized: "Checks on the head commit turn green.")
        case "Checks on the head commit turn red.": String(localized: "Checks on the head commit turn red.")
        case "Close": String(localized: "Close")
        case "Close the PR without merging.": String(localized: "Close the PR without merging.")
        case "Comment": String(localized: "Comment")
        case "Comment (optional)": String(localized: "Comment (optional)")
        case "Comment on ticket": String(localized: "Comment on ticket")
        case "Conflicting": String(localized: "Conflicting")
        case "Dates: {year} {month} {day} {isoWeek}, unpadded {y} {m} {d} {w}, offsets like {year-2000}; also {prNumber} and any {{variable}} below. {year}.{isoWeek} is 2026.39 in week 39.": String(localized: "Dates: {year} {month} {day} {isoWeek}, unpadded {y} {m} {d} {w}, offsets like {year-2000}; also {prNumber} and any {{variable}} below. {year}.{isoWeek} is 2026.39 in week 39.")
        case "Days": String(localized: "Days")
        case "Days without update": String(localized: "Days without update")
        case "Decision": String(localized: "Decision")
        case "Delete branch after merge": String(localized: "Delete branch after merge")
        case "Dependabot → approve and auto-merge": String(localized: "Dependabot → approve and auto-merge")
        case "Draft": String(localized: "Draft")
        case "Enable auto-merge": String(localized: "Enable auto-merge")
        case "Failing": String(localized: "Failing")
        case "From": String(localized: "From")
        case "GitHub's review decision.": String(localized: "GitHub's review decision.")
        case "Globs over the files the PR changes.": String(localized: "Globs over the files the PR changes.")
        case "Has a linked ticket": String(localized: "Has a linked ticket")
        case "Head branch": String(localized: "Head branch")
        case "Hear about new tickets assigned to you.": String(localized: "Hear about new tickets assigned to you.")
        case "Is draft": String(localized: "Is draft")
        case "Keeps only tickets in one of these statuses.": String(localized: "Keeps only tickets in one of these statuses.")
        case "Keeps only tickets in these Jira projects.": String(localized: "Keeps only tickets in these Jira projects.")
        case "Keeps only tickets of these types.": String(localized: "Keeps only tickets of these types.")
        case "Keeps only tickets with these priorities.": String(localized: "Keeps only tickets with these priorities.")
        case "Labels": String(localized: "Labels")
        case "Manual": String(localized: "Manual")
        case "Mark ready for review": String(localized: "Mark ready for review")
        case "Match": String(localized: "Match")
        case "Max files changed": String(localized: "Max files changed")
        case "Max lines changed": String(localized: "Max lines changed")
        case "Merge commit": String(localized: "Merge commit")
        case "Merge conflict": String(localized: "Merge conflict")
        case "Merge now": String(localized: "Merge now")
        case "Merge once required checks and reviews pass.": String(localized: "Merge once required checks and reviews pass.")
        case "Merge the PR immediately.": String(localized: "Merge the PR immediately.")
        case "Mergeable": String(localized: "Mergeable")
        case "Message": String(localized: "Message")
        case "Method": String(localized: "Method")
        case "Move each ticket to a status.": String(localized: "Move each ticket to a status.")
        case "Move your ticket to In Review and link the PR on it.": String(localized: "Move your ticket to In Review and link the PR on it.")
        case "My PR opened → In Review": String(localized: "My PR opened → In Review")
        case "My review requested": String(localized: "My review requested")
        case "Name from a template": String(localized: "Name from a template")
        case "New commits pushed": String(localized: "New commits pushed")
        case "Next unreleased version": String(localized: "Next unreleased version")
        case "Next unreleased: the first release in the Jira project that is not yet released, whatever it is called. A template builds the name, and the release is created if Jira does not have it.": String(localized: "Next unreleased: the first release in the Jira project that is not yet released, whatever it is called. A template builds the name, and the release is created if Jira does not have it.")
        case "No checks": String(localized: "No checks")
        case "No decision": String(localized: "No decision")
        case "Not a draft": String(localized: "Not a draft")
        case "Notify me": String(localized: "Notify me")
        case "Notify you when one of your PRs has sat untouched for five days.": String(localized: "Notify you when one of your PRs has sat untouched for five days.")
        case "On merge → Jira": String(localized: "On merge → Jira")
        case "Only runs from the Run button, against a chosen PR.": String(localized: "Runs manually against a chosen pull request.")
        case "Only when the run happens on these days and hours (local time).": String(localized: "Only when the run happens on these days and hours (local time).")
        case "POST to webhook": String(localized: "POST to webhook")
        case "PR approved": String(localized: "PR approved")
        case "PR closed": String(localized: "PR closed")
        case "PR merged": String(localized: "PR merged")
        case "PR opened": String(localized: "PR opened")
        case "PR ready for review": String(localized: "PR ready for review")
        case "PR stale": String(localized: "PR stale")
        case "Passing": String(localized: "Passing")
        case "Patterns": String(localized: "Patterns")
        case "Post a comment on each ticket.": String(localized: "Post a comment on each ticket.")
        case "Post a comment on the PR.": String(localized: "Post a comment on the PR.")
        case "Post to Activity and show a macOS notification.": String(localized: "Post to Activity and show a macOS notification.")
        case "Priorities": String(localized: "Priorities")
        case "Project keys": String(localized: "Project keys")
        case "Pull request": String(localized: "Pull request")
        case "Pull requests": String(localized: "Pull requests")
        case "Re-run failed GitHub Actions jobs on the head commit.": String(localized: "Re-run failed GitHub Actions jobs on the head commit.")
        case "Re-run failed checks": String(localized: "Re-run failed checks")
        case "Re-run failed jobs on your PRs once per commit.": String(localized: "Re-run failed jobs on your PRs once per commit.")
        case "Rebase": String(localized: "Rebase")
        case "Rebase instead of merge": String(localized: "Rebase instead of merge")
        case "Record which Jira release each ticket ships in. Needs a Jira API token.": String(localized: "Record which Jira release each ticket ships in. Needs a Jira API token.")
        case "Regex": String(localized: "Regex")
        case "Regular expression over the PR title.": String(localized: "Regular expression over the PR title.")
        case "Remove labels": String(localized: "Remove labels")
        case "Remove labels from the PR.": String(localized: "Remove labels from the PR.")
        case "Request changes": String(localized: "Request changes")
        case "Request reviewers": String(localized: "Request reviewers")
        case "Review comment": String(localized: "Review comment")
        case "Review decision": String(localized: "Review decision")
        case "Review requested → notify": String(localized: "Review requested → notify")
        case "Review required": String(localized: "Review required")
        case "Reviewers": String(localized: "Reviewers")
        case "Run a zsh script in the project's workspace (60 s limit). The event is in CASCADE_* variables.": String(localized: "Run a zsh script in the project's workspace (60 s limit). The event is in CASCADE_* variables.")
        case "Run manually": String(localized: "Run manually")
        case "Run shell script": String(localized: "Run shell script")
        case "Running": String(localized: "Running")
        case "Script": String(localized: "Script")
        case "Send the event as JSON to an HTTPS URL (Slack, Teams, your own service).": String(localized: "Send the event as JSON to an HTTPS URL (Slack, Teams, your own service).")
        case "Send your ticket back to In Progress and tell you.": String(localized: "Send your ticket back to In Progress and tell you.")
        case "Set Fix Version": String(localized: "Set Fix Version")
        case "Set a Fix Version and close linked tickets when a PR merges.": String(localized: "Set a Fix Version and close linked tickets when a PR merges.")
        case "Size": String(localized: "Size")
        case "Source branch matches a pattern.": String(localized: "Source branch matches a pattern.")
        case "Squash": String(localized: "Squash")
        case "Stale PR → nudge": String(localized: "Stale PR → nudge")
        case "State": String(localized: "State")
        case "Status": String(localized: "Status")
        case "Statuses": String(localized: "Statuses")
        case "Submit a changes-requested review.": String(localized: "Submit a changes-requested review.")
        case "Take the PR out of draft.": String(localized: "Take the PR out of draft.")
        case "Target branch matches a pattern (* and ** globs).": String(localized: "Target branch matches a pattern (* and ** globs).")
        case "Text (optional)": String(localized: "Text (optional)")
        case "The PR can no longer merge cleanly.": String(localized: "The PR can no longer merge cleanly.")
        case "The PR links at least one Jira ticket (title, body or a saved link).": String(localized: "The PR links at least one Jira ticket (title, body or a saved link).")
        case "The PR's head commit changes.": String(localized: "The PR's head commit changes.")
        case "The PR's labels.": String(localized: "The PR's labels.")
        case "The combined state of checks on the head commit.": String(localized: "The combined state of checks on the head commit.")
        case "The review decision becomes approved.": String(localized: "The review decision becomes approved.")
        case "Ticket assigned → notify": String(localized: "Ticket assigned → notify")
        case "Ticket matches JQL": String(localized: "Ticket matches JQL")
        case "Ticket priority": String(localized: "Ticket priority")
        case "Ticket project": String(localized: "Ticket project")
        case "Ticket status": String(localized: "Ticket status")
        case "Ticket status changed": String(localized: "Ticket status changed")
        case "Ticket type": String(localized: "Ticket type")
        case "Time": String(localized: "Time")
        case "Time window": String(localized: "Time window")
        case "Title": String(localized: "Title")
        case "Title matches": String(localized: "Title matches")
        case "To": String(localized: "To")
        case "Transition ticket": String(localized: "Transition ticket")
        case "Types": String(localized: "Types")
        case "Update branch": String(localized: "Update branch")
        case "Upper bounds on the change size. Leave a bound empty to ignore it.": String(localized: "Upper bounds on the change size. Leave a bound empty to ignore it.")
        case "Users": String(localized: "Users")
        case "Version": String(localized: "Version")
        case "Version name": String(localized: "Version name")
        case "Whether GitHub can merge the PR cleanly.": String(localized: "Whether GitHub can merge the PR cleanly.")
        case "Whether the PR is a draft.": String(localized: "Whether the PR is a draft.")
        case "Who opened the PR. @me is you, @bots is any bot account.": String(localized: "Who opened the PR. @me is you, @bots is any bot account.")
        case "You are asked to review a PR.": String(localized: "You are asked to review a PR.")
        case "any file matches": String(localized: "any file matches")
        case "every file matches": String(localized: "every file matches")
        case "has all of": String(localized: "has all of")
        case "has any of": String(localized: "has any of")
        case "has none of": String(localized: "has none of")
        case "is not one of": String(localized: "is not one of")
        case "is one of": String(localized: "is one of")
        case "no file matches": String(localized: "no file matches")
        default: source
        }
    }
}
