import Foundation
import Observation
import SwiftUI

@MainActor protocol BuildTerminal: AnyObject {
    func waitUntilReady() async throws
    func atShell() async throws -> Bool
    func foregroundProcess() async throws -> (atShell: Bool, process: String, subshell: Bool?)
    func submit(_ line: String) async throws
    func interrupt() async throws
    func close()
}
extension BuildTerminal {
    /// The foreground group's leader, empty when unknown. A terminal that cannot tell reports
    /// a build for as long as it is away from its shell.
    func foregroundProcess() async throws -> (atShell: Bool, process: String, subshell: Bool?) { (try await atShell(), "", nil) }
}
extension DetachedShell: BuildTerminal {}

/// The build log popover's size. The shell is created to fit it, since that is where it is read.
enum BuildLog { static let size = CGSize(width: 420, height: 560) }

struct BuildSchemes: Decodable, Sendable {
    let target: String; let schemes: [String]
    /// The scheme to show: the wanted one if it exists, else the one named after the
    /// target or the project, else the first.
    func resolve(_ wanted: String, project: Project) -> String {
        if schemes.contains(wanted) { return wanted }
        let targetName = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
        return schemes.first { $0.caseInsensitiveCompare(targetName) == .orderedSame }
            ?? schemes.first { $0.caseInsensitiveCompare(project.name) == .orderedSame }
            ?? schemes.first ?? ""
    }
}
/// A run destination the chosen scheme accepts: this Mac, a connected device or a
/// simulator. The name predates the first two.
struct BuildSimulator: Decodable, Sendable, Identifiable {
    let udid: String
    let name: String
    let runtime: String
    var kind: String? = nil
    var id: String { udid }
    var label: String { kind == "mac" ? name : "\(name) · \(runtime)" }
}
struct BuildSettings: Decodable, Sendable {
    let appPath: String
    let bundleId: String
    let target: String
    let configuration: String
    /// `PLATFORM_NAME` for the chosen destination; it decides how the app is launched.
    var platform: String? = nil
    var executablePath: String? = nil
}

protocol BuildServing: Sendable {
    /// The schemes, and the destinations of `scheme` — or of the scheme `resolve` picks
    /// when that one does not exist.
    func destinations(project: Project, session: WorkspaceSession, scheme: String) async throws -> (BuildSchemes, [BuildSimulator])
    func settings(project: Project, session: WorkspaceSession, scheme: String, simulator: String) async throws -> BuildSettings
    /// The destination belongs to the session; `seedingProject` also makes it the
    /// default for a project that has none yet.
    func saveDestination(session: WorkspaceSession, seedingProject: Bool, scheme: String, simulator: String) async throws
}

@MainActor @Observable final class BuildWorkspaceViewModel {
    var scheme: String
    var simulator: String
    private(set) var schemes: [String] = []
    private(set) var simulators: [BuildSimulator] = []
    private(set) var loading = false
    private(set) var starting = false
    private(set) var running = false
    /// The build is over and what holds the terminal is the app it launched. Still `running`,
    /// so Stop reaches it; only the spinner ends.
    private(set) var launched = false
    private(set) var error: String?
    private let service: any BuildServing
    private var project: Project
    private let session: WorkspaceSession
    private let terminalFactory: () throws -> any BuildTerminal
    @ObservationIgnored private var terminal: (any BuildTerminal)?
    @ObservationIgnored private var monitor: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    private var monitorGeneration = UUID()
    private var loadGeneration = UUID()
    private var presentationID: UUID?
    private var valid = true

