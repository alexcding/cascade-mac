import Foundation

enum WorkflowCLI: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}
struct WorkflowStep: Codable, Equatable, Sendable {
    var title = ""
    var command = ""
    init(title: String = "", command: String = "") { self.title = title; self.command = command }
    private enum CodingKeys: String, CodingKey { case title, command }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
    }
}
struct WorkflowRecipe: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var cli: WorkflowCLI
    var steps: [WorkflowStep]
    init(id: String = UUID().uuidString, name: String = "", cli: WorkflowCLI = .claude, steps: [WorkflowStep] = []) {
        self.id = id; self.name = name; self.cli = cli; self.steps = steps
    }
    private enum CodingKeys: String, CodingKey { case id, name, cli, steps, commands }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        cli = WorkflowCLI(rawValue: try values.decodeIfPresent(String.self, forKey: .cli) ?? "") ?? .claude
        steps = try values.decodeIfPresent([WorkflowStep].self, forKey: .steps)
            ?? values.decodeIfPresent([String].self, forKey: .commands)?.map { WorkflowStep(command: $0) } ?? []
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(cli, forKey: .cli); try values.encode(steps, forKey: .steps)
    }
}

enum WorkflowText {
    static func slug(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
    }
    static func branch(key: String, summary: String) -> String {
        "feature/" + [slug(key), slug(summary)].filter { !$0.isEmpty }.joined(separator: "-")
    }
    static func resolve(_ text: String, context: [String: String]) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{([A-Za-z0-9_]+)\}"#)
        let source = text as NSString
        var result = text
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let key = source.substring(with: match.range(at: 1))
            guard let value = context[key], !value.isEmpty, let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
}

struct WorkflowEditorStep: Identifiable, Equatable {
    let id = UUID()
    var value: WorkflowStep
    var hasCommand: Bool { !value.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
struct WorkflowEditorRecipe: Identifiable, Equatable {
    let id = UUID()
    var savedID: String
    var name: String
    var cli: WorkflowCLI
    var steps: [WorkflowEditorStep]
    var hasCommands: Bool { steps.contains(where: \.hasCommand) }
    init(_ recipe: WorkflowRecipe) {
        savedID = recipe.id; name = recipe.name; cli = recipe.cli
        steps = (recipe.steps.isEmpty ? [WorkflowStep()] : recipe.steps).map { WorkflowEditorStep(value: $0) }
    }
    var payload: WorkflowRecipe {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(id: savedID, name: name.isEmpty ? "Untitled workflow" : name, cli: cli,
            steps: steps.map { WorkflowStep(title: $0.value.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                          command: $0.value.command.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.command.isEmpty })
    }
}

protocol WorkflowService: Sendable {
    func save(projectID: String, workflows: [WorkflowRecipe]) async throws -> Project
}
struct APIWorkflowService: WorkflowService {
    let api: APIClient
    func save(projectID: String, workflows: [WorkflowRecipe]) async throws -> Project {
        struct Patch: Encodable { let workflows: [WorkflowRecipe] }
        return try await api.request(Routes.project(projectID), method: "PUT", body: Patch(workflows: workflows))
    }
}
