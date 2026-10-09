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
    /// What the backend calls the destination. An answer kept from before it said lists only
    /// simulators.
    var kind: Kind = .simulator
    var id: String { udid }
    var label: String { kind == .mac ? name : "\(name) · \(runtime)" }
    /// This Mac or a connected device, which the menu lists apart from the simulators: a device
    /// often shares its name with one.
    var isHardware: Bool { kind != .simulator }

    enum Kind: Decodable, Equatable, Sendable {
        case mac, device, simulator
        /// One this app does not know yet. Never taken for a simulator, which would list a
        /// destination that runs on hardware among them.
        case other(String)

        init(from decoder: any Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "mac": self = .mac
            case "device": self = .device
            case "simulator": self = .simulator
            case let other: self = .other(other)
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case udid, name, runtime, kind }
    init(udid: String, name: String, runtime: String, kind: Kind = .simulator) {
        self.udid = udid; self.name = name; self.runtime = runtime; self.kind = kind
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        udid = try values.decode(String.self, forKey: .udid)
        name = try values.decode(String.self, forKey: .name)
        runtime = try values.decode(String.self, forKey: .runtime)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .simulator
    }
}
struct BuildSettings: Decodable, Sendable {
    let appPath: String
    let bundleId: String
    let target: String
    let configuration: String
    /// `PLATFORM_NAME` for the chosen destination; it decides how the app is launched.
    var platform: String? = nil
    var executablePath: String? = nil
    /// What the scheme's Run passes the app, as Xcode would: the arguments already split into
    /// words, and the environment.
    var launchArguments: [String]? = nil
    var launchEnvironment: [String: String]? = nil
}

