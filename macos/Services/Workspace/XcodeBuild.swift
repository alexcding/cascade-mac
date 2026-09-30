import Foundation

// Everything that knows how Xcode builds and launches. `BuildWorkspace.swift` is the
// IDE-neutral part (the model, the sheet, `BuildServing`); another IDE gets a file like
// this one beside it.

/// `BuildServing` for an Xcode project: schemes and destinations come from `xcodebuild`.
struct XcodeBuildService: BuildServing {
    let api: APIClient
    func destinations(project: Project, session: WorkspaceSession, scheme: String, refresh: Bool) async throws -> (BuildSchemes, [BuildSimulator]) {
        let place = ["path": session.worktree, "rel": project.ideTarget ?? ""]
        // Only the destinations are asked for afresh. The scheme list changes with the project
        // files, which the backend's cached answer already tracks.
        let fresh = refresh ? ["refresh": "1"] : [:]
        // Long, because each answer that is not cached waits for a warm-up still resolving the
        // worktree: a cold package graph can take minutes, and the list is not wrong, just late.
        let list: @Sendable (String) async throws -> [BuildSimulator] = { [api] scheme in
            try await api.get(APIClient.query(Routes.XCODE_DESTINATIONS, place.merging(fresh.merging(["scheme": scheme]) { $1 }) { $1 }), timeout: 600)
        }
        // The wanted scheme is usually right, so its destinations load alongside the schemes.
        async let schemes: BuildSchemes = api.get(APIClient.query(Routes.XCODE_SCHEMES, place), timeout: 600)
        async let guess: [BuildSimulator]? = scheme.isEmpty ? nil : try? list(scheme)
        let found = try await schemes, resolved = found.resolve(scheme, project: project)
        if resolved.isEmpty { _ = await guess; return (found, []) }
        if resolved == scheme, let guess = await guess { return (found, guess) }
        return (found, try await list(resolved))
    }
    /// Long, because the backend holds Run until a warm-up still resolving this worktree has
    /// finished: the build would otherwise clone into the same package checkouts.
    func settings(project: Project, session: WorkspaceSession, scheme: String, simulator: String) async throws -> BuildSettings {
        try await api.get(APIClient.query(Routes.XCODE_BUILD_SETTINGS,
            ["path": session.worktree, "rel": project.ideTarget ?? "", "scheme": scheme, "sim": simulator]), timeout: 600)
    }
    func saveDestination(session: WorkspaceSession, seedingProject: Bool, scheme: String, simulator: String) async throws {
        let body = ["runScheme": scheme, "runSim": simulator]
        let _: OperationOK = try await api.request(Routes.task(session.id), method: "PATCH", body: body)
        if seedingProject { let _: Project = try await api.request(Routes.project(session.projectId), method: "PUT", body: body) }
    }
}

