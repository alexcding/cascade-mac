import Foundation
import Darwin

struct PtydConfiguration: Sendable {
    let executable: URL
    let directory: URL
    let socketPath: String

    static func current() throws -> Self {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let data = argument("--data-dir") ?? env["CRAFT_DATA_DIR"]
            ?? LegacyIdentity.supportDirectory.path
        let executable = argument("--ptyd-path").map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/craft-ptyd")
        return Self(executable: executable, directory: URL(fileURLWithPath: data).appendingPathComponent("ptyd-native-spike"),
                    socketPath: try argument("--pty-socket") ?? env["CRAFT_PTYD_SOCK"] ?? defaultSocket(environment: env))
    }

    static func defaultSocket(environment: [String: String]) throws -> String {
        let candidate = environment["TMPDIR"] ?? ""
        let directory: String
        if candidate.hasPrefix("/"), candidate.utf8.count < 70, privateDirectory(candidate) {
            directory = candidate
        } else {
            directory = "/tmp/craft-\(getuid())"
            if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw PtyError.connection("Cannot create terminal socket directory.") }
            guard privateDirectory(directory) else { throw PtyError.connection("Terminal socket directory is not private.") }
        }
        // Temporary M1 isolation: the established app uses craft-ptyd.sock.
        return URL(fileURLWithPath: directory).appendingPathComponent("craft-native-ptyd.sock").path
    }

    static func privateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid()
            && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0
    }

    func validateSocket() throws {
        guard socketPath.hasPrefix("/"), socketPath.utf8.count < 104 else {
            throw PtyError.connection("Terminal socket path must be absolute and shorter than 104 bytes.")
        }
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw PtyError.connection("Refusing an unowned or non-socket terminal endpoint.")
            }
        } else if errno != ENOENT { throw PtyError.connection("Cannot inspect terminal socket.") }
    }
}

actor PtydHost {
    let configuration: PtydConfiguration
    private var child: Process?

    init(configuration: PtydConfiguration) { self.configuration = configuration }

    func connect(client: PtydClient) async throws -> PtyHello {
        try configuration.validateSocket()
        // Never replace a daemon which responds with an incompatible protocol.
        if FileManager.default.fileExists(atPath: configuration.socketPath) {
            do { return try await client.connect(path: configuration.socketPath) }
            catch { if !Self.mayStartDaemon(after: error) { throw error } }
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
            throw PtyError.connection("PTY helper is missing. Bundle it or pass --ptyd-path.")
        }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let log = configuration.directory.appendingPathComponent("ptyd.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = [configuration.directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CRAFT_PTYD_SOCK"] = configuration.socketPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        child = process
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            try configuration.validateSocket()
            do { return try await client.connect(path: configuration.socketPath) }
            catch { if !Self.mayStartDaemon(after: error) { throw error } }
        }
        let diagnostic = (try? String(contentsOf: log, encoding: .utf8))?.suffix(500) ?? ""
        throw PtyError.connection("PTY daemon did not become ready: \(diagnostic). See \(log.path).")
    }

    // A stale socket or not-yet-created socket is the only reason to launch/retry.
    // A responsive but silent, malformed, or incompatible peer must never cause
    // helper replacement, repeated handshakes, or reuse of a connected client.
    static func mayStartDaemon(after error: Error) -> Bool {
        guard case PtyError.socket(let code) = error else { return false }
        return code == ENOENT || code == ECONNREFUSED
    }

    // Explicit Quit must also work after relaunch, before a pane has reattached,
    // or after its old connection failed. This path never starts a new helper.
    func stopExisting() async throws {
        try configuration.validateSocket()
        let client = PtydClient(onEvent: { _ in })
        defer { client.close() }
        let hello: PtyHello
        do { hello = try await client.connect(path: configuration.socketPath) }
        catch { if Self.mayStartDaemon(after: error) { return }; throw error }
        try await terminate(client: client, hello: hello)
    }

    // Session removal/restart owns only these paired shells. A missing daemon is
    // already stopped; never create one just to remove a session record.
    func stopPaired(keys: Set<String>) async throws {
        guard !keys.isEmpty else { return }
        try configuration.validateSocket()
        let client = PtydClient(onEvent: { _ in })
        defer { client.close() }
        do { _ = try await client.connect(path: configuration.socketPath) }
        catch { if Self.mayStartDaemon(after: error) { return }; throw error }
        let all: [PtyInfo] = try await client.request(.init(op: "list"))
        let owned = all.filter { $0.paired && keys.contains($0.pairKey) }
        for term in owned { let _: Bool = try await client.request(.init(op: "kill", term: term.id)) }
        for _ in 0..<100 {
            let remaining: [PtyInfo] = try await client.request(.init(op: "list"))
            if !remaining.contains(where: { $0.paired && keys.contains($0.pairKey) }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PtyError.connection("Session processes did not stop. The worktree has been kept; retry the operation.")
    }

    /// The shell of each paired terminal the daemon runs, by pair key. Asking never starts a daemon:
    /// with none running there are no shells.
    func pairedShells() async throws -> [String: Int32] {
        try configuration.validateSocket()
        let client = PtydClient(onEvent: { _ in })
        defer { client.close() }
        do { _ = try await client.connect(path: configuration.socketPath) }
        catch { if Self.mayStartDaemon(after: error) { return [:] }; throw error }
        let all: [PtyInfo] = try await client.request(.init(op: "list"))
        return Dictionary(all.filter(\.paired).map { ($0.pairKey, Int32(bitPattern: $0.pid)) }, uniquingKeysWith: { first, _ in first })
    }

    // The M1 namespace is exclusively for the spike. Never invokes the daily
    // daemon's killAll. Verify the connected PID again before signalling it.
    func quit(client: PtydClient, hello: PtyHello) async {
        try? await terminate(client: client, hello: hello)
        client.close()
        child = nil
    }

    private func terminate(client: PtydClient, hello: PtyHello) async throws {
        let current: PtyHello = try await client.request(.init(op: "hello"))
        guard current.pid == hello.pid, current.pid > 1 else { throw PtyError.connection("PTY daemon identity changed during Quit.") }
        let _: Int = try await client.request(.init(op: "killAll"))
        // killAll schedules asynchronous teardown. Let the daemon reap children
        // and close each master before terminating it, instead of racing that work.
        for _ in 0..<50 {
            let remaining: [PtyInfo] = try await client.request(.init(op: "list"))
            if remaining.isEmpty {
                let check: PtyHello = try await client.request(.init(op: "hello"))
                guard check.pid == hello.pid else { throw PtyError.connection("PTY daemon identity changed during Quit.") }
                if Darwin.kill(check.pid, SIGTERM) != 0 && errno != ESRCH { throw PtyError.socket(errno) }
                child = nil
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PtyError.connection("Terminal processes did not stop. Quit can be retried.")
    }
}
