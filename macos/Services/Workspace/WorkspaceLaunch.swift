import Foundation
import Observation

struct ExternalTool: Identifiable, Sendable {
    let id: String
    let name: String
    let application: String
    static let gitClients: [Self] = [
        .init(id: "fork", name: "Fork", application: "Fork"),
        .init(id: "tower", name: "Tower", application: "Tower"),
        .init(id: "sourcetree", name: "Sourcetree", application: "Sourcetree"),
        .init(id: "github", name: "GitHub Desktop", application: "GitHub Desktop")
    ]
    static let editors: [Self] = [
        .init(id: "vscode", name: "VS Code", application: "Visual Studio Code"),
        .init(id: "cursor", name: "Cursor", application: "Cursor"),
        .init(id: "windsurf", name: "Windsurf", application: "Windsurf"),
        .init(id: "zed", name: "Zed", application: "Zed"),
        .init(id: "xcode", name: "Xcode", application: "Xcode"),
        .init(id: "intellij", name: "IntelliJ IDEA", application: "IntelliJ IDEA"),
        .init(id: "webstorm", name: "WebStorm", application: "WebStorm"),
        .init(id: "android", name: "Android Studio", application: "Android Studio")
    ]
}

struct WorkspaceLaunchCommand: Equatable, Sendable {
    let arguments: [String]
    let directory: String
    let waitsForExit: Bool

    static func make(id: String, custom: String, tools: [ExternalTool], path: String, directory: String) throws -> Self {
        guard path.hasPrefix("/"), directory.hasPrefix("/"), !path.contains("\0"), !directory.contains("\0") else {
            throw BackendError.operation("The workspace must have an absolute local path.")
        }
        if id == "custom" {
            // Substitute after tokenization so spaces, quotes, and shell syntax in
            // the checkout name remain literal characters in one argument.
            return Self(arguments: try tokenize(custom).map { $0.replacingOccurrences(of: "{path}", with: path) },
                        directory: directory, waitsForExit: false)
        }
        guard let tool = tools.first(where: { $0.id == id }) else {
            throw BackendError.operation("Choose an external application in Settings.")
        }
        return Self(arguments: ["/usr/bin/open", "-a", tool.application, path], directory: directory, waitsForExit: true)
    }

    // The template grammar: single/double quotes group tokens;
    // backslashes are literal. No expansion, pipelines, or shell evaluation.
    static func tokenize(_ template: String) throws -> [String] {
        guard template.utf8.count <= 16_384, !template.contains("\0") else {
            throw BackendError.operation("The command is too long or contains a null character.")
        }
        var tokens: [String] = [], token = "", quote: Character?, started = false
        for character in template {
            if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started || !token.isEmpty { tokens.append(token); token = ""; started = false }
            } else { token.append(character) }
        }
        guard quote == nil else { throw BackendError.operation("Close the quote in the command template.") }
        if started || !token.isEmpty { tokens.append(token) }
        guard let program = tokens.first, !program.isEmpty, tokens.count <= 256 else {
            throw BackendError.operation("Enter a command with an executable name and no more than 256 arguments.")
        }
        return tokens
    }
}

protocol WorkspaceTargetService: Sendable {
    func target(directory: String, relative: String, kind: String) async throws -> String
}
struct APIWorkspaceTargetService: WorkspaceTargetService {
    let api: APIClient
    func target(directory: String, relative: String, kind: String) async throws -> String {
        struct Result: Decodable, Sendable { let path: String }
        // Opening Xcode waits for a warm-up still resolving the worktree (up to two minutes,
        // on the backend's side): Xcode would clone into the same package checkouts.
        let result: Result = try await api.get(APIClient.query(Routes.LAUNCH_TARGET,
            ["path": directory, "rel": relative, "kind": kind]), timeout: kind == "xcode" ? 130 : 10)
        return result.path
    }
}

protocol WorkspaceCommandLauncher: Sendable {
    func launch(_ command: WorkspaceLaunchCommand) async throws
}

