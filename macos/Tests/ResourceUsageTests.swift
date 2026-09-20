import Darwin
import Foundation
import Testing

private func resourceCounter(pid: Int32 = 20, start: UInt64 = 1, cpu: UInt64, time: UInt64, name: String = "Fixture") -> ProcessResourceCounter {
    .init(pid: pid, startedSeconds: start, startedMicroseconds: 0, name: name, group: .app,
          footprintBytes: 4096, cpuTicks: cpu, sampledTicks: time)
}

@Test func nativeResourceCPUUsesElapsedTicksAndRejectsReusedOrResetCounters() {
    let previous = resourceCounter(cpu: 100, time: 1_000)
    #expect(resourceCounter(cpu: 600, time: 2_000).cpuPercent(since: previous) == 50)
    #expect(resourceCounter(cpu: 2_600, time: 2_000).cpuPercent(since: previous) == 250)
    #expect(resourceCounter(start: 2, cpu: 600, time: 2_000).cpuPercent(since: previous) == nil)
    #expect(resourceCounter(cpu: 90, time: 2_000).cpuPercent(since: previous) == nil)
    #expect(resourceCounter(cpu: 600, time: 1_000).cpuPercent(since: previous) == nil)
    #expect(previous.cpuPercent(since: nil) == nil)
}

@Test(.timeLimit(.minutes(1))) func nativeResourceSamplerCountsRealChildOnceAndMeasuresCPU() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    let sampler = NativeProcessResourceSampler()
    let roots = [ResourceRoot(pid: child.processIdentifier, group: .backend), ResourceRoot(pid: getpid(), group: .app)]
    let first = try await sampler.sample(roots: roots)
    try await Task.sleep(for: .milliseconds(300))
    let second = try await sampler.sample(roots: roots)
    let process = try #require(second.processes.first { $0.pid == child.processIdentifier })
    #expect(process.group == .backend && process.footprintBytes > 0)
    #expect(second.processes.filter { $0.pid == child.processIdentifier }.count == 1)
    #expect(second.processes.contains { $0.pid == getpid() && $0.group == .app && $0.footprintBytes > 0 })
    let cpu = try #require(process.cpuPercent(since: first.processes.first { $0.id == process.id }))
    #expect(cpu > 1 && cpu < 150) // A real single-threaded busy child, in Mach units.
}

@Test func nativeResourceReadDoesNotStartMissingDaemon() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resources-\(UUID().uuidString)")
    let socket = "/tmp/resource-\(UUID().uuidString).sock"
    let config = PtydConfiguration(executable: URL(fileURLWithPath: "/bin/false"), directory: directory, socketPath: socket)
    let service = NativeResourceUsageService(api: nil, pty: config)
    let sample = try await service.sample()
    #expect(sample.processes.contains { $0.pid == getpid() })
    #expect(sample.notes.contains("PTY helper is not running."))
    #expect(!FileManager.default.fileExists(atPath: socket))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

actor HeldResourceService: ResourceUsageService {
    private(set) var calls = 0
    private var closed = false
    private var pending: [CheckedContinuation<ResourceUsageSample, Error>] = []
    func sample() async throws -> ResourceUsageSample {
        guard !closed else { throw CancellationError() }
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(_ sample: ResourceUsageSample) {
        guard !pending.isEmpty else { Issue.record("No resource request to complete"); return }
        pending.removeFirst().resume(returning: sample)
    }
    func fail() {
        guard !pending.isEmpty else { Issue.record("No resource request to fail"); return }
        pending.removeFirst().resume(throwing: BackendError.operation("Fixture sample failed"))
    }
    func close() {
        closed = true
        pending.forEach { $0.resume(throwing: CancellationError()) }; pending = []
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func nativeResourcePollingStopsWhileHiddenAndRejectsLateConnections() async throws {
    let old = HeldResourceService(), current = HeldResourceService()
    let model = ResourceUsageViewModel(interval: .milliseconds(25))
    model.connect(old)
    try await Task.sleep(for: .milliseconds(40))
    #expect(await old.calls == 0)
    model.setVisible(true)
    for _ in 0..<100 { if await old.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await old.calls == 1)
    model.setVisible(true)
    #expect(await old.calls == 1)
    model.connect(current)
    for _ in 0..<100 { if await current.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
    await current.complete(.init(processes: [resourceCounter(cpu: 100, time: 1_000, name: "Current")]))
    for _ in 0..<100 { if model.rows.first?.process.name == "Current" { break }; try await Task.sleep(for: .milliseconds(5)) }
    await old.complete(.init(processes: [resourceCounter(cpu: 0, time: 10, name: "Stale")]))
    for _ in 0..<100 { if await current.calls == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.rows.first?.process.name == "Current" && model.rows.first?.cpuPercent == nil)
    await current.complete(.init(processes: [resourceCounter(cpu: 600, time: 2_000, name: "Current")]))
    for _ in 0..<100 { if model.rows.first?.cpuPercent == 50 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.cpu == "50.0%")
    for _ in 0..<100 { if await current.calls == 3 { break }; try await Task.sleep(for: .milliseconds(5)) }
    await current.fail()
    for _ in 0..<100 { if model.error != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.error == "Fixture sample failed" && model.rows.first?.process.name == "Current")
    model.setVisible(false)
    let calls = await current.calls
    try await Task.sleep(for: .milliseconds(60))
    #expect(await current.calls == calls)
    model.setForeground(false); model.setVisible(true)
    try await Task.sleep(for: .milliseconds(40))
    #expect(await current.calls == calls)
    model.setForeground(true)
    for _ in 0..<100 { if await current.calls > calls { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await current.calls == calls + 1)
    await current.complete(.init(processes: [resourceCounter(cpu: 1_000, time: 3_000, name: "Resumed")]))
    for _ in 0..<100 { if model.rows.first?.process.name == "Resumed" { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.rows.first?.cpuPercent == nil && model.error == nil)
    model.stop()
    await old.close(); await current.close()
}
