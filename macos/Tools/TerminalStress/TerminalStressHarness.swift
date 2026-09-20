import AppKit
import Darwin
import Foundation
import GhosttyTerminal

private struct TerminalStressSample: Codable {
    let elapsedSeconds: Double
    let inputToParsedOutputMS: Double
    let hostResidentBytes: UInt64
    let hostCPUPercent: Double?
    let daemonTreeResidentBytes: UInt64
    let daemonTreeCPUPercent: Double?
    let activeWindowVisible: Bool
    let floodPausedByObserver: Bool
    let submittedFrames: [UInt64]
    let terminals: [TerminalPipe.Diagnostics]
}
private struct TerminalStressReport: Encodable {
#if DEBUG
    let swiftConfiguration = "Debug"
#else
    let swiftConfiguration = "Release"
#endif
    let helperConfiguration: String
    let scope = "Native TerminalSession/WorkspaceTerminalView harness; not full-app or key-to-display benchmark"
    let clock = "ContinuousClock; latency ends when parsed viewport contains the echoed key marker"
    let ghosttyRevision = "82938b633ba646db38591d969c3c526332bd7e65"
    let workload = "One interactive visible terminal, one hidden Unicode/ANSI flood, eight hidden 10 Hz tickers"
    let machine: String
    let operatingSystem: String
    let memoryBytes: UInt64
    let logicalCPUs: Int
    let seconds: Double
    let p95InputToParsedOutputMS: Double
    let initialSubmittedFrames: [UInt64]
    let samples: [TerminalStressSample]
}
private func elapsed(_ value: Duration) -> Double {
    Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
}
private func machineModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "unknown" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}
private func stressRequire(_ condition: @autoclosure () -> Bool, _ message: String = "Terminal stress invariant failed") throws {
    guard condition() else { throw BackendError.operation(message) }
}

