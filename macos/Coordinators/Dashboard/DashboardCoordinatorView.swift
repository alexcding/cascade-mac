import SwiftUI

/// Hosts the dashboard and owns its toolbar: the page title and the usage agent picker.
struct DashboardCoordinatorView: View {
    @Bindable var coordinator: DashboardCoordinator

    var body: some View {
        coordinator.root.view()
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                PageTitleToolbarItem(title: "Overview")
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                ToolbarItem(placement: .primaryAction) { usageAgentPicker }
            }
    }

    /// Usage agent: a plain native segmented control.
    private var usageAgentPicker: some View {
        Picker("Usage agent", selection: Binding(get: { coordinator.shell.usageAgent }, set: coordinator.shell.setUsageAgent)) {
            Text("Claude").tag("claude")
            Text("Codex").tag("codex")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Usage agent")
        .accessibilityIdentifier("dashboard-agent")
    }
}
