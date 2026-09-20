import Foundation

@MainActor protocol WelcomeFeatureFactory { func welcome() -> WelcomeViewModel }

/// The welcome owns a CLI model of its own: the Settings one is gated on its window and section,
/// and the two must not share in-flight reads.
@MainActor struct NativeWelcomeFeatureFactory: WelcomeFeatureFactory {
    let desktop: any DesktopActions
    let copy: (String) -> Void

    func welcome() -> WelcomeViewModel {
        WelcomeViewModel(clis: CLISettingsViewModel(copy: copy, openBrowser: desktop.openBrowser))
    }
}
