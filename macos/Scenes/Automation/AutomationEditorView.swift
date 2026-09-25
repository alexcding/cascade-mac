import SwiftUI

/// One pipeline as a page in the Dashboard's style: the name as the page title with its mode
/// beside it, then When → Only if → Then as outlined cards joined by a rule, and a bar that
/// saves, reverts and dry-runs.
struct AutomationEditorView: View {
    @Bindable var model: AutomationViewModel
    @State private var showDryRun = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, 12).padding(.bottom, 20)
                    if !model.isNew { AutomationPanelTabs(selection: $model.panel).padding(.bottom, 32) }
                    switch model.panel {
                    case .editor:
                        if let catalog = model.catalog, let draft = model.draft {
                            AutomationChain(model: model, catalog: catalog, draft: draft)
                        } else {
                            ProgressView().padding(40)
                        }
                    case .runs:
                        AutomationRunsView(model: model)
                    }
                }
                .frame(maxWidth: Theme.Size.readableColumn, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The page inset lives inside the scroll view, so its scroller runs down the pane's edge.
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 40)
            }
            if model.panel == .editor { footer }
        }
        .sheet(isPresented: $showDryRun) { AutomationDryRunSheet(model: model) }
        .confirmationDialog("Delete this automation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("Existing Activity entries are kept.")
        }
    }

    /// The Dashboard's page header, with the name editable in the title's place.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption).font(.system(size: 13, weight: .medium)).foregroundStyle(DashboardPalette.ink3)
                    .lineLimit(1)
                TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .bold)).tracking(-0.6)
                    .accessibilityIdentifier("automation-name")
            }
            // Both the field and the spacer are flexible, and would split the room between them,
            // clipping the name at half the pane. The name gets all of it but the spacer's minimum.
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text(model.draft?.mode == .live ? String(localized: "On") : String(localized: "Off")).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.draft?.mode == .live ? Theme.success : DashboardPalette.ink3)
                Toggle(String(localized: "On"), isOn: Binding(
                    get: { model.draft?.mode == .live },
                    set: { on in Task { await model.setMode(on ? .live : .off) } }))
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.bottom, 6)
            .help("On: runs and acts on real events. Try it with Dry Run first.")
            .accessibilityIdentifier("automation-mode")
        }
    }

    private var caption: String {
        guard let draft = model.draft else { return "" }
        if model.isNew { return String(localized: "New automation · not saved") }
        let mode = draft.mode == .live ? String(localized: "On — acts on real events") : String(localized: "Off — automatic runs disabled")

        let stored = model.automations.first { $0.id == draft.id }
        return stored?.lastRun.map { "\(mode) · \(AutomationStatus.lastRun($0))" } ?? mode
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled).lineLimit(2)
            } else if model.saved && !model.dirty {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.success)
                    .accessibilityIdentifier("automation-saved")
            } else if model.isNew {
                Text("Not saved yet").font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3)
            } else if model.dirty {
                Text("Unsaved changes").font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3)
            }
            Spacer()
            Button(model.isNew ? String(localized: "Discard") : String(localized: "Delete…"), role: .destructive) {
                if model.isNew { model.revert() } else { confirmDelete = true }
            }
            .disabled(model.saving)
            if !model.isNew {
                Button("Revert", action: model.revert).disabled(!model.dirty || model.saving)
            }
            Button("Dry Run…") { showDryRun = true; model.loadSamples() }
                .disabled(model.draft?.trigger.types.isEmpty != false)
                .accessibilityIdentifier("automation-dry-run")
            if model.saving { ProgressView().controlSize(.small) }
            Button("Save") { Task { await model.save() } }
                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
                .accessibilityIdentifier("automation-save")
        }
        .controlSize(.large)
        .padding(.horizontal, 28).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(DashboardPalette.hairline).frame(height: 1) }
    }
}

