import SwiftUI

struct WorkflowRunView: View {
    @Bindable var model: WorkflowRunViewModel
    let openHookSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Workflow", selection: $model.selectedID) {
                    ForEach(model.recipes, id: \.id) { Text($0.name.isEmpty ? "Untitled workflow" : $0.name).tag($0.id) }
                }.frame(maxWidth: 280).disabled(model.running)
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Stop Workflow", systemImage: "stop.fill") { Task { await model.stop() } }.disabled(model.stopping)
                } else {
                    Button("Run Workflow", systemImage: "play.fill") { Task { await model.run() } }.disabled(!model.canRun)
                }
                Text(model.status).font(.caption).lineLimit(2)
                Spacer()
            }
            if let analysis = model.analysis, !analysis.summary.isEmpty { Text(analysis.summary).font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if model.needsHooks { Button("Open CLI Settings", action: openHookSettings) }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}
