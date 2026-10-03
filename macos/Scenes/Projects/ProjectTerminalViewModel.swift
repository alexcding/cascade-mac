import Foundation
import Observation

/// The project's own shell, split under its pages: a terminal for a quick look or a quick command,
/// in the project's checkout or any of its worktrees, that needs no session. Anything longer is a
/// session's work.
///
/// The shell lives while the panel is open. Opening it asks the app for a new one
/// (`requestTerminal`); moving to another worktree asks for one in its place; closing it stops the
/// shell (`closeTerminal`), so a panel nobody has open holds no process, and opening it again is a
/// fresh shell — there is no separate Restart. Switching
/// tabs or projects leaves an open panel's shell running.
@MainActor @Observable final class ProjectTerminalViewModel {
    /// A folder the shell can run in: the project's own, or one of its worktrees.
    struct Location: Equatable, Identifiable {
        let path: String
        /// Nil on a detached HEAD.
        let branch: String?
        /// The project's workspace folder, which may sit inside its checkout rather than be it.
        let isProjectFolder: Bool
        /// `path` with symlinks and trailing slashes resolved, once, for comparing.
        let resolvedPath: String
        /// `resolvedPath` when the caller has already resolved `path`.
        init(path: String, branch: String?, isProjectFolder: Bool, resolvedPath: String? = nil) {
            self.path = path; self.branch = branch; self.isProjectFolder = isProjectFolder
            self.resolvedPath = resolvedPath ?? ProjectTerminalViewModel.resolved(path)
        }
        var id: String { path }
        var title: String { branch ?? (path as NSString).lastPathComponent }
    }

    /// The terminal's own minimum (`TerminalPane`), with the bar above it.
    static let minimumHeight = 280.0
    static let defaultHeight = 320.0
    static let heightKey = "projectTerminalHeight"

    private(set) var shown = false
    /// The panel's height, kept across projects and launches; the view clamps it to the window.
    private(set) var height: Double
    private(set) var terminal: TerminalSession?
    /// Where the shell runs, or the next one will.
    private(set) var directory: String { didSet { resolvedDirectory = Self.resolved(directory) } }
    @ObservationIgnored private var resolvedDirectory: String
    private(set) var locations: [Location] = []
    private(set) var loadingLocations = false
    /// A shell has been asked for and not yet handed back.
    var pending: Bool { request != nil }
    private(set) var error: String?
    private(set) var retired = false
    /// Asks for a new shell in `directory`, in place of any running; the answer comes back
    /// through `attach` or `requestFailed` with the same `request`.
    @ObservationIgnored var requestTerminal: (_ directory: String, _ request: UUID) -> Void = { _, _ in }
    /// Stops the project's shell.
    @ObservationIgnored var closeTerminal: () -> Void = {}
    @ObservationIgnored private var project: Project
    @ObservationIgnored private var operations: (any SessionCreating)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = UUID()
    /// The request outstanding, and the checkout it is for; an answer to any other is stale.
    private var request: UUID?
    @ObservationIgnored private var requestedDirectory: String?
    @ObservationIgnored private var resolvedRequest: String?

    init(project: Project, operations: (any SessionCreating)? = nil, defaults: UserDefaults = .standard) {
        self.project = project
        self.operations = operations
        self.defaults = defaults
        directory = project.workspace
        resolvedDirectory = Self.resolved(project.workspace)
        let stored = defaults.double(forKey: Self.heightKey)
        height = stored > 0 ? max(Self.minimumHeight, stored) : Self.defaultHeight
    }

    /// The location the shell runs in, as the bar names it.
    var location: Location? { locations.first(where: isCurrent) }
    /// Whether the shell runs in `location`, by resolved path: git's paths and the workspace
    /// setting can differ by a symlink or a trailing slash.
    func isCurrent(_ location: Location) -> Bool { location.resolvedPath == resolvedDirectory }
    var locationTitle: String { location?.title ?? (directory as NSString).lastPathComponent }

    func toggle() { setShown(!shown) }

    func setShown(_ value: Bool) {
        guard !retired, value != shown else { return }
        shown = value
        if value {
            ask(for: directory)
            reloadLocations()
        } else {
            request = nil; requestedDirectory = nil; resolvedRequest = nil
            terminal = nil; error = nil
            closeTerminal()
        }
    }

