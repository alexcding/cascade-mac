import Foundation

/// A pipeline as the backend stores it: one trigger, then filters and actions in order.
struct Automation: Codable, Equatable, Identifiable, Sendable {
    /// On or off. "live" is the stored name for on; try a pipeline with Dry Run before switching it on.
    enum Mode: String, Codable, CaseIterable, Sendable {
        case off, live
        var label: String { self == .live ? "On" : "Off" }
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
        let triggers = trigger.types.map { catalog?.trigger($0)?.label ?? $0 }
        let when = triggers.isEmpty ? "No trigger" : triggers.joined(separator: " or ")
        let actions = steps.filter { $0.kind == .action }.map { catalog?.action($0.type)?.label ?? $0.type }
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

    struct Option: Decodable, Equatable, Sendable { let value: String; let label: String }
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
        var id: String { type }
    }
    struct Template: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let summary: String
        let automation: Automation
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
        return order.map { ($0, groups[$0] ?? []) }
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
