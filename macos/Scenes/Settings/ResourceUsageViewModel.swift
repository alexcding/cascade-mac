import Foundation
import Observation

@MainActor @Observable final class ResourceUsageViewModel {
    struct Row: Identifiable {
        let process: ProcessResourceCounter
        let cpuPercent: Double?
        var id: String { process.id }
        var memory: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: process.footprintBytes), countStyle: .memory) }
        var cpu: String { cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Sampling…" }
    }
    private(set) var rows: [Row] = []
    private(set) var notes: [String] = []
    private(set) var updatedAt: Date?
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var service: (any ResourceUsageService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var previous: [String: ProcessResourceCounter] = [:]
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = .seconds(3)) { self.interval = interval }
    var memory: String {
        guard updatedAt != nil else { return "Sampling…" }
        let maximum = UInt64(Int64.max)
        let total = rows.reduce(UInt64(0)) { min(maximum, $0 + min(maximum, $1.process.footprintBytes)) }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory)
    }
    var cpu: String {
        let values = rows.compactMap(\.cpuPercent)
        guard !values.isEmpty else { return "Sampling…" }
        let result = String(format: "%.1f%%", values.reduce(0, +))
        return values.count == rows.count ? result : result + " (partial)"
    }
    func connect(_ service: any ResourceUsageService) {
        cancel(); self.service = service
        rows = []; notes = []; updatedAt = nil; error = nil
        begin()
    }
    func setVisible(_ value: Bool) { visible = value; if value { begin() } else { cancel() } }
    func setForeground(_ value: Bool) { foreground = value; if value { begin() } else { cancel() } }
    func refresh() {
        let baseline = previous
        cancel(); previous = baseline; begin()
    }

    private func begin() {
        guard visible, foreground, task == nil, let service else { return }
        let token = generation
        task = Task {
            defer { if generation == token { task = nil; loading = false } }
            while !Task.isCancelled {
                loading = true
                do {
                    let sample = try await service.sample()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    rows = sample.processes.map { Row(process: $0, cpuPercent: $0.cpuPercent(since: previous[$0.id])) }
                        .sorted { lhs, rhs in
                            if lhs.process.group != rhs.process.group { return lhs.process.group.rawValue < rhs.process.group.rawValue }
                            return lhs.process.pid < rhs.process.pid
                        }
                    previous = Dictionary(sample.processes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    notes = sample.notes; updatedAt = sample.updatedAt; error = nil
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    self.error = error.localizedDescription; previous = [:]
                }
                loading = false
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil; loading = false; previous = [:]
    }
    func stop() { cancel(); service = nil }
}
