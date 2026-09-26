import SwiftUI

@main
struct CascadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window is AppKit's (`MainWindowController`, made by the delegate), so its toolbar
        // can be split where its columns are, and so is Help's. Settings is the only scene: SwiftUI
        // opens an app's first window scene at launch, but leaves a lone Settings shut.
        // Settings is its own window; SwiftUI supplies the Settings… menu item and ⌘, for it.
        Settings {
            SettingsWindowView(coordinator: delegate.model.coordinator)
                .environment(\.documentFont, delegate.model.shell.font(.diff))
        }
        .windowResizability(.contentMinSize)
        .commands {
            CascadeCommands(model: delegate.model, perform: delegate.perform, showHelp: delegate.showHelp,
                            canCheckForUpdates: delegate.canCheckForUpdates)
        }
    }
}