    func resize(to value: Double) {
        guard !retired else { return }
        let value = max(Self.minimumHeight, value)
        guard value != height else { return }
        height = value
        defaults.set(value, forKey: Self.heightKey)
    }

    /// The project came on screen with the panel open: worktrees may have come and gone since.
    func appear() {
        guard !retired, shown else { return }
        reloadLocations()
    }

    /// Moves the shell to another checkout: a new shell there, the old one stopped. The bar names
    /// the new checkout once its shell is there.
    func open(_ location: Location) {
        let target = resolvedRequest ?? resolvedDirectory
        guard !retired, shown, location.resolvedPath != target else { return }
        ask(for: location.path)
    }

    func attach(_ terminal: TerminalSession, request: UUID) {
        guard !retired, shown, request == self.request else { return }
        self.request = nil
        if let requestedDirectory { directory = requestedDirectory }
        requestedDirectory = nil; resolvedRequest = nil
        self.terminal = terminal
    }

    /// The app stops the running shell before anything else can fail, so nothing is left to show.
    func requestFailed(_ message: String, request: UUID) {
        guard !retired, shown, request == self.request else { return }
        self.request = nil; requestedDirectory = nil; resolvedRequest = nil
        terminal = nil
        error = message
    }

    func connect(_ operations: (any SessionCreating)?) {
        guard !retired else { return }
        self.operations = operations
        if operations == nil { generation = UUID(); locations = []; loadingLocations = false }
        else if shown { reloadLocations() }
    }

    /// A new workspace folder takes the shell with it when it ran in the old one; one in a
    /// worktree stays there. Either way the worktrees are the new folder's.
    func update(_ project: Project) {
        guard !retired else { return }
        let old = self.project.workspace
        self.project = project
        guard project.workspace != old else { return }
        locations = []
        if shown { reloadLocations() }
        // The same folder written another way (a trailing slash, a symlink) is no move.
        let oldResolved = Self.resolved(old)
        guard Self.resolved(project.workspace) != oldResolved else { return }
        // Where the shell is going if a move is under way, else where it is: a move to a worktree
        // that has not arrived yet stays the person's choice.
        guard (resolvedRequest ?? resolvedDirectory) == oldResolved else { return }
        if shown { ask(for: project.workspace) } else { directory = project.workspace }
    }

    func dismissError() {
        guard !retired else { return }
        error = nil
    }

    func loadLocations() async {
        guard !retired, let operations else { return }
        let generation = UUID(); self.generation = generation
        loadingLocations = true
        defer { if self.generation == generation { loadingLocations = false } }
        do {
            let refs = try await operations.references(project)
            guard !retired, self.generation == generation else { return }
            let workspace = project.workspace
            let trees = (refs.worktrees ?? []).compactMap { tree in
                tree.path.map { (path: $0, resolved: Self.resolved($0), branch: tree.branch) }
            }
            // The tree holding the workspace folder: the deepest one it is, or sits inside.
            let folder = Self.resolved(workspace)
            let home = trees.filter { folder == $0.resolved || folder.hasPrefix($0.resolved + "/") }
                .max { $0.resolved.count < $1.resolved.count }
            // The workspace folder itself first, so the shell can always go back to it, then the
            // other worktrees by branch.
            let others = trees.filter { $0.resolved != home?.resolved }
                .map { Location(path: $0.path, branch: $0.branch, isProjectFolder: false, resolvedPath: $0.resolved) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            locations = [Location(path: workspace, branch: home?.branch, isProjectFolder: true, resolvedPath: folder)] + others
        } catch {
            if !retired, self.generation == generation { self.error = error.localizedDescription }
        }
    }

    func retire() {
        retired = true
        generation = UUID()
        request = nil
        requestTerminal = { _, _ in }; closeTerminal = {}
        operations = nil
        terminal = nil
    }

    /// The panel's own read of the worktrees, kept so a test can wait for it.
    @ObservationIgnored private(set) var locationsLoad: Task<Void, Never>?
    private func reloadLocations() { locationsLoad = Task { await loadLocations() } }

    nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func ask(for directory: String) {
        let request = UUID()
        self.request = request; requestedDirectory = directory; resolvedRequest = Self.resolved(directory)
        error = nil
        requestTerminal(directory, request)
    }
}
