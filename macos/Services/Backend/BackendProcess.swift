import Foundation

public struct BackendConfiguration: Sendable {
    public enum Mode: Sendable {
        case external
        case owned(executable: URL, dataDirectory: URL)
        /// The backend linked into this process (`EmbeddedBackend`); the default.
        case embedded(dataDirectory: URL)
    }
    public let baseURL: URL
    public let mode: Mode
    public let packaged: Bool

    public init(baseURL: URL, mode: Mode, packaged: Bool = false) {
        self.baseURL = baseURL
        self.mode = mode
        self.packaged = packaged
    }

    public static func current(arguments: [String] = ProcessInfo.processInfo.arguments,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func argument(_ name: String) throws -> String? {
            guard let index = arguments.firstIndex(of: name) else { return nil }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw BackendError.configuration("Missing value for \(name).")
            }
            return arguments[index + 1]
        }
        if let external = try argument("--backend-url") ?? environment["CRAFT_BACKEND_URL"] {
            guard let url = URL(string: external) else { throw BackendError.configuration("Invalid backend address.") }
            _ = try APIClient(baseURL: url)
            return Self(baseURL: url, mode: .external)
        }
        let dataPath = try argument("--data-dir") ?? environment["CRAFT_DATA_DIR"]
        let dataDirectory = dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LegacyIdentity.supportDirectory
        // A checkout run (--backend-root) is development; a bare launch is the packaged app.
        let root = try argument("--backend-root")
        if let path = try argument("--backend-path") {
            // A separate backend process: development against another build, and the
            // integration tests. Its port must be known in advance.
            let portString = try argument("--backend-port") ?? "3000"
            guard let port = Int(portString), (1...65535).contains(port) else {
                throw BackendError.configuration("Backend port must be between 1 and 65535.")
            }
            return Self(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                        mode: .owned(executable: URL(fileURLWithPath: path), dataDirectory: dataDirectory), packaged: root == nil)
        }
        // The default: the Rust backend runs inside this process. Its loopback port is
        // ephemeral, so the base URL is only known once it has started.
        return Self(baseURL: URL(string: "http://127.0.0.1:0")!, mode: .embedded(dataDirectory: dataDirectory), packaged: root == nil)
    }
}

// Only this owner can terminate the Process it started. External servers are never
// adopted, killed by port, or implicitly replaced. No waits block the UI actor.
public actor BackendProcess {
    public let configuration: BackendConfiguration
    private var process: Process?
    private var logHandle: FileHandle?

    public init(configuration: BackendConfiguration) { self.configuration = configuration }

    public func start() async throws -> APIClient {
        let api = try APIClient(baseURL: configuration.baseURL)
        if case .external = configuration.mode {
            _ = try await api.health()
            return api
        }
        guard process == nil else { throw BackendError.startup("The backend is already starting or running.") }
        guard case let .owned(executable, directory) = configuration.mode else { throw BackendError.incompatible }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BackendError.startup("The Rust backend executable is missing. Build craft-backend, pass --backend-path, or use --backend-url.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("native-backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        let child = Process()
        let instanceID = UUID().uuidString
        child.executableURL = executable
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(configuration.baseURL.port ?? 3000)
        environment["CRAFT_DATA_DIR"] = directory.path
        environment["CRAFT_INSTANCE_ID"] = instanceID
        environment["CRAFT_PACKAGED"] = configuration.packaged ? "1" : "0"
        environment["CRAFT_NATIVE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // Finder launches have a small PATH; keep the user's entries and include
        // standard CLI installation locations for gh, acli, and agent CLIs.
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log
        child.standardError = log
        do { try child.run() } catch { try? log.close(); throw error }
        process = child
        logHandle = log
        do {
            let deadline = ContinuousClock.now + .seconds(configuration.packaged ? 120 : 12)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw BackendError.startup("Backend exited (\(child.terminationStatus)). See \(logURL.path).") }
                if let health = try? await api.health(), health.instanceId == instanceID,
                   health.pid == child.processIdentifier {
                    try Task.checkCancellation()
                    return api
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw BackendError.startup("Backend did not become ready. The port may be occupied. See \(logURL.path).")
        } catch {
            if process === child { process = nil; logHandle = nil }
            await terminate(child, log: log)
            throw error
        }
    }

    public func stop() async {
        guard let child = process else { return }
        process = nil
        let log = logHandle
        logHandle = nil
        await terminate(child, log: log)
    }

    private func terminate(_ child: Process, log: FileHandle?) async {
        if child.isRunning {
            child.terminate()
            for _ in 0..<30 {
                if !child.isRunning { break }
                // A cancelled caller must still give its child time to terminate.
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        try? log?.close()
    }
}