extension BuildSettings {
    /// One word a scheme passes, for the shell line. The line is typed into a shell, where a
    /// control character ends it or is read as a key, so a word that has one is written in
    /// the `$'…'` form, which spells them out.
    private static func word(_ value: String) -> String {
        let control: (Unicode.Scalar) -> Bool = { $0.value < 0x20 || $0.value == 0x7f }
        guard value.unicodeScalars.contains(where: control) else { return SessionAgent.quote(value) }
        return "$'" + value.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\\": "\\\\"
            case "'": "\\'"
            case "\n": "\\n"
            case "\r": "\\r"
            case "\t": "\\t"
            // No argument holds a NUL.
            case "\0": ""
            default: control(scalar) ? String(format: "\\x%02x", scalar.value) : String(scalar)
            }
        }.joined() + "'"
    }
    /// The shell line that builds the scheme and launches it on the destination, by the
    /// destination's platform: the executable itself on this Mac, `devicectl` on a
    /// device, `simctl` on a simulator. Each launch passes what the scheme's Run passes.
    /// `host` and `pid` are the app doing the running, which a scheme can also be the build of.
    func command(scheme: String, simulator: String, host: String? = Bundle.main.executablePath,
                 pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> String {
        guard appPath.hasSuffix(".app"), !bundleId.isEmpty, !scheme.isEmpty, !simulator.isEmpty else {
            throw BackendError.operation(String(localized: "Choose a scheme that builds an application and a destination."))
        }
        let q = SessionAgent.quote
        let document = target.hasSuffix(".xcworkspace") ? " -workspace \(q(target))"
            : target.hasSuffix(".xcodeproj") ? " -project \(q(target))" : ""
        let cwd = target.hasSuffix("Package.swift") ? (target as NSString).deletingLastPathComponent
            : document.isEmpty ? target : (target as NSString).deletingLastPathComponent
        // One foreground shell group keeps Stop and completion detection scoped to
        // the entire build/install/launch chain, including transitions between tools.
        // The launch is exec'd, so the group's leader stops being a shell once the app is up:
        // that is how `BuildWorkspaceViewModel` tells building from running.
        // Not -quiet: a cold build is minutes long, and a silent log reads as a hang. Without
        // each script phase's environment dump, though, which is hundreds of lines apiece.
        let build = "/usr/bin/xcodebuild\(document) -scheme \(q(scheme)) -configuration \(q(configuration)) -destination \(q("id=" + simulator)) -hideShellScriptEnvironment build"
        let platform = platform ?? "iphonesimulator"
        // What the scheme's Run passes, since the app is launched here and not by Xcode. The
        // environment is exported in the chain's own subshell, under the prefix the launcher
        // hands on to the app; a name no shell would export is left out.
        let arguments = (launchArguments ?? []).map { " " + Self.word($0) }.joined()
        let pairs: (String) -> [String] = { prefix in
            (launchEnvironment ?? [:]).sorted { $0.key < $1.key }
                .filter { $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
                .map { " " + Self.word(prefix + $0.key + "=" + $0.value) }
        }
        let environment: (String) -> String = { prefix in
            let exported = pairs(prefix).joined()
            return exported.isEmpty ? "" : "export\(exported) && "
        }
        if platform == "macosx" {
            // Run the executable itself so its output lands here and Stop reaches it.
            // pkill reads a pattern over each whole command line, so the path is escaped and
            // held to the start: a process that is this executable, not one that names it, as
            // a debugger or an editor opened on it does.
            guard let executablePath, !executablePath.isEmpty, executablePath != (appPath as NSString).deletingLastPathComponent else {
                throw BackendError.operation(String(localized: "Scheme \(scheme) builds no runnable application."))
            }
            // The copy to end can be this app: a development build of Cascade running its own
            // scheme. It is asked to leave, through the hook its terminals reach it by, since it
            // cannot always be ended: a debugger holds the copy it is attached to against every
            // signal, and under Xcode that left it stopped and the new build yielding to it. The
            // new build is opened outside the terminal, which belongs to the app it would run.
            let resolved: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            if let host, resolved(host) == resolved(executablePath) {
                // Straight to the app's own port, whatever proxy the shell is set up for.
                let ask = "port=$(/bin/cat \"$CASCADE_PORT_FILE\" 2>/dev/null) && [ -n \"$port\" ] && /usr/bin/curl -fs --noproxy '*' --connect-timeout 2 -o /dev/null -X POST \"http://127.0.0.1:$port\(Routes.HOOK_RELAUNCH)?pid=\(pid)\""
                // Asked every two seconds until it has heard, and ended as any other app would be
                // while it cannot hear. Once it has, it leaves in its own time: it may be asking
                // about unsaved files, and Stop gives up on it.
                let gone = "heard=; n=0; while kill -0 \(pid) 2>/dev/null; do [ -z \"$heard\" ] && [ $((n % 20)) -eq 0 ] && { { \(ask) && heard=1; } || kill \(pid) 2>/dev/null; }; n=$((n+1)); /bin/sleep 0.1; done"
                let passed = pairs("").map { " --env" + $0 }.joined() + (arguments.isEmpty ? "" : " --args" + arguments)
                return "(cd \(q(cwd)) && { \(build) && { \(gone); exec /usr/bin/open -n \(q(appPath))\(passed); }; })"
            }
            return "(cd \(q(cwd)) && { \(build) && { /usr/bin/pkill -f -- \(q("^" + NSRegularExpression.escapedPattern(for: executablePath) + "( |$)")) >/dev/null 2>&1; \(environment(""))exec \(q(executablePath))\(arguments); }; })"
        }
        if !platform.hasSuffix("simulator") {
            // devicectl takes an argument that starts with a dash for an option of its own
            // unless the app and its arguments come after `--`.
            let app = (arguments.isEmpty ? "" : "-- ") + q(bundleId) + arguments
            return "(cd \(q(cwd)) && { \(build)"
                + " && /usr/bin/xcrun devicectl device install app --device \(q(simulator)) \(q(appPath))"
                + " && \(environment("DEVICECTL_CHILD_"))exec /usr/bin/xcrun devicectl device process launch --console --terminate-existing --device \(q(simulator)) \(app); })"
        }
        // The simulator boots and Simulator opens while the app builds, as they do in Xcode, and
        // the install waits for both. Boot still comes first: Simulator opened with nothing
        // booted boots a device of its own. The subshell has no job control, so the pair
        // prints no job notice; it also ignores Stop's interrupt, which leaves a simulator
        // booting, not a build running.
        return "(cd \(q(cwd)) && { { /usr/bin/xcrun simctl boot \(q(simulator)); "
            + "/usr/bin/open \"$(/usr/bin/xcode-select -p)/Applications/Simulator.app\" || /usr/bin/open \"$(/usr/bin/xcode-select -p)/../Applications/DeviceHub.app\" || /usr/bin/open -a Simulator; } >/dev/null 2>&1 & "
            + build
            + " && { wait; /usr/bin/xcrun simctl install \(q(simulator)) \(q(appPath)); }"
            + " && \(environment("SIMCTL_CHILD_"))exec /usr/bin/xcrun simctl launch --console-pty --terminate-running-process \(q(simulator)) \(q(bundleId))\(arguments); })"
    }
}
