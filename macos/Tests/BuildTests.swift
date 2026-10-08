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

/// `XCODE_BUILD_SETTINGS` with an explicit `platform`, to drive `onSimulatorRun`.
private final class BuildHTTPFixtureSimulator: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case Routes.XCODE_SCHEMES: body = #"{"target":"/tmp/Fixture.xcodeproj","schemes":["Dependency","Fixture"]}"#
        case Routes.XCODE_DESTINATIONS: body = #"[{"udid":"12345678-1234-1234-1234-123456789abc","name":"Fixture device","runtime":"iOS fixture"}]"#
        case Routes.XCODE_BUILD_SETTINGS:
            body = #"{"appPath":"/tmp/Fixture.app","bundleId":"fixture.app","target":"/tmp/Fixture.xcodeproj","configuration":"Debug","platform":"iphonesimulator"}"#
        default: body = #"{"id":"fixture","name":"Fixture","repo":"","workspace":"/tmp","ide":"xcode"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// `XCODE_BUILD_SETTINGS` reporting a Mac destination, which must not raise the Simulator panel.
private final class BuildHTTPFixtureMac: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case Routes.XCODE_SCHEMES: body = #"{"target":"/tmp/Fixture.xcodeproj","schemes":["Dependency","Fixture"]}"#
        case Routes.XCODE_DESTINATIONS: body = #"[{"udid":"this-mac","name":"This Mac","runtime":"","kind":"mac"}]"#
        case Routes.XCODE_BUILD_SETTINGS:
            body = #"{"appPath":"/tmp/Fixture.app","bundleId":"fixture.app","target":"/tmp/Fixture.xcodeproj","configuration":"Debug","platform":"macosx"}"#
        default: body = #"{"id":"fixture","name":"Fixture","repo":"","workspace":"/tmp","ide":"xcode"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// `XCODE_BUILD_SETTINGS` as the backend answers it for a Mac app whose scheme passes arguments
/// and environment. Asked about the worktree `/tmp/own`, the app it builds is this very process.
private final class BuildHTTPFixtureLaunch: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case Routes.XCODE_SCHEMES: body = #"{"target":"/tmp/Fixture.xcodeproj","schemes":["Fixture"]}"#
        case Routes.XCODE_DESTINATIONS: body = #"[{"udid":"this-mac","name":"This Mac","runtime":"","kind":"mac"}]"#
        case Routes.XCODE_BUILD_SETTINGS:
            let own = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "path" && $0.value == "/tmp/own" } == true
            let executable = own ? Bundle.main.executablePath! : "/tmp/Fixture.app/Contents/MacOS/Fixture"
            let settings: [String: Any] = ["appPath": "/tmp/Fixture.app", "executablePath": executable, "platform": "macosx",
                "bundleId": "fixture.app", "productName": "Fixture.app", "target": "/tmp/Fixture.xcodeproj", "configuration": "Debug",
                "launchArguments": ["--data-dir", "/tmp/dev data"], "launchEnvironment": ["LOG": "1"]]
            body = String(decoding: try! JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        default: body = #"{"id":"fixture","name":"Fixture","repo":"","workspace":"/tmp","ide":"xcode"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A `SimulatorPreviewing` fake that answers immediately, for tests that only care whether it was asked.
private final class NoopSimulatorPreviewService: SimulatorPreviewing, @unchecked Sendable {
    func start(udid: String) async throws -> URL { URL(string: "http://127.0.0.1:3100")! }
    func stopAll() async {}
}

@MainActor private final class BuildTerminalRecorder: BuildTerminal {
    var commands: [String] = []
    var interrupts = 0
    var shell = true
    var holdReady = false
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    func waitUntilReady() async throws {
        if holdReady { await withCheckedContinuation { readyContinuations.append($0) } }
    }
    func releaseReady() {
        holdReady = false
        let waiting = readyContinuations; readyContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
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
    build.holdReady = true // Keep startup observable even when the HTTP fixture answers immediately.
    var factories = 0
    let model = BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session,
        terminalFactory: { factories += 1; return build })
    let destination = BuildDestinationViewModel(runtime: model)
    await destination.load()
    #expect(destination.canRun && destination.scheme == "Fixture")
    async let first: Void = destination.run()
    async let second: Void = destination.run()
    for _ in 0..<100 {
        if model.starting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.starting)
    build.releaseReady()
    _ = await (first, second)
    #expect(model.running && build.commands.count == 1 && factories == 1)
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

@MainActor @Test func buildRunRetainsDestinationWhenInjectedTerminalFactoryFails() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: "/tmp", title: "", branch: "", url: "", createdAt: nil, pinned: false)
    let model = NativeWorkspaceFeatureFactory().build(api: api, project: project, session: session,
        terminalFactory: { throw BackendError.operation("Runtime closed") })
    let destination = BuildDestinationViewModel(runtime: model)
    await destination.load(); await destination.run()
    #expect(model.error == "Runtime closed" && !model.running && model.canRun)
    // The run keeps its destination and its error, which the toolbar shows, for another try.
    #expect(!destination.retired)
    destination.retire()
    #expect(model.error == "Runtime closed" && model.canRun)
}