protocol BuildServing: Sendable {
    /// The schemes, and the destinations of `scheme` — or of the scheme `resolve` picks
    /// when that one does not exist. `refresh` asks for the destinations afresh instead of the
    /// answer the backend keeps: a device plugged in since is not in that answer.
    func destinations(project: Project, session: WorkspaceSession, scheme: String, refresh: Bool) async throws -> (BuildSchemes, [BuildSimulator])
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
    /// This Mac and connected devices, then the simulators: the menu lists them apart.
    var hardware: [BuildSimulator] { simulators.filter(\.isHardware) }
    var simulatorsOnly: [BuildSimulator] { simulators.filter { !$0.isHardware } }
    private(set) var loading = false
    /// A Run is finding its lists before it starts: the Run button shows it, and the menu waits.
    var preparing: Bool { preparingID != nil }
    private var preparingID: UUID?
    /// Selecting the session is asking for the kept lists.
    private(set) var warmingLists = false
    /// Some list has been answered, so empty lists mean the project has none.
    private(set) var listsLoaded = false
    private(set) var starting = false
    private(set) var running = false
    /// The build is over and what holds the terminal is the app it launched. Still `running`,
    /// so Stop reaches it; only the spinner ends.
    private(set) var launched = false
    private(set) var error: String? { didSet { quietError = false } }
    /// The error is a load's that nobody asked for (the menu's lists, behind the toolbar): the menu
    /// shows it, the toolbar's line is for a Run that failed.
    private(set) var quietError = false
    /// The session's Simulator panel; a run on a simulator points it at that device.
    let preview: SimulatorPreviewModel?
    /// A run on a simulator started: the workspace brings its Simulator panel forward.
    @ObservationIgnored var onSimulatorRun: (() -> Void)?
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
         preview: SimulatorPreviewModel? = nil, terminalFactory: @escaping () throws -> any BuildTerminal) {
        self.service = service; self.project = project; self.session = session; self.preview = preview
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
    /// The session or its project names a destination, so Run needs no lists to start.
    var hasSavedDestination: Bool { !saved.scheme.isEmpty && !saved.simulator.isEmpty }
    /// What is chosen is what is saved, so Run can go without the lists. Otherwise a pick is still
    /// being saved or failed to, and Run saves it, or the saved scheme is gone from the project.
    private var choosesSaved: Bool { hasSavedDestination && scheme == saved.scheme && simulator == saved.simulator }
    /// The choice is one made in the run destination menu and not saved yet, rather than one the
    /// lists put there because the saved scheme is gone.
    private var picked = false
    /// The saved pair is trusted until the lists say otherwise; xcodebuild rejects a stale one.
    private var canRunSaved: Bool {
        guard choosesSaved else { return false }
        return schemes.isEmpty || simulators.isEmpty ? valid && !loading && !starting && !running : canRun
    }
    func adopt(_ project: Project) {
        self.project = project
        guard !ownsDestination, presentationID == nil, !starting, !running else { return }
        if let scheme = project.runScheme, !scheme.isEmpty { self.scheme = scheme; saved.scheme = scheme }
        if let simulator = project.runSim, !simulator.isEmpty { self.simulator = simulator; saved.simulator = simulator }
    }
    /// Saves go one at a time, so the backend keeps the last pick, and only the newest says what is
    /// saved: two quick picks must not leave the first one as the saved pair.
    private func saveDestination(scheme: String, simulator: String) async throws {
        let previous = savingTail, generation = UUID(); saveGeneration = generation
        savesInFlight += 1
        defer { savesInFlight -= 1 }
        let seeding = (project.runScheme ?? "").isEmpty || (project.runSim ?? "").isEmpty
        let save = Task { [service, session] in
            await previous?.value
            try await service.saveDestination(session: session, seedingProject: seeding, scheme: scheme, simulator: simulator)
        }
        savingTail = Task { _ = try? await save.value }
        try await save.value
        guard saveGeneration == generation else { return }
        saved = (scheme, simulator); ownsDestination = true
        if self.scheme == scheme && self.simulator == simulator { picked = false }
    }
    @ObservationIgnored private var savingTail: Task<Void, Never>?
    @ObservationIgnored private var saveGeneration = UUID()
    @ObservationIgnored private var savesInFlight = 0
    fileprivate func beginPresentation(_ id: UUID) -> Bool {
        guard valid, !starting, !preparing else { return false }
        presentationID = id; loadGeneration = UUID(); loading = false; error = nil; loadFailed = false
        return true
    }
    fileprivate func endPresentation(_ id: UUID) {
        guard presentationID == id else { return }
        presentationID = nil; loadGeneration = UUID(); loading = false
        if preparingID == id { preparingID = nil }
    }
    fileprivate func isCurrent(_ id: UUID) -> Bool { valid && presentationID == id }
    /// Destinations differ by scheme, so the cache is per project and scheme.
    static var cachedDestinations: [String: (BuildSchemes, [BuildSimulator])] = [:]
    private func cacheKey(_ scheme: String) -> String { "\(project.id)\n\(scheme)" }
    private func load(presentation id: UUID, fresh: Bool) async { await load(fresh: fresh) { isCurrent(id) } }
    /// The schemes and destinations for the run destination menu, which is no presentation: a run
    /// in flight has one, and its load and choice come first. A fresh look too, for a device plugged
    /// in since: the menu's Refresh and a scheme picked there.
    func loadDestinations() async { await load(fresh: true) { valid && presentationID == nil } }
    /// Also how a scheme change reloads: a newer load supersedes the one in flight.
    private func load(fresh: Bool, while current: () -> Bool) async {
        guard current(), !Task.isCancelled, !starting else { return }
        let wanted = scheme, cached = Self.cachedDestinations[cacheKey(wanted)]
        // Another scheme's destinations must not stay selectable while this one loads.
        if let cached { apply(cached) } else { simulators = [] }
        let generation = UUID(); loadGeneration = generation
        // A failed run's error stays on the toolbar, so loading keeps that one and
        // clears only what an earlier load left behind.
        if loadFailed { error = nil; loadFailed = false }
        loading = cached == nil
        defer { if loadGeneration == generation { loading = false } }
        // With nothing on screen, the list the backend keeps comes first, so the menu is usable
        // at once. Then one fresh look, when asked for, since the menu is where a destination is chosen and a
        // device plugged in since is not in the kept list; it only updates what is shown.
        for refresh in (cached == nil ? [false] : []) + (fresh ? [true] : []) {
            do {
                let values = try await service.destinations(project: project, session: session, scheme: wanted, refresh: refresh)
                try Task.checkCancellation()
                guard current(), loadGeneration == generation else { return }
                // Under the asked-for scheme too, or a session with none saved never hits the cache.
                for key in [wanted, values.0.resolve(wanted, project: project)] { Self.cachedDestinations[cacheKey(key)] = values }
                // A run already on its way keeps the destination it was started with.
                if !starting { apply(values) }
                loading = false
            } catch {
                if current() && loadGeneration == generation && !Task.isCancelled {
                    self.error = error.localizedDescription; loadFailed = true; quietError = presentationID == nil
                }
                return
            }
        }
    }
    private var loadFailed = false
    /// What the backend keeps, cached for the next Run and put in the run destination menu: one
    /// request however often it is asked for (selecting the session, its toolbar), none once cached.
    func warmDestinations() {
        let wanted = scheme
        guard valid else { return }
        if let cached = Self.cachedDestinations[cacheKey(wanted)] { return showKept(cached) }
        guard warming == nil else { return }
        warmingLists = true
        warming = Task { [service, project, session] in
            defer { warming = nil; warmingLists = false }
            let values: (BuildSchemes, [BuildSimulator])
            do { values = try await service.destinations(project: project, session: session, scheme: wanted, refresh: false) }
            catch {
                // Said in the menu, which would otherwise say it is loading with nothing loading.
                if valid, presentationID == nil, schemes.isEmpty, self.error == nil {
                    self.error = error.localizedDescription; loadFailed = true; quietError = true
                }
                return
            }
            guard valid else { return }
            for key in [wanted, values.0.resolve(wanted, project: project)].map(cacheKey) where Self.cachedDestinations[key] == nil {
                Self.cachedDestinations[key] = values
            }
            showKept(values)
        }
    }
    /// Fills the menu's lists while they are empty; never under a run.
    private func showKept(_ values: (BuildSchemes, [BuildSimulator])) {
        if valid, presentationID == nil, !starting, !running, schemes.isEmpty { apply(values) }
    }
    @ObservationIgnored private var warming: Task<Void, Never>?
    private func apply(_ values: (BuildSchemes, [BuildSimulator])) {
        schemes = values.0.schemes; simulators = values.1; listsLoaded = true
        if !schemes.contains(scheme) { scheme = values.0.resolve(scheme, project: project) }
        // The saved destination stays chosen though a list lacks it: the list the backend keeps
        // predates a device plugged in since, and a later one has it again. Run says it is not
        // available rather than building elsewhere and saving that over it.
        let keepsSaved = !saved.simulator.isEmpty && scheme == saved.scheme && simulator == saved.simulator
        if !keepsSaved, !simulators.contains(where: { $0.udid == simulator }) {
            // Never a plugged-in device by default, as Xcode does not: a Run there installs on
            // someone's phone. This Mac or a simulator first, a device only when it is all.
            simulator = (simulators.first { $0.kind != .device } ?? simulators.first)?.udid ?? ""
        }
    }
    /// Only for a daemon too old to say whether the leader is a subshell.
    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]
    private func run(presentation id: UUID, direct: Bool) async -> Bool {
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
            guard isCurrent(id) else { return false }
            let atShell = try await terminal.atShell()
            try Task.checkCancellation()
            guard isCurrent(id) else { return false }
            if atShell { try await terminal.submit(command) }
            guard isCurrent(id) else { return false }
            // The same default `command` launches by: a destination with no platform is a simulator.
            // Only for a command this Run sent: an adopted build runs to whatever destination it
            // was started for, which need not be the one picked now.
            if atShell, (settings.platform ?? "iphonesimulator").hasSuffix("simulator"), let preview {
                preview.show(udid: simulator)
                onSimulatorRun?()
            }
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
    /// Run, all of it: the saved destination as it is, a pick not saved yet (still being saved, or its
    /// save failed) saved as it starts, and with nothing saved the lists' first. A Run that does not
    /// start says why under the scheme.
    fileprivate func runRequested(presentation id: UUID) async -> Bool {
        guard isCurrent(id), !starting, !running, !preparing else { return false }
        preparingID = id
        defer { if preparingID == id { preparingID = nil } }
        if choosesSaved {
            if canRunSaved { return await run(presentation: id, direct: true) }
            // The lists lack it. The kept one may predate a device plugged in since: one fresh look.
            await load(presentation: id, fresh: true)
            if isCurrent(id), canRun { return await run(presentation: id, direct: true) }
        } else if !hasSavedDestination || picked {
            if schemes.isEmpty || simulators.isEmpty { await load(presentation: id, fresh: false) }
            if isCurrent(id), canRun { return await run(presentation: id, direct: false) }
        }
        // A failed load has said why already.
        if isCurrent(id), error == nil { error = notRunnable }
        return false
    }
    private var notRunnable: String {
        if schemes.isEmpty { return String(localized: "The project has no scheme to run.") }
        if hasSavedDestination, !picked, scheme != saved.scheme || !schemes.contains(scheme) {
            return String(localized: "The scheme \(saved.scheme) is not in the project. Choose one in the run destination menu.")
        }
        if simulators.isEmpty { return String(localized: "\(scheme) has no run destination.") }
        return String(localized: "The run destination is not available. Connect it and refresh, or choose another in the run destination menu.")
    }
    /// The chosen destination is not in the lists: the saved one, kept until it is back or another is picked.
    var destinationUnavailable: Bool {
        !simulators.isEmpty && !simulator.isEmpty && !simulators.contains { $0.udid == simulator }
    }
    /// A scheme picked in the run destination menu, saved at once with the destination it runs on.
    func choose(scheme: String) async {
        guard valid, presentationID == nil, !starting else { return }
        picked = true
        if scheme != self.scheme {
            self.scheme = scheme
            // Saved at once on the lists already known; the fresh look below only corrects it.
            if let cached = Self.cachedDestinations[cacheKey(scheme)] { apply(cached); await saveChoice() }
            // Another scheme runs on other destinations; the list it loads picks one if this one is not there.
            await loadDestinations()
        }
        await saveChoice()
    }
    /// A destination picked in the run destination menu, saved at once.
    func choose(simulator: String) async {
        guard valid, presentationID == nil, !starting else { return }
        self.simulator = simulator; picked = true
        await saveChoice()
    }
    /// Also when the pick is what was already on screen: the lists may have put it there unsaved.
    private func saveChoice() async {
        let scheme = scheme, simulator = simulator
        guard valid, presentationID == nil, schemes.contains(scheme),
              simulators.contains(where: { $0.udid == simulator }) else { return }
        // A valid pick answers what the last Run said, the saved one included.
        error = nil
        // Back to the saved pair while another pick is still being saved: that save would win, so
        // this one is saved too.
        guard !choosesSaved || savesInFlight > 0 else { picked = false; return }
        do { try await saveDestination(scheme: scheme, simulator: simulator) }
        catch { if valid { self.error = error.localizedDescription } }
    }
    func stop() async {
        guard valid, running else { return }
        do { try await terminal?.interrupt() }
        catch { if valid { self.error = error.localizedDescription } }
    }
    func disconnect() {
        valid = false; presentationID = nil; preparingID = nil; loadGeneration = UUID(); monitorGeneration = UUID()
        monitor = nil; terminal?.close(); terminal = nil; running = false; launched = false; loading = false
        preview?.retire(); onSimulatorRun = nil
    }
}

/// One model per Run; retiring it leaves the cached build and its PTY running. While it lives the
/// build is its presentation: the run destination menu neither loads nor picks over it.
@MainActor final class BuildDestinationViewModel {
    private let runtime: BuildWorkspaceViewModel
    private let id = UUID()
    private(set) var retired = false

    init(runtime: BuildWorkspaceViewModel) {
        self.runtime = runtime
        retired = !runtime.beginPresentation(id)
    }
    private var active: Bool { !retired && runtime.isCurrent(id) }
    /// What Run does: see `BuildWorkspaceViewModel.runRequested`. False when it did not start.
    @discardableResult func start() async -> Bool {
        guard active, await runtime.runRequested(presentation: id), active else { return false }
        retire()
        return true
    }
    func retire() {
        retired = true
        runtime.endPresentation(id)
    }
}
