import Foundation
import Observation

@MainActor struct TrayState {
    var reviews: [TrayPR] = []
    var acknowledging: Set<String> = []
    var canNavigate = false
}

@MainActor protocol TrayServing: AnyObject {
    func trayState() -> TrayState
    func refreshTray()
    func acknowledgeTrayReview(_ review: TrayPR)
}

@MainActor @Observable public final class TrayViewModel {
    enum Action: Equatable { case refresh, openReview(String) }
    let shell: ShellStore
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored private weak var service: (any TrayServing)?
    private(set) var retired = false
    private(set) var active = false {
        didSet { if oldValue != active && active { refresh() } }
    }
    private(set) var actionError: String?

    init(service: any TrayServing, shell: ShellStore) {
        self.service = service; self.shell = shell
    }
    private var state: TrayState { service?.trayState() ?? TrayState() }
    var available: Bool { !retired && service != nil }
    var pendingReviews: [TrayPR] { state.reviews.filter(\.pendingReview) }
    func canOpen(_ review: TrayPR) -> Bool {
        available && active && state.canNavigate && review.pendingReview
            && review.webURL != nil && !state.acknowledging.contains(review.id)
    }
    func setActive(_ value: Bool) { if !retired { active = value } }
    func refresh() { request(.refresh) }
    func openReview(_ review: TrayPR) { request(.openReview(review.id)) }
    private func request(_ action: Action) { if available && active { onAction(action) } }

    func performRefresh() { if available { service?.refreshTray() } }
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
    func retire() { active = false; retired = true; onAction = { _ in }; service = nil }
}