/// Pipeline and Runs as the Dashboard's filter tags: outlined, the chosen one filled.
private struct AutomationPanelTabs: View {
    @Binding var selection: AutomationViewModel.Panel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AutomationViewModel.Panel.allCases) { panel in
                let active = panel == selection
                Button { selection = panel } label: {
                    Text(panel.label).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(active ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(active ? Color.primary : DashboardPalette.buttonBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("automation-panel-\(panel.id)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
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
            DashboardSectionHeader(title: String(localized: "When"), detail: String(localized: "Any of these starts a run"))
            TriggerCard(model: model, catalog: catalog, draft: draft, jira: jiraTrigger)
            ChainConnector()
            DashboardSectionHeader(title: String(localized: "Only if"), detail: filters.isEmpty ? String(localized: "No filters: every event continues") : String(localized: "Every filter must pass, top to bottom"))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(filters) { step in
                    StepCard(model: model, step: step, node: catalog.filter(step.type), glyph: "line.3.horizontal.decrease", tone: .warning)
                }
                AddNodeMenu(title: String(localized: "Add Filter"), nodes: catalog.filters) { model.addStep(.filter, type: $0) }
                    .accessibilityIdentifier("automation-add-filter")
            }
            ChainConnector()
            DashboardSectionHeader(title: String(localized: "Then"), detail: actions.isEmpty ? String(localized: "Add at least one action") : String(localized: "Runs in order. Errors stop the following actions unless configured to continue."))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions) { step in
                    StepCard(model: model, step: step, node: catalog.action(step.type), glyph: "arrow.right", tone: .success)
                }
                AddNodeMenu(title: String(localized: "Add Action"), nodes: catalog.actions) { model.addStep(.action, type: $0) }
                    .accessibilityIdentifier("automation-add-action")
            }
            if !catalog.variables.isEmpty {
                Text("Text fields accept \(catalog.variables.map { "{{\($0)}}" }.joined(separator: " "))")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, 28)
            }
        }
    }
}

/// The rule that carries one section down into the next.
private struct ChainConnector: View {
    var body: some View {
        Rectangle().fill(DashboardPalette.hairline).frame(width: 1, height: 32)
            .padding(.leading, 30).padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

/// An outlined card, like the Dashboard's tiles at a smaller radius for the denser content.
private struct NodeCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
    }
}

/// A node's name line: its glyph, label and summary, then the card's own controls far right.
private struct NodeTitle<Trailing: View>: View {
    let glyph: String
    let tone: ThemeTone
    let title: String
    let summary: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AutomationGlyph(symbol: glyph, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                if let summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// The Dashboard's outlined square icon button.
private struct AutomationIconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DashboardPalette.buttonBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DashboardPalette.ink2)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
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
        NodeCard {
            if selected.isEmpty {
                NodeTitle(glyph: "bolt.fill", tone: .accent, title: String(localized: "No trigger yet"), summary: String(localized: "Choose what starts this automation.")) { EmptyView() }
            }
            ForEach(selected) { node in
                NodeTitle(glyph: "bolt.fill", tone: .accent, title: node.localizedLabel, summary: node.localizedSummary) {
                    AutomationIconButton(symbol: "xmark", help: String(localized: "Remove trigger")) { model.toggleTrigger(node.type) }
                }
            }
            ForEach(AutomationCatalog.visible(params, values: draft.trigger.params)) { param in
                ParamField(param: param, value: draft.trigger.params[param.key]) { model.setTriggerParam(param.key, $0) }
            }
            Menu {
                ForEach(AutomationCatalog.grouped(catalog.triggers), id: \.group) { group in
                    Section(group.group) {
                        ForEach(group.nodes) { node in
                            Toggle(node.localizedLabel, isOn: Binding(get: { draft.trigger.types.contains(node.type) },
                                                             set: { _ in model.toggleTrigger(node.type) }))
                        }
                    }
                }
            } label: {
                OutlinedButtonLabel(title: String(localized: "Add Trigger"), symbol: "plus")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("automation-add-trigger")
            if !jira { ProjectScope(model: model, draft: draft) }
        }
    }
}