    init(service: any BuildServing, project: Project, session: WorkspaceSession,
         terminalFactory: @escaping () throws -> any BuildTerminal) {
        self.service = service; self.project = project; self.session = session
        self.terminalFactory = terminalFactory
        let own = (session.runScheme ?? "", session.runSim ?? "")
        let owns = !own.0.isEmpty && !own.1.isEmpty
        let saved = owns ? own : (project.runScheme ?? "", project.runSim ?? "")
        self.saved = saved; ownsDestination = owns
        scheme = saved.0; simulator = saved.1
    }
    /// What Run uses without asking: this session's choice, else the project's default.
    private var saved: (scheme: String, simulator: String)
    /// Once a session has chosen, the project's default no longer moves it.
    private var ownsDestination: Bool
    var canRun: Bool { valid && !loading && !starting && !running && schemes.contains(scheme) && simulators.contains { $0.udid == simulator } }
    /// The project already names a destination, so Run needs no sheet.
    var hasSavedDestination: Bool { !saved.scheme.isEmpty && !saved.simulator.isEmpty }
    /// The saved pair is trusted until the lists say otherwise; xcodebuild rejects a stale one.
    private var canRunSaved: Bool {
        guard hasSavedDestination, scheme == saved.scheme, simulator == saved.simulator else { return false }
        return schemes.isEmpty || simulators.isEmpty ? valid && !loading && !starting && !running : canRun
    }
    func adopt(_ project: Project) {
        self.project = project
        guard !ownsDestination, presentationID == nil, !starting, !running else { return }
        if let scheme = project.runScheme, !scheme.isEmpty { self.scheme = scheme; saved.scheme = scheme }
        if let simulator = project.runSim, !simulator.isEmpty { self.simulator = simulator; saved.simulator = simulator }
    }
    private func saveDestination(scheme: String, simulator: String) async throws {
        try await service.saveDestination(session: session, seedingProject: (project.runScheme ?? "").isEmpty || (project.runSim ?? "").isEmpty,
            scheme: scheme, simulator: simulator)
        saved = (scheme, simulator); ownsDestination = true
    }
    fileprivate func beginPresentation(_ id: UUID) -> Bool {
        guard valid, !starting else { return false }
        presentationID = id; loadGeneration = UUID(); loading = false; error = nil
        return true
    }
    fileprivate func endPresentation(_ id: UUID) {
        guard presentationID == id else { return }
        presentationID = nil; loadGeneration = UUID(); loading = false
    }
    fileprivate func isCurrent(_ id: UUID) -> Bool { valid && presentationID == id }
    /// Destinations differ by scheme, so the cache is per project and scheme.
    static var cachedDestinations: [String: (BuildSchemes, [BuildSimulator])] = [:]
    private func cacheKey(_ scheme: String) -> String { "\(project.id)\n\(scheme)" }
    /// Also how a scheme change reloads: a newer load supersedes the one in flight.
    fileprivate func load(presentation id: UUID) async {
        guard isCurrent(id), !Task.isCancelled, !starting else { return }
        let wanted = scheme, cached = Self.cachedDestinations[cacheKey(wanted)]
        // Another scheme's destinations must not stay selectable while this one loads.
        if let cached { apply(cached) } else { simulators = [] }
        let generation = UUID(); loadGeneration = generation
        // A failed direct run hands its error to the sheet, so loading keeps that one and
        // clears only what an earlier load left behind.
        if loadFailed { error = nil; loadFailed = false }
        loading = cached == nil
        defer { if loadGeneration == generation { loading = false } }
        do {
            let values = try await service.destinations(project: project, session: session, scheme: wanted)
            try Task.checkCancellation()
            guard isCurrent(id), loadGeneration == generation else { return }
            // Under the asked-for scheme too, or a session with none saved never hits the cache.
            for key in [wanted, values.0.resolve(wanted, project: project)] { Self.cachedDestinations[cacheKey(key)] = values }
            apply(values)
        } catch { if isCurrent(id) && loadGeneration == generation && !Task.isCancelled { self.error = error.localizedDescription; loadFailed = true } }
    }
    private var loadFailed = false
    func warmDestinations() {
        let wanted = scheme
        guard valid, Self.cachedDestinations[cacheKey(wanted)] == nil, warming == nil else { return }
        warming = Task { [service, project, session] in
            defer { warming = nil }
            guard let values = try? await service.destinations(project: project, session: session, scheme: wanted), valid else { return }
            for key in [wanted, values.0.resolve(wanted, project: project)].map(cacheKey) where Self.cachedDestinations[key] == nil {
                Self.cachedDestinations[key] = values
            }
        }
    }
    @ObservationIgnored private var warming: Task<Void, Never>?
    private func apply(_ values: (BuildSchemes, [BuildSimulator])) {
        schemes = values.0.schemes; simulators = values.1
        if !schemes.contains(scheme) { scheme = values.0.resolve(scheme, project: project) }
        if !simulators.contains(where: { $0.udid == simulator }) { simulator = simulators.first?.udid ?? "" }
    }
    /// Only for a daemon too old to say whether the leader is a subshell.
    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]
    fileprivate func run(presentation id: UUID, direct: Bool = false) async -> Bool {
        if direct, schemes.isEmpty, let cached = Self.cachedDestinations[cacheKey(scheme)] { apply(cached) }
        guard isCurrent(id), direct ? canRunSaved : canRun, !Task.isCancelled else { return false }
        let scheme = scheme, simulator = simulator
        starting = true; error = nil
        defer { starting = false }
        do {
            let settings = try await service.settings(project: project, session: session, scheme: scheme, simulator: simulator)
            try Task.checkCancellation()
            guard isCurrent(id), self.scheme == scheme, self.simulator == simulator else { return false }
            let command = try settings.command(scheme: scheme, simulator: simulator)
            if !direct { try await saveDestination(scheme: scheme, simulator: simulator) }
            try Task.checkCancellation()
            guard isCurrent(id) else { return false }
            let terminal = try terminalFactory()
            self.terminal = terminal
            try await terminal.waitUntilReady()
            try await Task.sleep(for: .seconds(1))
            guard isCurrent(id) else { return false }
            let atShell = try await terminal.atShell()
            try Task.checkCancellation()
            guard isCurrent(id) else { return false }
            if atShell { try await terminal.submit(command) }
            guard isCurrent(id) else { return false }
            // A detached build already running is adopted without injecting a
            // second command. Only this build PTY is polled or interrupted.
            running = true; launched = false
            let generation = UUID(); monitorGeneration = generation
            monitor = Task { [weak self, weak terminal] in
                while !Task.isCancelled && self?.monitorGeneration == generation {
                    do {
                        try await Task.sleep(for: .milliseconds(1200))
                        guard self?.monitorGeneration == generation, let terminal else { break }
                        let foreground = try await terminal.foregroundProcess()
                        if foreground.atShell { break }
                        // Until the launch is exec'd the leader is the subshell running the chain.
                        if self?.monitorGeneration == generation, !foreground.process.isEmpty {
                            self?.launched = !(foreground.subshell ?? Self.shells.contains(foreground.process))
                        }
                    } catch {
                        if !Task.isCancelled && self?.monitorGeneration == generation { self?.error = error.localizedDescription }
                        break
                    }
                }
                if self?.monitorGeneration == generation { self?.running = false; self?.launched = false }
            }
            return true
        } catch { if isCurrent(id) && !Task.isCancelled { self.error = error.localizedDescription } }
        return false
    }
    fileprivate func save(presentation id: UUID) async -> Bool {
        guard isCurrent(id), canRun, !Task.isCancelled else { return false }
        let scheme = scheme, simulator = simulator
        starting = true; error = nil
        defer { starting = false }
        do {
            try await saveDestination(scheme: scheme, simulator: simulator)
            try Task.checkCancellation()
            return isCurrent(id)
        } catch { if isCurrent(id) && !Task.isCancelled { self.error = error.localizedDescription } }
        return false
    }
    func stop() async {
        guard valid, running else { return }
        do { try await terminal?.interrupt() }
        catch { if valid { self.error = error.localizedDescription } }
    }
    func disconnect() {
        valid = false; presentationID = nil; loadGeneration = UUID(); monitorGeneration = UUID()
        monitor = nil; terminal?.close(); terminal = nil; running = false; launched = false; loading = false
    }
}

