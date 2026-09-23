import Foundation
import Observation

/// The Automation screen: every pipeline across projects, one open in the editor as a draft,
/// with dry runs against a synced PR or ticket and the pipeline's run history.
@MainActor @Observable final class AutomationViewModel {
    enum Action: Equatable {
        case saved(Automation)
        case deleted(String)
    }
    enum Panel: String, CaseIterable, Identifiable {
        case editor = "Pipeline", runs = "Runs"
        var id: String { rawValue }
    }
    struct ProjectOption: Equatable, Identifiable {
        let id: String
        let name: String
        let hasGitHub: Bool
        let hasJira: Bool
    }

    private(set) var automations: [Automation] = []
    private(set) var catalog: AutomationCatalog?
    private(set) var projects: [ProjectOption] = []
    private(set) var settings: AutomationSettings?
    /// The pipeline in the editor. A new one has an empty id until its first save.
    var draft: Automation? {
        didSet { if draft != oldValue { saved = false; if draft?.trigger != oldValue?.trigger { invalidateSamples() } } }
    }
    private(set) var baseline: Automation?
    /// Which list row the editor shows: a saved pipeline's id, or a `new:` key for one not yet saved.
    private(set) var openKey: String?
    /// Unsaved work on the rows not open right now, by row key: edits to saved pipelines and every
    /// new one. Moving to another row keeps it here, so nothing typed is lost by looking elsewhere.
    private(set) var unsaved: [String: Automation] = [:]
    /// New pipelines in the order they were started; the list shows them after the saved ones.
    private(set) var newKeys: [String] = []
    private(set) var loading = false
    private(set) var saving = false
    private(set) var saved = false
    private(set) var error: String?
    var panel = Panel.editor { didSet { if panel == .runs, oldValue != .runs { loadRuns() } } }

    private(set) var samples: [AutomationSample] = []
    private(set) var samplesLoading = false
    private(set) var samplesError: String?
    var sample: AutomationSample?
    /// Which trigger the dry run pretends fired, for a pipeline with several.
    var sampleEvent: String?
    private(set) var trace: AutomationTrace?
    private(set) var dryRunning = false
    private(set) var dryRunError: String?

    private(set) var runs: [AutomationTrace] = []
    private(set) var runsLoading = false
    private(set) var retired = false

