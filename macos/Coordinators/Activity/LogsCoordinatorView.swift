import SwiftUI

/// The Settings window's Activity section: the log list plus its Clear confirmation.
struct LogsCoordinatorView: View {
    @Bindable var coordinator: LogsCoordinator
    var body: some View {
        coordinator.root.view()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(item: Binding(get: { coordinator.confirmation }, set: { value in
                if value == nil, let request = coordinator.confirmation { coordinator.cancel(id: request.id) }
            })) { request in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Clear \(request.label)?").font(.title2.weight(.semibold))
                    Text("This deletes every entry in this category, including entries hidden by search or Errors only.")
                    if let error = coordinator.model.clearFailure(for: request) {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack {
                        Button("Cancel", role: .cancel) { coordinator.cancel(id: request.id) }.keyboardShortcut(.cancelAction)
                        Spacer()
                        if coordinator.model.clearing { ProgressView().controlSize(.small) }
                        Button("Clear Logs", role: .destructive) { Task { await coordinator.confirm(id: request.id) } }
                            .disabled(!coordinator.model.canClear(request))
                    }.disabled(coordinator.model.clearing)
                }.padding(24).frame(width: 460).interactiveDismissDisabled(coordinator.model.clearing)
            }
            .onDisappear(perform: coordinator.endPresentation)
    }
}