@MainActor @Test func buildRunOnSimulatorPlatformShowsPreviewAndFiresCallback() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixtureSimulator.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: "/tmp", title: "", branch: "", url: "session:task", createdAt: nil, pinned: false)
    let build = BuildTerminalRecorder()
    let preview = SimulatorPreviewModel(service: NoopSimulatorPreviewService())
    var simulatorRuns = 0
    let model = BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session,
        preview: preview, terminalFactory: { build })
    model.onSimulatorRun = { simulatorRuns += 1 }
    let destination = BuildDestinationViewModel(runtime: model)
    await destination.load()
    #expect(destination.canRun)
    await destination.run()
    #expect(simulatorRuns == 1)
    #expect(preview.udid == "12345678-1234-1234-1234-123456789abc")
    model.disconnect()
}

@MainActor @Test func buildRunAdoptingARunningBuildLeavesThePreviewAlone() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixtureSimulator.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: "/tmp", title: "", branch: "", url: "session:task", createdAt: nil, pinned: false)
    // A build from before a reconnect still holds the terminal: Run adopts it and sends nothing,
    // so the destination picked now says nothing about what is running.
    let build = BuildTerminalRecorder()
    build.shell = false; build.process = "xcodebuild"; build.subshell = true
    let preview = SimulatorPreviewModel(service: NoopSimulatorPreviewService())
    var simulatorRuns = 0
    let model = BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session,
        preview: preview, terminalFactory: { build })
    model.onSimulatorRun = { simulatorRuns += 1 }
    let destination = BuildDestinationViewModel(runtime: model)
    await destination.load()
    await destination.run()
    #expect(build.commands.isEmpty, "the running build is adopted, not joined by a second command")
    #expect(simulatorRuns == 0)
    #expect(preview.state == .idle && preview.udid == nil)
    model.disconnect()
}

@MainActor @Test func buildRunOnMacPlatformDoesNotShowPreview() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixtureMac.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: "/tmp", title: "", branch: "", url: "session:task", createdAt: nil, pinned: false)
    let build = BuildTerminalRecorder()
    let preview = SimulatorPreviewModel(service: NoopSimulatorPreviewService())
    var simulatorRuns = 0
    let model = BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session,
        preview: preview, terminalFactory: { build })
    model.onSimulatorRun = { simulatorRuns += 1 }
    let destination = BuildDestinationViewModel(runtime: model)
    await destination.load()
    #expect(destination.canRun)
    await destination.run()
    #expect(simulatorRuns == 0)
    #expect(preview.state == .idle && preview.udid == nil)
    model.disconnect()
}

/// From the Run button's model to the line typed into the terminal: what the backend answers for
/// the scheme reaches the launch, and a scheme that builds the app doing the running asks it to
/// leave instead of ending it.
@MainActor @Test func runTypesTheLaunchTheBackendDescribes() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BuildHTTPFixtureLaunch.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp", ide: "xcode")
    func typed(worktree: String) async throws -> String {
        let session = WorkspaceSession(id: "task", projectId: "fixture", workspace: "/tmp", worktree: worktree, title: "", branch: "", url: "session:task", createdAt: nil, pinned: false)
        let build = BuildTerminalRecorder()
        let model = BuildWorkspaceViewModel(service: XcodeBuildService(api: api), project: project, session: session, terminalFactory: { build })
        let destination = BuildDestinationViewModel(runtime: model)
        await destination.load()
        await destination.run()
        defer { model.disconnect() }
        #expect(build.commands.count == 1, "\(model.error ?? "no command")")
        return build.commands.first ?? ""
    }
    let other = try await typed(worktree: "/tmp")
    #expect(other.contains("export 'LOG=1' && exec '/tmp/Fixture.app/Contents/MacOS/Fixture' '--data-dir' '/tmp/dev data'; }"), "\(other)")
    #expect(other.contains(#"/usr/bin/pkill -f -- '^\/tmp\/Fixture\.app\/Contents\/MacOS\/Fixture( |$)'"#), "\(other)")
    let own = try await typed(worktree: "/tmp/own")
    #expect(own.contains("/api/hooks/relaunch?pid=\(ProcessInfo.processInfo.processIdentifier)\""), "\(own)")
    #expect(own.hasSuffix("exec /usr/bin/open -n '/tmp/Fixture.app' --env 'LOG=1' --args '--data-dir' '/tmp/dev data'; }; })"), "\(own)")
    #expect(!own.contains("pkill"))
}

@Test func buildCommandKeepsOneForegroundGroupAndQuotesDestinationValues() throws {
    let settings = BuildSettings(appPath: "/tmp/Build Output/Example.app", bundleId: "example.app",
        target: "/tmp/Project's folder/Example.xcworkspace", configuration: "Debug")
    let command = try settings.command(scheme: "App's scheme; echo injected", simulator: "12345678-1234-1234-1234-123456789abc")
    #expect(command.hasPrefix("(cd "))
    #expect(command.hasSuffix("; })"))
    // Boot, then Simulator, alongside the build; the install waits for both.
    #expect(command.contains("{ { /usr/bin/xcrun simctl boot '12345678-1234-1234-1234-123456789abc'; /usr/bin/open "))
    #expect(command.contains("/usr/bin/open -a Simulator; } >/dev/null 2>&1 & /usr/bin/xcodebuild"))
    #expect(command.contains(" -hideShellScriptEnvironment build && { wait; /usr/bin/xcrun simctl install"))
    #expect(command.contains("; } && exec /usr/bin/xcrun simctl launch --console-pty --terminate-running-process"))
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