    @ObservationIgnored private var service: (any AutomationService)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var sampleGeneration = UUID()
    @ObservationIgnored private var runGeneration = UUID()
    @ObservationIgnored private var visible = false
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }

    init(service: (any AutomationService)? = nil) { self.service = service }

    var dirty: Bool { draft != nil && draft != baseline }
    var isNew: Bool { draft?.id.isEmpty == true }
    var canSave: Bool { service != nil && draft != nil && (dirty || isNew) && !saving }
    var selectedID: String? { draft?.id.isEmpty == false ? draft?.id : nil }
    /// The new, unsaved pipelines as the list shows them, the open one as it is being typed.
    var newDrafts: [(key: String, draft: Automation)] {
        newKeys.compactMap { key in (key == openKey ? draft : unsaved[key]).map { (key, $0) } }
    }
    /// Whether a saved pipeline has edits that are not saved yet, open or set aside.
    func hasUnsavedEdits(_ id: String) -> Bool { unsaved[id] != nil || (openKey == id && dirty) }
    var sampleKind: String { draft?.trigger.types.contains { $0.hasPrefix("jira.") } == true ? "jira" : "pr" }

    // MARK: Connection and loading

    func connect(_ service: (any AutomationService)?) {
        guard !retired else { return }
        self.service = service; generation = UUID(); invalidateSamples()
        // Work for the old connection is dropped, so its in-flight flags must not outlive it.
        saving = false; loading = false; refreshing = false; refreshAgain = false
        if service != nil, visible { refresh() }
    }

    func setVisible(_ value: Bool) {
        guard !retired else { return }
        let appeared = value && !visible
        visible = value
        if appeared { refresh() }
    }

    func updateProjects(_ values: [Project]) {
        guard !retired else { return }
        let next = values.map { ProjectOption(id: $0.id, name: $0.name, hasGitHub: !$0.repo.isEmpty,
                                              hasJira: !($0.jiraProjectKey ?? "").isEmpty) }
        if next != projects { projects = next }
    }

    /// Reload the list, catalogue and settings. The open draft is kept; its saved copy updates.
    func refresh() {
        guard !retired, let service else { return }
        // Runs finish in bursts on a busy repo: one refresh in flight, at most one queued.
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let token = generation
        loading = automations.isEmpty
        Task { [weak self] in
            defer {
                if let self, self.generation == token {
                    self.refreshing = false
                    if self.refreshAgain { self.refreshAgain = false; self.refresh() }
                }
            }
            do {
                async let list = service.list()
                async let settings = service.settings()
                let needsCatalog = self?.catalog == nil
                let catalog = needsCatalog ? try await service.catalog() : nil
                let (items, current) = try await (list, settings)
                guard let self, !self.retired, self.generation == token else { return }
                if let catalog { self.catalog = catalog }
                self.automations = items; self.settings = current; self.loading = false; self.error = nil
                self.reconcileDraft()
                if self.panel == .runs { self.loadRuns() }
            } catch {
                guard let self, !self.retired, self.generation == token else { return }
                self.loading = false; self.error = error.localizedDescription
            }
        }
    }

    /// A backend `automations` event: another save, a delete, or a run finished.
    func receive(scope: String?) {
        guard !retired, visible else { return }
        refresh()
    }

    private func reconcileDraft() {
        // Edits set aside on a pipeline deleted elsewhere stay, as a new one.
        for (key, value) in unsaved where !key.hasPrefix("new:") && !automations.contains(where: { $0.id == key }) {
            unsaved[key] = nil
            var orphan = value; orphan.id = ""
            let newKey = Self.newKey(); unsaved[newKey] = orphan; newKeys.append(newKey)
        }
        guard let draft, !draft.id.isEmpty else {
            if draft == nil, let first = automations.first { select(first.id) }
            return
        }
        guard let stored = automations.first(where: { $0.id == draft.id }) else {
            // Deleted elsewhere: an untouched draft goes with it, an edited one stays as new.
            if dirty {
                self.draft?.id = ""; baseline = nil
                let key = Self.newKey(); openKey = key; newKeys.append(key)
            } else {
                self.draft = nil; baseline = nil; openKey = nil
                if let first = automations.first { select(first.id) }
            }
            return
        }
        let edited = dirty
        baseline = stored
        if !edited { self.draft = stored }
    }

    // MARK: Selection

    /// Open a row: a saved pipeline by id, or a new one by its `new:` key. Whatever was open and
    /// unsaved is set aside first and comes back when its row is chosen again.
    func select(_ key: String) {
        guard !retired, key != openKey || draft == nil else { return }
        if key.hasPrefix("new:") {
            guard let value = unsaved[key] else { return }
            setAside()
            unsaved[key] = nil
            open(value, baseline: nil, key: key)
            panel = .editor
            return
        }
        guard let item = automations.first(where: { $0.id == key }) else { return }
        setAside()
        open(unsaved.removeValue(forKey: key) ?? item, baseline: item, key: key)
        if panel == .runs { loadRuns() }
    }

    func create(from template: AutomationCatalog.Template? = nil) {
        guard !retired else { return }
        var automation = template?.automation ?? Automation(name: "New automation", trigger: .init(types: ["pr.opened"]))
        automation.id = ""; automation.mode = .off
        setAside()
        let key = Self.newKey()
        newKeys.append(key)
        open(automation, baseline: nil, key: key)
        panel = .editor
    }

    /// Back to the saved copy; a new pipeline is discarded, and the next row opens.
    func revert() {
        guard !retired, !saving else { return }
        error = nil
        if let baseline { draft = baseline; return }
        discardOpenDraft()
    }

    private func open(_ value: Automation, baseline: Automation?, key: String) {
        draft = value; self.baseline = baseline; openKey = key
        error = nil; trace = nil; dryRunError = nil; saved = false; runs = []
    }

    /// Keep the open row's unsaved work: a new pipeline always, a saved one only if edited.
    private func setAside() {
        guard let key = openKey, let draft else { return }
        if baseline == nil || draft != baseline { unsaved[key] = draft } else { unsaved[key] = nil }
    }

    /// Drop the open new pipeline and open whichever row is left: another new one, else the first saved.
    private func discardOpenDraft() {
        if let key = openKey { newKeys.removeAll { $0 == key }; unsaved[key] = nil }
        draft = nil; baseline = nil; openKey = nil
        if let first = automations.first { select(first.id) }
        else if let key = newKeys.last { select(key) }
    }

    private static func newKey() -> String { "new:\(UUID().uuidString)" }

    // MARK: Editing

    func toggleTrigger(_ type: String) {
        guard !retired, var value = draft else { return }
        if let index = value.trigger.types.firstIndex(of: type) {
            value.trigger.types.remove(at: index)
        } else {
            // PR and Jira triggers deliver different subjects; one pipeline listens to one kind.
            let jira = type.hasPrefix("jira.")
            value.trigger.types.removeAll { $0.hasPrefix("jira.") != jira || $0 == "manual" || type == "manual" }
            value.trigger.types.append(type)
            for param in catalog?.trigger(type)?.params ?? [] where value.trigger.params[param.key] == nil {
                if let fallback = param.default { value.trigger.params[param.key] = fallback }
            }
        }
        draft = value
    }

    func setTriggerParam(_ key: String, _ value: ParamValue) {
        guard !retired else { return }
        draft?.trigger.params[key] = value
    }

    func setAllProjects(_ all: Bool) {
        guard !retired else { return }
        draft?.trigger.projects = all ? [] : projects.filter(\.hasGitHub).prefix(1).map(\.id)
    }

    func toggleProject(_ id: String) {
        guard !retired, var value = draft else { return }
        if let index = value.trigger.projects.firstIndex(of: id) {
            value.trigger.projects.remove(at: index)
        } else {
            value.trigger.projects.append(id)
        }
        draft = value
    }

    func addStep(_ kind: AutomationStep.Kind, type: String) {
        guard !retired, let catalog else { return }
        let step = catalog.step(kind: kind, type: type)
        guard var value = draft else { return }
        // Filters run before actions: a new filter lands after the last filter.
        if kind == .filter, let index = value.steps.lastIndex(where: { $0.kind == .filter }) {
            value.steps.insert(step, at: index + 1)
        } else if kind == .filter {
            value.steps.insert(step, at: 0)
        } else {
            value.steps.append(step)
        }
        draft = value
    }

    func removeStep(_ id: String) {
        guard !retired else { return }
        draft?.steps.removeAll { $0.id == id }
    }

    /// Move a step up or down within its own section.
    func moveStep(_ id: String, by offset: Int) {
        guard !retired, var value = draft, let index = value.steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard value.steps.indices.contains(target), value.steps[target].kind == value.steps[index].kind else { return }
        value.steps.swapAt(index, target)
        draft = value
    }

    func canMove(_ id: String, by offset: Int) -> Bool {
        guard let steps = draft?.steps, let index = steps.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        return steps.indices.contains(target) && steps[target].kind == steps[index].kind
    }

    func setParam(step id: String, key: String, value: ParamValue) {
        guard !retired, let index = draft?.steps.firstIndex(where: { $0.id == id }) else { return }
        draft?.steps[index].params[key] = value
    }

    func setContinueOnError(step id: String, _ value: Bool) {
        guard !retired, let index = draft?.steps.firstIndex(where: { $0.id == id }) else { return }
        draft?.steps[index].continueOnError = value
    }

    // MARK: Saving

    func save() async {
        guard !retired, canSave, let service, var value = draft else { return }
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = generation
        saving = true; error = nil
        defer { if generation == token { saving = false } }
        do {
            let stored = try await service.save(value)
            guard !retired, generation == token else { return }
            if let index = automations.firstIndex(where: { $0.id == stored.id }) { automations[index] = stored }
            else { automations.append(stored) }
            if let key = openKey, key.hasPrefix("new:") { newKeys.removeAll { $0 == key } }
            draft = stored; baseline = stored; openKey = stored.id; saved = true
            onAction(.saved(stored))
        } catch {
            if !retired, generation == token { self.error = error.localizedDescription }
        }
    }

    /// Switch the mode and save straight away: the list's toggle, not an edit to review.
    func setMode(_ mode: Automation.Mode) async {
        guard !retired, draft != nil, draft?.mode != mode else { return }
        draft?.mode = mode
        if !isNew, !dirtyBeyondMode { await save() }
    }

    private var dirtyBeyondMode: Bool {
        guard var draft, let baseline else { return false }
        draft.mode = baseline.mode
        return draft != baseline
    }

    func delete() async {
        guard !retired, let service, let draft else { return }
        if draft.id.isEmpty { discardOpenDraft(); return }
        let token = generation
        do {
            try await service.delete(id: draft.id)
            guard !retired, generation == token else { return }
            automations.removeAll { $0.id == draft.id }
            unsaved[draft.id] = nil
            self.draft = nil; baseline = nil; openKey = nil
            if let first = automations.first { select(first.id) } else if let key = newKeys.last { select(key) }
            onAction(.deleted(draft.id))
        } catch {
            if !retired, generation == token { self.error = error.localizedDescription }
        }
    }

    // MARK: Settings

    func setPaused(_ paused: Bool) async { await updateSettings(paused: paused, forward: nil) }

    private func updateSettings(paused: Bool?, forward: Bool?) async {
        guard !retired, let service else { return }
        let token = generation
        do {
            let value = try await service.updateSettings(paused: paused, forwardWebhooks: forward)
            if !retired, generation == token { settings = value }
        } catch {
            if !retired, generation == token { self.error = error.localizedDescription }
        }
    }

    // MARK: Dry run

    private func invalidateSamples() {
        sampleGeneration = UUID(); samples = []; samplesError = nil; samplesLoading = false
        sample = nil; sampleEvent = nil
    }

    func loadSamples() {
        guard !retired, let service, let draft else { return }
        let token = UUID(), kind = sampleKind
        sampleGeneration = token; samplesLoading = true; samplesError = nil
        let jql = draft.trigger.params["jql"]?.text ?? ""
        Task { [weak self] in
            do {
                let items = try await service.samples(kind: kind, projects: draft.trigger.projects, jql: jql)
                guard let self, !self.retired, self.sampleGeneration == token else { return }
                self.samples = items; self.samplesLoading = false
                if self.sample == nil || !items.contains(where: { $0.id == self.sample?.id }) { self.sample = items.first }
            } catch {
                guard let self, !self.retired, self.sampleGeneration == token else { return }
                self.samplesLoading = false; self.samplesError = error.localizedDescription
            }
        }
    }

    func dryRun() async {
        guard !retired, let service, let draft, let sample else { return }
        let token = UUID()
        runGeneration = token; dryRunning = true; dryRunError = nil; trace = nil
        defer { if runGeneration == token { dryRunning = false } }
        do {
            let result = try await service.dryRun(draft, sample: sample, event: sampleEvent ?? draft.trigger.types.first)
            if !retired, runGeneration == token { trace = result }
        } catch {
            if !retired, runGeneration == token { dryRunError = error.localizedDescription }
        }
    }

    /// Run the saved pipeline for real on the chosen sample.
    func runNow() async {
        guard !retired, let service, let draft, !draft.id.isEmpty, !dirty, let sample else { return }
        let token = UUID()
        runGeneration = token; dryRunning = true; dryRunError = nil; trace = nil
        defer { if runGeneration == token { dryRunning = false } }
        do {
            let result = try await service.run(id: draft.id, sample: sample, event: sampleEvent ?? draft.trigger.types.first)
            if !retired, runGeneration == token { trace = result; loadRuns() }
        } catch {
            if !retired, runGeneration == token { dryRunError = error.localizedDescription }
        }
    }

    func clearTrace() { guard !retired else { return }; trace = nil; dryRunError = nil }

    // MARK: Runs

    func loadRuns() {
        guard !retired, let service, let id = selectedID else { runs = []; return }
        let token = generation
        runsLoading = runs.isEmpty
        Task { [weak self] in
            let items = (try? await service.runs(id: id)) ?? []
            guard let self, !self.retired, self.generation == token, self.selectedID == id else { return }
            self.runs = items; self.runsLoading = false
        }
    }

    // MARK: Lifetime

    func stop() async {
        generation = UUID(); sampleGeneration = UUID(); runGeneration = UUID(); service = nil
        saving = false; loading = false; dryRunning = false; samplesLoading = false
        refreshing = false; refreshAgain = false
    }

    func retire() {
        retired = true; visible = false; service = nil
        generation = UUID(); sampleGeneration = UUID(); runGeneration = UUID()
        onAction = { _ in }
    }
}
