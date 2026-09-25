import AppKit

/// The app was called TaskHub, then Craft, before it was Cascade. Everything it had stored was
/// filed under those names, so the first launch as Cascade carries it across rather than starting empty.
enum LegacyIdentity {
    /// Every earlier bundle identifier, newest first.
    static let bundleIdentifiers = ["com.alexcding.craft", "com.alexcding.taskhub"]
    /// Every earlier data folder, newest first.
    private static let folders = ["Craft", "TaskHub"]
    /// The durable database under every name it has had. The backend renames the one it finds.
    private static let databases = ["cascade.db", "craft.db", "taskhub.db", "config.db"]

    /// The default data folder. Reading it moves nothing: the old folders are carried by
    /// `carryData`, which the app calls at one point in launch, once it knows it is not yielding.
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cascade")

    /// A copy still running under an old name, which has that data open and can still change it.
    static func runningOldCopy() -> NSRunningApplication? {
        bundleIdentifiers.flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .first { !$0.isTerminated }
    }

    /// Carries each old data folder into the current one, and returns the current one. The app
    /// calls this after deciding not to yield to a running old copy and before the backend opens
    /// anything, so the choice to carry and the choice to yield are the same choice.
    @discardableResult
    static func carryData(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          fileManager: FileManager = .default) -> URL {
        let support = home.appendingPathComponent("Library/Application Support")
        let current = support.appendingPathComponent("Cascade")
        // Newest first: a TaskHub folder that Craft already carried is a link by now, and is skipped.
        for name in folders {
            carry(support.appendingPathComponent(name), into: current, fileManager: fileManager)
        }
        return current
    }

    private static func carry(_ legacy: URL, into current: URL, fileManager: FileManager) {
        func holdsData(_ folder: URL) -> Bool {
            databases.contains { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
        // `attributesOfItem` does not follow links, so the link left by an earlier move is not a folder.
        // The new folder existing proves nothing: a status line or a run with `--data-dir` can have
        // made it. Only a database in it means there is nothing left to carry. A move that fails
        // leaves the old folder untouched and is tried again on the next launch.
        guard (try? fileManager.attributesOfItem(atPath: legacy.path))?[.type] as? FileAttributeType == .typeDirectory,
              holdsData(legacy), !holdsData(current) else { return }
        if !fileManager.fileExists(atPath: current.path) {
            guard (try? fileManager.moveItem(at: legacy, to: current)) != nil else { return }
        } else {
            // Whatever the new folder already has wins; everything else comes across.
            for item in (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
            where !fileManager.fileExists(atPath: current.appendingPathComponent(item).path) {
                try? fileManager.moveItem(at: legacy.appendingPathComponent(item), to: current.appendingPathComponent(item))
            }
            guard (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true,
                  (try? fileManager.removeItem(at: legacy)) != nil else { return }
        }
        try? fileManager.createSymbolicLink(at: legacy, withDestinationURL: current)
    }

    /// Preferences are filed by bundle identifier, so the new identifier starts with none. Copies
    /// the old ones once, never over a value already set under the new name, and the newer name's
    /// value over the older one's. Finding none is not "done": they are looked for again next launch.
    static func carryDefaults(into defaults: UserDefaults = .standard, from domains: [String] = bundleIdentifiers,
                              oldCopyRunning: Bool = runningOldCopy() != nil) {
        let done = "legacyIdentity.defaultsCarried"
        // Runs before the app decides whether to yield, since the model reads preferences as it is
        // built. A running old copy can still change them, so they are carried once it has quit.
        guard !oldCopyRunning, !defaults.bool(forKey: done) else { return }
        let old = domains.compactMap(defaults.persistentDomain(forName:))
        guard !old.isEmpty else { return }
        for domain in old {
            for (key, value) in domain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: done)
    }
}
