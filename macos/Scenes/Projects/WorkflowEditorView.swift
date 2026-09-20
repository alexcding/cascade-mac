import SwiftUI

struct WorkflowEditorView: View {
    let model: WorkflowEditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project workflows").font(.headline)
                Spacer()
                Button("New Workflow", action: model.add).disabled(!model.canAdd)
            }
            Text("Save ordered commands for Claude or Codex. A Stop hook signals when each step finishes; its goal guides the completion check.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.draft.isEmpty { Text("No workflows configured.").foregroundStyle(.secondary).padding(.vertical) }
                    ForEach(model.draft) { recipe in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    TextField("Workflow name", text: Binding(get: { recipe.name }, set: { model.setName(recipe.id, $0) }))
                                        .accessibilityIdentifier("workflow-name")
                                    Button("Delete Workflow", systemImage: "trash", role: .destructive) { model.remove(recipe.id) }.labelStyle(.iconOnly)
                                }
                                Picker("Run with", selection: Binding(get: { recipe.cli }, set: { model.setCLI(recipe.id, $0) })) {
                                    ForEach(WorkflowCLI.allCases) { Text($0.title).tag($0) }
                                }.accessibilityIdentifier("workflow-cli")
                                ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Step \(index + 1)").font(.subheadline.bold())
                                            Spacer()
                                            Button("Move Step Up", systemImage: "arrow.up") { model.moveStep(recipe.id, step: step.id, direction: -1) }.disabled(index == 0)
                                            Button("Move Step Down", systemImage: "arrow.down") { model.moveStep(recipe.id, step: step.id, direction: 1) }.disabled(index == recipe.steps.count - 1)
                                            Button("Remove Step", systemImage: "minus.circle") { model.removeStep(recipe.id, step: step.id) }
                                        }.labelStyle(.iconOnly)
                                        TextField("Step goal", text: Binding(get: { step.value.title }, set: { model.setStep(recipe.id, step: step.id, title: $0) }))
                                            .accessibilityIdentifier("workflow-step-goal")
                                        TextField("Step command", text: Binding(get: { step.value.command }, set: { model.setStep(recipe.id, step: step.id, command: $0) }), axis: .vertical)
                                            .font(.system(.body, design: .monospaced)).lineLimit(1...4).accessibilityIdentifier("workflow-step-command")
                                        if step.hasCommand {
                                            Text("Sample: \(model.preview(step.value.command))").font(.caption.monospaced()).textSelection(.enabled)
                                            if !step.value.title.isEmpty { Text("Goal: \(model.preview(step.value.title))").font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }.padding(.vertical, 6)
                                }
                                Button("Add Step") { model.addStep(recipe.id) }.disabled(recipe.steps.count >= 20)
                                if recipe.hasCommands {
                                    Text("Sample preparation: create or reuse \(model.sampleBranch), then launch \(recipe.cli.title).")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(8)
                        }
                    }
                }.textFieldStyle(.roundedBorder).disabled(model.busy)
            }
            Text("Placeholders: {url}, {key}, {pr}, {branch}, {repo}, {worktree}, {workspace}. Unresolved values stay literal in this sample. Blank commands are omitted when saving.")
                .font(.caption).foregroundStyle(.secondary)
            if model.changedElsewhere { Text("Workflows changed elsewhere. Revert to load them, or save to replace them with your draft.").foregroundStyle(.orange) }
            if let message = model.validationError { Text(message).foregroundStyle(.orange) }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if model.saved && !model.dirty { Text("Workflows saved").foregroundStyle(.secondary) }
                Spacer()
                Button("Revert Workflows", action: model.revert).disabled((!model.dirty && !model.changedElsewhere) || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save Workflows") { Task { await model.save() } }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }
    }
}
