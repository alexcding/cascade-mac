import SwiftUI

struct ProjectCoordinatorView: View {
    @Bindable var coordinator: ProjectCoordinator

    var body: some View {
        coordinator.root.view()
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar { PageTitleToolbarItem(title: coordinator.model.project.name) }
            .sheet(item: Binding(get: { coordinator.deletionConfirmation }, set: { value in
                if value == nil, let request = coordinator.deletionConfirmation { coordinator.cancelDeletion(id: request.id) }
            })) { request in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Delete this project?").font(.title2.weight(.semibold))
                    Text(request.name).font(.headline)
                    Text("This removes the project configuration and PR/Jira links. Sessions remain under Sessions, and workspace folders and running terminals are kept.")
                    if let error = coordinator.model.editor.deletionError(for: request) {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack {
                        Button("Cancel", role: .cancel) { coordinator.cancelDeletion(id: request.id) }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        if coordinator.deleting { ProgressView().controlSize(.small) }
                        Button("Delete Project", role: .destructive) { Task { await coordinator.confirmDeletion(id: request.id) } }
                            .disabled(!coordinator.model.editor.canDelete(request))
                    }.disabled(coordinator.deleting)
                }.padding(24).frame(width: 480)
                    .interactiveDismissDisabled(coordinator.deleting)
            }
            .onDisappear(perform: coordinator.endPresentation)
    }
}
