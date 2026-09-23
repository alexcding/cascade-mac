import Foundation
import Observation

@MainActor @Observable final class LogsViewModel {
    enum Action: Equatable { case requestClear }
    struct ClearRequest: Identifiable, Equatable {
        let id: UUID
        let category: String
        fileprivate let owner: UUID
        fileprivate let connection: UUID
        var label: String { LogsViewModel.label(category) }
    }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored var canAct: () -> Bool = { true }
    let navigation: PageActionViewModel
    private(set) var retired = false
    var category = "event" { didSet { if oldValue != category { cancelActions(); refresh() } } }
    var errorsOnly = false { didSet { if oldValue != errorsOnly { cancelActions(); refresh() } } }
    var search = "" { didSet { if oldValue != search { cancelActions() } } }
    private(set) var categories = ["all", "event"]
    private(set) var entries: [LogEntry] = []
    private(set) var error: String?
    private(set) var loading = false
    private(set) var clearing = false
    private(set) var clearError: String?
    private(set) var updated: Date?
    @ObservationIgnored private var service: (any LogService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var loadedCategory: String?
    @ObservationIgnored private var loadedErrorsOnly = false
    @ObservationIgnored private let identity = UUID()
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private var readGeneration = UUID()
    @ObservationIgnored private var clearGeneration = UUID()
    @ObservationIgnored private let copy: (String) -> Void

    init(pageActions: any PageActionServing, copy: @escaping (String) -> Void) {
        navigation = PageActionViewModel(service: pageActions, failureDescription: "Could not open pull request")
        self.copy = copy
    }
    func connect(_ service: any LogService) {
        guard !retired else { return }
        disconnect(); self.service = service
    }
    var rows: [LogEntry] {
        guard loadedCategory == category && loadedErrorsOnly == errorsOnly else { return [] }
        return entries.filter { search.isEmpty || "\($0.title) \($0.detail) \($0.category)".localizedStandardContains(search) }
    }
    var canRequestClear: Bool { !retired && service != nil && !clearing }
    nonisolated static func label(_ category: String) -> String {
        switch category { case "all": "All logs"; case "event": "Activity"; default: category.capitalized }
    }
    func refresh() {
        guard !retired, let service else { return }
        pending = true
        guard task == nil else { return }
        let generation = readGeneration
        loading = true
        task = Task {
            defer { if readGeneration == generation { task = nil; loading = false } }
            while pending && !Task.isCancelled && readGeneration == generation {
                pending = false
                let scope = category, errors = errorsOnly
                do {
                    async let categoryRequest = try? service.categories()
                    let entries = try await service.entries(category: scope, errorsOnly: errors)
                    let names = await categoryRequest
                    try Task.checkCancellation()
                    guard readGeneration == generation else { return }
                    if let names { categories = ["all", "event"] + names.filter { !["all", "event"].contains($0) }.sorted() }
                    if !categories.contains(category) { categories.append(category) }
                    guard scope == category && errors == errorsOnly else { pending = true; continue }
                    self.entries = entries; loadedCategory = scope; loadedErrorsOnly = errors
                    if let url = navigation.opening, !rows.contains(where: { $0.link == url }) { cancelActions() }
                    updated = Date(); error = nil
                } catch {
                    if !Task.isCancelled && readGeneration == generation {
                        if scope == category && errors == errorsOnly { self.error = error.localizedDescription }
                        else { pending = true }
                    }
                }
            }
        }
    }
    func requestClear() { if canRequestClear { onAction(.requestClear) } }
    func makeClearRequest() -> ClearRequest? {
        guard canRequestClear else { return nil }
        clearGeneration = UUID(); clearError = nil
        return ClearRequest(id: clearGeneration, category: category, owner: identity, connection: connection)
    }
    func canClear(_ request: ClearRequest) -> Bool {
        canRequestClear && request.owner == identity && request.connection == connection && request.id == clearGeneration
    }
    func clearFailure(for request: ClearRequest) -> String? {
        guard !retired, service != nil, request.owner == identity, request.connection == connection, request.id == clearGeneration else {
            return "The connection or clear request changed. Cancel and review the category again."
        }
        return clearError
    }
    func cancelClear(_ request: ClearRequest) {
        if !clearing && request.id == clearGeneration { clearGeneration = UUID(); clearError = nil }
    }
    func clear(_ request: ClearRequest) async -> Bool {
        guard canClear(request), let service else { return false }
        clearing = true; clearError = nil; cancelActions()
        defer { clearing = false }
        do {
            try await service.clear(category: request.category)
            if !retired && request.connection == connection {
                // Do not wait for a pre-clear read: its generation prevents it from
                // restoring deleted entries even if its transport ignores cancellation.
                cancelRead()
                entries.removeAll { request.category == "all" || $0.category == request.category }
                clearGeneration = UUID(); refresh()
            }
            return true
        } catch {
            if !retired && request.connection == connection { clearError = error.localizedDescription }
            return false
        }
    }
    func open(_ entry: LogEntry) {
        guard !retired, canAct(), rows.contains(where: { $0.id == entry.id }) else { return }
        guard let raw = entry.link, safeWebURL(raw) != nil else { return }
        guard service != nil else { navigation.reject("Connect to open pull requests in Craft."); return }
        navigation.open(OpenPageRequest(url: raw, kind: "github", title: entry.title))
    }
    func copyEntry(_ entry: LogEntry) {
        guard !retired, canAct(), rows.contains(where: { $0.id == entry.id }) else { return }
        copy("\(entry.created_at) [\(entry.category)/\(entry.level)] \(entry.title)\n\(entry.payload ?? entry.detail)")
    }
    func cancelActions() { navigation.cancel() }
    private func cancelRead() {
        readGeneration = UUID(); task?.cancel(); task = nil; pending = false; loading = false
    }
    private func disconnect() {
        connection = UUID(); clearGeneration = UUID(); service = nil
        cancelActions(); cancelRead()
    }
    func retire() { retired = true; onAction = { _ in }; canAct = { false }; disconnect() }
    func stop() async {
        let previous = task; disconnect(); await previous?.value
    }
}
