import Foundation

@MainActor protocol ShellAppearanceApplying {
    func apply(_ appearance: AppAppearance)
}

@MainActor protocol ShellFeatureFactory {
    func shell(notifications: NotificationStore) -> ShellStore
    func coordinator(model: ShellStore) -> ShellCoordinator
    func data(api: APIClient) -> any ShellDataServing
}

@MainActor struct NativeShellFeatureFactory: ShellFeatureFactory {
    var preferences: UserDefaults = .standard
    var appearance: any ShellAppearanceApplying = NativeShellAppearance()
    func shell(notifications: NotificationStore) -> ShellStore { ShellStore(preferences: preferences, notifications: notifications) }
    func coordinator(model: ShellStore) -> ShellCoordinator { ShellCoordinator(model: model, appearance: appearance) }
    func data(api: APIClient) -> any ShellDataServing { APIShellDataService(api: api) }
}

// Theme application is global, including while Settings is hidden. The model
// owns the choice and persistence; this coordinator owns the platform action.
@MainActor final class ShellCoordinator {
    private weak var model: ShellStore?
    private let appearance: any ShellAppearanceApplying
    private var binding = UUID()

    init(model: ShellStore, appearance: any ShellAppearanceApplying) {
        self.appearance = appearance
        bind(model)
    }
    func bind(_ model: ShellStore) {
        self.model = model
        let binding = UUID()
        self.binding = binding
        model.actionBinding = binding
        model.onAction = { [weak self, weak model] action in
            guard let self, let model, self.model === model, self.binding == binding,
                  model.actionBinding == binding else { return }
            switch action {
            case .applyAppearance(let value):
                guard model.appearance == value else { return }
                self.appearance.apply(value)
            }
        }
    }
    func retire() { binding = UUID(); model = nil }
}
