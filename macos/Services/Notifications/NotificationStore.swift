import Foundation
import Observation

@MainActor @Observable public final class NotificationStore {
    enum Action: Equatable {
        case enable, previewSound(String), openCurrent(String), openDelivered(NativeNotice)
    }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    private(set) var retired = false
    private(set) var actionError: String?
    private(set) var permission: NotificationPermission = .unavailable
    private(set) var error: String?
    private(set) var requesting = false
    private(set) var recent: [NativeNotice] = []
    private(set) var toast: NativeNotice?
    @ObservationIgnored public var isMainWindowFocused: () -> Bool = { false }
    @ObservationIgnored private var delivery: (any NotificationDelivery)?
    @ObservationIgnored private var reviewTracker = ReviewAnnouncementTracker()
    @ObservationIgnored private var activityKeys: [Data] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authorizationRead: UUID?

    func configure(_ delivery: any NotificationDelivery) {
        guard !retired else { return }
        _ = cancelOperations()
        self.delivery = delivery
        error = nil
        refreshAuthorization()
    }

    func accepts(_ delivery: any NotificationDelivery) -> Bool { !retired && self.delivery === delivery }
    private func isCurrent(_ generation: UUID) -> Bool { !retired && self.generation == generation && !Task.isCancelled }

    public func refreshAuthorization() {
        guard !retired, authorizationRead == nil, !requesting, let delivery else { return }
        let revision = UUID(); authorizationRead = revision
        let generation = generation
        enqueue { [weak self] in
            guard let self, isCurrent(generation) else { return }
            let access = await delivery.access()
            guard isCurrent(generation), authorizationRead == revision else { return }
            permission = access.permission; authorizationRead = nil
        }
    }

    var canEnable: Bool { !retired && delivery != nil && authorizationRead == nil && !requesting && permission == .notDetermined }
    func enable() { if canEnable { onAction(.enable) } }
    func previewSound(_ sound: String) { if !retired, sound != "off" { onAction(.previewSound(sound)) } }

    func requestAuthorization() {
        guard canEnable, let delivery else { return }
        requesting = true; authorizationRead = nil
        let generation = generation
        enqueue { [weak self] in
            guard let self, isCurrent(generation) else { return }
            defer { if self.generation == generation { requesting = false } }
            do {
                try await delivery.requestAuthorization()
                guard isCurrent(generation) else { return }
                let access = await delivery.access()
                guard isCurrent(generation) else { return }
                permission = access.permission; error = nil
            } catch { if isCurrent(generation) { self.error = error.localizedDescription } }
        }
    }

    func playPreview(_ sound: String) {
        guard !retired, sound != "off", let delivery else { return }
        do { try delivery.playReviewSound(sound); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func receiveReviews(_ prs: [TrayPR], sound: String) {
        guard !retired else { return }
        let fresh = reviewTracker.consume(prs)
        guard !fresh.isEmpty else { return }
        let notices = fresh.map {
            NativeNotice(kind: .review, title: "Review requested", body: "PR #\($0.number) \($0.title)",
                         url: $0.webURL?.absoluteString, repo: $0.repo, number: $0.number)
        }
        deliver(notices, reviewSound: sound)
    }

    func receiveActivity(_ event: ActivityEvent, enabled: Bool) {
        guard !retired else { return }
        // The server has no replay IDs. Deduplicate recent identical timestamped
        // events, bounded independently of the visible recent activity list.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if event.created_at != nil, let key = try? encoder.encode(event) {
            if activityKeys.contains(key) { return }
            activityKeys.append(key)
            if activityKeys.count > 256 { activityKeys.removeFirst(activityKeys.count - 256) }
        }
        let notice = event.message
        recent.insert(notice, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        guard enabled else { return }
        if isMainWindowFocused() { showToast(notice) }
        else { deliver([notice]) }
    }

    private func deliver(_ notices: [NativeNotice], reviewSound: String? = nil) {
        guard !retired, let delivery else { return }
        let generation = generation
        enqueue { [weak self] in
            guard let self, isCurrent(generation) else { return }
            let access = await delivery.access()
            guard isCurrent(generation) else { return }
            guard access.permission == .authorized else { return }
            var delivered = false
            for notice in notices {
                do {
                    try Task.checkCancellation()
                    try await delivery.deliver(notice)
                    guard isCurrent(generation) else { return }
                    delivered = true
                    error = nil
                } catch { if isCurrent(generation) { self.error = error.localizedDescription } }
            }
            if isCurrent(generation), delivered, access.soundAllowed, let reviewSound, reviewSound != "off" {
                do { try delivery.playReviewSound(reviewSound) }
                catch { self.error = "Could not play review sound: \(error.localizedDescription)" }
            }
        }
    }

    // Recheck focus if it changed between SSE receipt and the OS callback.
    func shouldPresentBanner(for notice: NativeNotice) -> Bool {
        guard !retired else { return false }
        if notice.kind == .activity, isMainWindowFocused() { showToast(notice); return false }
        return true
    }

    /// How long an activity toast stays (activity-toast.js LINGER_MS); hovering holds it.
    static let toastLinger: Duration = .seconds(6)

    func showToast(_ notice: NativeNotice) {
        guard !retired else { return }
        toast = notice
        armToast()
    }

    /// The pointer is over the toast: keep it until it leaves.
    func holdToast() { toastTask?.cancel(); toastTask = nil }
    func releaseToast() { if toast != nil { armToast() } }

    private func armToast() {
        guard let notice = toast else { return }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.toastLinger) } catch { return }
            if self?.toast?.id == notice.id { self?.dismissToast() }
        }
    }

    func dismissToast() { toastTask?.cancel(); toastTask = nil; toast = nil }
    func notice(id: String) -> NativeNotice? { toast?.id == id ? toast : recent.first { $0.id == id } }
    func open(_ notice: NativeNotice) { if !retired { onAction(.openCurrent(notice.id)) } }
    func openDelivered(_ notice: NativeNotice) { if !retired { onAction(.openDelivered(notice)) } }
    func didOpen(_ notice: NativeNotice, success: Bool) {
        guard !retired else { return }
        actionError = success ? nil : "Could not open the notification link."
        if success, toast?.id == notice.id { dismissToast() }
    }

    private func enqueue(_ action: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await action()
            self?.tasks.removeValue(forKey: id)
        }
    }

    func waitForDelivery() async {
        for task in Array(tasks.values) { await task.value }
    }

    private func cancelOperations() -> [Task<Void, Never>] {
        generation = UUID(); authorizationRead = nil; requesting = false
        let pending = Array(tasks.values); tasks.removeAll()
        pending.forEach { $0.cancel() }
        return pending
    }

    func retire() {
        retired = true; onAction = { _ in }; isMainWindowFocused = { false }
        dismissToast(); _ = cancelOperations(); delivery = nil
    }

    func stop() async {
        dismissToast()
        let pending = cancelOperations()
        for task in pending { await task.value }
        // New work may start while old tasks drain; never clear its bookkeeping.
        // Keep review markers across backend reconnects to avoid repeat alerts.
    }
}
