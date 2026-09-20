import SwiftUI

/// The Settings window's content. It reports the window coming and going to the app coordinator,
/// which is what the settings model's activity and `canPresent` follow.
struct SettingsWindowView: View {
    let coordinator: AppCoordinator
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Group {
            if let settings = coordinator.settingsCoordinator {
                SettingsView(model: settings.model, shell: settings.shell,
                             activity: { coordinator.logsCoordinator.map { AnyView(LogsCoordinatorView(coordinator: $0)) } })
            } else {
                ContentUnavailableView("Settings", systemImage: "gearshape", description: Text("Connect to load settings."))
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 720)
        .onAppear { coordinator.setSettingsPresented(true) }
        .onDisappear { coordinator.setSettingsPresented(false) }
        .onChange(of: activeState, initial: true) { _, state in coordinator.settingsFocused = state == .key }
    }
}
