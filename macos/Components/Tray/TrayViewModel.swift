import Foundation
import Observation

@MainActor struct TrayState {
    var pendingReviews: [TrayPR] = []
    var acknowledging: Set<String> = []
    var canNavigate = false
}

@MainActor protocol TrayServing: AnyObject {
    func trayState() -> TrayState
    func refreshTray()
    func acknowledgeTrayReview(_ review: TrayPR)
}

@MainActor @Observable public final class TrayViewModel {
    enum Action: Equatable { case openReview(String), openUsage, quit }
    let shell: ShellStore
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored var canAct: () -> Bool = { true }
    @ObservationIgnored private weak var service: (any TrayServing)?
    private(set) var retired = false
    /// Opening the menu asks for a refresh, through the same gated path as every other request.
    private(set) var active = false {
        didSet { if oldValue != active && active { refresh() } }
    }
    private(set) var actionError: String?

    init(service: any TrayServing, shell: ShellStore) {
        self.service = service; self.shell = shell
    }
    private var state: TrayState { service?.trayState() ?? TrayState() }
    var available: Bool { !retired && service != nil }
    var pendingReviews: [TrayPR] { state.pendingReviews }

    /// Everything a menu build needs, taken from one snapshot, so a build reads the service
    /// once instead of once per row.
    struct Snapshot {
        let pending: [TrayPR]
        let acknowledging: Set<String>
        let canNavigate: Bool
    }
    func snapshot() -> Snapshot {
        let state = state
        return Snapshot(pending: state.pendingReviews, acknowledging: state.acknowledging, canNavigate: state.canNavigate)
    }
    func canOpen(_ review: TrayPR, in snapshot: Snapshot) -> Bool {
        available && active && snapshot.canNavigate && review.pendingReview
            && review.webURL != nil && !snapshot.acknowledging.contains(review.id)
    }
    func canOpen(_ review: TrayPR) -> Bool { canOpen(review, in: snapshot()) }
    func setActive(_ value: Bool) { if !retired { active = value } }
    func refresh() {
        guard !retired, available, active, canAct() else { return }
        service?.refreshTray()
    }
    func openReview(_ review: TrayPR) { openReview(review.id) }
    /// By identity: the coordinator re-resolves and gates the row, so a click needs no lookup here.
    func openReview(_ id: String) { request(.openReview(id)) }
    func openUsage() { request(.openUsage) }
    func quit() { request(.quit) }
    private func request(_ action: Action) { if available && active { onAction(action) } }

    func review(for id: String) -> TrayPR? {
        guard let review = pendingReviews.first(where: { $0.id == id }), canOpen(review) else { return nil }
        return review
    }
    func reviewDidOpen(_ review: TrayPR, success: Bool) {
        guard available else { return }
        guard success else { actionError = "Could not open the pull request in Craft."; return }
        actionError = nil
        service?.acknowledgeTrayReview(review)
    }
    func retire() { active = false; retired = true; onAction = { _ in }; canAct = { false }; service = nil }
}
