import Foundation
import Observation

@MainActor @Observable final class DiagnosticsViewModel {
    struct CacheRow: Identifiable {
        let id: String
        let title: String
        let count: String
        let lastSync: String
        let error: String?

        init(id: String, title: String, cache: DiagnosticsSnapshot.Cache?, unit: String) {
            self.id = id; self.title = title
            count = cache.map { "\($0.open ?? $0.tickets ?? 0) \(unit)" } ?? "No snapshot"
            lastSync = cache?.lastSynced.map { "Last synced: \($0)" } ?? "Never synced"
            error = cache?.error.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
    struct ProjectRow: Identifiable {
        let id: String
        let name: String
        let repository: String
        let automation: String
        let caches: [CacheRow]
    }

    private(set) var snapshot: DiagnosticsSnapshot?
    private(set) var projects: [ProjectRow] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?
    @ObservationIgnored private var service: (any DiagnosticsService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var refreshPending = false

    func connect(_ service: any DiagnosticsService) {
        cancelRead()
        self.service = service
        snapshot = nil; projects = []; updatedAt = nil; error = nil
        invalidate()
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value { refresh() } else { cancelRead() }
    }

    // SSE invalidations are coalesced, with one trailing read if data changed
    // during a request. Hidden Settings never run a diagnostic polling loop.
    func invalidate() {
        guard visible else { return }
        if loading { refreshPending = true } else { refresh() }
    }

    func refresh() {
        guard task == nil, let service else { return }
        let requestGeneration = generation
        loading = true
        task = Task {
            defer {
                if generation == requestGeneration {
                    task = nil; loading = false
                    if refreshPending { refreshPending = false; invalidate() }
                }
            }
            do {
                let result = try await service.snapshot()
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                snapshot = result
                projects = result.projects.map { project in
                    ProjectRow(id: project.id, name: project.name,
                        repository: project.repo.isEmpty ? "No GitHub repository" : project.repo,
                        automation: project.mergeTransition.flatMap { $0.isEmpty ? nil : $0 }
                            .map { "On merge: \($0)" } ?? "No merge transition",
                        caches: [
                            CacheRow(id: "github", title: "GitHub", cache: result.snapshots[project.id], unit: "open PRs"),
                            CacheRow(id: "jira", title: "Jira tickets", cache: result.jiraSnapshots[project.id], unit: "tickets"),
                            CacheRow(id: "board", title: "Sprint board", cache: result.jiraSnapshots["board:\(project.id)"], unit: "tickets")
                        ])
                }
                updatedAt = Date(); error = nil
            } catch {
                if !Task.isCancelled && generation == requestGeneration { self.error = error.localizedDescription }
            }
        }
    }

    private func cancelRead() {
        generation = UUID(); task?.cancel(); task = nil
        loading = false; refreshPending = false
    }

    func stop() {
        cancelRead(); service = nil
        snapshot = nil; projects = []; updatedAt = nil; error = nil
    }
}
