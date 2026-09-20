import Foundation
import Observation

@MainActor @Observable final class DiffCoordinator {
    private(set) var showsActions = false
    private(set) var discardProposal: DiscardProposal?
    var isPresenting: Bool { showsActions || discardProposal != nil }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored var presentationEnded: () -> Void = {}
    @ObservationIgnored private weak var model: DiffViewModel?
    @ObservationIgnored private var bindingID = UUID()

    func bind(_ model: DiffViewModel, openFile: @escaping (DocumentLocation) -> Void) {
        retire()
        self.model = model
        let binding = UUID(); bindingID = binding
        model.onAction = { [weak self, weak model] action in
            guard let self, let model, self.model === model, bindingID == binding else { return }
            switch action {
            case .showActions:
                guard model.isActive, model.actions != nil, !isPresenting, canPresent() else { return }
                showsActions = true
            case .openFile(let location):
                guard model.isActive, !isPresenting, canPresent() else { return }
                openFile(location)
            case .hide: retirePresentation()
            }
        }
        model.actions?.onPresentation = { [weak self, weak model] action in
            guard let self, let model, self.model === model, bindingID == binding else { return }
            switch action {
            case .discard(let proposal):
                guard model.isActive, !isPresenting, canPresent() else { model.actions?.cancelDiscard(); return }
                discardProposal = proposal
            case .discardEnded:
                if discardProposal != nil { discardProposal = nil; presentationEnded() }
            }
        }
    }

    func dismissActions() {
        guard showsActions, model?.actions?.busy != true else { return }
        showsActions = false; presentationEnded()
    }

    func dismissDiscard() {
        guard discardProposal != nil, model?.actions?.busy != true else { return }
        model?.actions?.cancelDiscard()
    }

    private func retirePresentation() {
        let presented = isPresenting
        showsActions = false; discardProposal = nil
        model?.actions?.cancelDiscard()
        if presented { presentationEnded() }
    }

    func retire() {
        retirePresentation()
        bindingID = UUID(); model = nil
    }
}
