import Foundation

/// Whether the first-run welcome has been shown. It is a fact about this install, not about the
/// user's data, so it lives with the app and the backend never hears of it.
@MainActor protocol WelcomePersisting: AnyObject {
    var shown: Bool { get set }
}

/// Defaults to shown, so a model built without a store never opens the welcome over a test.
@MainActor final class TransientWelcomeStore: WelcomePersisting {
    var shown: Bool
    init(shown: Bool = true) { self.shown = shown }
}

@MainActor final class UserDefaultsWelcomeStore: WelcomePersisting {
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var shown: Bool {
        get { preferences.bool(forKey: "native.welcomeShown") }
        set { preferences.set(newValue, forKey: "native.welcomeShown") }
    }
}