public enum TerminalStressHarness {
    @MainActor public static func run(seconds: Double, root: URL, reportURL: URL, helperURL: URL? = nil) async throws -> URL {
        try stressRequire(seconds >= 10 && seconds <= 600, "Choose a duration from 10 through 600 seconds")
        let directory = URL(fileURLWithPath: "/tmp/th-stress-\(UUID().uuidString.prefix(10))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = directory.appendingPathComponent("interactive")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-O2", root.appendingPathComponent("macos/scripts/terminal-stress-fixture.c").path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        try stressRequire(compiler.terminationStatus == 0)
        for name in ["flood", "ticker"] {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: executable)
        }
        let config = PtydConfiguration(executable: helperURL ?? root.appendingPathComponent("crates/craft-ptyd/target/debug/craft-ptyd"),
            directory: directory, socketPath: directory.appendingPathComponent("daemon.sock").path)
        let host = PtydHost(configuration: config)
        let control = PtydClient(onEvent: { _ in })
        let hello = try await host.connect(client: control)
        var sessions: [TerminalSession] = [], views: [WorkspaceTerminalView] = [], windows: [NSWindow] = []
        var pauseOwner: PtydClient?
        func cleanUp() async throws {
            pauseOwner?.close(); pauseOwner = nil
            for session in sessions { await session.stopConnecting(); session.disconnect() }
            try await host.stopExisting()
            control.close()
            for window in windows { window.contentView = nil; window.close() }
        }
        do {
            for index in 0..<10 {
                let mode = index == 0 ? "interactive" : index == 1 ? "flood" : "ticker"
                let session = TerminalSession(pairKey: "stress-\(index)", cwd: directory.path, configuration: config,
                                              shellPath: directory.appendingPathComponent(mode).path)
                let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
                view.delegate = session.surface; view.controller = session.surface.controller; view.configuration = session.surface.configuration
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Craft isolated terminal stress"
                window.isReleasedWhenClosed = false; window.contentView = view
                sessions.append(session); views.append(view); windows.append(window)
                view.layoutSubtreeIfNeeded()
                view.setSurfaceVisible(index == 0)
                if index == 0 { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                await session.start(); try await session.waitUntilReady()
            }
            let pids = sessions.map(\.shellPID)
            let generations = sessions.map(\.surfaceGeneration)
            for _ in 0..<100 {
                if windows[0].occlusionState.contains(.visible) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try stressRequire(windows[0].occlusionState.contains(.visible), "The interactive benchmark window must be visible")
            let controlInfo: [PtyInfo] = try await control.request(.init(op: "list"))
            try stressRequire(controlInfo.count == 10)
            try stressRequire(controlInfo.allSatisfy { $0.geometryResponseOwner == PtyHello.geometryResponseOwnerVersion })
            func submittedFrames() throws -> [UInt64] {
                try sessions.enumerated().map { index, session in
                    guard let count = session.surface.surface?.submittedFrameCount else {
                        throw BackendError.operation("Missing native render diagnostics for terminal \(index)")
                    }
                    return count
                }
            }
            // Visibility reaches the renderer through its mailbox. Exclude mount
            // frames and allow in-flight work to settle before measuring inactivity.
            try await Task.sleep(for: .seconds(2))
            let initialSubmittedFrames = try submittedFrames()
            try stressRequire(initialSubmittedFrames[0] > 0, "The visible surface has not submitted a native render frame")
            let sampler = NativeProcessResourceSampler()
            let roots = [ResourceRoot(pid: hello.pid, group: .terminals), ResourceRoot(pid: getpid(), group: .app)]
            var previous = try await sampler.sample(roots: roots)
            var samples: [TerminalStressSample] = []
            let clock = ContinuousClock(), started = ContinuousClock.now
            var sequence = 0
            var pausedFloodBytes: UInt64 = 0
            var pausedTickerBytes: UInt64 = 0
            while elapsed(started.duration(to: clock.now)) < seconds {
                try Task.checkCancellation()
                try stressRequire(sessions.allSatisfy { $0.ready && $0.error == nil })
                try stressRequire(sessions.map(\.shellPID) == pids)
                try stressRequire(sessions.map(\.surfaceGeneration) == generations)
                sequence += 1
                if sequence == 3 {
                    let observer = PtydClient(onEvent: { _ in })
                    _ = try await observer.connect(path: config.socketPath)
                    let _: Bool? = try await observer.request(.init(op: "flow", term: sessions[1].termID, pause: true))
                    pauseOwner = observer
                    pausedFloodBytes = sessions[1].outputDiagnostics.receivedBytes
                    pausedTickerBytes = sessions[2].outputDiagnostics.receivedBytes
                } else if sequence == 4 {
                    try stressRequire(sessions[2].outputDiagnostics.receivedBytes > pausedTickerBytes)
                    pauseOwner?.close(); pauseOwner = nil
                } else if sequence == 5 {
                    try stressRequire(sessions[1].outputDiagnostics.receivedBytes > pausedFloodBytes)
                }
                let marker = String(format: "INPUT:%08d", sequence)
                let sent = clock.now
                try stressRequire(views[0].sendKey(.enter))
                var found = false
                for _ in 0..<1000 {
                        if await sessions[0].viewportText()?.contains(marker) == true { found = true; break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                try stressRequire(found, "Interactive terminal did not echo a key while the hidden terminal flooded")
                let latency = elapsed(sent.duration(to: clock.now)) * 1000
                let resources = try await sampler.sample(roots: roots)
                let prior = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.id, $0) })
                let app = resources.processes.filter { $0.group == .app }
                let daemon = resources.processes.filter { $0.group == .terminals }
                let stats = sessions.map(\.outputDiagnostics)
                let frames = try submittedFrames()
                for index in 1..<10 {
                    try stressRequire(frames[index] == initialSubmittedFrames[index],
                        "Hidden terminal \(index) submitted native render frames: \(initialSubmittedFrames[index]) → \(frames[index])")
                }
                if let priorSample = samples.last {
                    for index in 2..<10 {
                        try stressRequire(stats[index].receivedBytes > priorSample.terminals[index].receivedBytes,
                                "A hidden ticker stopped progressing while another terminal flooded")
                    }
                }
                try stressRequire(stats.allSatisfy { !$0.failed && $0.peakQueuedBytes <= 8 * 1024 * 1024 && $0.peakQueuedEvents <= 16384 })
                samples.append(.init(elapsedSeconds: elapsed(started.duration(to: clock.now)), inputToParsedOutputMS: latency,
                    hostResidentBytes: app.reduce(0) { $0 + $1.residentBytes },
                    hostCPUPercent: app.compactMap { $0.cpuPercent(since: prior[$0.id]) }.reduce(0, +),
                    daemonTreeResidentBytes: daemon.reduce(0) { $0 + $1.residentBytes },
                    daemonTreeCPUPercent: daemon.compactMap { $0.cpuPercent(since: prior[$0.id]) }.reduce(0, +),
                    activeWindowVisible: windows[0].occlusionState.contains(.visible), floodPausedByObserver: pauseOwner != nil, submittedFrames: frames, terminals: stats))
                previous = resources
                if sequence % 15 == 0 { print("Terminal stress: \(Int(elapsed(started.duration(to: clock.now))))s, \(sequence) input samples") }
                try await Task.sleep(for: .seconds(2))
            }
            for index in 1..<10 {
                let text = await sessions[index].viewportText() ?? ""
                try stressRequire(text.contains(index == 1 ? "FLOOD:" : "TICK:"))
                try stressRequire(sessions[index].outputDiagnostics.receivedBytes > 0)
            }
            let sorted = samples.map(\.inputToParsedOutputMS).sorted()
            try stressRequire(samples.allSatisfy { $0.activeWindowVisible }, "Occluded samples cannot prove the visible-terminal workload")
            let finalSubmittedFrames = try submittedFrames()
            try stressRequire(finalSubmittedFrames[0] > initialSubmittedFrames[0], "The visible surface stopped submitting render frames")
            let report = TerminalStressReport(helperConfiguration: config.executable.deletingLastPathComponent().lastPathComponent,
                machine: machineModel(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                memoryBytes: ProcessInfo.processInfo.physicalMemory, logicalCPUs: ProcessInfo.processInfo.processorCount,
                seconds: elapsed(started.duration(to: clock.now)), p95InputToParsedOutputMS: sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], initialSubmittedFrames: initialSubmittedFrames, samples: samples)
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            print("Terminal stress report: \(reportURL.path)")
            print("p95 input-to-parsed-output: \(report.p95InputToParsedOutputMS) ms (not display latency)")
            try await cleanUp()
            try FileManager.default.removeItem(at: directory)
            return reportURL
        } catch {
            try? await cleanUp()
            print("Terminal stress failure diagnostics: \(directory.path)")
            throw error
        }
    }
}
