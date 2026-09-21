import Foundation
import Testing

private final class BuildHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case Routes.XCODE_SCHEMES: body = #"{"target":"/tmp/Fixture.xcodeproj","schemes":["Dependency","Fixture"]}"#
        case Routes.XCODE_DESTINATIONS: body = #"[{"udid":"12345678-1234-1234-1234-123456789abc","name":"Fixture device","runtime":"iOS fixture"}]"#
        case Routes.XCODE_BUILD_SETTINGS:
            body = #"{"appPath":"/tmp/Fixture.app","bundleId":"fixture.app","target":"/tmp/Fixture.xcodeproj","configuration":"Debug"}"#
        default: body = #"{"id":"fixture","name":"Fixture","repo":"","workspace":"/tmp","ide":"xcode"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class BuildTerminalRecorder: BuildTerminal {
    var commands: [String] = []
    var interrupts = 0
    var shell = true
    func waitUntilReady() async throws {}
    func atShell() async throws -> Bool { shell }
    var process = "zsh"
    var subshell: Bool?
    func foregroundProcess() async throws -> (atShell: Bool, process: String, subshell: Bool?) { (shell, shell ? "" : process, subshell) }
    func submit(_ line: String) async throws { commands.append(line); shell = false }
    func interrupt() async throws { interrupts += 1; shell = true }
    func close() {}
}

@MainActor @Test func buildModelCoalescesRunAndStopsOnlyItsInjectedTerminal() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: "/tmp", title: "", branch: "", url: "session:task", createdAt: nil, pinned: false)
    let build = BuildTerminalRecorder()
    var factories = 0
    let model = BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session,
        terminalFactory: { factories += 1; return build })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.presentBuild { model }
    let presentation = try #require(coordinator.sheet)
    guard case .build(let destination) = presentation.destination else { Issue.record("Wrong destination"); return }
    await destination.load()
    #expect(destination.canRun && destination.scheme == "Fixture")
    async let first: Void = destination.run()
    async let second: Void = destination.run()
    for _ in 0..<100 {
        if model.starting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.starting)
    coordinator.dismissSheet(id: presentation.id)
    #expect(coordinator.sheet?.id == presentation.id)
    _ = await (first, second)
    #expect(model.running && build.commands.count == 1 && factories == 1)
    #expect(coordinator.sheet == nil)
    #expect(destination.retired && !destination.canRun)
    await destination.run()
    #expect(build.commands.count == 1 && model.running)
    // The subshell running the chain is still the build; the exec'd launch is the app.
    try await Task.sleep(for: .milliseconds(1500))
    #expect(model.running && !model.launched)
    build.process = "nu"; build.subshell = true
    try await Task.sleep(for: .milliseconds(1500))
    #expect(model.running && !model.launched)
    build.process = "simctl"; build.subshell = false
    for _ in 0..<300 where !model.launched { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.running && model.launched)
    await model.stop()
    #expect(build.interrupts == 1)
    for _ in 0..<300 where model.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.running && !model.launched)
    model.disconnect()
    #expect(!model.canRun)
}

@MainActor @Test func buildCoordinatorRetainsDestinationWhenInjectedTerminalFactoryFails() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: "/tmp", title: "", branch: "", url: "", createdAt: nil, pinned: false)
    let model = NativeWorkspaceFeatureFactory().build(api: api, project: project, session: session,
        terminalFactory: { throw BackendError.operation("Runtime closed") })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.presentBuild { model }
    let sheet = try #require(coordinator.sheet)
    guard case .build(let destination) = sheet.destination else { Issue.record("Wrong destination"); return }
    await destination.load(); await destination.run()
    #expect(model.error == "Runtime closed" && !model.running && model.canRun)
    #expect(coordinator.sheet?.id == sheet.id && sheet.canDismiss)
    coordinator.dismissSheet(id: sheet.id)
    #expect(coordinator.sheet == nil)
}

@Test func buildCommandKeepsOneForegroundGroupAndQuotesDestinationValues() throws {
    let settings = BuildSettings(appPath: "/tmp/Build Output/Example.app", bundleId: "example.app",
        target: "/tmp/Project's folder/Example.xcworkspace", configuration: "Debug")
    let command = try settings.command(scheme: "App's scheme; echo injected", simulator: "12345678-1234-1234-1234-123456789abc")
    #expect(command.hasPrefix("(cd "))
    #expect(command.hasSuffix("; })"))
    #expect(command.contains("&& /usr/bin/xcrun simctl install"))
    #expect(command.contains("&& exec /usr/bin/xcrun simctl launch --console-pty --terminate-running-process"))
    #expect(command.contains("'App'\"'\"'s scheme; echo injected'"))
    #expect(!command.contains("\n"))
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-n", "-c", command] // Parse only; never build or launch a simulator in this test.
    shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
    try shell.run(); shell.waitUntilExit()
    #expect(shell.terminationStatus == 0)
    #expect(throws: BackendError.self) {
        try BuildSettings(appPath: "/tmp/Library.framework", bundleId: "", target: "/tmp", configuration: "Debug")
            .command(scheme: "Library", simulator: "destination")
    }
}
