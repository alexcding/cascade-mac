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
    /// The shell line that builds the scheme and launches it on the destination, by the
    /// destination's platform: the executable itself on this Mac, `devicectl` on a
    /// device, `simctl` on a simulator.
    func command(scheme: String, simulator: String) throws -> String {
        guard appPath.hasSuffix(".app"), !bundleId.isEmpty, !scheme.isEmpty, !simulator.isEmpty else {
            throw BackendError.operation("Choose a scheme that builds an application and a destination.")
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
        if platform == "macosx" {
            // Run the executable itself so its output lands here and Stop reaches it.
            // pkill reads a pattern, so the path is escaped to match only itself.
            guard let executablePath, !executablePath.isEmpty, executablePath != (appPath as NSString).deletingLastPathComponent else {
                throw BackendError.operation("Scheme \(scheme) builds no runnable application.")
            }
            return "(cd \(q(cwd)) && { \(build) && { /usr/bin/pkill -f -- \(q(NSRegularExpression.escapedPattern(for: executablePath))) >/dev/null 2>&1; exec \(q(executablePath)); }; })"
        }
        if !platform.hasSuffix("simulator") {
            return "(cd \(q(cwd)) && { \(build)"
                + " && /usr/bin/xcrun devicectl device install app --device \(q(simulator)) \(q(appPath))"
                + " && exec /usr/bin/xcrun devicectl device process launch --console --terminate-existing --device \(q(simulator)) \(q(bundleId)); })"
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
            + " && exec /usr/bin/xcrun simctl launch --console-pty --terminate-running-process \(q(simulator)) \(q(bundleId)); })"
    }
}
