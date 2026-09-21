import Foundation

@MainActor final class BrowserControlsCoordinator {
    private let canPerform: () -> Bool

    init(canPerform: @escaping () -> Bool = { true }) { self.canPerform = canPerform }

    func bind(_ model: BrowserControlsViewModel, page: any BrowserControlling, isOwned: @escaping () -> Bool) {
        let bindingID = UUID()
        model.bindingID = bindingID
        model.onAction = { [weak self, weak model, weak page] action in
            guard let self, let model, let page, model.bindingID == bindingID, isOwned() else { return }
            // Mute is the one control that works on a background tab, and needs no dialog slot.
            if case .toggleMute = action { page.toggleMute(); return }
            guard model.active, canPerform() else { return }
            switch action {
            case .navigate(let url):
                guard let url = safeWebURL(url.absoluteString) else { return }
                page.navigate(url.absoluteString)
            case .back: page.back()
            case .forward: page.forward()
            case .reload: page.reload()
            case .stop: page.stop()
            case .zoom(let delta): page.zoom(delta)
            case .find(let text, let backwards): page.find(text, backwards: backwards)
            case .toggleMute: page.toggleMute()
            }
        }
    }
}
