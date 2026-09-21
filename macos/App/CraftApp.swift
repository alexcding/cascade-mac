import SwiftUI

@main
struct CraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Craft", id: "main") {
            AppCoordinatorView(coordinator: delegate.model.coordinator)
                .frame(minWidth: 760, minHeight: 480)
                .environment(\.documentFont, delegate.model.shell.font(.diff))
                .overlay(alignment: .topTrailing) {
                    ActivityToastView(notifications: delegate.model.shell.notifications)
                        .padding(.top, 6).padding(.trailing, 20)
                }
                .modifier(SettingsWindowOpener(model: delegate.model))
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1000, height: 680)
        .defaultPosition(.center)
        .commands {
            CraftCommands(model: delegate.model, perform: delegate.perform,
                            canCheckForUpdates: delegate.canCheckForUpdates)
        }

        // Settings is its own window; SwiftUI supplies the Settings… menu item and ⌘, for it.
        Settings {
            SettingsWindowView(coordinator: delegate.model.coordinator)
                .environment(\.documentFont, delegate.model.shell.font(.diff))
        }
        .windowResizability(.contentMinSize)
    }
}

/// Hands the environment's `openSettings` to the app model, for opens that do not start in a
/// view: the sidebar gear's command, and the workflow hooks' jump to CLIs.
private struct SettingsWindowOpener: ViewModifier {
    let model: AppViewModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { model.openSettingsWindow = { openSettings() } }
    }
}
