import SwiftUI

/// One pipeline as a chain of node cards: When → Only if → Then.
struct AutomationEditorView: View {
    @Bindable var model: AutomationViewModel
    @State private var showDryRun = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.panel {
            case .editor:
                ScrollView {
                    if let catalog = model.catalog, let draft = model.draft {
                        AutomationChain(model: model, catalog: catalog, draft: draft)
                            .padding(20)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ProgressView().padding(40)
                    }
                }
                Divider()
                footer
            case .runs:
                AutomationRunsView(model: model)
            }
        }
        .sheet(isPresented: $showDryRun) { AutomationDryRunSheet(model: model) }
        .confirmationDialog("Delete this automation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("Its run history is kept in Activity.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                .textFieldStyle(.plain).font(.title3)
                .accessibilityIdentifier("automation-name")
            Spacer()
            Picker("Mode", selection: Binding(
                get: { model.draft?.mode ?? .off },
                set: { mode in Task { await model.setMode(mode) } })) {
                ForEach(Automation.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Off: never runs. Shadow: runs on real events but only records what it would do. Live: acts.")
            .accessibilityIdentifier("automation-mode")
            Picker("View", selection: $model.panel) {
                ForEach(AutomationViewModel.Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(model.isNew)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.error {
                Text(error).foregroundStyle(Theme.warn).textSelection(.enabled).lineLimit(2)
            } else if model.saved && !model.dirty {
                Text("Saved").foregroundStyle(Theme.textSecondary)
            } else if model.isNew {
                Text("Not saved yet").foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Delete…", role: .destructive) { confirmDelete = true }
                .disabled(model.saving)
            Button("Revert", action: model.revert).disabled(!model.dirty || model.saving)
            Button("Dry Run…") { showDryRun = true; model.loadSamples() }
                .disabled(model.draft?.trigger.types.isEmpty != false)
                .accessibilityIdentifier("automation-dry-run")
            if model.saving { ProgressView().controlSize(.small) }
            Button("Save") { Task { await model.save() } }
                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
                .accessibilityIdentifier("automation-save")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

private struct AutomationChain: View {
    let model: AutomationViewModel
    let catalog: AutomationCatalog
    let draft: Automation

    private var filters: [AutomationStep] { draft.steps.filter { $0.kind == .filter } }
    private var actions: [AutomationStep] { draft.steps.filter { $0.kind == .action } }
    private var jiraTrigger: Bool { draft.trigger.types.contains { $0.hasPrefix("jira.") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChainSection(title: "When", detail: "Any of these starts a run.") {
                TriggerCard(model: model, catalog: catalog, draft: draft, jira: jiraTrigger)
            }
            ChainConnector()
            ChainSection(title: "Only if", detail: filters.isEmpty ? "No filters: every event continues." : "Every filter must pass, top to bottom.") {
                ForEach(filters) { step in
                    StepCard(model: model, step: step, node: catalog.filter(step.type), tint: Theme.warn)
                }
                AddNodeMenu(title: "Add Filter", nodes: catalog.filters) { model.addStep(.filter, type: $0) }
                    .accessibilityIdentifier("automation-add-filter")
            }
            ChainConnector()
            ChainSection(title: "Then", detail: actions.isEmpty ? "Add at least one action." : "Actions run in order; an error stops the rest.") {
                ForEach(actions) { step in
                    StepCard(model: model, step: step, node: catalog.action(step.type), tint: Theme.success)
                }
                AddNodeMenu(title: "Add Action", nodes: catalog.actions) { model.addStep(.action, type: $0) }
                    .accessibilityIdentifier("automation-add-action")
            }
            if !catalog.variables.isEmpty {
                Text("Text fields accept \(catalog.variables.map { "{{\($0)}}" }.joined(separator: " ")).")
                    .font(.caption).foregroundStyle(Theme.textTertiary).padding(.top, 16)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ChainSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            content()
        }
    }
}

/// The line that joins one section's cards to the next.
private struct ChainConnector: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 2, height: 22).padding(.leading, 18).padding(.vertical, 4)
    }
}

private struct NodeCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surfaceHover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
    }
}

private struct TriggerCard: View {
    let model: AutomationViewModel
    let catalog: AutomationCatalog
    let draft: Automation
    let jira: Bool

    private var selected: [AutomationCatalog.Node] { draft.trigger.types.compactMap(catalog.trigger) }
    /// Params of the selected triggers, each key once (the two Jira triggers share one JQL).
    private var params: [AutomationCatalog.Param] {
        var seen = Set<String>()
        return selected.flatMap(\.params).filter { seen.insert($0.key).inserted }
    }

    var body: some View {
        NodeCard(tint: Theme.accent) {
            if selected.isEmpty {
                Text("Choose what starts this automation.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(selected) { node in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.label).fontWeight(.medium)
                        Text(node.summary).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button { model.toggleTrigger(node.type) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Remove trigger")
                }
            }
            ForEach(params) { param in
                ParamField(param: param, value: draft.trigger.params[param.key]) { model.setTriggerParam(param.key, $0) }
            }
            HStack {
                Menu("Add Trigger") {
                    ForEach(AutomationCatalog.grouped(catalog.triggers), id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.nodes) { node in
                                Toggle(node.label, isOn: Binding(get: { draft.trigger.types.contains(node.type) },
                                                                 set: { _ in model.toggleTrigger(node.type) }))
                            }
                        }
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("automation-add-trigger")
                Spacer()
            }
            if !jira { ProjectScope(model: model, draft: draft) }
        }
    }
}

private struct ProjectScope: View {
    let model: AutomationViewModel
    let draft: Automation
    private var all: Bool { draft.trigger.projects.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("All projects", isOn: Binding(get: { all }, set: { model.setAllProjects($0) }))
            if !all {
                ForEach(model.projects.filter(\.hasGitHub)) { project in
                    Toggle(project.name, isOn: Binding(get: { draft.trigger.projects.contains(project.id) },
                                                       set: { _ in model.toggleProject(project.id) }))
                        .padding(.leading, 18)
                }
                if model.projects.allSatisfy({ !$0.hasGitHub }) {
                    Text("No project has a GitHub repository yet.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

private struct StepCard: View {
    let model: AutomationViewModel
    let step: AutomationStep
    let node: AutomationCatalog.Node?
    let tint: Color

    var body: some View {
        NodeCard(tint: tint) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node?.label ?? step.type).fontWeight(.medium)
                    if let summary = node?.summary { Text(summary).font(.caption).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
                Button { model.moveStep(step.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!model.canMove(step.id, by: -1)).help("Move up")
                Button { model.moveStep(step.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!model.canMove(step.id, by: 1)).help("Move down")
                Button { model.removeStep(step.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove")
            }
            if node == nil {
                Text("This app does not know this step. It may come from a newer version.").font(.caption).foregroundStyle(Theme.warn)
            }
            ForEach(node?.params ?? []) { param in
                ParamField(param: param, value: step.params[param.key]) { model.setParam(step: step.id, key: param.key, value: $0) }
            }
            if step.kind == .action {
                Toggle("Continue if this fails", isOn: Binding(get: { step.continueOnError },
                                                              set: { model.setContinueOnError(step: step.id, $0) }))
                    .font(.caption).controlSize(.small)
                    .help("Record the failure and still run the actions after this one.")
            }
        }
    }
}

private struct AddNodeMenu: View {
    let title: String
    let nodes: [AutomationCatalog.Node]
    let add: (String) -> Void
    var body: some View {
        Menu {
            ForEach(AutomationCatalog.grouped(nodes), id: \.group) { group in
                Section(group.group) {
                    ForEach(group.nodes) { node in Button(node.label) { add(node.type) } }
                }
            }
        } label: {
            Label(title, systemImage: "plus")
        }
        .fixedSize()
    }
}

/// One param, drawn by its catalogue kind.
private struct ParamField: View {
    let param: AutomationCatalog.Param
    let value: ParamValue?
    let set: (ParamValue) -> Void

    private var text: Binding<String> {
        Binding(get: { value?.text ?? "" }, set: { set(.text($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch param.kind {
            case "bool":
                Toggle(param.label, isOn: Binding(get: { value?.flag ?? false }, set: { set(.flag($0)) }))
            case "enum":
                Picker(param.label, selection: Binding(get: { value?.text ?? param.options?.first?.value ?? "" },
                                                       set: { set(.text($0)) })) {
                    ForEach(param.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
                }
                .fixedSize()
            case "number":
                LabeledContent(param.label) {
                    TextField(param.placeholder ?? "", text: Binding(
                        get: { value?.text ?? "" },
                        set: { set(Double($0).map(ParamValue.number) ?? ($0.isEmpty ? .null : .text($0))) }))
                        .frame(width: 90)
                }
            case "template", "script":
                Text(param.label).font(.callout)
                TextField(param.placeholder ?? "", text: text, axis: .vertical)
                    .lineLimit(param.kind == "script" ? 3...10 : 1...5)
                    .font(param.kind == "script" ? .system(.body, design: .monospaced) : .body)
            default:
                Text(param.label).font(.callout)
                TextField(param.placeholder ?? "", text: text)
                    .font(param.kind == "jql" ? .system(.body, design: .monospaced) : .body)
            }
            if let help = param.help { Text(help).font(.caption).foregroundStyle(Theme.textSecondary) }
        }
    }
}