/// One model per sheet; retiring it leaves the cached build and its PTY running.
@MainActor @Observable final class BuildDestinationViewModel {
    enum Action { case started, saved }
    enum Purpose { case run, configure }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let purpose: Purpose
    private let runtime: BuildWorkspaceViewModel
    private let id = UUID()
    private(set) var retired = false

    init(runtime: BuildWorkspaceViewModel, purpose: Purpose = .run) {
        self.runtime = runtime; self.purpose = purpose
        retired = !runtime.beginPresentation(id)
    }
    private var active: Bool { !retired && runtime.isCurrent(id) }
    var scheme: String {
        get { runtime.scheme }
        set {
            guard active, !runtime.starting, newValue != runtime.scheme else { return }
            runtime.scheme = newValue
            // Another scheme runs on other destinations.
            Task { await load() }
        }
    }
    var simulator: String {
        get { runtime.simulator }
        set { if active && !runtime.starting { runtime.simulator = newValue } }
    }
    var schemes: [String] { runtime.schemes }
    var simulators: [BuildSimulator] { runtime.simulators }
    var loading: Bool { active && runtime.loading }
    var starting: Bool { active && runtime.starting }
    var error: String? { runtime.error }
    var canRun: Bool { active && runtime.canRun }
    func load() async { if active { await runtime.load(presentation: id) } }
    /// Still the runtime's presentation, so it may go on screen.
    var presentable: Bool { active }
    func run() async { await run(direct: false) }
    /// Runs the session's saved destination without a sheet; false means the sheet is needed.
    func runSaved() async -> Bool { await run(direct: true) }
    @discardableResult private func run(direct: Bool) async -> Bool {
        guard active, await runtime.run(presentation: id, direct: direct), active else { return false }
        let action = onAction
        retire()
        action(.started)
        return true
    }
    func save() async {
        guard active, await runtime.save(presentation: id), active else { return }
        let action = onAction
        retire()
        action(.saved)
    }
    func confirm() async { if purpose == .run { await run() } else { await save() } }
    func retire() {
        retired = true; onAction = { _ in }
        runtime.endPresentation(id)
    }
}

struct BuildDestinationView: View {
    @Bindable var model: BuildDestinationViewModel
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.purpose == .run ? "Run Destination" : "Build Destination").font(.title2.weight(.semibold))
            Picker("Scheme", selection: $model.scheme) {
                ForEach(model.schemes, id: \.self) { Text($0).tag($0) }
            }.disabled(model.starting).accessibilityIdentifier("build-scheme")
            Picker("Destination", selection: $model.simulator) {
                ForEach(model.simulators) { Text($0.label).tag($0.udid) }
            }.disabled(model.starting).accessibilityIdentifier("build-simulator")
            if model.loading { ProgressView("Loading destinations…") }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if model.starting { ProgressView().controlSize(.small) }
                Button(model.purpose == .run ? "Run" : "Save") { Task { await model.confirm() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canRun)
            }.disabled(model.starting)
        }.padding(24).frame(width: 480)
        .interactiveDismissDisabled(model.starting)
        .task { await model.load() }
    }
}
