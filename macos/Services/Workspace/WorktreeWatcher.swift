import CoreServices
import Foundation

/// Something watching a worktree for changes; `stop` ends it, and so does releasing it.
@MainActor protocol ChangeWatching: AnyObject { func stop() }

/// Watches a worktree through FSEvents, with the git directories that change what its diff shows: a
/// linked worktree's own (its `.git` file names it) and the repository's common one, where branch refs
/// live. Changes arrive coalesced, at most once per `latency`, on the main queue: a save, an agent's
/// edit, a commit, a checkout or a push made anywhere — the terminal included — tells the diff to look
/// again, so it never needs a Refresh button.
///
/// What cannot change the diff is let through quietly: build output and dependency folders, and inside
/// a git directory everything but the index, `HEAD` and the refs.
@MainActor final class WorktreeWatcher: ChangeWatching {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void
    private let filter: Filter

    /// Nil when the worktree is not on this Mac (a backend elsewhere) or the stream cannot start; the
    /// diff then polls instead (`PollingWatcher`).
    init?(worktree: String, latency: TimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: worktree, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        self.onChange = onChange
        filter = Filter(worktree: worktree)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            MainActor.assumeIsolated {
                if count > 0, changed.contains(where: watcher.filter.matters) { watcher.onChange() }
            }
        }
        let flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(nil, callback, &context, filter.roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(flags))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit { stop() }

    /// Which reported paths can change the worktree's diff.
    struct Filter: Sendable {
        let worktree: String
        /// The git directories outside the worktree: a linked worktree's own, and the common one.
        let gitDirectories: [String]
        var roots: [String] { [worktree] + gitDirectories }

        /// Folders whose contents are build output or fetched dependencies: never what a diff is about,
        /// and written by the thousand while a build runs.
        static let ignoredFolders: Set<String> = ["node_modules", ".build", "DerivedData", "target", ".swiftpm",
                                                  "__pycache__", ".venv", ".gradle", "Pods"]

        nonisolated init(worktree: String) {
            // FSEvents reports real paths, `/private/tmp` for `/tmp`: the roots are compared resolved.
            let root = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
            self.worktree = root
            var directories: [String] = []
            if let own = Self.gitDirectory(of: root) {
                directories.append(own)
                if let common = Self.commonDirectory(of: own), common != own { directories.append(common) }
            }
            gitDirectories = directories
        }

        nonisolated func matters(_ path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            for directory in gitDirectories + [worktree + "/.git"] {
                if let inner = Self.relative(path, to: directory) { return Self.gitStateChanged(inner) }
            }
            guard let inner = Self.relative(path, to: worktree) else { return false }
            return !inner.split(separator: "/").contains { Self.ignoredFolders.contains(String($0)) }
        }

        /// Inside a git directory only the index, `HEAD` and the refs say anything about the diff; a
        /// lock file is the write in progress, not its result.
        nonisolated static func gitStateChanged(_ inner: String) -> Bool {
            if inner.isEmpty { return true }
            if inner.hasSuffix(".lock") { return false }
            return inner == "index" || inner == "HEAD" || inner == "packed-refs" || inner.hasPrefix("refs/") || inner == "refs"
        }

        /// The part of `path` under `directory`, "" for the directory itself, nil outside it.
        nonisolated static func relative(_ path: String, to directory: String) -> String? {
            if path == directory { return "" }
            return path.hasPrefix(directory + "/") ? String(path.dropFirst(directory.count + 1)) : nil
        }

        /// A linked worktree's git directory, from the `gitdir:` line of its `.git` file; nil for a
        /// checkout whose `.git` is a folder, which the worktree's own stream already covers.
        nonisolated static func gitDirectory(of worktree: String) -> String? {
            let root = URL(fileURLWithPath: worktree)
            guard let path = firstLine(of: root.appendingPathComponent(".git"), prefix: "gitdir:") else { return nil }
            return resolve(path, against: root)
        }

        /// The repository's common git directory, from a linked worktree's `commondir` file.
        nonisolated static func commonDirectory(of gitDirectory: String) -> String? {
            let root = URL(fileURLWithPath: gitDirectory)
            guard let path = firstLine(of: root.appendingPathComponent("commondir"), prefix: "") else { return nil }
            return resolve(path, against: root)
        }

        private nonisolated static func firstLine(of file: URL, prefix: String) -> String? {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix(prefix) else { return nil }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        private nonisolated static func resolve(_ path: String, against root: URL) -> String {
            (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).resolvingSymlinksInPath().path
        }
    }
}

/// For a worktree FSEvents cannot watch — one on a backend elsewhere, through `--backend-url` — the
/// diff still keeps itself current: it looks again every few seconds while it is on screen.
@MainActor final class PollingWatcher: ChangeWatching {
    private var task: Task<Void, Never>?
    init(every interval: Duration = .seconds(3), onChange: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if !Task.isCancelled { onChange() }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    isolated deinit { stop() }
}