/// Which projects' pull requests the trigger listens to, as the Dashboard's filter tags.
private struct ProjectScope: View {
    let model: AutomationViewModel
    let draft: Automation
    private var all: Bool { draft.trigger.projects.isEmpty }
    private var projects: [AutomationViewModel.ProjectOption] { model.projects.filter(\.hasGitHub) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: String(localized: "Projects"))
            FlowRow(spacing: 8, lineSpacing: 8) {
                ScopeTag(title: String(localized: "All projects"), active: all) { model.setAllProjects(!all) }
                ForEach(projects) { project in
                    ScopeTag(title: project.name, active: !all && draft.trigger.projects.contains(project.id)) {
                        model.toggleProject(project.id)
                    }
                }
            }
            if projects.isEmpty {
                Text("No project has a GitHub repository yet.").font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
            }
        }
    }
}

private struct ScopeTag: View {
    let title: String
    let active: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(active ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.primary : DashboardPalette.buttonBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct StepCard: View {
    let model: AutomationViewModel
    let step: AutomationStep
    let node: AutomationCatalog.Node?
    let glyph: String
    let tone: ThemeTone

    var body: some View {
        NodeCard {
            NodeTitle(glyph: glyph, tone: tone, title: node?.localizedLabel ?? step.type, summary: node?.localizedSummary) {
                HStack(spacing: 6) {
                    AutomationIconButton(symbol: "chevron.up", help: String(localized: "Move up"), disabled: !model.canMove(step.id, by: -1)) {
                        model.moveStep(step.id, by: -1)
                    }
                    AutomationIconButton(symbol: "chevron.down", help: String(localized: "Move down"), disabled: !model.canMove(step.id, by: 1)) {
                        model.moveStep(step.id, by: 1)
                    }
                    AutomationIconButton(symbol: "trash", help: String(localized: "Remove")) { model.removeStep(step.id) }
                }
            }
            if node == nil {
                Text("This app does not know this step. It may come from a newer version.")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            ForEach(AutomationCatalog.visible(node?.params ?? [], values: step.params)) { param in
                ParamField(param: param, value: step.params[param.key]) { model.setParam(step: step.id, key: param.key, value: $0) }
            }
            if step.kind == .action {
                Toggle(isOn: Binding(get: { step.continueOnError }, set: { model.setContinueOnError(step: step.id, $0) })) {
                    Text("Continue if this fails").font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink2)
                }
                .toggleStyle(.switch).controlSize(.mini)
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
                    ForEach(group.nodes) { node in Button(node.localizedLabel) { add(node.type) } }
                }
            }
        } label: {
            OutlinedButtonLabel(title: title, symbol: "plus")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// The Dashboard's outlined button face, for menus that add to the chain.
private struct OutlinedButtonLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DashboardPalette.ink2)
            .padding(.horizontal, 12).frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardPalette.buttonBorder, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

private struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(DashboardPalette.ink2)
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
        VStack(alignment: .leading, spacing: 6) {
            switch param.kind {
            case "bool":
                Toggle(isOn: Binding(get: { value?.flag ?? false }, set: { set(.flag($0)) })) {
                    Text(param.localizedLabel).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink2)
                }
                .toggleStyle(.switch).controlSize(.mini)
            case "enum":
                FieldLabel(text: param.localizedLabel)
                Picker(param.localizedLabel, selection: Binding(get: { value?.text ?? param.default?.text ?? param.options?.first?.value ?? "" },
                                                       set: { set(.text($0)) })) {
                    ForEach(param.options ?? [], id: \.value) { Text($0.localizedLabel).tag($0.value) }
                }
                .labelsHidden().fixedSize()
            case "number":
                FieldLabel(text: param.localizedLabel)
                TextField(param.placeholder ?? "", text: Binding(
                    get: { value?.text ?? "" },
                    set: { set(Double($0).map(ParamValue.number) ?? ($0.isEmpty ? .null : .text($0))) }))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
            case "template", "script":
                FieldLabel(text: param.localizedLabel)
                TextField(param.placeholder ?? "", text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(param.kind == "script" ? 3...10 : 1...5)
                    .font(param.kind == "script" ? .system(size: 12, design: .monospaced) : .system(size: 13))
            default:
                FieldLabel(text: param.localizedLabel)
                TextField(param.placeholder ?? "", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(param.kind == "jql" ? .system(size: 12, design: .monospaced) : .system(size: 13))
            }
            if let help = param.localizedHelp {
                Text(help).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
