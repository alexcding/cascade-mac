import Foundation
import Testing

@Test func workspaceLaunchTemplatesPreserveLiteralPathsAndExistingPresets() throws {
    let path = "/tmp/it's a \"checkout\"; $(touch sentinel) `echo injected`"
    let command = try WorkspaceLaunchCommand.make(id: "custom", custom: #"open -a "GitHub Desktop" "{path}" "" 'literal\backslash'"#,
        tools: [], path: path, directory: "/tmp")
    #expect(command.arguments == ["open", "-a", "GitHub Desktop", path, "", #"literal\backslash"#])
    #expect(!command.waitsForExit)
    #expect(try WorkspaceLaunchCommand.tokenize(#"tool --target="{path}""#) == ["tool", "--target={path}"])
    for invalid in ["", "''", "tool 'unclosed", "tool\0value", String(repeating: "a", count: 16_385)] {
        #expect(throws: BackendError.self) { try WorkspaceLaunchCommand.tokenize(invalid) }
    }
    #expect(throws: BackendError.self) {
        try WorkspaceLaunchCommand.make(id: "fork", custom: "", tools: ExternalTool.gitClients, path: "relative", directory: "/tmp")
    }
    for tool in ExternalTool.gitClients + ExternalTool.editors {
        let preset = try WorkspaceLaunchCommand.make(id: tool.id, custom: "ignored", tools: [tool], path: path, directory: "/tmp")
        #expect(preset.arguments == ["/usr/bin/open", "-a", tool.application, path] && preset.waitsForExit)
    }
}

private actor LaunchRecorder: WorkspaceCommandLauncher {
    var commands: [WorkspaceLaunchCommand] = []
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func launch(_ command: WorkspaceLaunchCommand) throws {
        commands.append(command)
        if fails { throw BackendError.operation("Application missing") }
    }
}

private actor LaunchTargetFixture: WorkspaceTargetService {
    struct Request: Equatable { let directory: String; let relative: String; let kind: String }
    var requests: [Request] = []
    var pending: CheckedContinuation<String, any Error>?
    func target(directory: String, relative: String, kind: String) async throws -> String {
        requests.append(.init(directory: directory, relative: relative, kind: kind))
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ path: String) { pending?.resume(returning: path); pending = nil }
}

@MainActor @Test(.timeLimit(.minutes(1))) func workspaceLaunchResolvesTargetCoalescesAndCancelsRemovedSessions() async throws {
    let launcher = LaunchRecorder(), targets = LaunchTargetFixture()
    let model = WorkspaceLaunchViewModel(launcher: launcher)
    model.connect(targets)
    let project = Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp/main", ide: "xcode", ideTarget: "App.xcworkspace")
    let session = WorkspaceSession(id: "s", projectId: "p", workspace: "/tmp/main", worktree: "/tmp/branch", title: "", branch: "", url: "session:s", createdAt: nil, pinned: false)
    let first = Task { await model.openEditor(session: session, project: project) }
    while await targets.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    await model.openEditor(session: session, project: project)
    #expect(await targets.requests == [.init(directory: "/tmp/branch", relative: "App.xcworkspace", kind: "xcode")])
    await targets.finish("/tmp/branch/App.xcworkspace")
    await first.value
    #expect(await launcher.commands.first?.arguments == ["/usr/bin/open", "-a", "Xcode", "/tmp/branch/App.xcworkspace"])
    #expect(model.opening.isEmpty)
    await launcher.setFailure(true)
    await model.openGitClient(session: session, id: "fork", custom: "ignored")
    #expect(model.errors["task:s"] == "Application missing")
    // A sidebar launch reports elsewhere: taking the failure leaves no banner behind.
    #expect(model.takeError(sessionID: "s") == "Application missing" && model.errors.isEmpty)
    #expect(model.takeError(sessionID: "s") == nil)
    #expect(await targets.requests.count == 1) // Git clients always open the worktree folder.
    await launcher.setFailure(false)
    await model.openGitClient(session: session, id: "fork", custom: "")
    #expect(model.errors.isEmpty)
    let removed = Task { await model.openEditor(session: session, project: project) }
    while await targets.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    model.cancel(sessionID: session.id)
    await targets.finish("/tmp/removed/App.xcworkspace")
    await removed.value
    #expect(await launcher.commands.count == 3 && model.opening.isEmpty)
    let stopped = Task { await model.openEditor(session: session, project: project) }
    while await targets.requests.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
    model.stop(); model.connect(targets)
    await targets.finish("/tmp/stale/App.xcworkspace")
    await stopped.value
    #expect(await launcher.commands.count == 3 && model.errors.isEmpty)
    model.stop()
}

@Test(.timeLimit(.minutes(1))) func nativeWorkspaceLauncherPassesArgumentsWithoutShellExpansionAndReportsFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("capture.sh"), output = root.appendingPathComponent("arguments.txt")
    try Data("destination=\"$1\"\nshift\nprintf '%s\\n' \"$@\" > \"$destination\"\n".utf8).write(to: script)
    let literal = "/tmp/checkout; $(touch injected) `touch injected` \"quoted\""
    let template = "/bin/sh \"\(script.path)\" \"\(output.path)\" {path} \"\""
    let command = try WorkspaceLaunchCommand.make(id: "custom", custom: template, tools: [], path: literal, directory: root.path)
    let launcher = NativeWorkspaceCommandLauncher()
    try await launcher.launch(command)
    for _ in 0..<200 {
        if (try? String(contentsOf: output, encoding: .utf8)) == literal + "\n\n" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try String(contentsOf: output, encoding: .utf8) == literal + "\n\n")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    await #expect(throws: BackendError.self) {
        try await launcher.launch(.init(arguments: ["/bin/sh", "-c", "exit 7"], directory: root.path, waitsForExit: true))
    }
    await #expect(throws: BackendError.self) {
        try await launcher.launch(.init(arguments: [root.appendingPathComponent("missing-command").path], directory: root.path, waitsForExit: false))
    }
}