// Process creation and executable lookup stay off the UI actor. Presets use the
// system's app-name lookup (including apps outside /Applications), and report open's
// exit status. A custom command is handed off and left alone;
// long-running editors are not waited for or terminated when Craft closes.
actor NativeWorkspaceCommandLauncher: WorkspaceCommandLauncher {
    func launch(_ command: WorkspaceLaunchCommand) async throws {
        guard let program = command.arguments.first else { throw BackendError.operation("The launch command is empty.") }
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPath = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            + ":/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:\(home)/.bun/bin"
        environment["PATH"] = searchPath
        let candidates = program.contains("/")
            ? [program.hasPrefix("/") ? program : (command.directory as NSString).appendingPathComponent(program)]
            : searchPath.split(separator: ":").filter { $0.hasPrefix("/") }.map { ($0 as NSString).appendingPathComponent(program) }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BackendError.operation("Could not find executable ‘\(program)’. Check the custom command and PATH.")
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.arguments.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: command.directory, isDirectory: true)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        guard command.waitsForExit else { return }
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(15)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw BackendError.operation("macOS timed out opening the application.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard process.terminationStatus == 0 else {
            throw BackendError.operation("macOS could not open the application (exit \(process.terminationStatus)). Check that it is installed and the target exists.")
        }
    }
}

@MainActor @Observable final class WorkspaceLaunchViewModel {
    private(set) var opening: Set<String> = []
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private let launcher: any WorkspaceCommandLauncher
    @ObservationIgnored private var targets: (any WorkspaceTargetService)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var requests: [String: UUID] = [:]

    init(launcher: any WorkspaceCommandLauncher) { self.launcher = launcher }
    func connect(_ targets: any WorkspaceTargetService) {
        stop(); self.targets = targets
    }
    func editorLabel(_ project: Project?) -> String? {
        guard let id = project?.ide, !id.isEmpty else { return nil }
        return id == "custom" ? "Open in Custom IDE" : ExternalTool.editors.first { $0.id == id }.map { "Open in \($0.name)" }
    }
    func gitClientLabel(_ id: String) -> String? {
        id == "custom" ? "Open in Custom Git Client" : ExternalTool.gitClients.first { $0.id == id }.map { "Open in \($0.name)" }
    }
    func openEditor(session: WorkspaceSession, project: Project?) async {
        guard let project else { return }
        await open(key: "task:\(session.id)", directory: session.worktree, id: project.ide ?? "", custom: project.ideCmd ?? "",
                   tools: ExternalTool.editors, relative: project.ideTarget ?? "", probe: project.ide == "xcode" ? "xcode" : "")
    }
    func openGitClient(session: WorkspaceSession, id: String, custom: String) async {
        await open(key: "task:\(session.id)", directory: session.worktree, id: id, custom: custom,
                   tools: ExternalTool.gitClients, relative: "", probe: "")
    }
    private func open(key: String, directory: String, id: String, custom: String,
                      tools: [ExternalTool], relative: String, probe: String) async {
        guard opening.insert(key).inserted else { return }
        let requestGeneration = generation
        let requestID = UUID(); requests[key] = requestID
        errors[key] = nil
        let task = Task {
            defer {
                if requests[key] == requestID { opening.remove(key); tasks[key] = nil; requests[key] = nil }
            }
            do {
                var path = directory
                if !relative.isEmpty || !probe.isEmpty {
                    guard let targets else { throw BackendError.operation("Connect to resolve the IDE launch target.") }
                    path = try await targets.target(directory: directory, relative: relative, kind: probe)
                }
                try Task.checkCancellation()
                guard generation == requestGeneration, requests[key] == requestID else { return }
                let command = try WorkspaceLaunchCommand.make(id: id, custom: custom, tools: tools, path: path, directory: directory)
                try await launcher.launch(command)
            } catch {
                if !Task.isCancelled && generation == requestGeneration && requests[key] == requestID {
                    errors[key] = error.localizedDescription
                }
            }
        }
        tasks[key] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    /// Hands a failure to a caller that reports it elsewhere, so it does not wait as a banner
    /// for the next visit to that session.
    func takeError(sessionID: String) -> String? { errors.removeValue(forKey: "task:\(sessionID)") }
    func cancel(sessionID: String) {
        let key = "task:\(sessionID)"
        tasks.removeValue(forKey: key)?.cancel(); requests[key] = nil; opening.remove(key); errors[key] = nil
    }
    func stop() {
        generation = UUID(); tasks.values.forEach { $0.cancel() }; tasks = [:]; requests = [:]
        targets = nil; opening = []; errors = [:]
    }
}
